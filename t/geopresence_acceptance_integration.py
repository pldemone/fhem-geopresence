#!/usr/bin/env python3
"""Exercise the operator application against a private FHEM with dummy devices.

Only this fixture controls FHEM's clock. The installed operator application uses
real waiting, the normal debug commands and HTTP; it cannot advance FHEM's clock.
"""

import argparse
import base64
import datetime
import contextlib
import http.client
import io
import json
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch
from urllib.parse import urlencode

REPO = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(REPO / "tools"))
import geopresence_test as app

STOCK = ("01_FHEMWEB.pm 98_telnet.pm 96_allowed.pm 98_dummy.pm 98_JsonList2.pm 20_ROOMMATE.pm 73_PRESENCE.pm RESIDENTStk.pm "
         "Meta.pm Unit.pm UConv.pm GPUtils.pm RTypes.pm TcpServerUtils.pm HttpUtils.pm "
         "Blocking.pm DevIo.pm SetExtensions.pm AttrTemplate.pm 99_Utils.pm").split()
# Fictional places and synthetic geometry around (0, 0). Work and the
# waypoint are outside the outer circle and provide independent distance evidence.
ZONES = {"Home": ("home", 0.0, 0.0, 50),
         "Wolkenhain": ("outer", 0.0, 0.0, 4500),
         "Work": ("place", 0.10, 0.0, 100),
         "Sternensteg": ("place", 0.07, 0.0, 500)}


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def run(source, real_time=False):
    with tempfile.TemporaryDirectory(prefix="geopresence-acceptance-") as temporary:
        root = Path(temporary)
        (root / "FHEM/FhemUtils").mkdir(parents=True)
        (root / "log").mkdir()
        for name in ("fhem.pl", "MAINTAINER.txt"):
            shutil.copyfile(source / name, root / name)
        for name in STOCK:
            shutil.copyfile(source / "FHEM" / name, root / "FHEM" / name)
        shutil.copyfile(REPO / "FHEM/98_GeoPresence.pm", root / "FHEM/98_GeoPresence.pm")
        ports = set()
        while len(ports) < 3:
            ports.add(free_port())
        telport, httpport, adminport = sorted(ports)
        commands = ["attr global modpath .", "attr global logfile ./log/fhem.log", "attr global nofork 1",
                    "attr global statefile ./log/fhem.save", "attr global autosave 0", "attr global verbose 0",
                    f"define TEL telnet {telport}", f"define WEB FHEMWEB {adminport}",
                    "define rr_Lumo ROOMMATE", "attr rr_Lumo rr_locationUnderway underway"]
        commands += [f"define {name} dummy" for name in ("Phone", "Door", "Contact", "Feedback", "Gate", "GateState", "Upper", "Lower")]
        commands += [f"define {name} PRESENCE event rr_Lumo:FakeAbsent rr_Lumo:FakePresent" for name in ("P1", "P2")]
        commands += ["define System.GeoPresence GeoPresence controller", "set System.GeoPresence mode debug",
                     f"attr System.GeoPresence webhookPort {httpport}", "attr System.GeoPresence logFile ./log/geopresence-%Y-%m.log",
                     "define Geo.Lumo GeoPresence resident System.GeoPresence rr_Lumo", "set Geo.Lumo mode debug",
                     "attr Geo.Lumo deviceId test-phone", "attr Geo.Lumo webhookUser test-user",
                     "attr Geo.Lumo phoneProxies P1,P2", "attr Geo.Lumo allowDoor 1", "attr Geo.Lumo allowGarage 1"]
        for name, zone in ZONES.items():
            commands += [f"define Geo.Lumo.{name} GeoPresence location Geo.Lumo {zone[0]}", f"attr Geo.Lumo.{name} zoneId {name}"]
        commands += ["attr Geo.Lumo.Work groups Work"]
        commands += ["define A.Door GeoPresence action System.GeoPresence door_open", "attr A.Door target Door",
                     "attr A.Door command lock unlocked", "attr A.Door contact Contact", "attr A.Door feedbackDevice Feedback",
                     "define A.Gate GeoPresence action System.GeoPresence garage_open", "attr A.Gate target Gate",
                     "attr A.Gate command on", "attr A.Gate stateDevice GateState", "attr A.Gate upperContact Upper", "attr A.Gate lowerContact Lower"]
        for action in ("Enter", "Exit", "Route"):
            commands += [f"define A.{action} GeoPresence action System.GeoPresence notify", f"attr A.{action} message Test {action}"]
        rules = {"Door": ("arrival", "A.Door", []), "Gate": ("arrival", "A.Gate", ["arrivalFilter vehicle"]),
                 "Enter": ("enter", "A.Enter", ["locationGroup Work"]), "Exit": ("exit", "A.Exit", ["locationGroup Work"]),
                 "Route": ("exit", "A.Route", ["locations Geo.Lumo.Sternensteg", "afterExit group:Work"])}
        for name, (trigger, action, attrs) in rules.items():
            commands += [f"define R.{name} GeoPresence rule System.GeoPresence", f"attr R.{name} residents Geo.Lumo",
                         f"attr R.{name} trigger {trigger}", f"attr R.{name} action {action}"]
            commands += [f"attr R.{name} {value}" for value in attrs]
        (root / "fhem.cfg").write_text("\n".join(commands) + "\n")
        with (root / "process.log").open("w") as process_log:
            process = subprocess.Popen(["perl", "fhem.pl", "fhem.cfg"], cwd=root, stdout=process_log, stderr=subprocess.STDOUT)
        tail = None
        telnet = app.Telnet(port=telport)
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise AssertionError((root / "process.log").read_text())
                try:
                    telnet.command("list System.GeoPresence")
                    break
                except OSError:
                    time.sleep(0.1)
            else:
                raise AssertionError("Private FHEM did not start")
            telnet.command("{ no warnings 'redefine';; *pushMsg=sub { die 'Unexpected real notification' };; return 'test notification trap set' }")
            if not real_time:
                telnet.command("{ no warnings 'redefine';; $main::GP_test_offset=0;; "
                               "*GP_Now=sub { Time::HiRes::time()+$main::GP_test_offset };; "
                               "*GP_Mono=sub { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())+$main::GP_test_offset };; "
                               "return 'test clock set' }")

            class FixtureClock:
                ticks = 0

                def wall(self):
                    return float(telnet.command("{ GP_Now() }"))

                def monotonic(self):
                    return self.ticks

                def sleep(self, seconds):
                    self.ticks += seconds
                    telnet.command(f"{{ $main::GP_test_offset+={seconds};; GeoPresence_Timer($defs{{'System.GeoPresence'}});; return 'ticked' }}")

            clock = app.Clock() if real_time else FixtureClock()
            password = secrets.token_urlsafe(24)
            password_result = telnet.command(f"set Geo.Lumo webhookPassword {password}")
            assert "password stored" in password_result, (password_result.replace(password, "[redacted]") + "\n" +
                (root / "process.log").read_text() + "\n" + (root / "log/fhem.log").read_text())
            clock.sleep(32)
            assert telnet.command("get System.GeoPresence validate").startswith("OK:"), telnet.command("get System.GeoPresence validate")
            assert "Learning for" in telnet.command("set Geo.Lumo mode learning")
            authorization = "Basic " + base64.b64encode(("test-user:" + password).encode()).decode()
            for name, (_, lat, lon, radius) in ZONES.items():
                payload = {"device": "test-phone", "id": name, "name": name, "entry": 1, "isTest": "true",
                           "date": datetime.datetime.fromtimestamp(clock.wall(), datetime.timezone.utc).isoformat(),
                           "latitude": lat, "longitude": lon, "radius": radius}
                connection = http.client.HTTPConnection("127.0.0.1", httpport, timeout=5)
                connection.request("POST", "/fhem/geopresence", urlencode(payload),
                                   {"Content-Type": "application/x-www-form-urlencoded", "Authorization": authorization})
                response = connection.getresponse()
                assert response.status == 200 and b"learning captured" in response.read()
                connection.close()
                clock.sleep(1)
            telnet.command("set Geo.Lumo learnConfirm")
            telnet.command("set Geo.Lumo mode debug")
            profile = app.Profile(telnet, "System.GeoPresence", "Geo.Lumo", app.COMBINED_TESTS)
            assert profile.rules["work_exit"] == ("notify", "R.Exit")
            url = f"http://127.0.0.1:{httpport}/fhem/geopresence"
            webhook = app.Webhook(url, profile.user, password, profile.webhook_path)
            tail = app.LogTail(str(root / "log/geopresence-%Y-%m.log"), clock)
            runner = app.Runner(profile, webhook, tail, clock=clock, output=lambda line: None)
            before = telnet.command("{ ReadingsVal('rr_Lumo','state','unknown') }")
            if real_time:
                # Confirm the real ten-second GPS gaps and 180-second phone
                # qualification with normal FHEM timers, without a test clock.
                runner.output = lambda line: print(line, flush=True)
                runner.run_case(4)
                assert telnet.command("{ ReadingsVal('rr_Lumo','state','unknown') }") == before
                assert telnet.command("{ ReadingsVal('Door','state','untouched') }") == "untouched"
                assert telnet.command("{ ReadingsVal('Gate','state','untouched') }") == "untouched"
                runner.cleanup()
                print("PASS: real-time GPS and walk with ordinary FHEM timers", flush=True)
                return
            for number in app.COMBINED_TESTS:
                try:
                    runner.run_case(number)
                except Exception:
                    (Path("/tmp") / "geopresence-acceptance-failure.json").write_text(json.dumps(runner.results, indent=2))
                    print(json.dumps({"pending": list(runner.receipts.items()), "last_rows": runner.rows[-4:]}, indent=2))
                    raise
                print(f"PASS: scenario {number} – {app.SCENARIOS[number]}", flush=True)
            assert telnet.command("{ ReadingsVal('rr_Lumo','state','unknown') }") == before
            assert telnet.command("{ ReadingsVal('Door','state','untouched') }") == "untouched"
            assert telnet.command("{ ReadingsVal('Gate','state','untouched') }") == "untouched"
            geometry = telnet.json("get System.GeoPresence explain Geo.Lumo debug format=json")["geometry"]
            # Operator regression: only Home/outer have saved geometry. There
            # is no learning list to conceal loss of the two debug-only places.
            for name in ("Home", "Wolkenhain"):
                telnet.command(f"setreading Geo.Lumo.{name} gp_geometry " + json.dumps(
                    geometry["Geo.Lumo." + name], separators=(",", ":")))
            telnet.command("set Geo.Lumo mode learning")
            telnet.command("set Geo.Lumo mode disabled")
            telnet.command("set Geo.Lumo mode debug")
            assert "No current learning data" in telnet.command("get System.GeoPresence learnedLocations Geo.Lumo format=json")
            assert telnet.command("set System.GeoPresence mode active") == ""
            clock.sleep(32)
            capture = app.Runner(profile, webhook, None, clock=clock, output=lambda line: None)
            for name in ("Sternensteg", "Work"):
                capture.send(profile.locations["Geo.Lumo." + name], 1)
                clock.sleep(8)
            tail.read()

            def geometry_still_available():
                view = telnet.json("get System.GeoPresence explain Geo.Lumo debug format=json")
                assert set(view["geometry"]) == {"Geo.Lumo." + name for name in ZONES}
                assert all(value.get("radius", 0) > 0 and not value.get("blocked")
                           for value in view["geometry"].values())
                assert not view["state"].get("trip") and not view["state"].get("arrival")
                assert not view["state"].get("intents")
                for name in ("Sternensteg", "Work"):
                    assert telnet.command(f"{{ ReadingsVal('Geo.Lumo.{name}','gp_geometry','missing') }}") == "missing"
                assert telnet.command("{ ReadingsVal('rr_Lumo','state','unknown') }") == before
                assert telnet.command("{ ReadingsVal('Door','state','untouched') }") == "untouched"
                assert telnet.command("{ ReadingsVal('Gate','state','untouched') }") == "untouched"

            for attempt in (1, 2):
                repeat_report = root / f"walk-repeat-{attempt}.json"
                repeat_argv = ["geopresence_test.py", "--tests", "3", "--resident", "Geo.Lumo", "--url", url,
                               "--log", str(root / "log/geopresence-%Y-%m.log"), "--telnet-port", str(telport),
                               "--report", str(repeat_report)]
                with patch.object(sys, "argv", repeat_argv), patch.object(app, "Clock", return_value=clock), \
                        patch.object(app.getpass, "getpass", return_value=password), contextlib.redirect_stdout(io.StringIO()):
                    assert app.main() == 0
                assert json.loads(repeat_report.read_text())["passed"]
                geometry_still_available()
                print(f"PASS: separate walk invocation {attempt} retains debug-only place geometry without learning", flush=True)
            for name, error, expected_code in (("interrupted", KeyboardInterrupt, 130),
                                               ("failed", app.TestFailure("Test interruption fixture"), 1)):
                failure_report = root / f"geometry-{name}.json"
                failure_argv = repeat_argv[:-1] + [str(failure_report)]
                with patch.object(sys, "argv", failure_argv), patch.object(app, "Clock", return_value=clock), \
                        patch.object(app.getpass, "getpass", return_value=password), \
                        patch.object(app.Runner, "wait", side_effect=error), \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    assert app.main() == expected_code
                geometry_still_available()
                app.Profile(telnet, "System.GeoPresence", "Geo.Lumo", [3])
                print(f"PASS: {name} walk retains geometry and permits another invocation", flush=True)
            tail.read()
            # Reproduce the mode-transition gap, then confirm metadata through
            # the operator command. A test webhook alone never writes readings.
            assert telnet.command("set Geo.Lumo mode active") == ""
            active_view = telnet.json("get System.GeoPresence explain Geo.Lumo debug format=json")
            assert not active_view["geometry"]["Geo.Lumo.Sternensteg"]
            assert telnet.json("get System.GeoPresence validate Geo.Lumo format=json")["warnings"]
            assert telnet.command("set Geo.Lumo mode debug") == ""
            for name in ("Sternensteg", "Work"):
                assert telnet.command(f"attr Geo.Lumo.{name} userReadings callback:gp_geometry.* {{ ++$main::GP_geometry_callbacks }}") == ""
                assert telnet.command(f"attr Geo.Lumo.{name} stateFormat {{ ++$main::GP_geometry_callbacks;; return 'geometry' }}") == ""
            clock.sleep(32)
            for name in ("Sternensteg", "Work"):
                capture.send(profile.locations["Geo.Lumo." + name], 1)
                clock.sleep(8)
            callbacks_before = telnet.command("{ $main::GP_geometry_callbacks//0 }")
            assert telnet.command("set System.GeoPresence applyGeometry Geo.Lumo").startswith("Geometry applied for 2 location(s)")
            assert telnet.command("{ $main::GP_geometry_callbacks//0 }") == callbacks_before
            assert telnet.command("{ ReadingsVal('rr_Lumo','state','unknown') }") == before
            assert telnet.command("{ ReadingsVal('Door','state','untouched') }") == "untouched"
            assert telnet.command("{ ReadingsVal('Gate','state','untouched') }") == "untouched"
            assert telnet.command("set Geo.Lumo mode active") == ""
            assert not telnet.json("get System.GeoPresence validate Geo.Lumo format=json")["warnings"]
            for pool in ("production", "debug"):
                confirmed = telnet.json(f"get System.GeoPresence explain Geo.Lumo {('prod' if pool == 'production' else 'debug')} format=json")["geometry"]
                assert all(value.get("radius", 0) > 0 for value in confirmed.values())
                assert len(confirmed) == len(ZONES)
            saved = telnet.command("save")
            assert saved.startswith("Wrote configuration to "), saved
            statefile = (root / "log/fhem.save").read_text()
            assert "Geo.Lumo.Sternensteg" in statefile and "gp_geometry" in statefile
            telnet.command("reload 98_GeoPresence.pm")
            for pool in ("production", "debug"):
                reloaded = telnet.json(f"get System.GeoPresence explain Geo.Lumo {('prod' if pool == 'production' else 'debug')} format=json")
                assert reloaded["geometry"]["Geo.Lumo.Sternensteg"]["radius"] == 500
                assert not reloaded["state"].get("trip") and not reloaded["state"].get("arrival")
            # reload reinstates the real clock; continue the accelerated fixture
            # at its previous observation time, never in the installed program.
            if not real_time:
                telnet.command("{ no warnings 'redefine';; "
                               "*GP_Now=sub { Time::HiRes::time()+$main::GP_test_offset };; "
                               "*GP_Mono=sub { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())+$main::GP_test_offset };; "
                               "return 'test clock restored' }")
            assert telnet.command("set Geo.Lumo mode debug") == ""
            for name in ("Sternensteg", "Work"):
                assert telnet.command(f"deleteattr Geo.Lumo.{name} userReadings") == ""
                assert telnet.command(f"deleteattr Geo.Lumo.{name} stateFormat") == ""
            print("PASS: explicit geometry confirmation survives activation/save/reload without callbacks, actions or trips", flush=True)
            tail.read()
            assert telnet.command("set System.GeoPresence mode debug") == ""
            clock.sleep(32)
            runner.cleanup()
            assert telnet.json("get System.GeoPresence explain Geo.Lumo debug format=json")["state"].get("trip") is None
            # Persisted geometry must not generate preparatory departures or
            # consume WorkExit cooldowns. Repeat the complete operator paths.
            runner = app.Runner(profile, webhook, tail, clock=clock, output=lambda line: None)
            for number in app.COMBINED_TESTS:
                runner.run_case(number)
                print(f"PASS: scenario {number} with saved geometry", flush=True)
            runner.cleanup()
            assert telnet.command("set System.GeoPresence mode active") == ""
            clock.sleep(32)
            active_profile = app.Profile(telnet, "System.GeoPresence", "Geo.Lumo", [3])
            active_runner = app.Runner(active_profile, webhook, tail, clock=clock, output=lambda line: None)
            active_runner.run_case(3)
            active_runner.cleanup()
            assert telnet.command("set System.GeoPresence mode debug") == ""
            clock.sleep(32)
            print("PASS: resident debug under an active controller", flush=True)
            argv = ["geopresence_test.py", "--tests", "8", "--resident", "Geo.Lumo", "--url", url, "--log", str(root / "log/geopresence-%Y-%m.log"),
                    "--telnet-port", str(telport)]
            with patch.object(sys, "argv", argv), patch.object(app, "Clock", return_value=clock), \
                    patch.object(app, "DEFAULT_REPORT_DIR", root / "private/reports"), \
                    patch.object(app.getpass, "getpass", return_value=password), contextlib.redirect_stdout(io.StringIO()):
                assert app.main() == 0
            reports = list((root / "private/reports").glob("geopresence-test-*.json"))
            assert len(reports) == 1, reports
            report = reports[0]
            data = json.loads(report.read_text())
            assert data["passed"] and len(data["results"]) == 1
            assert password not in report.read_text()
            assert report.stat().st_mode & 0o777 == 0o600
            assert (root / "private").stat().st_mode & 0o777 == 0o700
            assert report.parent.stat().st_mode & 0o777 == 0o700
            print("PASS: CLI, hidden password input and private report without credentials", flush=True)
            tail.read()  # The CLI used its own log cursor for its independent run.
            assert telnet.command("attr Geo.Lumo allowGarage 0") == ""
            clock.sleep(32)
            try:
                app.Profile(telnet, "System.GeoPresence", "Geo.Lumo", [9])
            except app.TestFailure as error:
                assert "allowGarage" in str(error)
            else:
                raise AssertionError("Wrong Lumo garage permission silently weakened expectations")
            door_profile = app.Profile(telnet, "System.GeoPresence", "Geo.Lumo", [9], door_only=True)
            door_runner = app.Runner(door_profile, webhook, tail, clock=clock, output=lambda line: None)
            door_runner.run_case(9)
            door_runner.cleanup()
            assert telnet.command("attr Geo.Lumo allowGarage 1") == ""
            clock.sleep(32)
            print("PASS: explicit door-only expectation and rejected wrong garage permission", flush=True)
            abort_report = root / "aborted-report.json"
            abort_argv = argv + ["--report", str(abort_report)]
            with patch.object(sys, "argv", abort_argv), patch.object(app, "Clock", return_value=clock), \
                    patch.object(app.getpass, "getpass", return_value=password), \
                    patch.object(app.Runner, "wait", side_effect=KeyboardInterrupt), \
                    contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                assert app.main() == 130
            aborted = json.loads(abort_report.read_text())
            assert not aborted["passed"] and "abgebrochen" in aborted["error"]
            assert telnet.json("get System.GeoPresence explain Geo.Lumo debug format=json")["state"]["phone_mode"] == "live"
            tail.read()
            print("PASS: interruption saves its result and restores phone mode", flush=True)
            # A broken route rule must fail the actual outward journey, not be
            # accepted by deriving all expected outputs from the same config.
            telnet.command("deleteattr R.Route afterExit")
            clock.sleep(32)
            runner = app.Runner(profile, webhook, tail, clock=clock, output=lambda line: None)
            try:
                runner.run_case(1)
            except app.TestFailure as error:
                assert "Aktionspläne stimmen nicht" in str(error), str(error)
                assert runner.results[-1]["steps"][-1]["step"].startswith("Rückweg-Ort verlassen")
            else:
                raise AssertionError("Wrong outward notification was not detected")
            runner.cleanup()
            print("PASS: unexpected route notification fails at its actual log step; real outputs unchanged", flush=True)
            # The same real-log runner now supports a source profile with no phone.
            assert telnet.command("attr R.Route afterExit group:Work") == ""
            # Two overlapping places must remain one group even after the display
            # infers that a distant waypoint superseded one member's position.
            assert telnet.command("define Geo.Lumo.Work2 GeoPresence location Geo.Lumo place") == ""
            assert telnet.command("attr Geo.Lumo.Work2 zoneId Work2") == ""
            assert telnet.command("attr Geo.Lumo.Work2 groups Work") == ""
            second_geometry = json.loads(telnet.command("{ ReadingsVal('Geo.Lumo.Work','gp_geometry','{}') }"))
            second_geometry.update(id="work2", lat=second_geometry["lat"] + 0.0002)
            telnet.command("setreading Geo.Lumo.Work2 gp_geometry " + json.dumps(second_geometry, separators=(",", ":")))
            clock.sleep(32)
            assert telnet.command("get System.GeoPresence validate").startswith("OK:")
            telnet.command("set System.GeoPresence debugReset Geo.Lumo")
            telnet.command("set System.GeoPresence debugPhoneMode Geo.Lumo simulated")
            telnet.command("set System.GeoPresence debugPhone Geo.Lumo absent")
            clock.sleep(1)
            capture = app.Runner(profile, webhook, tail, clock=clock, output=lambda line: None)
            capture.collect()

            def group_event(name, entry):
                geometry = second_geometry if name == "Work2" else dict(zip(("lat", "lon", "radius"), ZONES[name][1:]))
                before_rows = len(capture.rows)
                capture.send(app.Location("Geo.Lumo." + name, "place", name, geometry), entry)
                clock.sleep(5)
                capture.collect()
                return [row["rule"] for row in capture.rows[before_rows:]
                        if row.get("reason") == "would execute; debug suppressed"]

            assert group_event("Home", 0) == []
            assert group_event("Work", 1) == ["R.Enter"]
            assert group_event("Work2", 1) == []
            assert group_event("Work", 0) == []
            assert group_event("Sternensteg", 1) == []
            assert group_event("Sternensteg", 0) == []
            assert group_event("Work2", 0) == ["R.Exit"]
            assert group_event("Sternensteg", 0) == ["R.Route"]
            assert group_event("Work2", 1) == []  # Existing message cooldown still applies.
            assert group_event("Sternensteg", 0) == []
            assert any(row.get("reason") == "required prior exit not observed in this trip" for row in capture.rows[-5:])
            assert telnet.command("{ ReadingsVal('Door','state','untouched') }") == "untouched"
            telnet.command("delete Geo.Lumo.Work2")
            print("PASS: overlapping places, explicit group exit and revoked route evidence over real HTTP/logs", flush=True)
            for text in ("attr Geo.Lumo sourceMode geofency_only", "deleteattr Geo.Lumo phoneProxies"):
                assert telnet.command(text) == ""
            clock.sleep(32)
            geo_profile = app.Profile(telnet, "System.GeoPresence", "Geo.Lumo", None)
            assert geo_profile.tests == app.GEO_TESTS and not geo_profile.phone
            geo_runner = app.Runner(geo_profile, webhook, tail, clock=clock, output=lambda line: None)
            for number in geo_profile.tests:
                geo_runner.run_case(number)
                print(f"PASS: geo-only scenario {number} with real HTTP and diagnostic log", flush=True)
            geo_runner.cleanup()
            # Reuse a known distant waypoint as a checkpoint for the isolated walk.
            assert telnet.command("attr R.Route enabled 0") == ""
            assert telnet.command("delete Geo.Lumo.Sternensteg") == ""
            assert telnet.command("define Geo.Lumo.Sternensteg GeoPresence location Geo.Lumo place") == ""
            assert telnet.command("attr Geo.Lumo.Sternensteg zoneId Sternensteg") == ""
            clock.sleep(32)
            # Recreating a location also deletes its saved geometry; this
            # fixture deliberately no longer has a learning list as a fallback.
            capture = app.Runner(geo_profile, webhook, None, clock=clock, output=lambda line: None)
            capture.send(geo_profile.locations["Geo.Lumo.Sternensteg"], 1)
            clock.sleep(8)
            tail.read()
            helper_profile = app.Profile(telnet, "System.GeoPresence", "Geo.Lumo", [17], checkpoint="Geo.Lumo.Sternensteg")
            helper_runner = app.Runner(helper_profile, webhook, tail, clock=clock, output=lambda line: None)
            helper_runner.run_case(17)
            helper_runner.cleanup()
            assert telnet.command("{ ReadingsVal('Door','state','untouched') }") == "untouched"
            assert telnet.command("{ ReadingsVal('Gate','state','untouched') }") == "untouched"
            assert telnet.json("get System.GeoPresence explain Geo.Lumo debug format=json")["state"]["phone"]["state"] == "disabled"
            print("PASS: geo-only helper walk and cleanup without simulated phone or productive output", flush=True)
            assert telnet.command("define AllowedTest allowed") == ""
            assert telnet.command("attr AllowedTest validFor TEL") == ""
            telnet_secret = secrets.token_urlsafe(24)
            telnet.command(f"set AllowedTest password {telnet_secret}")
            secured_telnet = app.Telnet(port=telport, password=telnet_secret)
            assert app.devices(secured_telnet)["Geo.Lumo"]["Internals"]["SUBTYPE"] == "resident"
            print("PASS: optional local Telnet password authentication", flush=True)
        finally:
            if tail:
                tail.close()
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--fhem-dir", type=Path, required=True)
    parser.add_argument("--real-time", action="store_true", help="Run the GPS/walk case with real waits and untouched FHEM clocks")
    args = parser.parse_args()
    run(args.fhem_dir.resolve(), args.real_time)
