#!/usr/bin/env python3
"""Exercise the installed GeoPresence debug endpoint and verify its real log.

Python 3.9+, standard library only. Run on the FHEM host. No device definitions,
attributes, production readings, actuator commands or simulated clock changes.
"""

import argparse
import base64
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
import getpass
import http.client
import json
import math
import os
from pathlib import Path
import re
import socket
import ssl
import sys
import time
import warnings
from urllib.parse import parse_qs, urlencode, urlsplit


DEFAULT_LOG = "/var/log/fhem/geopresence-%Y-%m.log"
DEFAULT_REPORT_DIR = Path("private/reports")
PLAN = "would execute; debug suppressed"
REAL_ACTIONS = {"actor command dispatched", "actor command failed", "notification dispatched",
                "notification failed", "switch command dispatched", "switch command failed"}
NAME = re.compile(r"[A-Za-z][A-Za-z0-9_.-]*\Z")
SCENARIOS = {
    1: "Haus zur Arbeit",
    2: "Arbeit nach Hause",
    3: "Spaziergang",
    4: "GPS-Sprünge, danach Spaziergang",
    5: "Arbeit ohne Außenbereich-Austritt",
    6: "Home-Webhook fehlt – Telefon-Fallback",
    7: "Kurze Empfangslücke mit falschem Fernbereich",
    8: "Home ohne vorherigen Ausflug",
    9: "Doppelte Heimkehr und identischer Webhook-Retry",
    10: "Rückkehr aus dem Fernbereich zu Fuß",
    11: "15-Sekunden-Home-Sprung während eines Spaziergangs",
    12: "Telefon bestätigt die vorgemerkte Rückkehr vorzeitig",
    13: "Autofahrt mit kurzer Ankunftsbestätigung",
    14: "Nur Geofency: Home-Austritt und lange Pause berechtigen keine Öffnung",
    15: "Nur Geofency: Fernausflug, Autofrist und doppelter Home-Webhook",
    16: "Nur Geofency: kurzer Home-Sprung nach bestätigtem Fernausflug",
    17: "Nur Geofency: Spaziergang über einen entfernten Helferort",
    18: "Nur Geofency: fehlender Home-Webhook hat keinen Telefon-Fallback",
}
COMBINED_TESTS = list(range(1, 14))
GEO_TESTS = [8, 14, 15, 16, 18]


def profile_tests(source_mode, tests, checkpoint=None):
    require(source_mode in ("geofency_phone", "geofency_only"),
            "Die Webhook-Testanwendung benötigt geofency_phone oder geofency_only; phone_only hat keine Geofency-Öffnungen.")
    defaults = COMBINED_TESTS if source_mode == "geofency_phone" else GEO_TESTS + ([17] if checkpoint else [])
    selected = list(defaults if tests is None else tests)
    allowed = set(COMBINED_TESTS if source_mode == "geofency_phone" else GEO_TESTS + [1, 2, 5, 10, 17])
    require(not (set(selected) - allowed),
            f"Tests {sorted(set(selected) - allowed)} passen nicht zu sourceMode {source_mode}; --tests all wählt das Quellenprofil.")
    return selected


class TestFailure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise TestFailure(message)


def password_prompt(prompt):
    # getpass otherwise falls back to echoing input when no terminal exists.
    with warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        try:
            return getpass.getpass(prompt)
        except getpass.GetPassWarning as error:
            raise TestFailure("Kennwort kann nicht verdeckt gelesen werden; in einem interaktiven Terminal starten.") from error


class Clock:
    wall = staticmethod(time.time)
    monotonic = staticmethod(time.monotonic)
    sleep = staticmethod(time.sleep)


class Telnet:
    """One bounded local FHEM request per connection, terminated by quit."""

    def __init__(self, host="127.0.0.1", port=7072, password=None):
        require(host in ("127.0.0.1", "::1", "localhost"), "Telnet muss lokal auf dem FHEM-Host erreichbar sein.")
        self.host, self.port, self.password = host, port, password

    def command(self, command):
        require("\n" not in command and "\r" not in command, "Ungültiger FHEM-Befehl.")
        prefix = (self.password + "\n") if self.password else ""
        with socket.create_connection((self.host, self.port), timeout=10) as client:
            client.sendall((prefix + command + "\nquit\n").encode("utf-8"))
            chunks, size = [], 0
            while True:
                chunk = client.recv(65536)
                if not chunk:
                    break
                size += len(chunk)
                require(size <= 8 * 1024 * 1024, "FHEM-Antwort ist unerwartet groß.")
                chunks.append(chunk)
        raw = b"".join(chunks)
        raw = re.sub(rb"\xff[\xfb-\xfe].", b"", raw)  # Telnet option negotiation
        text = raw.decode("utf-8").strip()
        text = re.sub(r"(?:^|\n)(?:Password: ?|fhem> ?)", "", text)
        return text.removesuffix("Bye...").strip()

    def json(self, command):
        text = self.command(command)
        try:
            return json.loads(text)
        except ValueError as error:
            raise TestFailure("Keine gültige JSON-Antwort von FHEM; Telnet-Zugang und jsonlist2 prüfen.") from error


class Webhook:
    def __init__(self, url, user, password, path):
        self.url = urlsplit(url)
        require(self.url.path == path and not self.url.query and not self.url.fragment,
                "Die URL muss exakt auf den konfigurierten /fhem/...-Webhook zeigen; kein /debug-Zusatz.")
        require(not self.url.username and not self.url.password, "Keine Zugangsdaten in der URL verwenden.")
        require(self.url.hostname and (self.url.scheme == "https" or
                (self.url.scheme == "http" and self.url.hostname in ("127.0.0.1", "::1", "localhost"))),
                "HTTPS ist erforderlich; HTTP ist nur für lokale Testinstanzen erlaubt.")
        self.authorization = "Basic " + base64.b64encode((user + ":" + password).encode()).decode()

    def send(self, body):
        try:
            fields = parse_qs(body.decode("utf-8"), keep_blank_values=True, strict_parsing=True)
        except (UnicodeError, ValueError) as error:
            raise TestFailure("Ungültiges Testformular; kein Webhook gesendet.") from error
        require(fields.get("isTest") == ["true"] and not any(key.lower() == "istest" and key != "isTest" for key in fields),
                "Test-Webhooks müssen eindeutig isTest=true enthalten; kein Webhook gesendet.")
        cls = http.client.HTTPSConnection if self.url.scheme == "https" else http.client.HTTPConnection
        options = {"timeout": 15}
        if self.url.scheme == "https":
            options["context"] = ssl.create_default_context()
        connection = cls(self.url.hostname, self.url.port, **options)
        try:
            connection.request("POST", self.url.path, body, {
                "Authorization": self.authorization,
                "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
            })
            response = connection.getresponse()
            text = response.read(16385).decode("utf-8", errors="replace").strip()
            require(response.status == 200 and text == "OK debug accepted; no actions",
                    "Webhook nicht zur Debug-Auswertung angenommen (HTTP %d). "
                    "Account, Kennwort, Webhook-URL, Testkennzeichen, Einlernmodus und FHEM-Validierung prüfen."
                    % response.status)
        finally:
            connection.close()


class LogTail:
    """Read only newly appended complete lines, including file rotation."""

    def __init__(self, pattern, clock):
        self.pattern, self.clock = pattern, clock
        self.file = None
        self.path = None
        self.partial = b""
        self._open(at_end=True)

    def _path(self):
        return Path(datetime.fromtimestamp(self.clock.wall()).strftime(self.pattern))

    def _open(self, at_end=False):
        self.path = self._path()
        self.file = self.path.open("rb")
        if at_end:
            self.file.seek(0, 2)

    def read(self):
        require(os.fstat(self.file.fileno()).st_size >= self.file.tell(),
                "Logdatei wurde während des Tests gekürzt; die Auswertung wäre unvollständig.")
        data = self.file.read()
        new_path = self._path()
        try:
            stat = new_path.stat()
        except FileNotFoundError:
            stat = None
        old = os.fstat(self.file.fileno())
        if stat and (new_path != self.path or (stat.st_dev, stat.st_ino) != (old.st_dev, old.st_ino)):
            require(not self.partial and (not data or data.endswith(b"\n")), "Unvollständige Zeile bei Logrotation.")
            self.file.close()
            self._open()
            data += self.file.read()
        combined = self.partial + data
        lines = combined.split(b"\n")
        self.partial = lines.pop()
        require(len(self.partial) <= 65536, "Unvollständige oder übergroße Logzeile.")
        return [line.decode("utf-8").rstrip("\r") for line in lines]

    def close(self):
        self.file.close()


@dataclass
class Location:
    device: str
    role: str
    zone_id: str
    geometry: dict


def devices(telnet):
    result = telnet.json("jsonlist2 TYPE=GeoPresence")
    return {item["Name"]: item for item in result.get("Results", [])}


def geometry_problem(geometry):
    if not geometry:
        return "fehlt (Not learned)"
    if geometry.get("blocked"):
        return "gesperrt: widersprüchliche Geometrie; neuere Geofency-Meldung erforderlich"
    try:
        lat, lon, radius = (float(geometry[key]) for key in ("lat", "lon", "radius"))
        if abs(lat) <= 90 and abs(lon) <= 180 and 0 < radius <= 100000:
            return None
    except (KeyError, TypeError, ValueError):
        pass
    return "unvollständig oder ungültig: latitude, longitude und radius erforderlich"


def debug_view(telnet, controller, resident):
    view = telnet.json(f"get {controller} explain {resident} debug format=json")
    require(view.get("view") == "debug" and isinstance(view.get("state"), dict),
            "Die Debug-Ansicht von explain ist nicht verfügbar. FHEM/98_GeoPresence.pm und "
            "tools/geopresence_test.py gemeinsam aktualisieren und das Modul laden.")
    return view


class Profile:
    def __init__(self, telnet, controller, resident, tests, work=None, waypoint=None, door_only=False, checkpoint=None, work_group=None):
        require(NAME.fullmatch(controller) and NAME.fullmatch(resident), "Ungültiger Gerätename.")
        self.telnet, self.controller, self.resident = telnet, controller, resident
        self.catalog = devices(telnet)
        require(controller in self.catalog and resident in self.catalog, "Controller oder Bewohner fehlen in FHEM.")
        c, r = self.catalog[controller], self.catalog[resident]
        self.source_mode = r.get("Attributes", {}).get("sourceMode", "geofency_phone")
        self.phone = self.source_mode == "geofency_phone"
        self.tests = tests = profile_tests(self.source_mode, tests, checkpoint)
        require(c["Internals"].get("SUBTYPE") == "controller" and
                r["Internals"].get("SUBTYPE") == "resident" and r["Internals"].get("CONTROLLER") == controller,
                "Controller und Bewohner gehören nicht zusammen.")
        self.controller_mode = c.get("Readings", {}).get("mode", {}).get("Value", "disabled")
        self.guard()
        result = telnet.command(f"get {controller} validate {resident}")
        require(result.startswith("OK: configuration valid"), "FHEM-Validierung fehlgeschlagen:\n" + result)
        status = telnet.json(f"get {controller} logStatus format=json")
        require(status.get("debugEnabled") == 1 and not status.get("error"),
                f"Dateidiagnose nicht bereit. get {controller} logStatus und attr {controller} debugLog auto prüfen.")
        self.log_path = status["file"]
        self.device_id = r.get("Attributes", {}).get("deviceId", "")
        self.user = r.get("Attributes", {}).get("webhookUser", "")
        require(self.device_id and self.user, "deviceId oder webhookUser fehlen beim Bewohner.")
        self.webhook_path = "/fhem/" + c.get("Attributes", {}).get("webhookPath", "geopresence")
        defaults = {"phone_poll": 5, "phone_absence_window": 180, "minimum_away": 60, "reorder_window": 2,
                    "arrival_wait_walking": 60, "arrival_wait_running": 30, "arrival_wait_cycling": 20,
                    "arrival_wait_automotive": 10, "arrival_wait_unknown": 60, "action_max_age": 90,
                    "departure_grace": 60}
        self.times = {key: float(c.get("Attributes", {}).get(key, default)) for key, default in defaults.items()}
        self.settle = max(self.times["phone_poll"] if self.phone else 0, self.times["reorder_window"]) + 3
        self.travel = max(self.times["phone_absence_window"], self.times["minimum_away"]) + 2 * self.settle
        if 7 in tests:
            require(self.times["minimum_away"] + 3 * self.settle < self.times["phone_absence_window"],
                    "Test 7 braucht eine Empfangslücke länger als minimum_away und kürzer als phone_absence_window.")
        if set(tests) & {11, 16}:
            require(self.times["arrival_wait_walking"] > 15 + self.settle,
                    "Der 15-Sekunden-GPS-Test braucht arrival_wait_walking größer als 15 Sekunden plus Verarbeitungsreserve.")
        if 12 in tests:
            require(self.times["arrival_wait_walking"] > 2 * self.settle,
                    "Test 12 braucht genug walking-Wartezeit für eine vorzeitige Telefonbestätigung.")
        if self.phone:
            require(r.get("Attributes", {}).get("phoneProxies"), "Telefon-Fallback benötigt konfigurierte phoneProxies.")
        require(r.get("Attributes", {}).get("allowDoor", "0") == "1", "Der Testbewohner benötigt allowDoor 1.")
        self.garage = not door_only
        require((r.get("Attributes", {}).get("allowGarage", "0") == "1") == self.garage,
                f"allowGarage passt nicht zum Testvertrag: erwartet {int(self.garage)}. Für Bewohner ohne Garage --door-only verwenden.")
        learned_text = telnet.command(f"get {controller} learnedLocations {resident} format=json")
        learned = json.loads(learned_text) if learned_text.startswith("[") else []
        learned = {item["id"].lower(): item for item in learned}
        debug = debug_view(telnet, controller, resident)
        require(debug.get("debug_ready") == 1, "Debug-System noch nicht bereit oder ein Aktorauftrag läuft.")
        self.previous_phone_mode = debug.get("state", {}).get("phone_mode", "live")
        self.previous_sim_phone = debug.get("state", {}).get("sim_phone", "absent")
        self.locations = {}
        geometry_errors = []
        for name, item in self.catalog.items():
            internal = item.get("Internals", {})
            if internal.get("SUBTYPE") != "location" or internal.get("PARENT") != resident:
                continue
            zone_id = item.get("Attributes", {}).get("zoneId", "").lower()
            candidates = []
            raw = item.get("Readings", {}).get("gp_geometry", {}).get("Value")
            if raw:
                try:
                    value = json.loads(raw)
                except ValueError:
                    value = None
                if isinstance(value, dict) and value.get("id", "").lower() == zone_id and value.get("device", "").lower() == self.device_id.lower():
                    candidates.append(value)
            if zone_id in learned:
                candidates.append(dict(learned[zone_id]["geometry"], time=learned[zone_id]["time"]))
            # FHEM also caches {} for a registered location with no geometry.
            # An empty cache entry is missing data, not a blocked observation.
            if debug.get("geometry", {}).get(name):
                candidates.append(debug["geometry"][name])
            geometry = max(candidates, key=lambda item: (float(item.get("time", 0)), bool(item.get("blocked"))), default={})
            problem = geometry_problem(geometry)
            if problem:
                geometry_errors.append(f"{name}: {problem}")
                continue
            self.locations[name] = Location(name, internal["ROLE"], zone_id, geometry)
        require(not geometry_errors,
                "Testvorbereitung: Ortsgeometrie fehlt oder ist nicht verwendbar:\n- " + "\n- ".join(sorted(geometry_errors)) +
                "\nvalidate prüft die Konfiguration; Geometry ready bestätigt nicht die Geometrie aller registrierten Orte."
                f"\n{resident} im Modus debug lassen. In Geofency für jeden genannten Ort den Testbutton "
                "Betreten oder Verlassen drücken (isTest=true, bestehende Webhook-URL)."
                f"\nZwischen den Meldungen und danach mindestens {self.settle:g} Sekunden warten; anschließend "
                f"get {controller} explain {resident} debug prüfen und die Anwendung erneut starten."
                "\nKein Lernmodus und keine neuen Ortsdefinitionen erforderlich. Nach dem Empfang weder debugReset ohne keepGeometry "
                "noch Moduswechsel oder Reload ausführen; diese verwerfen die nur in der Simulation empfangene Geometrie.")
        self.home = self.select("home")
        self.outer = self.select("outer")
        self.checkpoint = self.select("place", checkpoint) if 17 in tests else None
        needs_work = bool(set(tests) & {1, 2, 5, 10})
        self.work_group = None
        rules = [item.get("Attributes", {}) for item in self.catalog.values()
                 if item.get("Internals", {}).get("SUBTYPE") == "rule"
                 and item.get("Internals", {}).get("PARENT") == controller
                 and item.get("Attributes", {}).get("enabled", "1") == "1"
                 and self.catalog.get(item.get("Attributes", {}).get("action"), {}).get("Internals", {}).get("ACTIONTYPE") == "notify"
                 and resident in item.get("Attributes", {}).get("residents", "").split(",")]
        if needs_work:
            groups = {a["locationGroup"] for a in rules if a.get("trigger") == "enter" and a.get("locationGroup")} & \
                     {a["locationGroup"] for a in rules if a.get("trigger") == "exit" and a.get("locationGroup")}
            if work_group:
                groups &= {work_group}
            if work:
                groups &= set(self.catalog.get(work, {}).get("Attributes", {}).get("groups", "").split(","))
            require(len(groups) == 1, "Arbeitsortgruppe nicht eindeutig; --work-group GRUPPE angeben und Eintritt-/Austrittregeln prüfen.")
            self.work_group = next(iter(groups))
        self.work = self.select("place", work, self.work_group) if needs_work else None
        self.waypoint = None
        if set(tests) & {1, 2, 5}:
            if not waypoint:
                candidates = {name for a in rules if a.get("trigger") == "exit" for name in a.get("locations", "").split(",")
                              if name in self.locations and self.locations[name].role == "place"
                              and self.work_group not in self.catalog[name].get("Attributes", {}).get("groups", "").split(",")}
                require(len(candidates) == 1, "Rückweg-Ort nicht eindeutig; --waypoint ORT angeben.")
                waypoint = next(iter(candidates))
            self.waypoint = self.select("place", waypoint)
        self.rules = {}
        self.rule("door", "arrival", "door_open")
        if self.garage:
            self.rule("garage", "arrival", "garage_open")
        if needs_work:
            self.rule("work_enter", "enter", "notify", group=self.work_group)
            self.rule("work_exit", "exit", "notify", group=self.work_group)
        if self.waypoint:
            self.rule("waypoint", "exit", "notify", location=self.waypoint.device)

    def guard(self):
        current = devices(self.telnet)
        require(current.get(self.resident, {}).get("Attributes", {}).get("sourceMode", "geofency_phone") == self.source_mode,
                "Test abgebrochen: sourceMode hat sich während des Laufs geändert.")
        require(self.controller_mode in ("debug", "active") and
                current.get(self.controller, {}).get("Readings", {}).get("mode", {}).get("Value", "disabled") == self.controller_mode and
                current.get(self.resident, {}).get("Readings", {}).get("mode", {}).get("Value", "disabled") == "debug",
                f"Test abgebrochen: Controller muss debug/active und während des Laufs unverändert sein; set {self.resident} mode debug setzen.")
        debug = debug_view(self.telnet, self.controller, self.resident)
        require(debug.get("test_webhook_isolation") == 1,
                "Test abgebrochen: GeoPresence unterstützt die sichere isTest-Verarbeitung noch nicht; Modul aktualisieren und laden.")
        require(debug.get("debug_reset_keep_geometry") == 1,
                "Test abgebrochen: Das geladene GeoPresence-Modul kann die Geometrie beim Test-Reset noch nicht erhalten. "
                "FHEM/98_GeoPresence.pm und tools/geopresence_test.py gemeinsam aktualisieren und das Modul laden.")
        require(not debug.get("state", {}).get("debug_offset", 0),
                "Test abgebrochen: Die Debug-Uhr wurde mit debugAdvance verschoben. Zuerst debugReset ohne keepGeometry "
                "ausführen und fehlende Geometrie erneut per Geofency-Testbutton senden.")

    def select(self, role, name=None, group=None):
        matches = [zone for zone in self.locations.values() if zone.role == role and (not name or zone.device == name)
                   and (not group or group in self.catalog[zone.device].get("Attributes", {}).get("groups", "").split(","))]
        require(len(matches) == 1, f"Ort für {role} nicht eindeutig. --work bzw. --waypoint angeben, wenn mehrere vorhanden sind.")
        return matches[0]

    def rule(self, key, trigger, kind, group=None, location=None):
        matches = []
        for name, item in self.catalog.items():
            a = item.get("Attributes", {})
            if item.get("Internals", {}).get("SUBTYPE") != "rule" or a.get("enabled", "1") != "1":
                continue
            action = self.catalog.get(a.get("action"), {}).get("Internals", {})
            if (self.resident in a.get("residents", "").split(",") and a.get("trigger") == trigger and
                    action.get("ACTIONTYPE") == kind and (not group or a.get("locationGroup") == group) and
                    (not location or location in a.get("locations", "").split(",") or
                     a.get("locationGroup") in self.catalog.get(location, {}).get("Attributes", {}).get("groups", "").split(","))):
                matches.append((kind, name))
        require(len(matches) == 1,
                f"Erwartete Regel für {key} fehlt oder ist mehrfach vorhanden.")
        self.rules[key] = matches[0]


class Runner:
    def __init__(self, profile, webhook, log, clock=None, output=print):
        self.p, self.webhook, self.log = profile, webhook, log
        self.clock, self.output = clock or Clock(), output
        self.rows, self.receipts, self.results = [], Counter(), []
        self.current = None
        self.started = False

    def state(self):
        view = debug_view(self.p.telnet, self.p.controller, self.p.resident)
        require(view.get("debug_ready") == 1, "Debug-Auswertung nicht mehr bereit.")
        return view["state"]

    def debug(self, command, value=""):
        require(command in ("debugReset", "debugPhoneMode", "debugPhone"), "Nicht zugelassener Testbefehl.")
        choices = {"debugReset": ("", "keepGeometry"), "debugPhoneMode": ("simulated", "live"),
                   "debugPhone": ("present", "absent")}
        require(value in choices[command], "Ungültiger Testwert.")
        text = self.p.telnet.command(f"set {self.p.controller} {command} {self.p.resident} {value}".rstrip())
        expected = ("Debug session reset; geometry retained; no productive changes" if value == "keepGeometry"
                    else "Debug session reset; no productive changes" if command == "debugReset"
                    else "Debug state updated; no productive changes")
        require(text == expected,
                f"FHEM hat den Testbefehl {command} zurückgewiesen.")

    def collect(self):
        for line in self.log.read():
            match = re.search(r" (\S+) GeoPresence (\w+) (\{.*\})$", line)
            if not match or match[1] != self.p.controller:
                continue
            try:
                row = json.loads(match[3])
            except ValueError as error:
                raise TestFailure("Ungültige JSON-Diagnose im GeoPresence-Log.") from error
            if match[2] == "log_rate_limit":
                raise TestFailure("Diagnoselog begrenzt; ein vollständiger Lognachweis ist nicht möglich.")
            if row.get("resident") != self.p.resident:
                continue
            row = dict(row, event=match[2], line=line)
            self.rows.append(row)
            if self.current is not None:
                self.current["log"].append(row)
            require(row.get("reason") not in REAL_ACTIONS and row.get("mode") != "active",
                    "Produktive Verarbeitung im Testfenster entdeckt; Test gestoppt.")
            if row["event"] == "http":
                key = (row.get("zone"), int(row.get("entry", -1)), round(float(row.get("observed", 0)), 3))
                require(self.receipts[key] > 0, f"Fremder oder unerwarteter Webhook für diesen Bewohner ({key}); Handytests während des Laufs pausieren.")
                self.receipts[key] -= 1
                require(str(row.get("status")) == "200" and row.get("reason") == "OK debug accepted; no actions",
                        "Log bestätigt keine Debug-Annahme des Webhooks.")

    def wait(self, seconds):
        deadline = self.clock.monotonic() + seconds
        next_notice = self.clock.monotonic() + 10
        while self.clock.monotonic() < deadline:
            self.clock.sleep(min(1, deadline - self.clock.monotonic()))
            self.collect()
            if self.clock.monotonic() >= next_notice:
                self.p.guard()
                self.output(f"    Warten: noch {math.ceil(max(0, deadline - self.clock.monotonic()))} s")
                next_notice = self.clock.monotonic() + 10

    def send(self, zone, entry, motion=None, body=None):
        if body is None:
            payload = {"device": self.p.device_id, "id": zone.zone_id, "name": zone.device, "isTest": "true",
                       "entry": int(entry), "date": datetime.fromtimestamp(self.clock.wall(), timezone.utc).isoformat(timespec="milliseconds"),
                       "latitude": zone.geometry["lat"], "longitude": zone.geometry["lon"], "radius": zone.geometry["radius"]}
            if motion is not None:
                payload["motion"] = motion
            body = urlencode(payload).encode("utf-8")
        else:
            payload = {key: values[0] for key, values in parse_qs(body.decode()).items()}
        observed = datetime.fromisoformat(payload["date"]).timestamp()
        key = (zone.device, int(entry), round(observed, 3))
        self.receipts[key] += 1
        if self.current is not None:
            self.current.setdefault("webhooks", []).append(key)
        self.webhook.send(body)
        return body

    def expected(self, *keys):
        return [self.p.rules[key] for key in keys if key in self.p.rules]

    def step(self, title, action=None, expected=(), seconds=None, reasons=(), phase=None, phone=None, armed=None,
             one_of_reasons=()):
        self.p.guard()
        item = {"step": title, "expected": list(expected), "log": [], "passed": False,
                "wait_seconds": self.p.settle if seconds is None else seconds}
        self.results[-1]["steps"].append(item)
        self.current = item
        self.output("  " + title)
        try:
            self.collect()
            result = action() if action else None
            self.wait(self.p.settle if seconds is None else seconds)
            self.collect()
            actual = [(row["kind"], row["rule"]) for row in item["log"] if row.get("reason") == PLAN]
            item["actual"] = actual
            state = self.state()
            item["state"] = state
            require(Counter(actual) == Counter(expected), f"Aktionspläne stimmen nicht: erwartet {list(expected)}, erhalten {actual}.")
            for reason in reasons:
                require(any(row.get("reason") == reason for row in item["log"]), f"Lognachweis fehlt: {reason}")
            if one_of_reasons:
                require(any(row.get("reason") in one_of_reasons for row in item["log"]),
                        f"Lognachweis fehlt: einer von {one_of_reasons}")
            require(not any(self.receipts.values()), "HTTP-Antwort erhalten, aber die passende neue Logzeile fehlt.")
            for zone, entry, observed in item.get("webhooks", []):
                require(any(row.get("reason") == "observation received" and row.get("source") == "geo" and
                            row.get("zone") == zone and int(row.get("entry", -1)) == entry and
                            round(float(row.get("observed", 0)), 3) == observed for row in item["log"]),
                        f"HTTP-Annahme ohne fachliche Auswertung im Log: {zone}.")
                outcomes = {"zone observation processed"} | ((set(reasons) | set(one_of_reasons)) & {
                    "duplicate event", "event too old or future", "departure contradicted by current local presence"})
                require(any(row.get("reason") in outcomes and round(float(row.get("observed", 0)), 3) == observed
                            for row in item["log"]),
                        f"Kein erwarteter Abschluss der Ortsauswertung: {zone}; ein verworfenes Ereignis gilt nicht als aktionsloser Erfolg.")
            if phase:
                require(state.get("phase") == phase, f"Phase ist {state.get('phase')}, erwartet {phase}.")
            if phone:
                require(state.get("phone", {}).get("state") == phone, f"Telefonstatus ist nicht {phone}.")
            if armed is not None:
                require(bool(state.get("trip", {}).get("armed")) == armed, "Öffnungsberechtigung entspricht nicht der Erwartung.")
            for row in item["log"]:
                if row.get("reason") in set(reasons) | set(one_of_reasons) | {PLAN, "zone observation processed", "arrival confirmed"}:
                    self.output("    LOG: " + row["line"])
            self.output("    OK: " + (", ".join(kind + ":" + rule for kind, rule in actual) if actual else "kein Aktionsplan"))
            item["passed"] = True
            return result
        except (Exception, KeyboardInterrupt) as error:
            item["error"] = "Vom Nutzer abgebrochen." if isinstance(error, KeyboardInterrupt) else str(error)
            raise
        finally:
            self.current = None

    def prepare(self, start):
        self.p.guard()
        self.started = True
        self.debug("debugReset", "keepGeometry")
        if self.p.phone:
            self.debug("debugPhoneMode", "simulated")
            self.debug("debugPhone", "absent")
        self.output("  Vorbereitung: frische Debug-Sitzung und gelernte Ortsgeometrien übernehmen.")
        # Ordinary webhooks synchronize the geometry first. No private state is set.
        # Known geometry survives the journey reset. Sending its exits as
        # preparation would instead simulate actual travel and consume cooldowns.
        view = debug_view(self.p.telnet, self.p.controller, self.p.resident)
        preparation = {"step": "Geometrievorbereitung", "log": [], "preparation": True, "passed": False}
        self.results[-1]["steps"].append(preparation)
        self.current = preparation
        for zone in sorted(self.p.locations.values(), key=lambda zone: zone.device):
            old = view.get("geometry", {}).get(zone.device, {})
            if not old.get("blocked") and all(key in old and float(old[key]) == float(zone.geometry[key])
                                              for key in ("lat", "lon", "radius")):
                continue
            self.send(zone, 0)
            self.wait(self.p.settle)
        self.collect()
        require(not any(self.receipts.values()), "Lognachweis der Geometrievorbereitung fehlt.")
        require(not any(row.get("reason") == PLAN for row in preparation["log"]),
                "Geometrievorbereitung hat unerwartet bereits eine Aktion geplant.")
        view = debug_view(self.p.telnet, self.p.controller, self.p.resident)
        require(view.get("geometry_ready") == 1, "Ortsgeometrie ist nach der Vorbereitung nicht bereit.")
        preparation["passed"] = True
        self.current = None
        self.rows.clear()
        if start == "home":
            self.step("Startposition Home", lambda: self.send(self.p.home, 1), phase="home", armed=False,
                      reasons=("arrival confirmed",))
            if self.p.phone:
                self.step("Telefon wird zu Hause erkannt", lambda: self.debug("debugPhone", "present"), phase="home", phone="present")
        else:
            self.step("Startposition Work", lambda: self.send(self.p.work, 1), self.expected("work_enter"), phase="away", armed=True)
        self.results[-1]["preparation_steps"] = len(self.results[-1]["steps"])

    def depart(self):
        if self.p.phone:
            self.debug("debugPhone", "absent")
        self.send(self.p.home, 0)

    def outbound(self, missing_outer=False):
        self.step("Home verlassen; Telefon verlässt die Haussensoren" if self.p.phone else "Home verlassen", self.depart)
        if self.p.phone:
            self.step("Fahrt: Telefonabwesenheit qualifizieren", seconds=self.p.travel, phase="away", phone="absent", armed=True,
                      reasons=("phone absence qualified",))
        else:
            self.step("Home-Austritt ändert nur den Status", seconds=self.p.times["departure_grace"] + self.p.settle,
                      phase="away", phone="disabled", armed=False)
        if not missing_outer:
            self.step("Außenbereich verlassen", lambda: self.send(self.p.outer, 0), armed=True)
        self.step("Rückweg-Ort betreten: keine Hinweg-Nachricht", lambda: self.send(self.p.waypoint, 1))
        self.step("Rückweg-Ort verlassen: kein vorheriger Gruppenaustritt beobachtet", lambda: self.send(self.p.waypoint, 0),
                  reasons=("required prior exit not observed in this trip",))
        self.step("Work betreten: Arbeitsankunft melden", lambda: self.send(self.p.work, 1),
                  self.expected("work_enter"), phase="away", armed=True)

    def arrival(self, title, motion, expected):
        wait = self.p.times["arrival_wait_" + (motion or "unknown")]
        body = self.step(title, lambda: self.send(self.p.home, 1, motion), expected,
                         seconds=wait + self.p.settle, phase="home", armed=False,
                         reasons=("arrival pending", "arrival confirmed"))
        confirmations = [row for row in self.results[-1]["steps"][-1]["log"]
                         if row.get("reason") == "arrival confirmed"]
        require(len(confirmations) == 1 and confirmations[0].get("confirmation") == "timer" and
                float(confirmations[0].get("wait_seconds", -1)) >= wait,
                "Timerbestätigung fehlt oder erfolgte vor der konfigurierten Ankunftsfrist.")
        return body

    def run_case(self, number):
        require(number in self.p.tests, "Test ist nicht im gewählten Quellenprofil enthalten.")
        self.results.append({"test": number, "title": SCENARIOS[number], "steps": [], "passed": False})
        self.output(f"\nTest {number} – {SCENARIOS[number]}")
        self.prepare("work" if number in (2, 10) else "home")
        opens = self.expected("door", "garage")
        if number in (1, 5):
            self.outbound(number == 5)
        elif number in (2, 10):
            self.step("Work verlassen", lambda: self.send(self.p.work, 0), self.expected("work_exit"), phase="away")
            self.step("Rückweg: Mindestabwesenheit einhalten", seconds=self.p.times["minimum_away"] + self.p.settle, phase="away")
            if number == 2:
                self.step("Rückweg-Ort betreten", lambda: self.send(self.p.waypoint, 1))
                self.step("Rückweg-Ort verlassen: Rückweg melden", lambda: self.send(self.p.waypoint, 0), self.expected("waypoint"))
                self.step("Außenbereich betreten", lambda: self.send(self.p.outer, 1))
            self.arrival("Home betreten und Ankunftsfrist abwarten", "walking" if number == 10 else None,
                         self.expected("door") if number == 10 else opens)
        elif number in (3, 4):
            if number == 4:
                self.step("GPS-Sprung: Home verlassen, Telefon bleibt zu Hause", lambda: self.send(self.p.home, 0), seconds=10)
                self.step("GPS-Sprung: Home betreten, keine Aktion", lambda: self.send(self.p.home, 1), seconds=10, phase="home", armed=False)
            self.step("Home verlassen; Telefon nicht mehr erkannt", self.depart)
            self.step("Spaziergang: Telefonabwesenheit qualifizieren", seconds=self.p.travel, phase="away", phone="absent", armed=True,
                      reasons=("phone absence qualified",))
            self.arrival("Home mit walking betreten: Tür nach der Ankunftsfrist", "walking", self.expected("door"))
        elif number in (6, 9):
            self.step("Home verlassen; Telefon nicht mehr erkannt", self.depart)
            self.step("Fahrt: Telefonabwesenheit qualifizieren", seconds=self.p.travel, phase="away", armed=True)
            self.step("Außenbereich verlassen", lambda: self.send(self.p.outer, 0), phase="away", armed=True)
            if number == 6:
                self.step("Home-Webhook fehlt; Telefon meldet die Rückkehr", lambda: self.debug("debugPhone", "present"),
                          opens, phase="home", phone="present", armed=False, reasons=("arrival confirmed",))
                require(any(row.get("reason") == "arrival confirmed" and row.get("source") == "phone_present"
                            for row in self.results[-1]["steps"][-1]["log"]), "Ankunft stammt nicht vom Telefon.")
            else:
                body = self.arrival("Home betreten: einmal nach der Ankunftsfrist öffnen", None, opens)
                self.step("Identischen Home-Webhook erneut zustellen", lambda: self.send(self.p.home, 1, body=body),
                          phase="home", one_of_reasons=("duplicate event", "event too old or future"))
                self.step("Neuen Home-Eintritt zustellen: keine zweite Öffnung", lambda: self.send(self.p.home, 1), phase="home", armed=False)
        elif number in (11, 12, 13):
            self.step("Home verlassen; Telefon nicht mehr erkannt", self.depart)
            self.step("Abwesenheit für den Ausflug qualifizieren", seconds=self.p.travel,
                      phase="away", phone="absent", armed=True, reasons=("phone absence qualified",))
            if number == 13:
                self.step("Außenbereich verlassen: Fernausflug", lambda: self.send(self.p.outer, 0), armed=True)
                self.arrival("Home mit automotive betreten: kurze Ankunftsfrist", "automotive", opens)
            else:
                self.step("Home mit walking betreten: zunächst keine Öffnung", lambda: self.send(self.p.home, 1, "walking"),
                          seconds=15 if number == 11 else self.p.settle, phase="returning", armed=True,
                          reasons=("arrival pending",))
                if number == 11:
                    self.step("Home nach 15 Sekunden wieder verlassen: GPS-Sprung abbrechen",
                              lambda: self.send(self.p.home, 0), armed=True, reasons=("arrival cancelled",))
                    self.step("Über die alte Ankunftsfrist hinaus warten: kein Aktionsplan",
                              seconds=self.p.times["arrival_wait_walking"] + self.p.settle, phase="away", armed=True)
                    self.arrival("Tatsächliche Home-Rückkehr mit neuer voller Frist", "walking", self.expected("door"))
                else:
                    self.step("Ein Haussensor bestätigt vorzeitig: nur die Tür", lambda: self.debug("debugPhone", "present"),
                              self.expected("door"), phase="home", phone="present", armed=False,
                              reasons=("arrival confirmed",))
                    self.step("Alte Ankunftsfrist verstreicht: keine zweite Öffnung",
                              seconds=self.p.times["arrival_wait_walking"] + self.p.settle, phase="home", armed=False)
        elif number == 7:
            self.step("Raumwechsel: kurze Telefon-Empfangslücke", lambda: self.debug("debugPhone", "absent"), phone="present")
            require(self.state()["phone"]["health"] == "handover", "Empfangslücke ist nicht als handover erkannt.")
            self.step("Falscher Außenbereich-Austritt während der Empfangslücke", lambda: self.send(self.p.outer, 0),
                      phase="home", armed=False, reasons=("departure contradicted by current local presence",))
            self.step("Empfangslücke dauert über die Mindestabwesenheit hinaus", seconds=self.p.times["minimum_away"], phone="present")
            self.step("Home-Eintritt während derselben Lücke: keine Öffnung", lambda: self.send(self.p.home, 1), phase="home", phone="present", armed=False)
            self.step("Ein Haussensor erkennt das Telefon wieder", lambda: self.debug("debugPhone", "present"), phase="home", phone="present", armed=False)
        elif number == 8:
            self.step("Home erneut betreten ohne Ausflug", lambda: self.send(self.p.home, 1), phase="home", armed=False,
                      reasons=("departure not confirmed",))
        elif number == 14:
            self.step("Home verlassen ohne weiteren Entfernungsnachweis", self.depart, armed=False)
            self.step("Lange Pause ersetzt keinen Entfernungsnachweis",
                      seconds=max(self.p.travel, self.p.times["departure_grace"]) + self.p.settle,
                      phase="away", phone="disabled", armed=False)
            self.step("Home betreten: Status home, keine Öffnung", lambda: self.send(self.p.home, 1, "walking"),
                      phase="home", phone="disabled", armed=False, reasons=("departure not confirmed",))
        elif number in (15, 16, 17, 18):
            self.step("Home verlassen", self.depart, armed=False)
            zone = self.p.checkpoint if number == 17 else self.p.outer
            self.step("Entfernten Helferort betreten" if number == 17 else "Außenbereich verlassen",
                      lambda: self.send(zone, 1 if number == 17 else 0), phase="away", phone="disabled", armed=True)
            self.step("Mindestabwesenheit abwarten", seconds=self.p.times["minimum_away"] + self.p.settle,
                      phase="away", armed=True)
            if number == 18:
                self.step("Außenbereich betreten; Home-Meldung fehlt", lambda: self.send(self.p.outer, 1),
                          seconds=self.p.times["phone_absence_window"] + self.p.settle,
                          phase="away", phone="disabled", armed=True)
            elif number == 16:
                self.step("Kurzer Home-Eintritt mit walking", lambda: self.send(self.p.home, 1, "walking"),
                          seconds=15, phase="returning", armed=True, reasons=("arrival pending",))
                self.step("Home wieder verlassen: vorgemerkte Ankunft abbrechen", lambda: self.send(self.p.home, 0),
                          armed=True, reasons=("arrival cancelled",))
                self.step("Alte Ankunftsfrist verstreichen lassen", seconds=self.p.times["arrival_wait_walking"] + self.p.settle,
                          phase="away", phone="disabled", armed=True)
                self.arrival("Echte Rückkehr zu Fuß: nur die Tür", "walking", self.expected("door"))
            else:
                body = self.arrival("Berechtigte Home-Rückkehr mit voller Ankunftsfrist",
                                    "walking" if number == 17 else "automotive",
                                    self.expected("door") if number == 17 else opens)
                self.step("Identischen Home-Webhook wiederholen: keine zweite Öffnung",
                          lambda: self.send(self.p.home, 1, body=body), phase="home", armed=False,
                          one_of_reasons=("duplicate event", "event too old or future"))
        self.results[-1]["passed"] = True
        self.output(f"BESTANDEN: Test {number}")

    def cleanup(self):
        if self.started:
            self.debug("debugReset", "keepGeometry")
            if self.p.phone:
                self.debug("debugPhoneMode", self.p.previous_phone_mode)
                if self.p.previous_phone_mode == "simulated":
                    self.debug("debugPhone", self.p.previous_sim_phone)


def selected_tests(value):
    if value == "all":
        return None
    try:
        result = [int(item) for item in value.split(",")]
    except ValueError as error:
        raise argparse.ArgumentTypeError("Testnummern kommagetrennt angeben, z. B. 1,2,3.") from error
    if not result or len(set(result)) != len(result) or any(item not in SCENARIOS for item in result):
        raise argparse.ArgumentTypeError("Erlaubt: all oder unterschiedliche Testnummern 1 bis 18, passend zum Quellenprofil.")
    return result


def main():
    parser = argparse.ArgumentParser(description="GeoPresence auf dem FHEM-Host automatisch über Debug-Webhooks und echte Logzeilen prüfen.")
    parser.add_argument("--list", action="store_true", help="Tests auflisten, ohne Verbindung")
    parser.add_argument("--tests", type=selected_tests, default=None, help="all für das Quellenprofil oder z. B. 1,2,3 (Standard: all)")
    parser.add_argument("--url", help="HTTPS-URL des gemeinsamen Webhooks (erforderlich)")
    parser.add_argument("--log", default=DEFAULT_LOG, help="Lokale Diagnosedatei; Datumsplatzhalter sind erlaubt")
    parser.add_argument("--controller", default="System.GeoPresence")
    parser.add_argument("--resident", help="FHEM-Bewohnergerät, z. B. Geo.PERSON (erforderlich)")
    parser.add_argument("--work-group", help="Frei benannte Arbeitsortgruppe bei mehreren möglichen Gruppen")
    parser.add_argument("--work", help="FHEM-Ortsgerät bei mehreren Arbeitsorten")
    parser.add_argument("--waypoint", help="FHEM-Ortsgerät Rückweg-Ort bei mehreren Wegpunkten")
    parser.add_argument("--checkpoint", help="Entfernter Helferort für Test 17; ergänzt bei geofency_only auch die Standardauswahl")
    parser.add_argument("--door-only", action="store_true", help="Für einen Bewohner ohne Garagenberechtigung")
    parser.add_argument("--telnet-port", type=int, default=7072)
    parser.add_argument("--telnet-password-prompt", action="store_true", help="Zusätzlich lokales Telnet-Kennwort verdeckt abfragen")
    parser.add_argument("--report", type=Path, help="Neue JSON-Ergebnisdatei; Standard: private/reports/geopresence-test-*.json; wird nicht überschrieben")
    args = parser.parse_args()
    if args.list:
        for number, title in SCENARIOS.items():
            print(f"{number:2}: {title}")
        return 0
    if not args.url or not args.resident:
        parser.error("--url und --resident sind erforderlich; --list zeigt Tests ohne Verbindung")
    report_path = args.report or DEFAULT_REPORT_DIR / ("geopresence-test-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".json")
    runner, log = None, None
    report = {"started": datetime.now(timezone.utc).isoformat(), "resident": args.resident, "tests": args.tests,
              "passed": False, "results": []}
    try:
        # Reserve a private report before starting a potentially long test.
        if args.report is None:
            DEFAULT_REPORT_DIR.parent.mkdir(mode=0o700, exist_ok=True)
            DEFAULT_REPORT_DIR.mkdir(mode=0o700, exist_ok=True)
        descriptor = os.open(report_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError as error:
        print(f"Ergebnisdatei kann nicht angelegt werden: {error}", file=sys.stderr)
        return 2
    code = 1
    try:
        telnet_password = password_prompt("Lokales FHEM-Telnet-Kennwort: ") if args.telnet_password_prompt else None
        telnet = Telnet(port=args.telnet_port, password=telnet_password)
        profile = Profile(telnet, args.controller, args.resident, args.tests, args.work, args.waypoint, args.door_only, args.checkpoint, args.work_group)
        report["tests"] = profile.tests
        report["sourceMode"] = profile.source_mode
        log = LogTail(args.log, Clock())
        print(f"Bewohner: {profile.resident}; Quellenprofil: {profile.source_mode}; Account: {profile.user}")
        print(f"Webhook: {args.url}\nGelesenes Log: {log.path}\nFHEM-logFile: {profile.log_path}")
        print(f"Echte Wartezeiten: Mindestabwesenheit {profile.times['minimum_away']:g} s; " +
              (f"Telefonabwesenheit {profile.times['phone_absence_window']:g} s." if profile.phone else "Telefonquelle deaktiviert."))
        print("Während des Laufs keine eigenen Geofency-Tests für diesen Bewohner senden. Abbruch mit Strg+C.")
        password = password_prompt("Aktuelles Geofency-Webhook-Kennwort: ")
        webhook = Webhook(args.url, profile.user, password, profile.webhook_path)
        runner = Runner(profile, webhook, log)
        report["results"] = runner.results
        for number in profile.tests:
            runner.run_case(number)
        report["passed"] = True
        code = 0
    except (KeyboardInterrupt, EOFError):
        report["error"] = "Vom Nutzer abgebrochen."
        code = 130
    except (TestFailure, OSError, ValueError, http.client.HTTPException) as error:
        report["error"] = str(error)
    finally:
        if runner:
            try:
                runner.cleanup()
            except Exception as error:
                report["cleanup_error"] = str(error)
                report["passed"] = False
                code = 1
        if log:
            log.close()
        report["finished"] = datetime.now(timezone.utc).isoformat()
        with open(descriptor, "w", encoding="utf-8", closefd=True) as output:
            json.dump(report, output, ensure_ascii=False, indent=2)
            output.write("\n")
    if code == 0:
        print(f"\nBESTANDEN: {len(report['tests'])} Tests. Bericht: {report_path}")
    else:
        print("\nNICHT BESTANDEN: " + report.get("error", report.get("cleanup_error", "Fehler")), file=sys.stderr)
        print(f"Bericht mit Schritt und tatsächlichen Logzeilen: {report_path}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
