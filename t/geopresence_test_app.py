#!/usr/bin/env python3
"""Failure modes of the operator's log verifier, without a running FHEM."""

import json
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
from urllib.parse import parse_qs

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import geopresence_test as app


class Clock:
    ticks = 0

    def wall(self):
        return 1789640000 + self.ticks

    def monotonic(self):
        return self.ticks

    def sleep(self, seconds):
        self.ticks += seconds


class LogTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "test.log"
        self.path.write_text("old expected output\n")
        self.clock = Clock()
        self.tail = app.LogTail(str(self.path), self.clock)
        self.addCleanup(self.tail.close)

    def append(self, text):
        with self.path.open("ab") as output:
            output.write(text if isinstance(text, bytes) else text.encode())

    def test_only_complete_new_utf8_lines(self):
        self.assertEqual(self.tail.read(), [])
        self.append(b"New J\xc3")
        self.assertEqual(self.tail.read(), [])
        self.append(b"\xb6rg\n")
        self.assertEqual(self.tail.read(), ["New Jörg"])

    def test_rotation_reads_old_tail_and_new_file(self):
        self.append("before rotation\n")
        self.path.rename(self.path.with_suffix(".old"))
        self.path.write_text("after rotation\n")
        self.assertEqual(self.tail.read(), ["before rotation", "after rotation"])

    def test_truncation_fails_instead_of_passing_with_missing_events(self):
        self.path.write_text("")
        with self.assertRaisesRegex(app.TestFailure, "gekürzt"):
            self.tail.read()

    def runner(self):
        profile = SimpleNamespace(controller="GP", resident="Geo.Test", settle=1,
                                  guard=lambda: None, telnet=SimpleNamespace(json=lambda _: {"view": "debug", "debug_ready": 1, "state": {"phase": "home"}}))
        runner = app.Runner(profile, None, self.tail, clock=self.clock, output=lambda _: None)
        runner.results.append({"steps": []})
        return runner

    def row(self, event, **data):
        self.append("2026-09-17 12:00:00 4: GP GeoPresence " + event + " " +
                    json.dumps(dict(resident="Geo.Test", mode="debug", **data)) + "\n")

    def test_http_receipt_is_not_a_processed_event(self):
        runner = self.runner()

        def request():
            key = ("Home", 1, 10.0)
            runner.receipts[key] += 1
            runner.current["webhooks"] = [key]
            self.row("http", zone="Home", entry="1", observed="10", status="200", reason="OK debug accepted; no actions")

        with self.assertRaisesRegex(app.TestFailure, "ohne fachliche Auswertung"):
            runner.step("Home", request)

    def test_exact_counts_reject_an_additional_action(self):
        runner = self.runner()

        def duplicate_plans():
            for _ in range(2):
                self.row("decision", reason=app.PLAN, kind="door_open", rule="Door")

        with self.assertRaisesRegex(app.TestFailure, "Aktionspläne stimmen nicht"):
            runner.step("Home", duplicate_plans, [("door_open", "Door")])

    def test_rejected_geo_event_is_not_a_successful_silent_step(self):
        runner = self.runner()

        def rejected():
            key = ("Home", 1, 10.0)
            runner.receipts[key] += 1
            runner.current["webhooks"] = [key]
            self.row("http", zone="Home", entry=1, observed=10, status=200, reason="OK debug accepted; no actions")
            self.row("decision", zone="Home", entry=1, observed=10, source="geo", reason="observation received")
            self.row("decision", observed=10, reason="event too old or future")

        with self.assertRaisesRegex(app.TestFailure, "Kein erwarteter Abschluss"):
            runner.step("Home", rejected)

    def test_silent_step_rejects_notification(self):
        runner = self.runner()
        with self.assertRaisesRegex(app.TestFailure, "Aktionspläne stimmen nicht"):
            runner.step("Outward route", lambda: self.row("decision", reason=app.PLAN, kind="notify", rule="Route"))

    def test_log_limit_and_foreign_requests_fail(self):
        runner = self.runner()
        self.row("log_rate_limit", reason="Further log entries suppressed for this minute")
        with self.assertRaisesRegex(app.TestFailure, "begrenzt"):
            runner.collect()
        self.row("http", zone="Home", entry="1", observed="10", status="200", reason="OK debug accepted; no actions")
        with self.assertRaisesRegex(app.TestFailure, "Fremder"):
            runner.collect()

    def test_production_output_is_never_accepted_as_a_debug_success(self):
        runner = self.runner()
        self.row("decision", reason="actor command dispatched", kind="door_open", rule="Door")
        with self.assertRaisesRegex(app.TestFailure, "Produktive Verarbeitung"):
            runner.collect()


class RequestTests(unittest.TestCase):
    def test_password_does_not_fall_back_to_echo(self):
        with patch.object(app.getpass, "getpass", side_effect=app.getpass.GetPassWarning), \
                self.assertRaisesRegex(app.TestFailure, "verdeckt"):
            app.password_prompt("Password: ")

    def test_only_exact_webhook_url(self):
        path = "/fhem/geopresence"
        for url in ("https://example.test/fhem/geopresence/debug", "https://example.test/fhem/geopresence?cmd=set",
                    "https://user:secret@example.test" + path, "http://example.test" + path):
            with self.subTest(url=url), self.assertRaises(app.TestFailure):
                app.Webhook(url, "user", "secret", path)

    def test_sender_refuses_missing_false_or_ambiguous_test_flag_before_connecting(self):
        webhook = app.Webhook("https://example.test/fhem/geopresence", "user", "secret", "/fhem/geopresence")
        with patch.object(app.http.client, "HTTPSConnection") as connect:
            for body in (b"entry=1", b"isTest=false", b"isTest=true&isTest=false", b"isTest=", b"istest=true",
                         b"isTest=true&istest=false", b"isTest=true%0A", b"isTest=1"):
                with self.subTest(body=body), self.assertRaises(app.TestFailure):
                    webhook.send(body)
            connect.assert_not_called()

    def test_sender_uses_single_url_and_requires_simulation_response(self):
        webhook = app.Webhook("https://example.test/fhem/geopresence", "user", "secret", "/fhem/geopresence")
        with patch.object(app.http.client, "HTTPSConnection") as connect:
            response = connect.return_value.getresponse.return_value
            response.status = 200
            response.read.return_value = b"OK debug accepted; no actions"
            webhook.send(b"isTest=true&entry=1")
            args = connect.return_value.request.call_args.args
            self.assertEqual(args[:2], ("POST", "/fhem/geopresence"))
            self.assertEqual(parse_qs(args[2].decode())["isTest"], ["true"])
            response.read.return_value = b"OK accepted in current FHEM session"
            with self.assertRaises(app.TestFailure):
                webhook.send(b"isTest=true&entry=1")

    def test_runner_marks_new_events_and_preserves_marker_on_retries(self):
        profile = SimpleNamespace(device_id="phone")
        webhook = Mock()
        runner = app.Runner(profile, webhook, None, clock=Clock())
        zone = SimpleNamespace(device="Home", zone_id="home", geometry=dict(lat=49, lon=8, radius=50))
        body = runner.send(zone, 1)
        self.assertEqual(parse_qs(body.decode())["isTest"], ["true"])
        self.assertEqual(runner.send(zone, 1, body=body), body)
        self.assertEqual(webhook.send.call_count, 2)

    def test_guard_refuses_a_module_without_test_isolation(self):
        profile = object.__new__(app.Profile)
        profile.controller = "GP"
        profile.resident = "Geo.Test"
        profile.controller_mode = "active"
        profile.source_mode = "geofency_phone"
        profile.telnet = Mock()
        current = {"GP": {"Readings": {"mode": {"Value": "active"}}},
                   "Geo.Test": {"Readings": {"mode": {"Value": "debug"}}}}
        with patch.object(app, "devices", return_value=current):
            for state in ({}, {"test_webhook_isolation": 0}):
                profile.telnet.json.return_value = {"view": "debug", "state": {}, **state}
                with self.assertRaisesRegex(app.TestFailure, "Modul aktualisieren"):
                    profile.guard()
            profile.telnet.json.return_value = {"view": "debug", "state": {}, "test_webhook_isolation": 1}
            with self.assertRaisesRegex(app.TestFailure, "Geometrie beim Test-Reset"):
                profile.guard()
            profile.telnet.json.return_value["debug_reset_keep_geometry"] = 1
            profile.guard()
            profile.telnet.json.return_value["state"] = {"debug_offset": 180}
            with self.assertRaisesRegex(app.TestFailure, "debugAdvance"):
                profile.guard()
            profile.telnet.command.assert_not_called()

    def test_command_transport_is_local(self):
        with self.assertRaises(app.TestFailure):
            app.Telnet(host="example.test")

    def test_source_profiles_select_applicable_tests(self):
        self.assertIsNone(app.selected_tests("all"))
        self.assertEqual(app.profile_tests("geofency_phone", None), list(range(1, 14)))
        self.assertEqual(app.profile_tests("geofency_only", None), [8, 14, 15, 16, 18])
        self.assertIn(17, app.profile_tests("geofency_only", None, "Geo.Test.Helper"))
        self.assertEqual(app.profile_tests("geofency_only", [1, 2, 5, 10]), [1, 2, 5, 10])
        for profile, tests in (("geofency_only", [3]), ("geofency_only", [6, 7]),
                               ("geofency_phone", [14]), ("phone_only", [8])):
            with self.subTest(profile=profile, tests=tests), self.assertRaises(app.TestFailure):
                app.profile_tests(profile, tests)

    def test_geo_only_cleanup_never_sends_phone_commands(self):
        runner = app.Runner(SimpleNamespace(phone=False), None, None)
        runner.started = True
        runner.debug = Mock()
        runner.cleanup()
        runner.debug.assert_called_once_with("debugReset", "keepGeometry")

    def test_cleanup_retains_geometry_and_restores_only_the_previous_phone_mode(self):
        for mode, phone in (("live", "present"), ("simulated", "absent")):
            with self.subTest(mode=mode):
                telnet = Mock()
                telnet.command.side_effect = lambda command: (
                    "Debug session reset; geometry retained; no productive changes" if " debugReset " in command
                    else "Debug state updated; no productive changes")
                profile = SimpleNamespace(controller="GP", resident="Geo.Test", phone=True, telnet=telnet,
                                          previous_phone_mode=mode, previous_sim_phone=phone)
                runner = app.Runner(profile, None, None)
                runner.started = True
                runner.cleanup()
                sent = [call.args[0] for call in telnet.command.call_args_list]
                self.assertEqual(sent[:2], ["set GP debugReset Geo.Test keepGeometry",
                                           "set GP debugPhoneMode Geo.Test " + mode])
                self.assertEqual(len(sent), 3 if mode == "simulated" else 2)
                if mode == "simulated":
                    self.assertEqual(sent[2], "set GP debugPhone Geo.Test absent")

    def test_cleanup_rejects_a_reset_that_does_not_confirm_geometry_retention(self):
        profile = SimpleNamespace(controller="GP", resident="Geo.Test", phone=False, telnet=Mock())
        profile.telnet.command.return_value = "Debug session reset; no productive changes"
        runner = app.Runner(profile, None, None)
        runner.started = True
        with self.assertRaisesRegex(app.TestFailure, "zurückgewiesen"):
            runner.cleanup()


class GeometryPreparationTests(unittest.TestCase):
    def setUp(self):
        self.catalog = {
            "GP": {"Internals": {"SUBTYPE": "controller"}, "Readings": {"mode": {"Value": "active"}}},
            "Geo.Test": {"Internals": {"SUBTYPE": "resident", "CONTROLLER": "GP"},
                         "Readings": {"mode": {"Value": "debug"}}, "Attributes": {"sourceMode": "geofency_phone",
                                        "deviceId": "phone", "webhookUser": "user", "phoneProxies": "p1",
                                        "allowDoor": "1", "allowGarage": "0"}},
            "A.Door": {"Internals": {"SUBTYPE": "action", "ACTIONTYPE": "door_open"}},
            "R.Door": {"Internals": {"SUBTYPE": "rule", "PARENT": "GP"},
                       "Attributes": {"residents": "Geo.Test", "trigger": "arrival", "action": "A.Door"}},
        }
        self.view = {"view": "debug", "state": {}, "debug_ready": 1, "geometry_ready": 1, "test_webhook_isolation": 1,
                     "debug_reset_keep_geometry": 1, "geometry": {}}
        self.learned = []
        for name, role, radius in (("Home", "home", 150), ("Outer", "outer", 4500),
                                   ("Route", "place", 500), ("Work", "place", 100)):
            self.catalog["Z." + name] = {"Internals": {"SUBTYPE": "location", "PARENT": "Geo.Test", "ROLE": role},
                                         "Attributes": {"zoneId": name.lower()}}
            self.view["geometry"]["Z." + name] = dict(lat=49, lon=8, radius=radius, time=100) if role != "place" else {}
        self.telnet = Mock()

        def get_json(command):
            if command == "get GP logStatus format=json":
                return {"debugEnabled": 1, "file": "test.log"}
            if command == "get GP explain Geo.Test debug format=json":
                return self.view
            self.fail("Unexpected query: " + command)

        def get_command(command):
            if command == "get GP validate Geo.Test":
                return "OK: configuration valid"
            if command == "get GP learnedLocations Geo.Test format=json":
                return json.dumps(self.learned)
            self.fail("Preflight must not write FHEM: " + command)

        self.telnet.json.side_effect = get_json
        self.telnet.command.side_effect = get_command

    def profile(self):
        with patch.object(app, "devices", return_value=self.catalog):
            return app.Profile(self.telnet, "GP", "Geo.Test", [8], door_only=True)

    def test_valid_configuration_and_opening_geometry_do_not_hide_both_missing_places(self):
        with self.assertRaises(app.TestFailure) as error:
            self.profile()
        message = str(error.exception)
        self.assertIn("Z.Route: fehlt (Not learned)", message)
        self.assertIn("Z.Work: fehlt (Not learned)", message)
        self.assertNotIn("gesperrt", message)
        self.assertIn("Betreten oder Verlassen", message)
        self.assertIn("mindestens 8 Sekunden", message)

    def test_explicit_debug_view_is_required_before_testing(self):
        for value in (None, "production"):
            self.view["view"] = value
            with self.assertRaisesRegex(app.TestFailure, "gemeinsam aktualisieren"):
                self.profile()
        self.assertFalse(any(call.args[0].startswith("set ") for call in self.telnet.command.call_args_list))

    def test_fresh_test_webhooks_make_existing_places_available_without_redefining(self):
        for name in ("Z.Route", "Z.Work"):
            self.view["geometry"][name] = dict(lat=49.2, lon=8.1, radius=100, time=200, blocked=0)
        profile = self.profile()
        self.assertEqual(len(profile.locations), 4)
        self.assertEqual(profile.locations["Z.Work"].geometry["lat"], 49.2)
        self.assertEqual(profile.rules["door"], ("door_open", "R.Door"))

    def test_empty_runtime_entries_do_not_hide_confirmed_learning(self):
        for name in ("route", "work"):
            self.learned.append(dict(id=name, geometry=dict(lat=49.2, lon=8.1, radius=100), time=100))
        self.assertEqual(len(self.profile().locations), 4)
        self.view["geometry"]["Z.Work"] = dict(lat=49.2, lon=8.1, radius=100, time=200, blocked=1)
        with self.assertRaisesRegex(app.TestFailure, "Z.Work: gesperrt"):
            self.profile()  # Never conceal a newer conflict with older learning.
        self.view["geometry"]["Z.Work"]["time"] = 100
        with self.assertRaisesRegex(app.TestFailure, "Z.Work: gesperrt"):
            self.profile()  # Nor a conflict at the exact same timestamp.

    def test_saved_geometry_must_belong_to_the_same_phone_and_zone(self):
        for name in ("Route", "Work"):
            self.catalog["Z." + name]["Readings"] = {"gp_geometry": {"Value": json.dumps(
                dict(lat=49.2, lon=8.1, radius=100, time=100, device="phone", id=name.lower()))}}
        self.assertEqual(len(self.profile().locations), 4)
        self.catalog["Z.Work"]["Readings"]["gp_geometry"]["Value"] = json.dumps(
            dict(lat=49.2, lon=8.1, radius=100, time=200, device="other-phone", id="work"))
        with self.assertRaisesRegex(app.TestFailure, "Z.Work: fehlt"):
            self.profile()

    def test_incomplete_geometry_is_distinct_from_missing_and_blocked(self):
        self.view["geometry"]["Z.Route"] = dict(lat=49, lon=8, time=200)
        self.view["geometry"]["Z.Work"] = dict(lat=None, lon=8, radius=100, time=200)
        with self.assertRaises(app.TestFailure) as error:
            self.profile()
        self.assertIn("Z.Route: unvollständig oder ungültig", str(error.exception))
        self.assertIn("Z.Work: unvollständig oder ungültig", str(error.exception))


if __name__ == "__main__":
    unittest.main()
