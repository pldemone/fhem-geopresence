#!/usr/bin/env python3
"""Run GeoPresence against FHEM in a temporary installation with dummy actuators.

Usage: python3 t/geopresence_fhem_integration.py --fhem-dir /path/to/fhem [--encoding bytestream|unicode] [--help-only]
Only the selected stock modules are copied; no source configuration is loaded.
No downloads, real sensors, notifications or production devices are used.
"""

import argparse
import base64
from contextlib import ExitStack
import datetime
import gzip
import http.client
from html.parser import HTMLParser
from html import unescape
import json
import re
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.parse


STOCK = (
    "01_FHEMWEB.pm 98_help.pm 92_FileLog.pm 98_telnet.pm 98_dummy.pm 91_notify.pm 98_apptime.pm 20_ROOMMATE.pm 10_RESIDENTS.pm 73_PRESENCE.pm "
    "RESIDENTStk.pm Meta.pm Unit.pm UConv.pm GPUtils.pm RTypes.pm "
    "TcpServerUtils.pm HttpUtils.pm Blocking.pm DevIo.pm SetExtensions.pm AttrTemplate.pm 99_Utils.pm"
).split()


def unused_port():
    with socket.socket() as server:
        server.bind(("127.0.0.1", 0))
        return server.getsockname()[1]


class HelpMarkup(HTMLParser):
    """Capture the anchor/parent-li contract used by FHEMWEB's FW_displayHelp."""

    def __init__(self, text):
        super().__init__(convert_charrefs=True)
        self.tags, self.items, self.anchors = [], [], {}
        self.item_tags, self.blocks = [], {}
        self.first_anchor = None
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "li":
            self.items.append([])
            self.item_tags.append(set())
        for tags in self.item_tags:
            tags.add(tag)
        if tag == "a" and "id" in attributes:
            key = attributes["id"]
            if self.first_anchor is None:
                self.first_anchor = key
            if key in self.anchors:
                raise AssertionError("Duplicate help anchor: " + key)
            self.anchors[key] = (self.tags[-1] if self.tags else None,
                                 self.items[-1] if self.items else [])
            self.blocks[key] = self.item_tags[-1] if self.item_tags else set()
        if tag not in ("br", "hr", "img", "input", "meta", "link"):
            self.tags.append(tag)

    def handle_endtag(self, tag):
        if tag in self.tags:
            while self.tags:
                current = self.tags.pop()
                if current == "li":
                    self.items.pop()
                    self.item_tags.pop()
                if current == tag:
                    break

    def handle_data(self, data):
        for item in self.items:
            item.append(data)


def check_help(command, http_request, admin_port, check):
    _, headers, _ = http_request("GET", "/fhem", port=admin_port)
    token = headers.get("x-fhem-csrftoken", "")

    def web_help(target):
        query = urllib.parse.urlencode({"cmd": "help " + target, "XHR": 1, "fwcsrf": token})
        status, _, body = http_request("GET", "/fhem?" + query, port=admin_port)
        check(status == 200 and '<a id="GeoPresence">' in body,
              "real FHEMWEB help resolves " + target)
        return body

    body = web_help("GeoPresence EN")
    markup = HelpMarkup(body)
    check(markup.first_anchor == "GeoPresence", "FHEMWEB discovers the correct module anchor")
    check("Setup example: PERSON" in body and "Operation, transport and persistence" in body,
          "general module help contains setup and operation")
    attributes = command("{ my %common=map { $_=>1 } split / /,$readingFnAttributes;; "
                         "return join(' ',grep { !$common{$_} } split / /,$modules{GeoPresence}{AttrList}) }")
    attrs = [value.split(":", 1)[0] for value in attributes.split()]
    check(len(attrs) == 55, "all 55 registered module attributes included in help checks")
    for removed in ("phoneAggregate", "absenceProxies", "webDevice", "role", "condition"):
        check(removed not in attrs and "GeoPresence-attr-" + removed not in markup.anchors,
              "removed attribute has no registry entry or contextual help: " + removed)
    entries = {"attr": attrs,
               "set": "mode webhookPassword learnConfirm applyGeometry debugReset debugPhoneMode debugPhone debugAdvance".split(),
               "get": "validate learnedLocations locationCommands debugTrace explain logStatus timerStats".split()}
    for category, names in entries.items():
        for name in names:
            anchor = "GeoPresence-" + category + "-" + name
            parent, parts = markup.anchors.get(anchor, (None, []))
            text = "".join(parts).strip()
            check(parent == "li" and len(text) > 80 and name in text,
                  "FHEMWEB can extract nonempty contextual help for " + category + " " + name)
            check({"p", "pre"}.issubset(markup.blocks.get(anchor, set())),
                  "contextual help separates explanations and command example for " + name)
            if category == "attr":
                check("Applies to:" in text, "attribute help identifies the applicable device for " + name)
    for target in ("GP", "Geo.Test", "Z.Home", "A.Door", "R.Door"):
        check(web_help(target) == body, "English default help resolves device type for " + target)
    check('id="GeoPresence-set-mode"' in web_help("GeoPresence DE"),
          "German help selection falls back to the complete English reference")
    text = command("help GP EN")
    check("GeoPresence" in text and "phoneProxies" in text and "<li>" not in text,
          "Telnet returns readable module help")
    status, _, detail = http_request("GET", "/fhem?detail=GP", port=admin_port)
    check(status == 200 and re.search(r"optgroup label=['\"]GeoPresence['\"]", detail),
          "FHEMWEB groups module attributes under GeoPresence for contextual help")


def check_attribute_widgets(command, http_request, admin_port, check):
    class Detail(HTMLParser):
        def __init__(self, html):
            super().__init__(convert_charrefs=True)
            self.attr_list = {}
            self.feed(html)

        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            if tag == "div" and attrs.get("cmd") == "attr":
                self.attr_list = dict((item.split(":", 1) + [""])[:2]
                                      for item in attrs["list"].split())

    def widget_list(device):
        status, _, html = http_request("GET", "/fhem?detail=" + device, port=admin_port)
        check(status == 200, "FHEMWEB detail page available for " + device)
        return Detail(html).attr_list

    module_names = set(command("{ return join(' ',map { s/:.*//r } split / /,$modules{GeoPresence}{AttrList}) }").split())
    common = set(command("{ return $readingFnAttributes }").split())
    common = {item.split(":", 1)[0] for item in common}
    module_names -= common
    expected = {
        "GP": "webhookPath webhookPort webhookBindAddress webhookAllowedPeers logFile debugLog "
              "action_max_age future_tolerance reorder_window departure_grace minimum_away phone_absence_window "
              "phone_poll motion_max_age approach_timeout zone_display_max_age actor_timeout departure_margin "
              "arrival_wait_walking arrival_wait_running arrival_wait_cycling arrival_wait_automotive "
              "arrival_wait_unknown arrival_motion_max_age trip_resume_max_age",
        "Geo.Test": "sourceMode deviceId webhookUser phoneProxies phoneSignalMode "
                    "allowDoor allowGarage",
        "Z.Home": "zoneId label groups",
        "A.Door": "target command contact feedbackDevice positionSignalMode",
        "A.Garage": "target command stateDevice upperContact lowerContact positionSignalMode",
        "A.WidgetMessage": "message priority channel",
        "A.WidgetLight": "target command",
        "R.Door": "enabled trigger residents afterExit arrivalFilter action cooldown",
    }
    command("define A.WidgetMessage GeoPresence action GP notify")
    command("define A.WidgetLight GeoPresence action GP switch_on")
    widgets = {}
    for device, attributes in expected.items():
        widgets[device] = widget_list(device)
        check(set(widgets[device]) & module_names == set(attributes.split()),
              "only applicable GeoPresence attributes offered for " + device)
        check({"alias", "room", "verbose", "userattr"}.issubset(widgets[device])
              and common.issubset(widgets[device]), "framework attributes preserved for " + device)

    enums = {
        ("GP", "debugLog"): "auto,0,1",
        ("Geo.Test", "sourceMode"): "geofency_phone,geofency_only,phone_only",
        ("Geo.Test", "phoneSignalMode"): "state,measurement",
        ("A.Door", "positionSignalMode"): "state,measurement",
        ("A.Garage", "positionSignalMode"): "state,measurement",
        ("Geo.Test", "allowDoor"): "0,1", ("Geo.Test", "allowGarage"): "0,1",
        ("R.Door", "enabled"): "1,0",
        ("R.Door", "trigger"): "arrival,enter,exit",
        ("R.Door", "arrivalFilter"): "any,vehicle",
        ("A.WidgetMessage", "priority"): "0,1,2", ("A.WidgetMessage", "channel"): "0,1,2,10",
        ("A.Door", "command"): "select,lock#unlocked",
        ("A.Garage", "command"): "select,on", ("A.WidgetLight", "command"): "select,on",
    }
    for (device, attribute), spec in enums.items():
        check(widgets[device][attribute] == spec, "native widget offers correct values for " + device + " " + attribute)
        check(bool(command(f"attr {device} {attribute} invalid-value")),
              "invalid typed value rejected for " + device + " " + attribute)
    check("unknown attribute" in command("attr Z.Home allowDoor 1"), "Telnet also rejects attributes for a different subtype")
    for device, removed in (("GP", "webDevice"), ("Geo.Test", "phoneAggregate"), ("Geo.Test", "absenceProxies")):
        check("unknown attribute " + removed in command(f"attr {device} {removed} unused"),
              "FHEM rejects removed attribute without compatibility fallback: " + removed)
    check("unknown attribute" in command("attr A.WidgetMessage target door"), "notification action cannot acquire actuator attributes")
    check(not command("attr A.Door command lock unlocked"), "fixed command with a space round-trips through FHEM")
    check(command("{ return AttrVal('A.Door','message','') }") == "legacy unused value",
          "old irrelevant action attribute survives config loading")
    check(not command("deleteattr A.Door message"), "old irrelevant action attribute can be deleted")

    check(widgets["Geo.Test"]["phoneProxies"] == "multiple-strict,p1,p2", "sensor list contains only PRESENCE devices")
    check(widgets["R.Door"]["residents"] == "multiple-strict,Geo.Test", "resident selector uses GeoPresence resident names")
    command("define R.Widget GeoPresence rule GP")
    command("attr R.Widget trigger enter")
    check(set(widget_list("R.Widget")["locations"].split(",")[1:]) == {"Z.Home", "Z.Outer", "Z.Work", "Z.Drive"},
          "location selector lists this controller's locations")
    check("Work" in widget_list("R.Widget")["locationGroup"], "free group appears in the selector")
    command("delete R.Widget")
    check("A.WidgetMessage" in widgets["R.Door"]["action"], "newly defined action appears in the rule dropdown")

    # A display refresh must not reset in-flight trips, queues or learning.
    epoch = command("{ return $defs{GP}{helper}{gp}{epoch} }")
    command("define pWidget PRESENCE event rr_Test:FakeAbsent rr_Test:FakePresent")
    check("pWidget" in widget_list("Geo.Test")["phoneProxies"], "new sensor appears without module reload")
    command("rename pWidget 9.pRenamed")
    spec = widget_list("Geo.Test")["phoneProxies"]
    check("9.pRenamed" in spec and "pWidget" not in spec, "sensor rename also supports FHEM names beginning with a digit")
    command("delete 9.pRenamed")
    check("9.pRenamed" not in widget_list("Geo.Test")["phoneProxies"], "deleted sensor disappears from choices")
    check(command("{ return $defs{GP}{helper}{gp}{epoch} }") == epoch,
          "unrelated device changes update widgets without resetting runtime")

    command("rename p1 pMoved")
    spec = widget_list("Geo.Test")["phoneProxies"].split(",")
    check("pMoved" in spec and "p1" in spec, "stale configured reference remains visible alongside the renamed device")
    check(command("{ return AttrVal('Geo.Test','phoneProxies','') }") == "p1,p2",
          "refreshing choices does not silently rewrite configured references")
    check("invalid PRESENCE proxy p1" in command("get GP validate"), "validation still rejects the stale sensor reference")
    command("rename pMoved p1")

    command("rename A.WidgetMessage A.RenamedMessage")
    spec = widget_list("R.Door")["action"]
    check("A.RenamedMessage" in spec and "A.WidgetMessage" not in spec, "action rename refreshes rule choices")
    command("delete A.RenamedMessage")
    command("delete A.WidgetLight")
    check("A.RenamedMessage" not in widget_list("R.Door")["action"], "deleted action disappears from choices")
    command("reload 98_GeoPresence.pm")
    check(set(widget_list("A.Door")) & module_names == set(expected["A.Door"].split()),
          "module reload reinstates per-action attribute lists on existing devices")
    # List order may change on save; group must be accepted before trigger.
    command("define R.Widget GeoPresence rule GP")
    check(not command("attr R.Widget locationGroup Work") and not command("attr R.Widget trigger enter"),
          "dependent rule attributes can be configured in either order")
    check(command("attr R.Widget group DisplayOnly") == "", "standard FHEM group remains usable independently")
    check(command("{ AttrVal('R.Widget','locationGroup','') }") == "Work" and
          command("{ AttrVal('R.Widget','group','') }") == "DisplayOnly", "locationGroup does not overwrite display grouping")
    command("delete R.Widget")
    command("attr Geo.Test sourceMode geofency_only")
    check(not ({"phoneProxies", "phoneSignalMode"} & widget_list("Geo.Test").keys()),
          "geo-only source hides phone configuration immediately")
    check(command("{ AttrVal('Geo.Test','phoneProxies','') }") == "p1,p2",
          "profile selection never silently deletes the existing sensor list")
    check("unknown attribute" in command("attr Geo.Test phoneProxies p1"),
          "geo-only cannot configure an inactive phone source")
    command("attr Geo.Test sourceMode phone_only")
    check(not ({"deviceId", "webhookUser", "allowDoor", "allowGarage"} & widget_list("Geo.Test").keys()),
          "phone-only hides Geo identity and opening-permission fields")
    command("deleteattr Geo.Test sourceMode")
    check("phoneProxies" in widget_list("Geo.Test") and "deviceId" in widget_list("Geo.Test"),
          "removing sourceMode restores combined default and both field groups")


def check_parameter_cleanup(command, repo, check):
    """Keep the installed step-1 cleanup covered after its operator file was retired."""
    snapshot = "{ JSON::PP::encode_json({map { $_ => $attr{$_} // {} } GP_DeviceNames($defs{GP})}) }"
    before = json.loads(command(snapshot))
    device_list = "{ join(' ',sort grep { !$defs{$_}{TEMPORARY} } keys %defs) }"
    devices = command(device_list)
    secret = command("{ (GP_ReadAuth('Geo.Test'))[1] }")
    # Represent an in-memory configuration loaded by the preceding module.
    # These names must not be registerable with the new module itself.
    command("{ $attr{'Geo.Test'}{phoneAggregate}='phone';; $attr{'Geo.Test'}{absenceProxies}='p1';; "
            "$attr{GP}{webDevice}='WEBadmin';; $attr{phone}{phoneAggregate}='unrelated';; return 'seeded' }")
    # Step 1 is installed; keep the regression without its retired operator file.
    deletes = ["deleteattr TYPE=GeoPresence:FILTER=SUBTYPE=resident phoneAggregate",
               "deleteattr TYPE=GeoPresence:FILTER=SUBTYPE=resident absenceProxies",
               "deleteattr TYPE=GeoPresence:FILTER=SUBTYPE=controller webDevice"]
    for repeat in range(2):
        for line in deletes:
            check(command(line) == "", f"cleanup command succeeds on pass {repeat + 1}: {line}")
        check(json.loads(command(snapshot)) == before, "cleanup preserves every other GeoPresence attribute")
    check(command("{ AttrVal('phone','phoneAggregate','') }") == "unrelated",
          "cleanup selection leaves similarly named attributes on unrelated devices intact")
    check(command(device_list) == devices,
          "cleanup retains residents, locations, actions, rules, sensors, aggregation and FHEMWEB devices")
    check(command("reload 98_GeoPresence.pm") == "", "clean configuration reloads with the new module")
    check(json.loads(command(snapshot)) == before, "reload retains resident modes and configured sources")
    check(command("{ (GP_ReadAuth('Geo.Test'))[1] }") == secret,
          "cleanup and reload preserve the existing webhook password record")
    check(command("get GP validate").startswith("OK:"), "cleaned configuration validates after reload")
    for device, removed in (("GP", "webDevice"), ("Geo.Test", "phoneAggregate"), ("Geo.Test", "absenceProxies")):
        check("unknown attribute " + removed in command(f"attr {device} {removed} unused"),
              "removed attribute remains unavailable after reload: " + removed)
    command("delete phone")  # Isolated dummy only: prove no aggregate is needed at all.
    check(command("get GP validate").startswith("OK:"), "validation also works with no aggregation device")


def check_resident_status(command, http_request, admin_port, check, device, expected):
    check(command("{ InternalVal('" + device + "','STATE','') }") == expected,
          f"{device} device status is {expected}")
    # The 2023 stock FHEMWEB encodes native wide-character detail HTML inside
    # its gzip branch. Use the normal browser negotiation for this framework
    # page; module report transport is tested compressed AND uncompressed above.
    status, _, html = http_request("GET", "/fhem?detail=" + device,
                                 headers={"Accept-Encoding": "gzip"}, port=admin_port)
    cell = re.search(r'<td\b[^>]*\binformId=[\'\"]' + re.escape(device)
                     + r'[\'\"][^>]*>(.*?)</td>', html, re.S)
    displayed = unescape(re.sub(r"<[^>]*>", "", cell.group(1))).strip() if cell else None
    check(status == 200 and displayed == expected,
          f"FHEMWEB overview displays {expected} for {device}")


def check_set_widgets(command, http_request, admin_port, password, check):
    """Read actual detail-page choices and submit the native FHEMWEB set form."""
    class Detail(HTMLParser):
        def __init__(self, html, device):
            super().__init__(convert_charrefs=True)
            self.device, self.specs, self.options, self.in_set = device, {}, [], False
            self.feed(html)

        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            if tag == "div" and attrs.get("cmd") == "set" and attrs.get("dev") == self.device:
                self.specs = dict((item.split(":", 1) + [""])[:2] for item in attrs["list"].split())
            if tag == "select":
                self.in_set = attrs.get("name") == "arg.set" + self.device
            if tag == "option" and self.in_set:
                self.options.append(attrs.get("value", ""))

        def handle_endtag(self, tag):
            if tag == "select":
                self.in_set = False

    def detail(device):
        status, _, html = http_request("GET", "/fhem?detail=" + device, port=admin_port)
        check(status == 200, "FHEMWEB set detail available for " + device)
        return Detail(html, device)

    _, headers, _ = http_request("GET", "/fhem", port=admin_port)
    token = headers["x-fhem-csrftoken"]

    def web_set(device, setter, value):
        suffix = "set" + device
        form = urllib.parse.urlencode({"cmd." + suffix: "set", "dev." + suffix: device,
                                       "arg." + suffix: setter, "val." + suffix: value,
                                       "XHR": 1, "fwcsrf": token})
        status, _, body = http_request("POST", "/fhem", form,
                                      {"Content-Type": "application/x-www-form-urlencoded"}, port=admin_port)
        check(status == 200, "FHEMWEB accepts native set form for " + setter)
        return body

    expected = sorted("mode applyGeometry debugReset debugPhoneMode debugPhone debugAdvance".split())
    menu = detail("GP")
    check(menu.options == expected, "controller set dropdown contains six distinct executable commands")
    for setter in ("applyGeometry",):
        check(menu.specs[setter] == "select,,Geo.Test", "resident dropdown offered for " + setter)
    check(menu.specs["debugReset"] == "select,,Geo.Test,Geo.Test#keepGeometry", "reset dropdown supports geometry retention")
    check(menu.specs["debugPhoneMode"] == "select,,Geo.Test#live,Geo.Test#simulated", "phone mode dropdown has fixed arguments")
    check(menu.specs["debugPhone"] == "select,,Geo.Test#present,Geo.Test#absent", "phone observation dropdown has fixed arguments")
    check(menu.specs["debugAdvance"] == "textField", "debug time has an editable argument field")
    check(detail("Geo.Test").options == ["learnConfirm", "mode", "webhookPassword"], "resident set dropdown contains credential command")
    for device in ("Z.Home", "A.Door", "R.Door"):
        check(detail(device).options == [], "no spurious set menu on " + device)
    check("stored" in web_set("Geo.Test", "webhookPassword", password), "resident set form stores test credentials")
    check("Learning for 15" in web_set("Geo.Test", "mode", "learning"), "resident native mode form starts learning")
    check_resident_status(command, http_request, admin_port, check, "Geo.Test", "learning")
    check("No device or location captured" in web_set("Geo.Test", "learnConfirm", ""), "native no-argument confirmation rejects empty capture")
    check(web_set("Geo.Test", "mode", "disabled") == "", "resident set form cancels learning")
    check_resident_status(command, http_request, admin_port, check, "Geo.Test", "disabled")
    check(web_set("Geo.Test", "mode", "debug") == "", "resident set form enables simulation")
    check_resident_status(command, http_request, admin_port, check, "Geo.Test", "debug")
    check(web_set("Geo.Test", "mode", "active") == "", "resident can request active under global debug")
    check(command("{ ReadingsVal('Geo.Test','mode','') }") == "active", "personal mode remains independently visible")
    check_resident_status(command, http_request, admin_port, check, "Geo.Test", "debug")
    check(web_set("Geo.Test", "mode", "debug") == "", "restore simulation after checking controller precedence")
    check(menu.specs["mode"] == "active,debug,disabled", "controller mode has a fixed dropdown")
    for setter, value, expected_reply in (
            ("applyGeometry", "Geo.Test", "Geometry applied for 0 location(s)"),
            ("debugReset", "Geo.Test#keepGeometry", "Debug session reset; geometry retained"),
            ("debugPhoneMode", "Geo.Test#simulated", "Debug state updated"),
            ("debugPhone", "Geo.Test#absent", "Debug state updated"),
            ("debugPhone", "Geo.Test#present", "Debug state updated"),
            ("debugAdvance", "Geo.Test 1", "Debug state updated"),
            ("debugReset", "Geo.Test", "Debug session reset; no productive changes"),
            ("debugPhoneMode", "Geo.Test#live", "Debug state updated")):
        if menu.specs[setter] != "textField":
            check(value in menu.specs[setter].split(",")[1:], "submitted argument is present in rendered widget: " + value)
        # Native FW_createSelect replaces '#' with a space in each option value.
        reply = web_set("GP", setter, value.replace("#", " "))
        check(reply.startswith(expected_reply), "native set form executes " + setter + ": " + reply)
    check(command("{ ReadingsVal('door','state','untouched') }") == "untouched"
          and command("{ ReadingsVal('garage','state','untouched') }") == "untouched",
          "set-menu simulation and setup commands do not dispatch actuator commands")
    command("attr Geo.Test sourceMode geofency_only")
    check(detail("GP").specs["debugPhone"] == "textField", "phone dropdown updates when resident source profile changes")
    command("deleteattr Geo.Test sourceMode")
    command("{ $defs{'Geo.Test'}{STATE}='configured';; return '' }")
    command("reload 98_GeoPresence.pm")
    check_resident_status(command, http_request, admin_port, check, "Geo.Test", "debug")
    check(detail("GP").options == expected, "controller set choices survive module reload")


def check_reports(command, http_request, admin_port, check):
    """Exercise the actual FHEMWEB get-button transport, including addLinks."""
    _, headers, _ = http_request("GET", "/fhem", port=admin_port)
    token = headers.get("x-fhem-csrftoken", "")

    def web_get(query, compressed=False):
        params = urllib.parse.urlencode({"cmd": "get GP " + query, "XHR": 1,
                                        "addLinks": 1, "fwcsrf": token})
        status, _, body = http_request("GET", "/fhem?" + params, port=admin_port,
                                      headers={"Accept-Encoding": "gzip"} if compressed else None)
        check(status == 200, "FHEMWEB get succeeds: " + query)
        return body

    for query, expected in (("explain Geo.Test", "Status"),
                            ("explain Geo.Test debug", "Debug ready"),
                            ("debugTrace Geo.Test", "Recent decisions"),
                            ("timerStats", "Delayed starts"),
                            ("logStatus", "Production diagnostics"),
                            ("validate", "set webhookPassword first")):
        text = command("get GP " + query)
        check(expected.lower() in text.lower() and "\n" in text and "<html>" not in text,
              "Telnet default is multiline text: " + query)
        html = web_get(query)
        check(html.startswith("<html>") and expected in html and "gp-report" in html,
              "get button receives native HTML: " + query)
        check("<a href='/fhem?detail=" not in html,
              "FHEMWEB automatic link rewriting cannot damage the report: " + query)
        json.loads(command("get GP " + query + " format=json"))
        json.loads(web_get(query + " format=json"))
        check(True, "explicit JSON parses in both interfaces: " + query)
    check("<details" in web_get("explain Geo.Test"), "full report keeps native disclosure elements")
    check("white-space:pre-wrap" in web_get("explain Geo.Test format=text"),
          "explicit browser text wraps")
    check(command("get GP explain Geo.Test format=html").startswith("<html>"),
          "explicit HTML also works over Telnet")
    check("Choose format" in command("get GP explain Geo.Test format=invalid"),
          "unknown output format is explained")
    check("Specify a resident" in json.loads(web_get("explain Missing format=json"))["error"],
          "machine errors use a JSON error object")

    discovery = dict((item.split(":", 1) + [""])[:2] for item in command("{ getAllGets('GP') }").split())
    check(discovery.get("explain") == "select,Geo.Test,Geo.Test#prod,Geo.Test#debug" and "debugState" not in discovery,
          "native FHEMWEB get list includes resident dropdown for the unified command")
    for selector, selected in (("", "production"), ("prod", "production"), ("debug", "debug")):
        query = f"explain Geo.Test {selector}".strip()
        html = web_get(query)
        check(f"=== {selected.upper()} ===" in html, "web report shows chosen state: " + query)
        check(re.search(r"Effective mode</td><td[^>]*>debug</td>", html) is not None,
              "view selection preserves actual operating mode")
        for heading in ("Status", "Arrival actions", "Locations and geometry", "Phone sensors", "Configured rules", "Technical details"):
            check(heading in html, "full report includes " + heading)
        value = json.loads(web_get(query + " format=json"))
        check(value["view"] == selected and value["mode"] == "debug" and "state" in value,
              "JSON has the complete selected state")
    for rejected in ("view=debug", "detail=all", "production", "prod debug"):
        check("[prod|debug]" in web_get("explain Geo.Test " + rejected), "invalid or removed syntax explained: " + rejected)

    class GetMenu(HTMLParser):
        def __init__(self, body, device):
            super().__init__(convert_charrefs=True)
            self.device, self.spec = device, ""
            self.feed(body)

        def handle_starttag(self, tag, attrs):
            attrs = dict(attrs)
            if tag == "div" and attrs.get("cmd") == "get" and attrs.get("dev") == self.device:
                entries = dict((item.split(":", 1) + [""])[:2] for item in attrs["list"].split())
                self.spec = entries.get("explain", "")

    for device in ("GP", "Geo.Test"):
        status, _, page = http_request("GET", "/fhem?detail=" + device, port=admin_port)
        menu = GetMenu(page, device)
        expected = "select,Geo.Test,Geo.Test#prod,Geo.Test#debug" if device == "GP" else "select,prod,debug"
        check(status == 200 and menu.spec == expected, "actual detail page offers resident/state choices for " + device)
        for choice in menu.spec.split(",")[1:]:
            suffix = "get" + device
            form = urllib.parse.urlencode({"cmd." + suffix: "get", "dev." + suffix: device,
                                           "arg." + suffix: "explain", "val." + suffix: choice.replace("#", " "),
                                           "XHR": 1, "fwcsrf": token})
            status, _, body = http_request("POST", "/fhem", form,
                                          {"Content-Type": "application/x-www-form-urlencoded"}, port=admin_port)
            banner = "DEBUG" if choice.endswith("debug") else "PRODUCTION"
            check(status == 200 and f"=== {banner} ===" in body and "Technical details" in body,
                  "native get form executes selected complete report: " + choice)

    command('attr rr_Test alias Jörg <img src=x onerror="alert(1)"> & friends')
    html = web_get("explain Geo.Test")
    check('Jörg <img' in unescape(html) and '<img src=x' not in html and '&amp; friends' in html,
          "actual FHEM encoding preserves names and escapes executable markup")
    check('href="/fhem?detail=p1"' in html and '<a href="<a ' not in html,
          "generated device links survive the real addLinks request")
    check('Jörg <img' in unescape(web_get("explain Geo.Test", compressed=True)),
          "compressed HTML displays the same safe Unicode name")
    command("set GP debugReset Geo.Test")
    command('{ $defs{GP}{helper}{gp}{debug}{"Geo.Test"}{last_reason}="<script>alert(1)</script> J".chr(246)."rg ".chr(0x1f319);; return "fixture set" }')
    for compressed in (False, True):
        raw = web_get("explain Geo.Test debug format=json", compressed=compressed)
        check("<script>" not in raw and json.loads(raw)["state"]["last_reason"] == '<script>alert(1)</script> Jörg 🌙',
              "browser JSON preserves Unicode and masks markup with gzip=" + str(compressed))
    command("set GP debugReset Geo.Test")
    command("deleteattr rr_Test alias")
    check(command("{ ReadingsVal('door','state','untouched') }") == "untouched"
          and command("{ ReadingsVal('garage','state','untouched') }") == "untouched",
          "reading reports does not dispatch actuator commands")


def check_http_quotas(command, http_request, request, auth_headers, password, check):
    """Exercise authentication and elapsed-time quotas over the real listener."""
    for line in ("define rr_Rate ROOMMATE", "define Geo.Rate GeoPresence resident GP rr_Rate",
                 "attr Geo.Rate sourceMode geofency_only", "attr Geo.Rate deviceId rate-device",
                 "attr Geo.Rate webhookUser rate-user", f"set Geo.Rate webhookPassword {password}",
                 "set Geo.Rate mode debug"):
        result = command(line)
        check("stored" in result if "webhookPassword" in line else result == "", "prepare quota test resident")
    command("{ $main::GP_rate_wall=GP_Now();; $main::GP_rate_mono=GP_Mono()+60;; "
            "no warnings 'redefine';; *GP_Now=sub { $main::GP_rate_wall };; "
            "*GP_Mono=sub { $main::GP_rate_mono };; GeoPresence_Timer($defs{GP});; return 'quota clocks set' }")
    headers = auth_headers()
    other_headers = dict(headers, Authorization="Basic " + base64.b64encode(f"rate-user:{password}".encode()).decode())

    def post(selected=headers):
        return http_request("POST", "/fhem/geopresence", "isTest=invalid", selected)[0]

    try:
        unknown = dict(headers, Authorization="Basic " + base64.b64encode(b"unknown:invalid").decode())
        for label, failed in (("missing", auth_headers(False)), ("wrong", auth_headers("wrong")), ("unknown", unknown)):
            statuses = [post(failed) for _ in range(121)]
            check(statuses == [401] * 121, f"{label} credentials never consume the processing quota")
        check(request("Home", 1, debug=True)[0] == 200, "valid webhook remains available after failed logins")
        check([post() for _ in range(119)] == [400] * 119, "all remaining authenticated processing slots are available")
        check(post() == 429, "authenticated request 121 is limited")
        check(post(auth_headers(False)) == 401, "exhausted quota retains the authentication challenge")
        command("{ $main::GP_rate_mono+=30;; return 'elapsed' }")
        check([post(other_headers) for _ in range(120)] == [400] * 120, "another resident retains its full quota")
        check(post(other_headers) == 429, "second resident has its own limit")
        command("{ $main::GP_rate_mono+=30;; return 'elapsed' }")
        check(post() == 400 and post(other_headers) == 429, "residents renew at independent deadlines")
        command("{ $main::GP_rate_mono+=30;; return 'elapsed' }")
        check(post(other_headers) == 400, "second resident renews at its own deadline")
        check(command("set Geo.Rate mode learning").startswith("Learning for 15 minutes"),
              "quota test enters the real learning mode")
        check([post(other_headers) for _ in range(119)] == [400] * 119, "learning shares the resident quota")
        check(post(other_headers) == 429, "mode change did not reset the processing limit")

        for shift in (-3600, 3600):
            command("{ $main::GP_rate_mono+=60;; return 'new window' }")
            check([post() for _ in range(120)] == [400] * 120, f"shift {shift}: full initial window")
            command(f"{{ $main::GP_rate_wall+={shift};; $main::GP_rate_mono+=59;; return 'clock corrected' }}")
            check(post() == 429, f"shift {shift}: still limited before 60 elapsed seconds")
            command("{ $main::GP_rate_mono+=1;; return 'elapsed' }")
            check(post() == 400, f"shift {shift}: renews exactly at 60 monotonic seconds")
            check([post() for _ in range(119)] == [400] * 119 and post() == 429,
                  f"shift {shift}: renewed window retains the full limit")
        check(command("delete Geo.Rate") == "", "temporary quota resident can be deleted")
        check(command("{ exists $defs{GP}{helper}{gp}{http_rate}{'Geo.Rate'} ? 1:0 }") == "0",
              "deleted resident leaves no quota entry")
    finally:
        command("delete Geo.Rate")
        command("delete rr_Rate")
        command("{ no warnings 'redefine';; "
                "*GP_Now=sub { ($main::GP_fixture_fixed_wall // Time::HiRes::time())+$main::GP_fixture_offset };; "
                "*GP_Mono=sub { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())+$main::GP_fixture_offset };; "
                "GP_ResetController($defs{GP});; GeoPresence_Timer($defs{GP});; return 'quota fixture cleared' }")


def check_auth_key_names(command, http_request, auth_headers, password, check):
    """Use the real regex-based FHEM store with colliding legacy names."""
    other_password = "other_password_0123456789"
    for line in ("define rr_Key ROOMMATE", "define GeoBA GeoPresence resident GP rr_Key",
                 "attr GeoBA sourceMode geofency_only", "attr GeoBA webhookUser key-user",
                 f"set GeoBA webhookPassword {other_password}", "set GeoBA mode debug"):
        result = command(line)
        check("stored" in result if "webhookPassword" in line else result == "",
              "prepare independent key-store login: " + " ".join(line.split()[:3])
              + ("" if "webhookPassword" in line else ": " + result))
    other_headers = dict(auth_headers(), Authorization="Basic " + base64.b64encode(f"key-user:{other_password}".encode()).decode())

    def post(headers):
        return http_request("POST", "/fhem/geopresence", "isTest=invalid", headers)[0]

    def check_foreign_lines():
        check(command("{ my ($err,@lines)=FileRead('./FHEM/FhemUtils/uniqueID');; "
                      "return !$err && (grep {$_ eq 'GeoPresence_GeoCA_auth:foreign value'} @lines) "
                      "&& (grep {$_ eq '# retained comment'} @lines) ? 1:0 }") == "1",
              "exact cleanup preserves foreign entries and comments")

    try:
        check(command("rename Geo.Test Geo.A") == "", "prepare dotted person name")
        check(command("{ my $file='./FHEM/FhemUtils/uniqueID';; my ($err,@lines)=FileRead($file);; die $err if $err;; "
                      "my $a=GP_AuthKey('Geo.A');; my $b=GP_AuthKey('GeoBA');; "
                      "my $first=(GP_ReadAuth('Geo.A'))[1];; my $second=(GP_ReadAuth('GeoBA'))[1];; "
                      "return FileWrite($file,(grep {index($_,$a.':')!=0 && index($_,$b.':')!=0} @lines),"
                      "'GeoPresence_GeoBA_auth:'.$second,'GeoPresence_Geo.A_auth:'.$first,"
                      "'GeoPresence_GeoCA_auth:foreign value','# retained comment') // 'seeded' }") == "seeded",
              "seed exact old-format entries with distinct passwords")
        command("{ GP_ResetController($defs{GP});; GeoPresence_Timer($defs{GP});; return 'reset' }")
        check(post(auth_headers()) == 400 and post(other_headers) == 400,
              "legacy lookup does not confuse names matched by a dot")
        check(command("{ defined((getKeyValue(GP_AuthKey('Geo.A')))[1]) ? 1:0 }") == "0",
              "reading a legacy password does not write a new key")
        for old, new in (("Geo.A", "GeoXA"), ("GeoXA", "Geo.A")):
            check(command(f"rename {old} {new}") == "", "rename succeeds: " + old + " to " + new)
            command("{ GP_ResetController($defs{GP});; GeoPresence_Timer($defs{GP});; return 'reset' }")
            check(post(auth_headers()) == 400, "migrated password authenticates with a cold cache")
            check(post(other_headers) == 400, "unrelated password authenticates with a cold cache")
            check(command("{ defined((GP_ReadAuth('" + old + "'))[1]) ? 1:0 }") == "0",
                  "old exact key is absent")
            check_foreign_lines()
        command("{ my $file='./FHEM/FhemUtils/uniqueID';; my ($err,@lines)=FileRead($file);; die $err if $err;; "
                "return FileWrite($file,@lines,'GeoPresence_Geo.A_auth:'.(GP_ReadAuth('Geo.A'))[1]) }")
        check("stored" in command(f"set Geo.A webhookPassword {password}"), "password change cleans a dotted legacy key")
        check(post(auth_headers()) == 400 and post(other_headers) == 400, "password change preserves both logins")
        check_foreign_lines()
    finally:
        command("{ CommandRename(undef,'GeoXA Geo.Test') if $defs{GeoXA};; "
                "CommandRename(undef,'Geo.A Geo.Test') if $defs{'Geo.A'};; return 'restored' }")
        command("delete GeoBA")
        command("delete rr_Key")
        command("{ GP_ResetController($defs{GP});; GeoPresence_Timer($defs{GP});; return 'reset' }")
    check(command("get GP validate").startswith("OK:"), "original configuration validates after key-store checks")


def check_lifecycle(command, request, advance, web_port, check):
    """Check real FHEM renames, credential storage and ROOMMATE failures."""
    original_offset = float(command("{ $main::GP_fixture_offset }"))
    try:
        with socket.create_connection(("127.0.0.1", web_port), timeout=4) as partial:
            partial.sendall(b"POST /fhem/geopresence HTTP/1.1\r\n")
            for _ in range(10):
                if command("{ scalar keys %{$defs{GP}{helper}{gp_http}{clients}} }") == "1":
                    break
            else:
                raise AssertionError("rename test client was not accepted")
            check(command("rename GP GP.Renamed") == "", "real controller rename succeeds")
            check(command("{ exists $selectlist{'GeoPresenceHTTP:GP'} ? 1:0 }") == "0", "old listener is deregistered")
            check(partial.recv(1) == b"", "partial old client is closed")
        command("{ GeoPresence_Timer($defs{'GP.Renamed'});; return 'ticked' }")
        check(command("{ $defs{'GP.Renamed'}{helper}{gp_http}{server}{OWNER} }") == "GP.Renamed",
              "reopened listener belongs to the renamed controller")
        check(command("{ $defs{'Geo.Test'}{DEF} }") == "resident GP.Renamed rr_Test", "resident definition follows controller")
        check(command("{ $defs{'A.Door'}{DEF} }") == "action GP.Renamed door_open", "action definition follows controller")
        check(request("Home", 1, debug=True)[0] == 200, "renamed controller accepts a real authenticated webhook")
        command("save")
        check(command("{ my ($err,@lines)=FileRead('test.cfg');; return scalar grep {/^define Geo.Test GeoPresence resident GP.Renamed rr_Test/} @lines }") == "1",
              "save persists the repaired parent definition")
        check(command("rename GP.Renamed GP") == "", "controller can be renamed back")
        command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")
        secret = command("{ (GP_ReadAuth('Geo.Test'))[1] }")
        check(command("rename Geo.Test Geo.Renamed") == "", "real resident rename succeeds")
        check(command("{ (GP_ReadAuth('Geo.Renamed'))[1] }") == secret, "verifier moved in the real key store")
        check(command("{ defined((GP_ReadAuth('Geo.Test'))[1]) ? 1:0 }") == "0", "old credential key was removed")
        check(command("{ $defs{'Z.Home'}{DEF} }") == "location Geo.Renamed home", "private location definition follows resident")
        check(request("Home", 1, debug=True)[0] == 200, "renamed resident keeps its existing webhook login")
        check("unknown resident Geo.Test" in command("get GP validate"), "unresolved public rule references remain visible")
        command("save")
        check(command("{ my ($err,@lines)=FileRead('test.cfg');; return scalar grep {/^define Z.Home GeoPresence location Geo.Renamed home/} @lines }") == "1",
              "save persists the repaired resident binding")
        check(command("rename Geo.Renamed Geo.Test") == "", "resident can be renamed back")
        command("save")
        check(command("get GP validate").startswith("OK:"), "original public configuration validates again")

        check(command("set Geo.Test mode active") == "", "resident activation succeeds")
        check(command("set GP mode active") == "", "controller activation succeeds")
        command("set rr_Test state absent")
        advance(40)
        command("{ $main::GP_original_roommate_set_fn=$modules{ROOMMATE}{SetFn};; "
                "no warnings 'redefine';; *GP_FailingRoommateSet=sub { return 'temporary ROOMMATE failure' };; "
                "$modules{ROOMMATE}{SetFn}='GP_FailingRoommateSet';; return 'failure installed' }")
        check(request("Home", 1)[0] == 200, "status-only Home observation enters through HTTP")
        advance(3)
        check("temporary ROOMMATE failure" in command("{ ReadingsVal('Geo.Test','gp_roommate_error','') }"),
              "real CommandSet failure is exposed in the resident Reading")
        check(command("{ $defs{GP}{helper}{gp}{prod}{'Geo.Test'}{desired_status} }") == "home",
              "unsuccessful status request remains pending")
        command("{ $modules{ROOMMATE}{SetFn}=$main::GP_original_roommate_set_fn;; return 'restored' }")
        advance(1)
        check(command("{ ReadingsVal('rr_Test','state','') }") == "home", "next timer retry uses the real ROOMMATE adapter")
        check(command("{ ReadingsVal('Geo.Test','gp_roommate_error','missing') }") == "", "recovery clears the error Reading")
        check(command("{ ReadingsVal('door','state','untouched') }") == "untouched"
              and command("{ ReadingsVal('garage','state','untouched') }") == "untouched",
              "retry does not create an opening permission")
    finally:
        command("{ $modules{ROOMMATE}{SetFn}=$main::GP_original_roommate_set_fn if defined $main::GP_original_roommate_set_fn;; "
                "CommandRename(undef,'Geo.Renamed Geo.Test') if $defs{'Geo.Renamed'};; "
                "CommandRename(undef,'GP.Renamed GP') if $defs{'GP.Renamed'};; return 'restored' }")
        command("set GP mode debug")
        command("set Geo.Test mode debug")
        command(f"{{ $main::GP_fixture_offset={original_offset};; GP_ResetController($defs{{GP}});; "
                "GeoPresence_Timer($defs{GP});; return 'fixture restored' }")


def check_roommate_echoes(command, check):
    original_offset = float(command("{ $main::GP_fixture_offset }"))
    try:
        for line in ("define rr_Status ROOMMATE", "attr rr_Status rr_locationUnderway underway",
                     "define Geo.Status GeoPresence resident GP rr_Status",
                     "attr Geo.Status sourceMode phone_only", "attr Geo.Status phoneProxies p1,p2",
                     "set Geo.Status mode active", "set Geo.Test mode active", "set GP mode active"):
            response = command(line)
            check(response == "", "prepare status callback fixture: " + line + ": " + response)
        check(command("get GP validate").startswith("OK:"), "status callback fixture validates")
        for line in ("define rr_Observer ROOMMATE", "attr rr_Observer disable 1",
                     "attr rr_Observer rr_presenceDevices rr_Test"):
            check(command(line) == "", "prepare real ROOMMATE event receiver: " + line)
        command("{ no warnings 'redefine';; *GP_PrepareStatusArrival=sub { "
                "GP_ResetController($defs{GP});; GeoPresence_Timer($defs{GP});; "
                "$main::GP_fixture_offset+=40;; "
                "my $c=$defs{GP};; my $cfg=GP_Config($c,'Geo.Test');; my $s=GP_State($c,'Geo.Test',0);; "
                "CommandSet(undef,'rr_Test state absent');; "
                "GP_Process($s,$cfg,{kind=>'geo',zone=>'Z.Work',entry=>0,time=>GP_Now(),received=>GP_Now(),key=>'status-departure'},GP_Now(),GP_Mono());; "
                "$main::GP_fixture_offset+=90;; "
                "GP_Process($s,$cfg,{kind=>'geo',zone=>'Z.Home',entry=>1,motion=>'automotive',time=>GP_Now(),received=>GP_Now(),key=>'status-arrival'},GP_Now(),GP_Mono());; "
                "if ($_[0]) { $main::GP_fixture_offset+=1;; GP_ConfirmArrival($s,$cfg,GP_Now(),GP_Mono()) };; "
                "return ($c,$cfg,$s) };; return 'prepared' }")

        event_mappings = [
                (None, "home"),
                ("home:Zuhause", "Zuhause"),
                ("/home:at home/", "at.home"),
                ("{ dev=>{'^home$'=>'state: Zuhause'}, usr=>{'^state: Zuhause$'=>'home'} }", "state:.Zuhause"),
                ("{ dev=>{'^home$'=>'arrival: Zuhause'}, usr=>{'^arrival: Zuhause$'=>'home'} }", "arrival:.Zuhause")]
        for depth, prefix, cycle in ((2, "state", False), (8, "arrival", False), (2, "state", True)):
            labels = [f"{prefix}: Place{step}" for step in range(1, depth + 1)]
            forward = [("home", labels[0]), *zip(labels[:-1], labels[1:])]
            if cycle:
                forward.append((labels[-1], labels[0]))
            dev = ",".join(f"'^{source}$'=>'{target}'" for source, target in forward)
            usr = ",".join(f"'^{label}$'=>'home'" for label in labels)
            event_mappings.append((f"{{ dev=>{{{dev}}}, usr=>{{{usr}}} }}", labels[0].replace(" ", ".")))
        mood_updates = ";;".join(f"set rr_Test mood {mood}" for mood in ("happy", "calm") * 4 + ("happy",))
        for event_map, home_pattern in event_mappings:
            command("set GP mode debug")
            command("set Geo.Test mode debug")
            check(command("attr rr_Test eventMap " + event_map if event_map else "deleteattr rr_Test eventMap") == "",
                  "configure ROOMMATE event mapping")
            command("set Geo.Test mode active")
            command("set GP mode active")
            normal = json.loads(command(
                "{ my ($c,$cfg,$s)=GP_PrepareStatusArrival(1);; my $revision=$s->{output_revision};; "
                "CommandSet(undef,'rr_Test state absent');; $s->{desired_status}='home';; my $writer=\\&setReadingsVal;; GP_Publish($c,'Geo.Test',$cfg,$s);; "
                "return JSON::PP::encode_json({unchanged=>$s->{output_revision}==$revision?1:0,plans=>scalar @{$s->{intents}},"
                "status=>ReadingsVal('rr_Test','state',''),marker=>$c->{helper}{gp}{status_request}?1:0,client=>defined($defs{rr_Test}{CL})?1:0,"
                "writer_restored=>\\&setReadingsVal==$writer?1:0}) }")
            )
            check(normal == {"unchanged": 1, "plans": 2, "status": "home", "marker": 0, "client": 0, "writer_restored": 1},
                  f"eventMap={event_map}: own Home echo preserves plans and leaves no temporary command context")

            for scenario in ("foreign_pending", "foreign_planned", "same_absent", "same_home_cycle",
                             "foreign_nested_pending", "foreign_nested_planned", "foreign_two_batches"):
                for order in ("00", "99"):
                    foreign = scenario.startswith("foreign")
                    nested = "nested" in scenario or scenario == "foreign_two_batches"
                    publisher = "Geo.Status" if foreign else "Geo.Test"
                    target = "rr_Status" if foreign else "rr_Test"
                    desired = "absent" if scenario == "same_absent" else "home"
                    callback = "set rr_Test state home"
                    if scenario == "same_home_cycle":
                        callback = "set rr_Test state absent;;set rr_Test state home"
                    elif nested:
                        callback = "set rr_Test mood happy"
                        if scenario == "foreign_two_batches":
                            callback += ";;set rr_Test mood calm"
                    nested_notify = (
                        "CommandDefine(undef,'Status.Nested notify rr_Test:mood:.happy set rr_Test state home');; "
                        f"$defs{{'Status.Nested'}}{{NTFY_ORDER}}='{order}-Status.Nested';; " if nested else "")
                    result = json.loads(command(
                        f"{{ my ($c,$cfg,$s)=GP_PrepareStatusArrival({0 if scenario.endswith('pending') else 1});; "
                        "my $revision=$s->{output_revision};; "
                        f"setReadingsVal($defs{{'{target}'}},'state','{'home' if desired == 'absent' else 'absent'}',FmtDateTime(GP_Now()));; "
                        f"CommandDefine(undef,'Status.Callback notify {target}:state:.{desired} {callback}');; "
                        "CommandAttr(undef,'Status.Callback addStateEvent 1');; "
                        f"$defs{{'Status.Callback'}}{{NTFY_ORDER}}='{order}-Status.Callback';; "
                        + nested_notify + "createNtfyHash();; "
                        f"my $pub=GP_State($c,'{publisher}',0);; $pub->{{desired_status}}='{desired}';; "
                        f"GP_Publish($c,'{publisher}',GP_Config($c,'{publisher}'),$pub);; "
                        "CommandDelete(undef,'Status.Callback');; "
                        "CommandDelete(undef,'Status.Nested') if $defs{'Status.Nested'};; "
                        "return JSON::PP::encode_json({revoked=>$s->{output_revision}>$revision?1:0,"
                        "trip=>$s->{trip}?1:0,arrival=>$s->{arrival}?1:0,plans=>scalar @{$s->{intents}},"
                        "checkpoint=>JSON::PP::decode_json(ReadingsVal('Geo.Test','gp_trip_checkpoint','{}'))->{status}}) }")
                    )
                    check(result == {"revoked": 1, "trip": 0, "arrival": 0, "plans": 0, "checkpoint": "none"},
                          f"{scenario}, notify order {order}, eventMap={event_map}: nested Home revokes permissions: {result}")

            for cached in (False, True):
                for planned in (0, 1):
                    for setter in ("CommandSet", "CommandSetReading"):
                        event = "state:.home" if cached else home_pattern
                        result = json.loads(command(
                            f"{{ my ($c,$cfg,$s)=GP_PrepareStatusArrival({planned});; my $revision=$s->{{output_revision}};; "
                            f"CommandDefine(undef,'Status.Callback notify rr_Test:{event} {mood_updates}');; "
                            f"CommandAttr(undef,'Status.Callback addStateEvent {int(cached)}');; "
                            "$defs{'Status.Callback'}{NTFY_ORDER}='00-Status.Callback';; createNtfyHash();; "
                            f"{setter}(undef,'rr_Test state home');; CommandDelete(undef,'Status.Callback');; "
                            "return JSON::PP::encode_json({revoked=>$s->{output_revision}>$revision?1:0,"
                            "trip=>$s->{trip}?1:0,arrival=>$s->{arrival}?1:0,plans=>scalar @{$s->{intents}}}) }")
                        )
                        check(result == {"revoked": 1, "trip": 0, "arrival": 0, "plans": 0},
                              f"eventMap={event_map}, cached={cached}, planned={planned}, {setter}: mood remapping cannot hide manual Home")

            benign = json.loads(command(
                "{ my ($c,$cfg,$s)=GP_PrepareStatusArrival(1);; my $revision=$s->{output_revision};; "
                "CommandDefine(undef,'Status.Callback notify rr_Test:state:.home set rr_Test mood happy;;set rr_Test mood calm;;set rr_Test mood happy');; "
                "CommandAttr(undef,'Status.Callback addStateEvent 1');; "
                "$defs{'Status.Callback'}{NTFY_ORDER}='99-Status.Callback';; createNtfyHash();; "
                "$s->{desired_status}='home';; GP_Publish($c,'Geo.Test',$cfg,$s);; CommandDelete(undef,'Status.Callback');; "
                "return JSON::PP::encode_json({unchanged=>$s->{output_revision}==$revision?1:0,plans=>scalar @{$s->{intents}}}) }")
            )
            check(benign == {"unchanged": 1, "plans": 2},
                  f"eventMap={event_map}: later mood changes retain the already attributed own Home echo")

            command("attr rr_Observer disable 0")
            for order in ("00", "70"):
                command(f"{{ $defs{{rr_Observer}}{{NTFY_ORDER}}='{order}-rr_Observer';; createNtfyHash();; return 'receiver ordered' }}")
                for planned in (0, 1):
                    for setter in ("CommandSet", "CommandSetReading"):
                        result = json.loads(command(
                            f"{{ my ($c,$cfg,$s)=GP_PrepareStatusArrival({planned});; my $revision=$s->{{output_revision}};; "
                            f"{setter}(undef,'rr_Test state home');; "
                            "return JSON::PP::encode_json({revoked=>$s->{output_revision}>$revision?1:0,"
                            "trip=>$s->{trip}?1:0,arrival=>$s->{arrival}?1:0,plans=>scalar @{$s->{intents}}}) }")
                        )
                        check(result == {"revoked": 1, "trip": 0, "arrival": 0, "plans": 0},
                              f"eventMap={event_map}, receiver={order}, planned={planned}, {setter}: cache deletion cannot hide Home")

                own = json.loads(command(
                    "{ my ($c,$cfg,$s)=GP_PrepareStatusArrival(1);; my $revision=$s->{output_revision};; "
                    "$s->{desired_status}='home';; GP_Publish($c,'Geo.Test',$cfg,$s);; "
                    "return JSON::PP::encode_json({unchanged=>$s->{output_revision}==$revision?1:0,plans=>scalar @{$s->{intents}}}) }")
                )
                check(own == {"unchanged": 1, "plans": 2},
                      f"eventMap={event_map}, receiver={order}: cache deletion preserves the actual own Home echo")

            late = json.loads(command(
                "{ my ($c,$cfg,$s)=GP_PrepareStatusArrival(0);; my $revision=$s->{output_revision};; "
                "setReadingsVal($defs{rr_Test},'state','home',FmtDateTime(GP_Now()));; "
                "CommandDefine(undef,'Status.Callback notify rr_Test:absent set rr_Test state home');; "
                "$defs{'Status.Callback'}{NTFY_ORDER}='99-Status.Callback';; createNtfyHash();; "
                "$s->{desired_status}='absent';; GP_Publish($c,'Geo.Test',$cfg,$s);; CommandDelete(undef,'Status.Callback');; "
                "return JSON::PP::encode_json({revoked=>$s->{output_revision}>$revision?1:0,trip=>$s->{trip}?1:0,arrival=>$s->{arrival}?1:0}) }")
            )
            check(late == {"revoked": 1, "trip": 0, "arrival": 0},
                  f"eventMap={event_map}: late Home revokes after a real receiver deleted the prior state view")

            foreign = json.loads(command(
                "{ my ($c,$cfg,$s)=GP_PrepareStatusArrival(0);; my $revision=$s->{output_revision};; "
                "CommandSet(undef,'rr_Status state absent');; "
                "CommandDefine(undef,'Status.Callback notify rr_Status:home set rr_Test mood happy');; "
                "CommandDefine(undef,'Status.Nested notify rr_Test:mood:.happy set rr_Test state home');; "
                "$defs{'Status.Nested'}{NTFY_ORDER}='99-Status.Nested';; createNtfyHash();; "
                "my $other=GP_State($c,'Geo.Status',0);; $other->{desired_status}='home';; "
                "GP_Publish($c,'Geo.Status',GP_Config($c,'Geo.Status'),$other);; "
                "CommandDelete(undef,'Status.Callback');; CommandDelete(undef,'Status.Nested');; "
                "return JSON::PP::encode_json({revoked=>$s->{output_revision}>$revision?1:0,trip=>$s->{trip}?1:0,arrival=>$s->{arrival}?1:0}) }")
            )
            check(foreign == {"revoked": 1, "trip": 0, "arrival": 0},
                  f"eventMap={event_map}: nested foreign Home revokes after receiver cache deletion")
            command("attr rr_Observer disable 1")

        result = json.loads(command(
            "{ my ($c,$cfg,$s)=GP_PrepareStatusArrival(1);; my $revision=$s->{output_revision};; "
            "CommandSet(undef,'rr_Test state absent');; $s->{desired_status}='home';; "
            "my $original=$modules{ROOMMATE}{SetFn};; my $nested=0;; "
            "no warnings 'redefine';; local *GP_NestedStatusSet=sub { "
            "if (!$nested) { $nested=1;; CommandSet(undef,'rr_Test state home') };; "
            "no strict 'refs';; return &{$original}(@_) };; "
            "{ local $modules{ROOMMATE}{SetFn}='GP_NestedStatusSet';; GP_Publish($c,'Geo.Test',$cfg,$s) };; "
            "return JSON::PP::encode_json({revoked=>$s->{output_revision}>$revision?1:0,plans=>scalar @{$s->{intents}}}) }")
        )
        check(result == {"revoked": 1, "plans": 0},
              "an identical nested Home before the own adapter update is not accepted as the own echo")

        command("set GP mode debug")
        command("set Geo.Test mode debug")
        check(command("attr rr_Test eventMap home:Zuhause absent:home") == "",
              "configure distinct Home and absence event names")
        command("set Geo.Test mode active")
        command("set GP mode active")
        absence = json.loads(command(
            "{ GP_ResetController($defs{GP});; GeoPresence_Timer($defs{GP});; $main::GP_fixture_offset+=40;; "
            "my $c=$defs{GP};; my $cfg=GP_Config($c,'Geo.Test');; my $s=GP_State($c,'Geo.Test',0);; "
            "setReadingsVal($defs{rr_Test},'state','home',FmtDateTime(GP_Now()));; "
            "GP_Process($s,$cfg,{kind=>'geo',zone=>'Z.Work',entry=>0,time=>GP_Now(),received=>GP_Now(),key=>'mapped-absence'},GP_Now(),GP_Mono());; "
            "my $revision=$s->{output_revision};; GP_Publish($c,'Geo.Test',$cfg,$s);; "
            "return JSON::PP::encode_json({unchanged=>$s->{output_revision}==$revision?1:0,armed=>($s->{trip}{armed}//0),"
            "status=>ReadingsVal('rr_Test','state','')}) }")
        )
        check(absence == {"unchanged": 1, "armed": 1, "status": "absent"},
              "an absence event named home does not revoke a trip when the actual Home event has another name")
    finally:
        command("{ CommandDelete(undef,$_) for grep {$defs{$_}} ('Status.Callback','Status.Nested');; return 'callbacks removed' }")
        command("set GP mode debug")
        command("set Geo.Test mode debug")
        command("deleteattr rr_Test eventMap")
        command("delete Geo.Status")
        command("delete rr_Status")
        command("delete rr_Observer")
        command(f"{{ $main::GP_fixture_offset={original_offset};; GP_ResetController($defs{{GP}});; "
                "GeoPresence_Timer($defs{GP});; return 'fixture restored' }")


def run(source, encoding="bytestream", help_only=False):
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="geopresence-test-") as directory:
        root = Path(directory)
        (root / "FHEM/FhemUtils").mkdir(parents=True)
        (root / "log").mkdir()
        (root / "docs").mkdir()
        (root / "www/pgm2").mkdir(parents=True)
        shutil.copyfile(source / "www/pgm2/fhemweb.js", root / "www/pgm2/fhemweb.js")
        shutil.copyfile(source / "docs/commandref_frame.html", root / "docs/commandref_frame.html")
        shutil.copyfile(source / "fhem.pl", root / "fhem.pl")
        shutil.copyfile(source / "MAINTAINER.txt", root / "MAINTAINER.txt")
        for name in STOCK:
            shutil.copyfile(source / "FHEM" / name, root / "FHEM" / name)
        shutil.copyfile(repo / "FHEM/98_GeoPresence.pm", root / "FHEM/98_GeoPresence.pm")
        ports = set()
        while len(ports) < 3:
            ports.add(unused_port())
        tel_port, web_port, admin_port = sorted(ports)
        cfg = [
            "attr global modpath .", "attr global logfile ./log/fhem.log",
            f"attr global encoding {encoding}",
            "attr global statefile ./log/fhem.save", "attr global pidfilename ./log/fhem.pid",
            "attr global nofork 1", "attr global verbose 2", "attr global autosave 0", "attr global language EN",
            f"define TEL telnet {tel_port}", f"define WEBadmin FHEMWEB {admin_port}",
            "define rr_Test ROOMMATE", "attr rr_Test rr_locationUnderway underway",
            "define phone dummy",
            "define breachProbe dummy", "set breachProbe untouched", "attr breachProbe alias untouched",
            "define p1 PRESENCE event rr_Test:FakeAbsent rr_Test:FakePresent",
            "define p2 PRESENCE event rr_Test:FakeAbsent rr_Test:FakePresent",
        ]
        cfg += [f"define {name} dummy" for name in ("door", "contact", "feedback", "garage", "gate", "upper", "lower")]
        # Idle work must scale with the relevant devices even in a large FHEM.
        cfg += [f"define Idle.Unrelated.{index} dummy" for index in range(808)]
        cfg += [
            "define GP GeoPresence controller", "set GP mode debug", f"attr GP webhookPort {web_port}",
            "define Geo.Test GeoPresence resident GP rr_Test", "set Geo.Test mode debug",
            "attr Geo.Test deviceId test-device", "attr Geo.Test webhookUser test-user",
            "attr Geo.Test phoneProxies p1,p2",
            "attr Geo.Test allowDoor 1", "attr Geo.Test allowGarage 1",
        ]
        # Existing transport/feedback regressions use short configured waits.
        # Separate arrival checks below restore and exercise the actual defaults.
        cfg += [f"attr GP arrival_wait_{motion} 0.01" for motion in
                ("walking", "running", "cycling", "automotive", "unknown")]
        zones = {"Home": ("home", 0, 50), "Drive": ("approach", 0, 250),
                 "Outer": ("outer", 0, 4500), "Work": ("place", 0.1, 100)}
        for name, (role, lat, radius) in zones.items():
            geometry = json.dumps({"lat": lat, "lon": 0, "radius": radius,
                                   "time": 1700000000, "changed": 1700000000,
                                   "id": name.lower(), "device": "test-device", "blocked": 0}, separators=(",", ":"))
            cfg += [f"define Z.{name} GeoPresence location Geo.Test {role}",
                    f"attr Z.{name} zoneId {name}",
                    f"setstate Z.{name} 2023-11-14 22:13:20 gp_geometry {geometry}"]
        cfg += [
            "define A.Door GeoPresence action GP door_open", "attr A.Door target door",
            "attr A.Door command lock unlocked", "attr A.Door contact contact", "attr A.Door feedbackDevice feedback",
            "attr A.Door message legacy unused value",
            "define A.Garage GeoPresence action GP garage_open", "attr A.Garage target garage",
            "attr A.Garage command on", "attr A.Garage stateDevice gate",
            "attr A.Garage upperContact upper", "attr A.Garage lowerContact lower",
        ]
        cfg += ["attr Z.Work groups Work"]
        for name, action, arrival_filter in [("Door", "A.Door", "any"), ("Garage", "A.Garage", "vehicle")]:
            cfg += [f"define R.{name} GeoPresence rule GP", f"attr R.{name} trigger arrival",
                    f"attr R.{name} residents Geo.Test", f"attr R.{name} action {action}",
                    f"attr R.{name} arrivalFilter {arrival_filter}"]
        (root / "test.cfg").write_text("\n".join(cfg) + "\n")
        password = secrets.token_urlsafe(30)
        process = subprocess.Popen(["perl", "fhem.pl", "test.cfg"], cwd=root,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        checks = 0

        def check(value, message):
            nonlocal checks
            if not value:
                raise AssertionError(message)
            checks += 1

        def command(text):
            with socket.create_connection(("127.0.0.1", tel_port), timeout=4) as client:
                client.sendall((text + "\nquit\n").encode())
                chunks = []
                while chunk := client.recv(65536):
                    chunks.append(chunk)
            return b"".join(chunks).decode().strip().removesuffix("Bye...").strip()

        def diagnostics():
            return "".join(path.read_text() for path in sorted((root / "log").glob("geopresence-*.log")))

        def event_body(zone, entry, motion=None, *, test=False, observed=None):
            current = float(command("{ GP_Now() }")) if observed is None else observed
            payload = {"device": "test-device", "id": zone, "entry": entry,
                       "date": datetime.datetime.fromtimestamp(current, datetime.timezone.utc).isoformat(),
                       "latitude": zones[zone][1], "longitude": 0, "radius": zones[zone][2]}
            if test:
                payload["isTest"] = "true"
            if motion is not None:
                payload["motion"] = motion
            return urllib.parse.urlencode(payload)

        def auth_headers(auth=True):
            headers = {"Content-Type": "application/x-www-form-urlencoded"}
            if auth:
                secret = password if auth is True else "wrong-test-password"
                headers["Authorization"] = "Basic " + base64.b64encode(f"test-user:{secret}".encode()).decode()
            return headers

        def http_request(method, path, body=None, headers=None, *, port=web_port, host="127.0.0.1", source=None):
            connection = http.client.HTTPConnection(host, port, timeout=4,
                                                   source_address=(source, 0) if source else None)
            try:
                connection.request(method, path, body, headers or {})
                response = connection.getresponse()
                response_headers = {k.lower(): v for k, v in response.getheaders()}
                content = response.read()
                if response_headers.get("content-encoding") == "gzip":
                    content = gzip.decompress(content)
                return response.status, response_headers, content.decode()
            finally:
                connection.close()

        def request(zone, entry, *, debug=False, auth=True, motion=None, observed=None):
            status, _, body = http_request("POST", "/fhem/geopresence",
                                           event_body(zone, entry, motion, test=debug, observed=observed), auth_headers(auth))
            return status, body

        def raw_request(parts):
            with socket.create_connection(("127.0.0.1", web_port), timeout=4) as client:
                for part in parts:
                    client.sendall(part)
                output = bytearray()
                while chunk := client.recv(65536):
                    output.extend(chunk)
                return bytes(output)

        def advance(seconds):
            command(f"{{ $main::GP_fixture_offset += {seconds} }}")
            command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")

        def phone_measurement(first, second):
            # Event-mode PRESENCE fixtures have no radio connection. Supply
            # measurement times on the same controlled clock as GeoPresence.
            for name, value in (("p1", first), ("p2", second)):
                command("{ for my $reading ('state','presence') { "
                        f"$defs{{{name}}}{{READINGS}}{{$reading}}={{VAL=>'{value}',"
                        "TIME=>strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now()))} };; return 'measured' }")

        def phone_state(name, value, observed=None):
            # Actual PRESENCE processing and FHEM event filtering; advance the
            # reading clock only for an explicitly supplied detector message.
            when = "GP_Now()" if observed is None else str(float(observed))
            return command("{ my $h=$defs{" + name + "};; readingsBeginUpdate($h);; "
                           "$h->{'.updateTimestamp'}=strftime('%Y-%m-%d %H:%M:%S',localtime(" + when + "));; "
                           "$h->{'.updateTime'}=" + when + ";; PRESENCE_ProcessState($h,'" + value + "');; "
                           "readingsEndUpdate($h,1);; return 'observed' }")

        def refresh_actor_contacts():
            command("{ for my $x (['contact','state','closed'],['feedback','pulse_state','idle'],"
                    "['gate','state','off'],['upper','state','open'],['lower','state','closed']) { "
                    "$defs{$x->[0]}{READINGS}{$x->[1]}={VAL=>$x->[2],"
                    "TIME=>strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now()))} };; return 'measured' }")

        def actor_reading(name, reading, value):
            return command("{ my $h=$defs{" + name + "};; readingsBeginUpdate($h);; "
                           "$h->{'.updateTimestamp'}=strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now()));; "
                           "$h->{'.updateTime'}=GP_Now();; readingsBulkUpdate($h,'" + reading + "','" + value + "');; "
                           "readingsEndUpdate($h,1);; return 'observed' }")

        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("isolated FHEM terminated at startup")
                try:
                    command("list GP")
                    break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError("isolated FHEM did not become reachable")
            check_help(command, http_request, admin_port, check)
            check_attribute_widgets(command, http_request, admin_port, check)
            check_reports(command, http_request, admin_port, check)
            check_set_widgets(command, http_request, admin_port, password, check)
            if help_only:
                print(f"PASS: {checks} help checks with real FHEM, FHEMWEB and Telnet; encoding={encoding}")
                return
            result = command(f"set Geo.Test webhookPassword {password}")
            check("stored" in result, "password must use the real FHEM key store")
            check_parameter_cleanup(command, repo, check)
            # Module reload and diagnostic commands are checked directly;
            # integration tests do not depend on operator update instructions.
            check(command("reload 98_GeoPresence.pm") == "", "module reload succeeds")
            check(command("get GP validate").startswith("OK:"), "configuration validates after reload")
            check(bool(re.search(r"STATE\s+debug", command("list TYPE=GeoPresence:FILTER=SUBTYPE=resident STATE mode"))),
                  "module reload preserves resident operating modes")
            command("apptime")
            check("TIMER WORK" in command("get GP timerStats"), "readable timer diagnostics are available")
            check("recent_slow" in json.loads(command("get GP timerStats format=json")),
                  "structured timer diagnostics are available")
            # Controlled clock affects only this copied module in this process.
            command("{ no warnings 'redefine';; $main::GP_fixture_offset=0;; *GP_Now=sub { ($main::GP_fixture_fixed_wall // Time::HiRes::time())+$main::GP_fixture_offset };; *GP_Mono=sub { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())+$main::GP_fixture_offset };; return 'clock set' }")
            check_http_quotas(command, http_request, request, auth_headers, password, check)
            check_lifecycle(command, request, advance, web_port, check)
            check_roommate_echoes(command, check)
            check_auth_key_names(command, http_request, auth_headers, password, check)
            check(command("attr GP verbose 4") == "", "normal controller verbosity accepted")
            check(command("attr GP logFile ./log/geopresence-%Y-%m.log") == "", "separate monthly diagnostic log configured")
            check(command("define GP.LogFile FileLog ./log/geopresence-%Y-%m.log .* readonly") == "", "optional FHEMWEB log viewer syntax accepted")
            check(command("{ $defs{'GP.LogFile'}{READONLY} }") == "1", "log viewer is read only and does not consume diagnostic events")
            check(command("get GP validate Geo.Test").startswith("OK:"), "real FHEM validates configuration")
            command("attr Geo.Test userReadings tested { ++$main::GP_fixture_user_readings }")
            command("{ $main::GP_fixture_user_readings=0 }")
            # Real event-loop delay outside GeoPresence: apptime must identify
            # the slow neighbour while GeoPresence records late, fast work.
            command("apptime")
            command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")
            command("{ no warnings 'redefine';; *GP_FixtureSlowNeighbor=sub { Time::HiRes::sleep(2.5) };; "
                    "InternalTimer(gettimeofday()+0.1,'GP_FixtureSlowNeighbor','test-delay',0);; return 'scheduled' }")
            time.sleep(3.8)
            stats = json.loads(command("get GP timerStats format=json"))
            check(stats["max_lag_ms"] >= 1000 and stats["late_runs"] >= 1,
                  "foreign blocking callback delays GeoPresence in the real FHEM loop")
            check(stats["max_ms"] < stats["max_lag_ms"], "own timer work is distinguished from external delay")
            check(stats["worst_late_run"]["start_lag_ms"] >= 1000
                  and stats["worst_late_run"]["elapsed_ms"] < stats["worst_late_run"]["start_lag_ms"],
                  "a delayed run retains its actual execution time and timestamp for correlation")
            timing = command("apptime max top")
            check("GP_FixtureSlowNeighbor" in timing, "apptime names the slow test neighbour")
            timing = command("apptime maxDly top")
            check("GeoPresence_Timer" in timing, "apptime distinguishes the delayed GeoPresence timer")
            advance(40)

            # Use the actual timer registry and readonly Get path. No latency
            # limit depends on the machine running the test.
            check(command("attr GP verbose 5") == "", "idle timer also measured with full diagnostics")
            command("{ GeoPresence_Timer($defs{GP}) for 1..20;; return 'ticked' }")
            stats = json.loads(command("get GP timerStats format=json"))
            check(stats["runs"] >= 20 and stats["last_device_scans"] == 0
                  and stats["last_config_builds"] == 0, "idle callbacks reuse catalogue and configuration")
            check(0 <= stats["last_ms"] <= stats["max_ms"] and 0 <= stats["mean_ms"] <= stats["max_ms"],
                  "timer statistics contain consistent measured millisecond durations")
            check(command("{ $main::GP_fixture_user_readings }") == "0", "idle statistics create no debug Reading callbacks")
            revision = command("{ return GP_ResumeRevision($defs{GP},'Geo.Test',GP_Config($defs{GP},'Geo.Test',1)) }")
            check(command("attr A.Door room Config.Cache") == "", "cosmetic action attribute accepted")
            check(command("attr rr_Test alias Cache Probe") == "", "dependent alias changed through FHEM")
            check(command("{ return GP_Config($defs{GP},'Geo.Test',1)->{label} }") == "Cache Probe",
                  "global ATTR event refreshes the committed dependent label")
            command("deleteattr rr_Test alias")
            check(command("{ return GP_ResumeRevision($defs{GP},'Geo.Test',GP_Config($defs{GP},'Geo.Test',1)) }") == revision,
                  "fresh configuration preserves checkpoint binding after a room change")
            params = json.loads(command(
                "{ my($rule)=grep { $_->{action} eq 'A.Door' } @{GP_Config($defs{GP},'Geo.Test',1)->{rules}};; "
                "return JSON::PP->new->encode($rule->{params}) }"))
            check(params["target"] == "door" and "room" not in params and "message" not in params,
                  "action parameters exclude cosmetic and obsolete fields")
            modified = json.loads(command(
                "{ no warnings 'redefine';; my($lists,$inventories)=(0,0);; "
                "my $list=\\&GP_UpdateAttrLists;; my $inventory=\\&GP_Inventory;; my $error;; "
                "{ local *GP_UpdateAttrLists=sub { $lists++;; return $list->(@_) };; "
                "local *GP_Inventory=sub { $inventories++;; return $inventory->(@_) };; "
                " $error=CommandModify(undef,'Idle.Unrelated.0') };; "
                "return JSON::PP->new->encode({lists=>$lists,inventories=>$inventories,error=>$error//''}) }"))
            check(modified == {"lists": 0, "inventories": 0, "error": ""},
                  "real unrelated modify performs no GeoPresence inventory or widget work")
            check(command(
                "{ my $prepared=$defs{GP}{helper}{gp_config};; my $kept=1;; "
                "for my $key ('debugLog','logFile') { my $old=$attr{GP}{$key};; "
                "CommandDeleteAttr(undef,'GP '.$key);; $kept&&=($defs{GP}{helper}{gp_config}//0)==$prepared;; "
                "CommandAttr(undef,'GP '.$key.' '.$old) if defined $old;; "
                "$kept&&=($defs{GP}{helper}{gp_config}//0)==$prepared };; return $kept }") == "1",
                  "real deletion and restoration of diagnostic attributes preserve the prepared catalogue")
            # Advancing the controlled module clock within validation models a
            # slow callback without blocking the actual FHEM event loop.
            scheduled = json.loads(command(
                "{ no warnings 'redefine';; my $original=\\&GP_Validate;; "
                "{ local *GP_Validate=sub { $main::GP_fixture_offset+=2.5;; return $original->(@_) };; "
                "GeoPresence_Timer($defs{GP}) };; "
                "my @timers=grep { $_->{FN} eq 'GeoPresence_Timer' && $_->{ARG} eq $defs{GP} } values %intAt;; "
                "return JSON::PP->new->encode({count=>scalar(@timers),delay=>$timers[0]{TRIGGERTIME}-GP_Now()}) }"))
            check(scheduled["count"] == 1 and scheduled["delay"] > 0,
                  "real FHEM registry contains one future timer after slow work")
            stats = json.loads(command("get GP timerStats format=json"))
            check(stats["last_ms"] >= 2500 and stats["slow_runs"] >= 1,
                  "slow work is measured independently of Freezemon's candidate list")
            check(stats["last_run"]["slowest_phase"] == "validation" and stats["last_run"]["slowest_target"] == "Geo.Test",
                  "profile identifies validation and the resident in the slow timer")
            check(stats["recent_slow"][-1]["started_at"] == stats["last_started_at"],
                  "slow-run history includes the corresponding start time")
            check("GeoPresence timer_slow" in diagnostics(), "slow timer diagnostic reaches its separate file")
            check("GeoPresence timer_slow" not in (root / "log/fhem.log").read_text(),
                  "slow timer diagnostic never enters the normal FHEM log")
            check(command("attr GP verbose 4") == "", "restore normal verbosity after timer check")

            # Regression for the actual pre-FWEXT bypass, using only this test
            # installation. Even a valid administrator CSRF token grants no
            # command execution through the independent webhook listener.
            _, admin_headers, _ = http_request("GET", "/fhem?XHR=1", port=admin_port)
            csrf = admin_headers.get("x-fhem-csrftoken")
            check(bool(csrf), "reference FHEMWEB supplies an actual CSRF token for attack tests")
            command("{ $main::GP_bypass_probe=0 }")
            for mode in ("debug", "active", "disabled"):
                check(command(f"set GP mode {mode}") == "", f"enter {mode} for HTTP attack regression")
                advance(1)
                # The resident remains debug throughout this attack matrix.
                before = command("{ ReadingsVal('rr_Test','state','unknown') }")
                for path in ("/fhem/geopresence", "/fhem/geopresence/debug"):
                    status, headers, _ = http_request("GET", path + "?XHR=1")
                    check(status == 404 and "x-fhem-csrftoken" not in headers,
                          f"{mode} {path}: unauthenticated XHR cannot obtain CSRF token")
                    for auth in (False, "wrong", True):
                        for injected in ("set breachProbe reached", "attr breachProbe alias reached",
                                         "{ $main::GP_bypass_probe=1 }"):
                            for switch in ("XHR", "jsonp"):
                                payload = urllib.parse.urlencode({switch: "1", "cmd": injected, "fwcsrf": csrf})
                                for method, target, body in (
                                    ("GET", path + "?" + payload, None),
                                    ("POST", path + "?" + payload, event_body("Home", 1)),
                                    ("POST", path, payload),
                                ):
                                    status, headers, _ = http_request(method, target, body, auth_headers(auth))
                                    expected = 404 if "?" in target or path.endswith("/debug") else 401 if auth is not True else 503 if mode == "disabled" else 400
                                    check(status == expected and "x-fhem-csrftoken" not in headers,
                                          f"{mode} {path}: {method} {switch}, auth={auth}, command={injected!r}")
                    # Includes commands named as FHEMWEB's per-device cmd fields.
                    for extra in ({"cmd.breachProbe": "set breachProbe reached"}, {"inform": "type=status"},
                                  {"asyncOutput": "1"}, {"cmd": "set GP mode active"}):
                        status, _, _ = http_request("POST", path, event_body("Home", 1) + "&" + urllib.parse.urlencode(extra), auth_headers())
                        check(status == (404 if path.endswith("/debug") else 503 if mode == "disabled" else 400), f"{mode} {path}: control field rejected")
                check(command("{ ReadingsVal('breachProbe','state','unknown') }") == "untouched"
                      and command("{ AttrVal('breachProbe','alias','unknown') }") == "untouched"
                      and command("{ $main::GP_bypass_probe }") == "0", f"{mode}: set, attr and Perl attacks had no effect")
                check(command("{ ReadingsVal('GP','mode','unknown') }") == mode
                      and command("{ ReadingsVal('rr_Test','state','unknown') }") == before
                      and command("{ $main::GP_fixture_user_readings }") == "0", f"{mode}: controller, ROOMMATE and readings unchanged")
                check(command("{ scalar @{$defs{GP}{helper}{gp}{queue}} }") == "0", f"{mode}: no attack queued an event")

            command("set GP mode debug")
            advance(1)
            prefix = b"POST /fhem/geopresence HTTP/1.1\r\nHost: localhost\r\n"
            for extra, expected in (
                (b"Content-Length: 0\r\ncontent-length: 0\r\n\r\n", 400),
                (b"Content-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
                (b"Content-Length: 0\r\nAuthorization: one\r\nauthorization: two\r\n\r\n", 400),
                (b"Content-Length: 16385\r\n\r\n", 413),
                (b"X-Test: " + b"x" * 8192, 431),
                (b"Content-Length: 0\r\nExpect: 100-continue\r\n\r\n", 417),
                (b"\r\n", 411),
            ):
                response = raw_request([prefix + extra])
                check(response.startswith(f"HTTP/1.1 {expected} ".encode()), f"network parser rejects malformed/oversized request: {expected}")

            # Slow/incomplete clients may not block FHEM, survive a timeout or
            # survive a module reset. No body has reached the event processor.
            with socket.create_connection(("127.0.0.1", web_port), timeout=4) as incomplete:
                incomplete.sendall(prefix + b"Content-Length: 8\r\n\r\nentry=")
                check(command("{ 6*7 }") == "42", "partial HTTP input does not block the FHEM event loop")
                advance(11)
                check(incomplete.recv(1) == b"", "incomplete request times out without a reply or event")

            with ExitStack() as stack:
                clients = [stack.enter_context(socket.create_connection(("127.0.0.1", web_port), timeout=4))
                           for _ in range(16)]
                for client in clients:
                    client.sendall(b"POST ")
                count_command = "{ scalar keys %{$defs{GP}{helper}{gp_http}{clients}} }"
                for _ in range(20):
                    if command(count_command) == "16":
                        break
                check(command(count_command) == "16", "listener holds at most the documented 16 clients")
                with socket.create_connection(("127.0.0.1", web_port), timeout=4) as excess:
                    check(excess.recv(1) == b"", "excess connection closes without entering FHEM commands")
                advance(11)
                check(command(count_command) == "0", "timeout releases all connection slots")
            advance(40)
            with socket.create_connection(("127.0.0.1", web_port), timeout=4) as fragmented:
                body = event_body("Home", 1).encode()
                header = prefix + f"Content-Length: {len(body)}\r\n".encode()
                header += b"".join(f"{key.lower()}: {value}\r\n".encode() for key, value in auth_headers().items()) + b"\r\n"
                fragmented.sendall(header[:20])
                check(command("{ scalar @{$defs{GP}{helper}{gp}{queue}} }") == "0", "partial request line queues nothing")
                fragmented.sendall(header[20:] + body[:-1])
                check(command("{ scalar @{$defs{GP}{helper}{gp}{queue}} }") == "0", "partial authenticated body queues nothing")
                fragmented.sendall(body[-1:])
                response = http.client.HTTPResponse(fragmented)
                response.begin()
                check(response.status == 200 and "debug accepted" in response.read().decode(), "fragmented authenticated request completes once")
            advance(3)
            check(request("Home", 1, auth=False)[0] == 401, "listener must return HTTP 401")
            check(request("Work", 0, debug=True)[0] == 200, "dedicated listener accepts authenticated form POST")
            advance(3)
            advance(90)
            check(request("Home", 1, debug=True)[0] == 200, "debug arrival accepted")
            advance(3)
            check("would execute" in command("get GP debugTrace Geo.Test format=json"), "debug trace traverses actual socket, parser and timer")
            check(command("{ $main::GP_fixture_user_readings }") == "0", "debug did not invoke real userReadings")
            check(command("{ ReadingsVal('door','state','untouched') }") == "untouched", "debug did not set actuator")
            # The first receipt closes each collection
            # window even while newer webhooks continue to arrive.
            command("set GP debugReset Geo.Test keepGeometry")
            advance(40)
            for step in range(6):
                payload = event_body("Work", 0, test=True)
                observed = datetime.datetime.fromisoformat(urllib.parse.parse_qs(payload)["date"][0]).timestamp()
                check(http_request("POST", "/fhem/geopresence", payload, auth_headers())[0] == 200,
                      "continuous stream accepts a fresh webhook")
                command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")
                pending = int(command("{ scalar @{$defs{GP}{helper}{gp}{queue}} }"))
                check(pending == (step + 1) % 3,
                      f"stream cannot postpone the first receipt deadline: step={step}, pending={pending}")
                if step % 3 == 2:
                    state = json.loads(command("get GP explain Geo.Test debug format=json"))["state"]
                    check(abs(state["last_observed"] - observed) < 0.001,
                          "due batch includes its newest received observation")
                if step < 5:
                    command("{ $main::GP_fixture_offset += 1 }")
            command("set GP debugReset Geo.Test keepGeometry")
            advance(100)
            latest = float(command("{ GP_Now() }"))
            for age in reversed(range(64)):
                payload = urllib.parse.parse_qs(event_body("Home", 1, test=True))
                payload["date"] = [datetime.datetime.fromtimestamp(latest - age, datetime.timezone.utc).isoformat()]
                check(http_request("POST", "/fhem/geopresence", urllib.parse.urlencode(payload, doseq=True), auth_headers())[0] == 200,
                      "accepts a batch with distinct observation times")
            comparisons = json.loads(command(
                "{ no warnings 'redefine';; my $compare=\\&GP_Contradiction;; my $calls=0;; "
                "$main::GP_fixture_offset+=2;; "
                "{ local *GP_Contradiction=sub { $calls++;; return $compare->(@_) };; GeoPresence_Timer($defs{GP}) };; "
                "return JSON::PP->new->encode({calls=>$calls,pending=>scalar(@{$defs{GP}{helper}{gp}{queue}}),"
                "observed=>$defs{GP}{helper}{gp}{debug}{'Geo.Test'}{last_observed}}) }"))
            check(comparisons["calls"] <= 64 and comparisons["pending"] == 0,
                  "removes quadratic batch comparisons for distinct times")
            check(abs(comparisons["observed"] - latest) < 0.001, "processes the latest observation in the sorted batch")
            check(command("set Geo.Test mode active") == "", "resident activation")
            check(command("set GP mode active") == "", "controller activation")
            advance(40)
            check(json.loads(command("get GP explain Geo.Test debug format=json"))["test_webhook_isolation"] == 1,
                  "shared test endpoint capability available to the test application")
            for marker, expected in (("true", "OK debug accepted; no actions"),
                                     ("1", "OK debug accepted; no actions"),
                                     (None, "OK accepted in current FHEM session"),
                                     ("false", "OK accepted in current FHEM session"),
                                     ("0", "OK accepted in current FHEM session")):
                payload = event_body("Home", 1)
                if marker is not None:
                    payload += "&" + urllib.parse.urlencode({"isTest": marker})
                status, _, body = http_request("POST", "/fhem/geopresence", payload, auth_headers())
                check(status == 200 and body.strip() == expected, f"active shared endpoint classifies isTest={marker!r}")
                advance(3)
            for marker in ("isTest=", "isTest=yes", "isTest=TRUE", "isTest=true%0A",
                           "isTest=true&isTest=false", "istest=true"):
                status, _, _ = http_request("POST", "/fhem/geopresence", event_body("Home", 1) + "&" + marker, auth_headers())
                check(status == 400, "active shared endpoint rejects invalid or ambiguous test flag: " + marker)
            check(http_request("POST", "/fhem/geopresence/debug", event_body("Home", 1, test=True), auth_headers())[0] == 404,
                  "removed debug URL is not an alias even with a valid test body")
            production_geometry = command("{ ReadingsVal('Z.Home','gp_geometry','unknown') }")
            productive_readings = command("{ $main::GP_fixture_user_readings }")
            roommate_before = command("{ ReadingsVal('rr_Test','state','unknown') }")
            check(request("Work", 0, debug=True)[0] == 200, "isTest=true on the shared URL accepts departure when both modes are active")
            advance(3)
            advance(90)
            check(request("Home", 1, debug=True)[0] == 200, "isTest=true on the shared URL accepts arrival when both modes are active")
            advance(3)
            check("would execute" in command("get GP debugTrace Geo.Test format=json")
                  and command("{ ReadingsVal('door','state','untouched') }") == "untouched"
                  and command("{ ReadingsVal('garage','state','untouched') }") == "untouched",
                  "isTest=true on the shared URL records intended openings without actuator effects in active mode")
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == roommate_before
                  and command("{ $main::GP_fixture_user_readings }") == productive_readings,
                  "isTest=true on the shared URL does not change ROOMMATE or call userReadings in active mode")
            check(command("{ ReadingsVal('Z.Home','gp_geometry','unknown') }") == production_geometry,
                  "test arrival does not replace productive geometry")
            check(request("Work", 0)[0] == 200, "active departure accepted")
            advance(3)
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "absent", "real ROOMMATE state changes to absent")
            # Sensor measurements are fabricated on dummy devices after session start.
            command("{ for my $x (['contact','state','closed'],['feedback','pulse_state','idle'],['gate','state','off'],['upper','state','open'],['lower','state','closed']) { $defs{$x->[0]}{READINGS}{$x->[1]}={VAL=>$x->[2],TIME=>strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now()))} };; return 'measured' }")
            advance(90)
            check(request("Home", 1)[0] == 200, "active arrival accepted")
            advance(3)
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "home", "real ROOMMATE state changes to home")
            check(command("{ ReadingsVal('door','state','unknown') }") == "lock unlocked", "one door adapter invocation reaches dummy")
            check(command("{ ReadingsVal('garage','state','unknown') }") == "on", "garage adapter reaches dummy")
            check(int(command("{ $main::GP_fixture_user_readings }")) > 0, "productive readings use FHEM event API")
            phone_measurement("present", "absent")
            advance(5)
            check(command("{ ReadingsVal('Geo.Test','gp_phone_state','unknown') }") == "present", "one room sensor establishes presence")
            before = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["trace"]
            phone_measurement("absent", "present")
            advance(5)
            check(command("{ ReadingsVal('Geo.Test','gp_phone_state','unknown') }") == "present", "another room sensor continues presence")
            phone_measurement("absent", "absent")
            advance(5)
            advance(120)
            check(command("{ ReadingsVal('Geo.Test','gp_phone_health','unknown') }") == "handover", "brief detection gap is reported as handover")
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "home", "real ROOMMATE remains home during room handover")
            phone_measurement("present", "absent")
            advance(5)
            after = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["trace"]
            check(sum(event["reason"] == "arrival confirmed" for event in before)
                  == sum(event["reason"] == "arrival confirmed" for event in after), "room handover creates no new arrival")
            # Finding 14: a Home webhook arrives while every room is briefly
            # negative, before another sensor can repair the false Geo trip.
            for signal_mode in ("state", "measurement"):
                command(f"attr Geo.Test phoneSignalMode {signal_mode}")
                command("{ GP_ResetController($defs{GP});; return 'reset' }")
                advance(40)
                phone_state("p1", "present")
                phone_state("p2", "absent")
                advance(5)
                phone_state("p1", "absent")
                advance(5)
                command("set door untouched")
                command("set garage untouched")
                refresh_actor_contacts()
                check(command("{ ReadingsVal('Geo.Test','gp_phone_health','unknown') }") == "handover",
                      f"{signal_mode}: all-negative room gap retains phone continuity")
                check(request("Outer", 0)[0] == 200, f"{signal_mode}: false outer exit accepted for evaluation")
                advance(3)
                evidence = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(not evidence.get("trip") and evidence["phase"] == "home",
                      f"{signal_mode}: handover veto removes remote evidence and keeps home")
                advance(61)
                check(request("Home", 1)[0] == 200, f"{signal_mode}: Home return during gap accepted")
                advance(3)
                check(command("{ ReadingsVal('door','state','unknown') }") == "untouched"
                      and command("{ ReadingsVal('garage','state','unknown') }") == "untouched",
                      f"{signal_mode}: Home after minimum-away time cannot open during handover")
                phone_state("p2", "present")
                advance(5)
                check(command("{ ReadingsVal('door','state','unknown') }") == "untouched"
                      and command("{ ReadingsVal('rr_Test','state','unknown') }") == "home",
                      f"{signal_mode}: detection in another room preserves home without a pulse")

            # Finding 5: real reading updates at start + 0.5 s have the same
            # whole-second TIME as the fractional dispatch start. Freeze only
            # this fixture's wall clock so host scheduling cannot hide the bug.
            command("attr Geo.Test phoneSignalMode state")
            phone_state("p1", "absent")
            phone_state("p2", "absent")
            command("{ GP_ResetController($defs{GP});; return 'reset' }")
            advance(40)
            check(request("Work", 0)[0] == 200, "fractional feedback test starts a real trip")
            advance(3)
            advance(90)
            refresh_actor_contacts()
            command("{ $main::GP_fixture_fixed_wall=int(GP_Now())+1.2-$main::GP_fixture_offset }")
            check(request("Home", 1)[0] == 200, "fractional feedback test arrives via actual webhook")
            advance(3)
            started = float(command("{ $defs{GP}{helper}{gp}{actors}{door}{start} }"))
            check(abs(started % 1 - 0.2) < 0.001, "door dispatch starts 200 ms into the second")
            advance(0.5)
            actor_reading("feedback", "pulse_state", "confirmed")
            for device, value in (("gate", "on"), ("upper", "closed"), ("lower", "open")):
                actor_reading(device, "state", value)
            check(float(command("{ GP_ReadingTime('feedback','pulse_state') }")) == int(started),
                  "actual FHEM pulse feedback timestamp is truncated to dispatch second")
            command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")
            check(command("{ ReadingsVal('Geo.Test','gp_door_result','unknown') }") == "confirmed",
                  "same-second pulse feedback confirms door rather than waiting for timeout")
            check(command("{ ReadingsVal('Geo.Test','gp_garage_result','unknown') }") == "confirmed",
                  "same-second consistent end positions confirm garage")
            check(command("{ scalar keys %{$defs{GP}{helper}{gp}{actors}} }") == "0",
                  "both shared reservations released for independent later arrivals")

            # A later authorized arrival must not inherit an old terminal value
            # from the same second. Real FHEM events distinguish pending ->
            # confirmed even when the final value AND timestamp are identical.
            check(request("Work", 0)[0] == 200, "next independent trip accepted")
            advance(3)
            advance(90)
            check(request("Home", 1)[0] == 200, "next qualified Home arrival accepted")
            command("{ $main::GP_fixture_offset += 3 }")
            actor_reading("feedback", "pulse_state", "confirmed")
            baseline = command("{ ReadingsTimestamp('feedback','pulse_state','missing') }")
            command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")
            command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")
            check(command("{ ReadingsVal('Geo.Test','gp_door_result','unknown') }") == "pending",
                  "old same-second confirmation does not finish the new pulse")
            actor_reading("feedback", "unrelated", "confirmed")
            command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")
            check(command("{ ReadingsVal('Geo.Test','gp_door_result','unknown') }") == "pending",
                  "unrelated real FHEM event cannot refresh pulse_state")
            actor_reading("feedback", "pulse_state", "pending")
            actor_reading("feedback", "pulse_state", "confirmed")
            check(command("{ ReadingsTimestamp('feedback','pulse_state','missing') }") == baseline,
                  "new pulse finishes with identical whole-second timestamp and terminal value")
            command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")
            check(command("{ ReadingsVal('Geo.Test','gp_door_result','unknown') }") == "confirmed"
                  and command("{ scalar keys %{$defs{GP}{helper}{gp}{actors}} }") == "0",
                  "matching real FHEM events confirm and release the independent new pulse")

            # Finding 16: the door controller resets its diagnostic state on
            # contact close. Emit both real events in one FHEM command so there
            # cannot be a GeoPresence timer between confirmed and idle.
            for terminal in ("confirmed", "failed", "cancelled"):
                check(request("Work", 0)[0] == 200, f"{terminal}: next trip accepted")
                advance(3)
                advance(90)
                actor_reading("feedback", "pulse_state", "idle")
                command("set door untouched")
                check(request("Home", 1)[0] == 200, f"{terminal}: authorized arrival accepted")
                advance(3)
                check(command("{ ReadingsVal('door','state','unknown') }") == "lock unlocked",
                      f"{terminal}: independent arrival receives its own door command")
                command("{ for my $value ('" + terminal + "','idle') { my $h=$defs{feedback};; "
                        "readingsBeginUpdate($h);; "
                        "$h->{'.updateTimestamp'}=strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now()));; "
                        "$h->{'.updateTime'}=GP_Now();; readingsBulkUpdate($h,'pulse_state',$value);; "
                        "readingsEndUpdate($h,1) };; return 'closed before next timer' }")
                check(command("{ ReadingsVal('feedback','pulse_state','unknown') }") == "idle",
                      f"{terminal}: visible pulse state has already returned to idle")
                command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")
                check(command("{ ReadingsVal('Geo.Test','gp_door_result','unknown') }") == terminal,
                      f"{terminal}: transient terminal event survives idle before polling")
                check(command("{ scalar keys %{$defs{GP}{helper}{gp}{actors}} }") == "0",
                      f"{terminal}: completion releases shared door reservation")

            # Real hardware requests outlive a debug/disabled mode switch. Their
            # terminal results must be logged without restoring productive state.
            check(command("attr GP debugLog 1") == "", "production diagnostics can be enabled independently")
            for change, restore in (("set GP mode debug", "set GP mode active"),
                                    ("set Geo.Test mode debug", "set Geo.Test mode active"),
                                    ("set GP mode disabled", "set GP mode active")):
                check(request("Work", 0)[0] == 200, "logging regression starts a fresh trip")
                advance(3)
                advance(90)
                refresh_actor_contacts()
                check(request("Home", 1)[0] == 200, "logging regression accepts authorized arrival")
                advance(3)
                check(command("{ scalar keys %{$defs{GP}{helper}{gp}{actors}} }") == "2",
                      "both actual dummy opening requests are pending")
                normal_before = len((root / "log/fhem.log").read_text())
                check(command(change) == "", "mode changes while requests are pending")
                readings_before = command("{ $main::GP_fixture_user_readings }")
                advance(1)
                actor_reading("feedback", "pulse_state", "confirmed")
                for device, value in (("gate", "on"), ("upper", "closed"), ("lower", "open")):
                    actor_reading(device, "state", value)
                advance(1)
                advance(1)
                normal = (root / "log/fhem.log").read_text()[normal_before:]
                check(normal.count('Door opener “door” confirmed the opening pulse.') == 1,
                      "real door completion is logged once after productive state was removed")
                check(normal.count('Garage “garage” is open.') == 1,
                      "real garage completion is logged once after productive state was removed")
                check(command("{ scalar keys %{$defs{GP}{helper}{gp}{actors}} }") == "0",
                      "retained requests finish normally in debug or disabled mode")
                check(command("{ $main::GP_fixture_user_readings }") == readings_before,
                      "completion logging does not publish productive resident readings")
                check(command(restore) == "", "productive mode can be restored after completed requests")
                advance(40)

            # A real CommandSet callback may reset the session before returning.
            # Flush the executed request immediately, and suppress the next one.
            check(request("Work", 0)[0] == 200, "callback regression starts a fresh trip")
            advance(3)
            advance(90)
            refresh_actor_contacts()
            command("set door untouched")
            command("set garage untouched")
            normal_before = len((root / "log/fhem.log").read_text())
            check(request("Home", 1)[0] == 200, "callback regression accepts arrival")
            command("{ $main::GP_fixture_offset+=3;; my $original=\\&CommandSet;; "
                    "{ no warnings 'redefine';; local *CommandSet=sub ($$) { "
                    "my $result=$original->(@_);; CommandSet(undef,'GP mode debug') if $_[1] eq 'door lock unlocked';; "
                    "return $result };; GeoPresence_Timer($defs{GP}) };; return 'callback tested' }")
            check(command("{ ReadingsVal('door','state','unknown') }") == "lock unlocked",
                  "actual door command executed before callback changed mode")
            check(command("{ ReadingsVal('garage','state','unknown') }") == "untouched",
                  "callback mode change blocks subsequent garage command")
            normal = (root / "log/fhem.log").read_text()[normal_before:]
            check(normal.count('Door opening requested for “door”.') == 1,
                  "dispatched command stays logged after synchronous session reset")
            advance(1)
            actor_reading("feedback", "pulse_state", "confirmed")
            advance(1)
            check(command("set GP mode active") == "", "restore mode after callback regression")
            check(command("attr GP debugLog auto") == "", "restore automatic diagnostics without changing mode")
            advance(40)

            command("{ $main::GP_fixture_offset += $main::GP_fixture_fixed_wall-Time::HiRes::time();; "
                    "undef $main::GP_fixture_fixed_wall;; return 'clock resumed' }")

            # Finding 18: no Home motion is evidence of neither a new car ride
            # nor a refreshed foot journey; the prior DriveIn proof still counts.
            for motion in (None, "unknown", "stationary", "unrecognized-test-value"):
                check(request("Work", 0)[0] == 200, "foot journey starts with valid remote evidence")
                advance(3)
                advance(90)
                refresh_actor_contacts()
                command("set door untouched")
                command("set garage untouched")
                check(request("Drive", 1, motion="walking")[0] == 200, "walking approach accepted")
                advance(3)
                observed = command("{ ReadingsVal('Geo.Test','gp_motion_time','missing') }")
                advance(7)
                check(request("Home", 1, motion=motion)[0] == 200, "inconclusive Home motion accepted")
                advance(3)
                check(command("{ ReadingsVal('door','state','unknown') }") == "lock unlocked",
                      "foot return still opens the authorized door")
                check(command("{ ReadingsVal('garage','state','unknown') }") == "untouched",
                      f"Home motion {motion!r} cannot erase fresh walking and open garage")
                check(command("{ ReadingsVal('Geo.Test','gp_motion','missing') }") == "walking"
                      and command("{ ReadingsVal('Geo.Test','gp_motion_time','missing') }") == observed,
                      "walking evidence keeps its original timestamp")

            # Findings 2-4: real PRESENCE processing, no periodic repeat messages.
            command("attr p1 event-on-change-reading presence")
            command("attr p2 event-on-change-reading presence")
            command("{ GP_ResetController($defs{GP});; return 'reset' }")
            advance(40)
            command("set door untouched")
            command("set garage untouched")
            rejected_remote = event_body("Outer", 0)
            advance(1)
            phone_state("p1", "present")
            phone_state("p2", "absent")
            advance(5)
            check(http_request("POST", "/fhem/geopresence", rejected_remote, auth_headers())[0] == 200,
                  "remote evidence is accepted for ordered evaluation")
            advance(3)
            evidence = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(not evidence.get("trip"), "newer local phone evidence rejects and removes the remote trip")
            advance(10)
            check(request("Home", 0)[0] == 200, "subsequent real local walk starts")
            advance(3)
            phone_state("p1", "absent")
            untouched_time = command("{ ReadingsTimestamp('p2','presence','missing') }")
            advance(5)
            advance(180)
            evidence = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(evidence["trip"]["armed"] and evidence["trip"]["scope"] == "local",
                  "single negative transition qualifies local walk with other room states held")
            check(command("{ ReadingsTimestamp('p2','presence','missing') }") == untouched_time,
                  "qualification does not need a new reading from an already-negative room")
            refresh_actor_contacts()
            check(request("Home", 1)[0] == 200, "return from local walk accepted")
            advance(3)
            check(command("{ ReadingsVal('door','state','unknown') }") == "lock unlocked"
                  and command("{ ReadingsVal('garage','state','unknown') }") == "untouched",
                  "rejected remote scope cannot open garage on the later local walk")
            advance(5)
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "home",
                  "same old phone negatives cannot undo fresh Home arrival on next poll")
            advance(120)
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "home",
                  "old latched negatives cannot start another departure after arrival")
            advance(1)
            request("Work", 0)
            advance(3)
            phone_state("p1", "absent")
            advance(5)
            advance(180)
            check(request("Drive", 1)[0] == 200, "fresh approach after confirmed departure accepted")
            advance(3)
            advance(5)
            check(command("{ ReadingsVal('Geo.Test','gp_phase','unknown') }") == "returning",
                  "old phone negatives cannot overwrite DriveIn returning state")
            request("Home", 1)
            advance(3)
            advance(5)
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "home",
                  "Home stays home after the same negative sensor snapshot is polled")

            # Generic phone_only status contract; all three planned residents
            # including Piko now use geofency_phone for qualified door arrivals.
            command("set GP mode debug")
            command("attr Geo.Test sourceMode phone_only")
            command("attr Geo.Test phoneSignalMode state")
            command("set GP mode active")
            advance(40)
            phone_state("p1", "present")
            advance(5)
            command("set door untouched")
            command("set garage untouched")
            phone_state("p1", "absent")
            absent_time = command("{ ReadingsTimestamp('p1','presence','missing') }")
            advance(5)
            advance(175)
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "home",
                  "phone_only does not become absent before the full qualification")
            advance(5)
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "absent",
                  "phone_only becomes absent from one negative message per changed room")
            check(command("{ ReadingsVal('Geo.Test','gp_phone_health','unknown') }") == "held"
                  and command("{ ReadingsTimestamp('p1','presence','missing') }") == absent_time,
                  "held-state diagnostic does not manufacture reading freshness")
            advance(600)
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "absent",
                  "unchanged state remains usable beyond the former TTL")
            phone_state("p2", "present")
            advance(5)
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "home",
                  "phone_only returns through a different room sensor")
            check(command("{ ReadingsVal('door','state','unknown') }") == "untouched"
                  and command("{ ReadingsVal('garage','state','unknown') }") == "untouched",
                  "phone_only never grants opening permission")
            # Keep later HTTP reload checks on a resident with Geofency enabled.
            command("set GP mode debug")
            command("attr Geo.Test sourceMode geofency_phone")
            command("set GP mode active")
            advance(1)

            # First installation without DriveIn: learn actual HTTP payloads
            # before any locations exist, then manually apply returned commands.
            command("set GP mode debug")
            for zone in zones:
                command(f"delete Z.{zone}")
            check("exactly one home" in command("get GP validate Geo.Test"), "incomplete registration is visible")
            check("Learning for 15" in command("set Geo.Test mode learning"), "learning starts before location registration")
            advance(1)
            before = command("{ $main::GP_fixture_user_readings }")
            for zone in ("Home", "Outer", "Work"):
                payload = event_body(zone, 1, test=True) + "&" + urllib.parse.urlencode({
                    "name": zone, "address": "PRIVATE_ADDRESS\r\nPRIVATE_CITY\tZIP",
                    "wifiSSID": "PRIVATE_WIFI", "notes": "PRIVATE_NOTES\nSECOND_LINE",
                })
                status, _, body = http_request("POST", "/fhem/geopresence", payload, auth_headers())
                check(status == 200 and "learning captured" in body, f"real HTTP learns {zone} without executing events")
            status, _, body = http_request("POST", "/fhem/geopresence",
                                          event_body("Home", 1, test=True) + "&name=PRIVATE_NAME%0AINJECTED_LINE", auth_headers())
            check(status == 400 and "U+000A in name" in body, "real HTTP identifies invalid decision field without its value")
            log_status = json.loads(command("get GP logStatus format=json"))
            logfile = root / log_status["file"]
            check(logfile.is_file() and not log_status["error"], "module creates monthly diagnostic file during real HTTP learning")
            diagnostic = logfile.read_text()
            check('"ignored_multiline":"address,notes"' in diagnostic,
                  "accepted metadata is diagnosed by field name only")
            check("Control character U+000A in name" in diagnostic and '"status":"400"' in diagnostic,
                  "rejected webhook is visible in the separate file")
            check("learning_started" in diagnostic and "OK learning captured; no actions" in diagnostic,
                  "learning lifecycle and successful responses are logged")
            check("Control character U+000A in name" not in (root / "log/fhem.log").read_text(),
                  "webhook debug details stay out of the standard FHEM log")
            check(not any(value in diagnostic for value in (password, "PRIVATE_ADDRESS", "PRIVATE_CITY", "PRIVATE_WIFI",
                                                            "PRIVATE_NOTES", "PRIVATE_NAME", "INJECTED_LINE", "Authorization", "Basic ")),
                  "separate diagnostic file contains no credentials or submitted text values")
            learned = json.loads(command("get GP learnedLocations Geo.Test format=json"))
            check([item["name"] for item in learned] == ["Home", "Outer", "Work"], "learning retains names and numbered identities")
            _, report_headers, _ = http_request("GET", "/fhem", port=admin_port)

            def report(query):
                params = urllib.parse.urlencode({"cmd": "get GP " + query, "XHR": 1, "addLinks": 1,
                                                "fwcsrf": report_headers["x-fhem-csrftoken"]})
                status, _, body = http_request("GET", "/fhem?" + params, port=admin_port)
                check(status == 200, "resident report HTTP success: " + query)
                return body

            learned_html = report("learnedLocations Geo.Test")
            check("Captured locations" in learned_html and "@1" in learned_html and "4500 m" in learned_html,
                  "learned locations have a readable browser table")
            check("3 captured locations" in command("get GP learnedLocations Geo.Test"),
                  "learned location default also readable via Telnet")
            check(json.loads(report("learnedLocations Geo.Test format=json")) == learned,
                  "learned machine records identical via Telnet and FHEMWEB")
            check(command("{ $main::GP_fixture_user_readings }") == before, "learning invokes no resident userReadings")
            check(command("{ exists $defs{'Z.Home'} ? 1 : 0 }") == "0", "learning creates no FHEM devices")
            advance(901)
            check(json.loads(command("get GP learnedLocations Geo.Test format=json")) == learned,
                  "real FHEM keeps learning results after reception expires without another command")
            status, _, body = http_request("POST", "/fhem/geopresence", event_body("Home", 1, test=True), auth_headers())
            check(status == 503 and "Resident disabled" in body, "retaining results does not extend HTTP learning reception")
            check(json.loads(command("get GP learnedLocations Geo.Test format=json")) == learned
                  and command("{ $main::GP_fixture_user_readings }") == before,
                  "expired HTTP learning neither replaces results nor publishes Readings")
            command("set Geo.Test learnConfirm")
            check(json.loads(command("get GP learnedLocations Geo.Test format=json")) == learned,
                  "learnConfirm keeps expired results available for manual registration")
            for number, zone, role in ((1, "Home", "home"), (2, "Outer", "outer"), (3, "Work", "place")):
                commands = command(f"get GP locationCommands Geo.Test @{number} {role} Z.{zone}")
                check(commands.startswith("define ") and "latitude" not in commands, "manual definitions contain no copied geometry")
                generated = json.loads(report(f"locationCommands Geo.Test @{number} {role} Z.{zone} format=json"))
                check(generated["commands"] == commands.splitlines(), "JSON commands match copyable Telnet commands")
                check(commands.splitlines()[0] in report(f"locationCommands Geo.Test @{number} {role} Z.{zone}"),
                      "browser command block contains the original definition")
                for text in commands.splitlines():
                    check(command(text) == "", "generated Telnet command accepted by real FHEM")
            check(json.loads(command("get GP learnedLocations Geo.Test format=json")) == learned,
                  "manual location definitions preserve captured results beyond the original deadline")
            check(command("get GP validate Geo.Test").startswith("OK:"), "no approach location required for activation")
            command("{ $main::GP_fixture_geometry_readings=0 }")
            for zone in ("Home", "Outer", "Work"):
                command(f"attr Z.{zone} userReadings observed {{ ++$main::GP_fixture_geometry_readings }}")
            command("set Geo.Test mode debug")
            command("set GP debugReset Geo.Test")
            advance(1)
            for zone in ("Home", "Outer", "Work"):
                request(zone, 1, debug=True)
                advance(3)
            view = json.loads(command("get GP explain Geo.Test debug format=json"))
            check(view["geometry_ready"] == 1, "debug learns geometry through the real timer")
            check(command("{ ReadingsVal('Z.Home','gp_geometry','missing') }") == "missing"
                  and command("{ $main::GP_fixture_geometry_readings }") == "0", "debug never stores or publishes geometry")
            command("set Geo.Test mode active")
            command("set GP mode active")
            advance(40)
            check(command("{ ReadingsVal('Geo.Test','gp_geometry_ready','unknown') }") == "0", "debug metadata does not initialize productive operation")
            phone_state("p1", "absent")
            phone_state("p2", "absent")
            advance(5)
            command("set door untouched")
            command("set garage untouched")
            for zone in ("Home", "Outer", "Work"):
                check(request(zone, 1)[0] == 200, "first productive geometry accepted")
                advance(3)
            check(command("{ ReadingsVal('door','state','unknown') }") == "untouched"
                  and command("{ ReadingsVal('garage','state','unknown') }") == "untouched", "initial geometry never grants opening")
            geometry = json.loads(command("{ ReadingsVal('Z.Home','gp_geometry','{}') }"))
            check(geometry["radius"] == 50 and geometry["device"] == "test-device", "productive metadata uses bound ordinary readings")
            check(int(command("{ $main::GP_fixture_geometry_readings }")) > 0, "productive geometry uses real FHEM readings API")
            # The prior positive phone snapshot still vetoes remote evidence
            # during handover; this scenario represents an actual later trip.
            advance(180)
            request("Work", 0)
            advance(3)
            check(json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["trip"]["armed"] == 1, "remote trip arms without DriveIn")
            advance(90)
            refresh_actor_contacts()
            request("Home", 1)
            advance(3)
            check(command("{ ReadingsVal('door','state','unknown') }") == "lock unlocked"
                  and command("{ ReadingsVal('garage','state','unknown') }") == "on", "Home arrival opens dummy actors without approach")
            command("set door untouched")
            command("set garage untouched")
            request("Work", 0)
            advance(3)
            advance(90)
            request("Home", 1)
            changed = urllib.parse.parse_qs(event_body("Work", 1))
            changed["radius"] = ["110"]
            changed_body = urllib.parse.urlencode({key: value[0] for key, value in changed.items()})
            http_request("POST", "/fhem/geopresence", changed_body, auth_headers())
            advance(3)
            check(command("{ ReadingsVal('door','state','unknown') }") == "untouched"
                  and command("{ ReadingsVal('garage','state','unknown') }") == "untouched", "changed geometry cancels pending arrival through real HTTP")
            check(json.loads(command("{ ReadingsVal('Z.Work','gp_geometry','{}') }"))["radius"] == 110, "changed geometry automatically stored")
            command("save")  # This isolated test has no System.SaveConfig automation.
            check("gp_geometry" in (root / "log/fhem.save").read_text(), "ordinary FHEM save contains geometry metadata")

            with socket.create_connection(("127.0.0.1", web_port), timeout=4) as incomplete:
                incomplete.sendall(prefix + b"Content-Length: 8\r\n\r\nentry=")
                # A test-only marker models the previous module's registration.
                command("{ $data{FWEXT}{'/geopresence'}={GP_OWNER=>'GP',FUNC=>'GeoPresence_CGI'};; return 'registered' }")
                timing_before_reload = json.loads(command("get GP timerStats format=json"))["worst_run"]
                command("reload 98_GeoPresence.pm")
                check(incomplete.recv(1) == b"", "reload closes pending HTTP clients")
            check(json.loads(command("get GP timerStats format=json"))["worst_run"] == timing_before_reload,
                  "module reload preserves the slowest measured profile")
            check(command("{ exists $data{FWEXT}{'/geopresence'} ? 'stale' : 'removed' }") == "removed", "reload removes legacy FWEXT registration")
            check(json.loads(command("get GP learnedLocations Geo.Test format=json")) == learned
                  and command("{ $defs{GP}{helper}{gp}{learning}{'Geo.Test'} ? 1 : 0 }") == "0",
                  "real module reload recovers expired results without reopening learning")
            command("{ GeoPresence_Timer($defs{GP});; return 'ticked' }")
            state = json.loads(command("get GP explain Geo.Test prod format=json"))
            check(not state["state"].get("trip"), "real reload revokes permissions")
            check(state["geometry"]["Z.Work"]["radius"] == 110, "reload restores latest geometry but no old permission")
            check(request("Home", 1, auth=False)[0] == 401, "listener reopens and authenticates after reload")
            command("set GP mode debug")
            command(f"attr GP webhookPort {admin_port}")
            advance(1)
            check("Cannot listen" in command("get GP validate"), "occupied port is a visible validation error")
            check(command("{ $defs{GP}{helper}{gp}{ready} }") == "0", "bind failure leaves controller unready")
            command(f"attr GP webhookPort {web_port}")
            advance(1)
            check(request("Home", 1, auth=False)[0] == 401, "listener recovers on a free port")
            # A distinct loopback address models the FHEM LAN interface and
            # client source addresses model separate proxy and untrusted hosts.
            check(command("attr GP webhookAllowedPeers 127.0.0.3") == "", "explicit remote proxy address accepted")
            check(command("attr GP webhookBindAddress 127.0.0.2") == "", "alternate interface accepted")
            advance(1)
            check(http_request("GET", "/fhem/geopresence", host="127.0.0.2", source="127.0.0.3")[0] == 405,
                  "allowed proxy reaches listener on configured interface")
            check(http_request("POST", "/fhem/geopresence", "", auth_headers(False),
                               host="127.0.0.2", source="127.0.0.3")[0] == 401,
                  "allowed proxy still needs resident authentication")
            check(http_request("POST", "/fhem/geopresence", event_body("Home", 1, test=True), auth_headers(),
                               host="127.0.0.2", source="127.0.0.3")[0] == 200,
                  "authenticated debug webhook works from allowed proxy address")
            for source in ("127.0.0.1", "127.0.0.4"):
                blocked = False
                try:
                    headers = {**auth_headers(), "X-Forwarded-For": "127.0.0.3", "X-Real-IP": "127.0.0.3"}
                    http_request("POST", "/fhem/geopresence", event_body("Home", 1, test=True), headers,
                                 host="127.0.0.2", source=source)
                except (ConnectionResetError, BrokenPipeError, http.client.RemoteDisconnected):
                    blocked = True
                check(blocked, "unlisted socket peer cannot enter, even with credentials and forged proxy headers")
            old_binding_closed = False
            try:
                with socket.create_connection(("127.0.0.1", web_port), timeout=1):
                    pass
            except ConnectionRefusedError:
                old_binding_closed = True
            check(old_binding_closed, "changing bind address releases old listener")
            check(command("deleteattr GP webhookBindAddress") == "", "default bind address can be restored")
            check(command("deleteattr GP webhookAllowedPeers") == "", "default peer list can be restored")
            advance(1)
            check(request("Home", 1, auth=False)[0] == 401, "default local listener works after restoration")

            # Execute the generic manual's PERSON and lamp recipes using real
            # FHEM commands in this isolated installation, not the user's cfg.
            # The preceding real module reload restored the stock clock funcs.
            command("{ no warnings 'redefine';; $main::GP_fixture_offset=0;; "
                    "*GP_Now=sub { Time::HiRes::time()+$main::GP_fixture_offset };; "
                    "*GP_Mono=sub { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())+$main::GP_fixture_offset };; return 'clock set' }")
            # Reload restored the real clock but saved test geometry may have
            # later observation times from the preceding controlled-clock cases.
            latest_geometry = max(json.loads(command(f"{{ ReadingsVal('Z.{zone}','gp_geometry','{{}}') }}")).get("time", 0)
                                  for zone in ("Home", "Outer", "Work"))
            advance(max(0, latest_geometry + 40 - float(command("{ GP_Now() }"))))
            # Arrival waits at production defaults, real HTTP and dummy actors.
            for motion in ("walking", "running", "cycling", "automotive", "unknown"):
                check(command(f"deleteattr GP arrival_wait_{motion}") == "", "restore default arrival wait")
            command("set Geo.Test mode active")
            command("attr GP debugLog 1")
            command("set GP mode active")
            advance(40)
            phone_state("p1", "absent")
            phone_state("p2", "absent")
            advance(5)
            advance(180)
            request("Outer", 0)
            advance(3)
            advance(90)
            refresh_actor_contacts()
            command("set door untouched")
            command("set garage untouched")
            request("Home", 1, motion="walking")
            advance(3)
            state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(state["phase"] == "returning" and state["arrival"]["wait"] == 60,
                  f"walking Home entry remains provisional for 60 seconds: {state}")
            pending_report = report("explain Geo.Test")
            check("Arrival pending" in pending_report and "Walking" in pending_report and "no request sent yet" in pending_report,
                  "real pending walking arrival is clearly distinguished from dispatch")
            after_report = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(after_report["arrival"] == state["arrival"] and after_report["trip"] == state["trip"],
                  "FHEMWEB report leaves pending arrival and trip unchanged")
            advance(12)
            request("Home", 0)
            advance(3)
            advance(60)
            state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(not state.get("arrival") and state["trip"]["armed"] == 1,
                  "15-second false entry cancels without consuming the armed outing")
            check(command("{ ReadingsVal('door','state','unknown') }") == "untouched",
                  "false walking entry does not open dummy door")
            request("Home", 1, motion="walking")
            advance(3)
            first_arrival = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["arrival"]
            advance(20)
            request("Home", 1, motion="walking")
            advance(3)
            delayed_exit = urllib.parse.parse_qs(event_body("Home", 0))
            delayed_exit["date"] = [datetime.datetime.fromtimestamp(
                first_arrival["event"]["time"] + 15, datetime.timezone.utc).isoformat()]
            status, _, _ = http_request("POST", "/fhem/geopresence",
                                       urllib.parse.urlencode({key: value[0] for key, value in delayed_exit.items()}), auth_headers())
            check(status == 200, "delayed intervening exit accepted through real HTTP")
            advance(3)
            state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(state["arrival"]["started"] > first_arrival["started"] + 20,
                  "older unchanged geometry does not hide an interruption of Home dwell")
            advance(31)
            check(command("{ ReadingsVal('door','state','unknown') }") == "untouched",
                  "original Home deadline cannot open after a delayed intervening exit")
            phone_state("p1", "present")
            advance(5)
            check(command("{ ReadingsVal('door','state','unknown') }") == "lock unlocked",
                  "new phone arrival finishes a pending walking return before 60 seconds")
            actor_reading("feedback", "pulse_state", "confirmed")
            advance(1)
            command("set door untouched")
            advance(200)
            check(command("{ ReadingsVal('door','state','unknown') }") == "untouched",
                  "expired timer cannot issue a second pulse after phone confirmation")
            command("set GP mode debug")
            command("set GP mode active")
            advance(40)
            phone_state("p1", "absent")
            phone_state("p2", "absent")
            advance(5)
            advance(180)
            request("Outer", 0)
            advance(3)
            advance(90)
            refresh_actor_contacts()
            command("set door untouched")
            # Real synchronous FHEM notify callback, solely on the dummy door.
            # Its delay belongs to actor_command, not to presence calculations.
            check(command("define Timing.Door notify door:lock.unlocked { Time::HiRes::sleep(0.55) }") == "",
                  "dummy door timing callback defined")
            request("Home", 1, motion="automotive")
            advance(3)
            state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(state["arrival"]["wait"] == 10 and command("{ ReadingsVal('door','state','unknown') }") == "untouched",
                  "car arrival also waits instead of opening immediately")
            advance(8)
            check(command("{ ReadingsVal('door','state','unknown') }") == "lock unlocked" and
                  command("{ ReadingsVal('garage','state','unknown') }") == "on",
                  "ten-second car confirmation opens both dummy actors before 30 seconds")
            timing = json.loads(command("get GP timerStats format=json"))
            sample = timing["recent_slow"][-1]
            check(sample["slowest_phase"] == "actor_command" and sample["slowest_target"] == "door"
                  and sample["slowest_self_ms"] >= 500, "real FHEM callback is attributed to the dummy actuator")
            phases = {row["phase"] + "|" + row["target"]: row for row in sample["phases"]}
            check(phases["dispatch|Geo.Test (production)"]["self_ms"] < phases["actor_command|door"]["self_ms"],
                  "parent dispatch does not double-count the blocking notify")
            check("slowest_phase" in diagnostics() and '"slowest_target":"door"' in diagnostics(),
                  "detailed callback evidence reaches the separate diagnostic file")
            check(command("delete Timing.Door") == "", "remove isolated timing callback")
            actor_reading("feedback", "pulse_state", "confirmed")
            actor_reading("gate", "state", "on")
            actor_reading("upper", "state", "closed")
            actor_reading("lower", "state", "open")
            advance(1)
            # use actual FHEM notify callbacks during the first dummy
            # opening. A short age budget makes a real 1.5 s stall sufficient.
            check(command("define rr_Callback ROOMMATE") == "", "prepare unrelated resident")
            for reason, callback in (("manual Home", "set rr_Test home"),
                                     ("expired", "{ Time::HiRes::sleep(1.5) }"),
                                     ("controller rename", "{ CommandRename(undef,'GP GP.Callback'), CommandRename(undef,'GP.Callback GP') }"),
                                     ("resident rename", "{ CommandRename(undef,'Geo.Test Geo.CallbackTemp'), CommandRename(undef,'Geo.CallbackTemp Geo.Test') }"),
                                     ("unrelated configuration", "define Geo.Callback GeoPresence resident GP rr_Callback"),
                                     ("alias", "attr Geo.Test alias Callback name"),
                                     ("alias deletion", "deleteattr Geo.Test alias"),
                                     ("ROOMMATE alias pattern", "deleteattr rr_Test ^alias$"),
                                     ("ROOMMATE alias class pattern", "deleteattr rr_Test [a]lias"),
                                     ("ROOMMATE alias spaced pattern", "deleteattr rr_Test (?x) ^ alias $"),
                                     ("ROOMMATE functional pattern", "deleteattr rr_Test ^(alias|rr_locationUnderway)$"),
                                     ("controller pattern", "{ $main::GP_fixture_delete_result=CommandDeleteAttr(undef,'GP action_max_ag.') }"),
                                     ("controller all", "{ $main::GP_fixture_delete_result=CommandDeleteAttr(undef,'GP') }"),
                                     ("clock correction during wait", "{ Time::HiRes::sleep(2.5) }")):
                check(command("set GP mode debug") == "", "pause fixture")
                check(command("attr GP reorder_window 0.1") == "", "short reorder window")
                check(command("attr GP action_max_age 2") == "", "short output budget")
                check(command("set GP mode active") == "", "activate fixture")
                if reason.startswith("ROOMMATE"):
                    check(command("attr rr_Test alias Callback label") == "", "prepare a real ROOMMATE alias")
                advance(40)
                phone_state("p1", "absent")
                phone_state("p2", "absent")
                advance(5)
                check(request("Outer", 0)[0] == 200, "remote departure accepted")
                advance(1)
                advance(90)
                refresh_actor_contacts()
                command("set door untouched")
                command("set garage untouched")
                check(command("define Callback.Door notify door:lock.unlocked " + callback) == "",
                      "synchronous callback installed: " + reason)
                correction = reason == "clock correction during wait"
                check(request("Home", 1, motion="unknown" if correction else "automotive")[0] == 200,
                      "Home observation accepted")
                advance(1)
                planned = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(planned["arrival"]["wait"] == (60 if correction else 10), "arrival retains its normal wait")
                if correction:
                    advance(49)
                    command("{ no warnings 'redefine';; *GP_Now=sub { Time::HiRes::time()+$main::GP_fixture_offset-10 };; return 'wall corrected' }")
                advance(10)
                check(command("{ ReadingsVal('door','state','') }") == "lock unlocked",
                      "first door command executes: " + reason)
                unrelated = reason == "unrelated configuration"
                renamed = reason in ("controller rename", "resident rename")
                allowed = not renamed and reason not in ("manual Home", "expired", "clock correction during wait", "ROOMMATE functional pattern")
                check(command("{ ReadingsVal('garage','state','') }") == ("on" if allowed else "untouched"),
                      "remaining garage command respects current permission: " + reason)
                changed = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                if allowed:
                    permission_valid = changed["output_revision"] == planned["output_revision"]
                elif renamed:
                    permission_valid = not changed or changed["generation"] != planned["generation"]
                elif reason in ("manual Home", "ROOMMATE functional pattern"):
                    permission_valid = changed["output_revision"] > planned["output_revision"]
                else:
                    permission_valid = any(row["reason"] == "intent expired" for row in changed["trace"])
                check(permission_valid, "permission change is scoped to the affected resident")
                check(("garage" in json.loads(command("get GP explain Geo.Test prod format=json"))["pending_actors"]) == allowed,
                      "reserves only commands that were actually issued")
                check(command("delete Callback.Door") == "", "remove callback")
                if reason.startswith("ROOMMATE"):
                    check(command("{ AttrVal('rr_Test','alias','missing') }") == "missing", "ROOMMATE pattern actually removed the alias")
                    check(command("{ GP_Config($defs{GP},'Geo.Test',0)->{label} }") == "rr_Test",
                          "ROOMMATE pattern refreshes the cached message label")
                    check(command("attr rr_Test rr_locationUnderway underway") == "", "restore ROOMMATE guard")
                if reason in ("controller pattern", "controller all"):
                    check("Controller configuration requires" in command("{ $main::GP_fixture_delete_result }"),
                          "rejects the real controller bulk deletion before committing it")
                    check(command("{ AttrVal('GP','action_max_age','missing') }") == "2",
                          "rejected bulk deletion retains the original age")
                if correction:
                    command("{ no warnings 'redefine';; *GP_Now=sub { Time::HiRes::time()+$main::GP_fixture_offset };; return 'wall restored' }")
                if unrelated:
                    check(command("delete Geo.Callback") == "", "remove unrelated resident")
                if allowed:
                    actor_reading("gate", "state", "open")
                    actor_reading("upper", "state", "open")
                    actor_reading("lower", "state", "closed")
                actor_reading("feedback", "pulse_state", "confirmed")
                advance(1)
                completed = json.loads(command("get GP explain Geo.Test prod format=json"))
                check("door" not in completed["pending_actors"] if renamed else completed["state"]["door_result"] == "confirmed",
                      "retains feedback for the issued door command")
            check(command("delete rr_Callback") == "", "remove unrelated ROOMMATE")
            command("set GP mode debug")
            command("deleteattr GP action_max_age")
            command("deleteattr GP reorder_window")
            command("set GP mode active")
            # Reproduce attributes left by an older module before warming the
            # real validation cache, then use actual FHEM deletion commands.
            for name, keys, pattern in (("R.Door", "role condition", "^(role|condition)$"),
                                        ("R.Door", "role condition", "(?x) ^ (role | condition) $"),
                                        ("GP", "mode operatingMode", "^(mode|operatingMode)$"),
                                        ("Geo.Test", "mode operatingMode", "^(mode|operatingMode)$")):
                check(command("set GP mode debug") == "", "pause obsolete-attribute fixture")
                check(command("{ $attr{'" + name + "'}{$_}='obsolete' for qw(" + keys + ");; "
                              "GP_InvalidateConfig($defs{GP});; return 'seeded' }") == "seeded",
                      "restore legacy attributes for " + name)
                invalid = command("get GP validate Geo.Test")
                check(not invalid.startswith("OK:") and all(key in invalid for key in keys.split()),
                      "real validation caches the obsolete attribute errors")
                check(command("deleteattr " + name + " " + pattern) == "", "real obsolete-attribute pattern accepted")
                check(command("get GP validate Geo.Test").startswith("OK:"), "cleaned attributes refresh real validation")
                check(command("set GP mode active") == "", "cleaned configuration activates without a reload")
            # keeping the same unarmed Home departure must keep its
            # route consumption, even after a new valid exit and another visit.
            zones["RouteA"] = ("place", 0.0009, 20)
            zones["RouteB"] = ("place", 0.00135, 20)
            for text in ("set GP mode debug", "define retainedRouteLamp dummy",
                         "define Z.RouteA GeoPresence location Geo.Test place", "attr Z.RouteA zoneId RouteA",
                         "define Z.RouteB GeoPresence location Geo.Test place", "attr Z.RouteB zoneId RouteB",
                         "define A.RetainedRoute GeoPresence action GP switch_on",
                         "attr A.RetainedRoute target retainedRouteLamp", "attr A.RetainedRoute command on",
                         "define R.RetainedRoute GeoPresence rule GP", "attr R.RetainedRoute residents Geo.Test",
                         "attr R.RetainedRoute trigger enter", "attr R.RetainedRoute locations Z.RouteB",
                         "attr R.RetainedRoute afterExit location:Z.RouteA", "attr R.RetainedRoute action A.RetainedRoute",
                         "attr R.RetainedRoute cooldown 0", "set GP mode active"):
                check(command(text) == "", "configures the real route: " + text)
            advance(40)
            for zone in ("RouteA", "RouteB"):
                check(request(zone, 1)[0] == 200, "initializes nearby geometry")
                advance(3)
            command("{ GP_ResetController($defs{GP});; return 'reset' }")
            advance(40)
            phone_state("p1", "present")
            phone_state("p2", "absent")
            advance(5)
            for target in ("retainedRouteLamp", "door", "garage"):
                command(f"set {target} untouched")
            check(request("Home", 0)[0] == 200, "accepts the unconfirmed Home departure")
            advance(3)
            retained = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["trip"]
            for zone, entry in (("RouteA", 0), ("RouteB", 1)):
                advance(10)
                check(request(zone, entry)[0] == 200, "accepts the initial route observation")
                advance(3)
            check(command("{ ReadingsVal('retainedRouteLamp','state','') }") == "on",
                  "first route command really reached the dummy")
            consumed = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["trip"]["actions"]
            command("set retainedRouteLamp untouched")
            advance(10)
            check(request("Outer", 0)[0] == 200, "accepts the contradictory outer observation")
            advance(3)
            state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(state["trip"]["id"] == retained["id"] and state["trip"]["home_exit"] == retained["home_exit"]
                  and state["trip"]["scope"] == "local" and not state["trip"]["armed"],
                  "retains the same unarmed local trip")
            check(state["trip"]["actions"] == consumed and not state["trip"].get("exits"),
                  "retains consumption while discarding rejected exit evidence")
            for zone, entry in (("RouteA", 1), ("RouteA", 0), ("RouteB", 0), ("RouteB", 1)):
                advance(10)
                check(request(zone, entry)[0] == 200, "accepts a new explicit route visit")
                advance(3)
            check(command("{ ReadingsVal('retainedRouteLamp','state','') }") == "untouched",
                  "new exit evidence cannot repeat a consumed route in the same trip")
            for zone, entry in (("Home", 1), ("Home", 0), ("RouteA", 0), ("RouteB", 1)):
                advance(10)
                check(request(zone, entry)[0] == 200, "accepts a genuinely new outing")
                advance(3)
            state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(state["trip"]["id"] != retained["id"]
                  and command("{ ReadingsVal('retainedRouteLamp','state','') }") == "on",
                  "a new trip with new evidence may execute the route again")
            check(command("{ ReadingsVal('door','state','') }") == "untouched"
                  and command("{ ReadingsVal('garage','state','') }") == "untouched",
                  "unconfirmed departures never open the door or garage")
            for text in ("set GP mode debug", "delete R.RetainedRoute", "delete A.RetainedRoute",
                         "delete Z.RouteA", "delete Z.RouteB", "delete retainedRouteLamp", "set GP mode active"):
                check(command(text) == "", "cleans up the isolated route")
            del zones["RouteA"], zones["RouteB"]

            # Phone-source timing: retain exact source dates while controlling only
            # the private fixture clocks. All physical outputs remain dummies.
            # An earlier geometry regression changed Work's radius to 110.
            # These journeys require unchanged geometry, not another reset.
            work_geometry = json.loads(command("{ ReadingsVal('Z.Work','gp_geometry','{}') }"))
            zones["Work"] = (zones["Work"][0], work_geometry["lat"], work_geometry["radius"])
            saved_intervals = json.loads(command("{ JSON::PP::encode_json({map { $_ => $defs{$_}{INTERVAL_NORMAL} } qw(p1 p2)}) }"))
            command("{ no warnings 'redefine';; $main::GP_phone_wall_base=int(GP_Now())+1;; "
                    "$main::GP_phone_mono_base=GP_Mono()+1;; $main::GP_phone_elapsed=0;; "
                    "*GP_Now=sub { $main::GP_phone_wall_base+$main::GP_phone_elapsed };; "
                    "*GP_Mono=sub { $main::GP_phone_mono_base+$main::GP_phone_elapsed };; return 'review clock' }")
            check(command("set GP mode debug") == "", "pause the isolated phone-source setup")
            zones["R05Near"] = ("place", 0.00135, 20)
            check(command("define Z.R05Near GeoPresence location Geo.Test place") == "", "define nearby review location")
            check(command("attr Z.R05Near zoneId R05Near") == "", "bind nearby review location")
            near_geometry = json.loads(command("{ ReadingsVal('Z.Home','gp_geometry','{}') }"))
            near_geometry.update(lat=.00135, lon=0, radius=20, time=1700000000,
                                 changed=1700000000, id="r05near", blocked=0)
            command("setstate Z.R05Near 2023-11-14 22:13:20 gp_geometry " + json.dumps(near_geometry, separators=(",", ":")))

            def begin_phone_scenario(signal="state", window=180, reorder=2, poll=5):
                for text in ("set GP mode debug", f"attr Geo.Test phoneSignalMode {signal}",
                             f"attr GP phone_absence_window {window}", f"attr GP reorder_window {reorder}",
                             f"attr GP phone_poll {poll}",
                             "set GP mode active", "set door untouched", "set garage untouched"):
                    check(command(text) == "", "prepare the isolated phone-source scenario: " + text)
                refresh_actor_contacts()
                baseline = int(float(command("{ GP_Now() }"))) - 1
                for sensor in ("p1", "p2"):
                    phone_state(sensor, "absent", baseline)
                command("{ GeoPresence_Timer($defs{GP});; return 'review listener ready' }")
                return int(float(command("{ GP_Now() }")))

            def phone_scenario_at(origin, seconds, *, tick=False):
                command(f"{{ $main::GP_phone_elapsed={origin + seconds}-$main::GP_phone_wall_base;; return 'review time' }}")
                if tick:
                    command("{ GeoPresence_Timer($defs{GP});; return 'review tick' }")

            for case in ("contradiction", "mixed_positive", "genuine_return"):
                origin = begin_phone_scenario(window=20, reorder=10)
                phone_scenario_at(origin, 50)
                for sensor in ("p1", "p2"):
                    phone_state(sensor, "absent", origin + 50)
                phone_scenario_at(origin, 50, tick=True)
                phone_scenario_at(origin, 100)
                exit_body = event_body("Home", 0)
                check(http_request("POST", "/fhem/geopresence", exit_body, auth_headers())[0] == 200, "accepts Home departure")
                phone_scenario_at(origin, 110, tick=True)
                phone_scenario_at(origin, 115, tick=True)
                phone_scenario_at(origin, 134)
                http_request("POST", "/fhem/geopresence", exit_body, auth_headers())
                phone_scenario_at(origin, 135, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(any(event["kind"] == "phone_absent" for event in state["queued_phones"]),
                      "really holds a completed absence behind the Geo batch")
                phone_scenario_at(origin, 140 if case == "contradiction" else 190)
                phone_state("p1", "present", origin + (190 if case == "genuine_return" else 90))
                if case == "mixed_positive":
                    phone_state("p2", "present", origin + 185)
                phone_scenario_at(origin, 140 if case == "contradiction" else 190, tick=True)
                if case == "contradiction":
                    phone_scenario_at(origin, 144, tick=True)
                    state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                    check(state.get("trip") and not state["trip"]["armed"], "preserves suspicion but rejects the contradicted completion")
                    phone_scenario_at(origin, 190)
                    request("Home", 1, motion="walking")
                    phone_scenario_at(origin, 200, tick=True)
                    phone_scenario_at(origin, 261, tick=True)
                check(command("{ ReadingsVal('door','state','') }") == ("lock unlocked" if case == "genuine_return" else "untouched")
                      and command("{ ReadingsVal('garage','state','') }") == "untouched",
                      "uses the actual temporal relationship: " + case)
                if case == "genuine_return":
                    actor_reading("feedback", "pulse_state", "confirmed")
                    phone_scenario_at(origin, 191, tick=True)

            for mixed_positive in (False, True):
                label = "mixed historical presence" if mixed_positive else "delayed historical presence"
                origin = begin_phone_scenario()
                phone_scenario_at(origin, 50)
                for sensor in ("p1", "p2"):
                    phone_state(sensor, "absent", origin + 50)
                phone_scenario_at(origin, 50, tick=True)
                phone_scenario_at(origin, 70)
                request("Work", 0)
                phone_scenario_at(origin, 72, tick=True)
                phone_scenario_at(origin, 80, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state.get("trip", {}).get("armed"), label + " independent departure really qualified: " + state.get("last_reason", ""))
                saved_id = state["trip"]["id"]
                phone_scenario_at(origin, 100)
                command("{ GP_ResetController($defs{GP},'resume');; GeoPresence_Timer($defs{GP});; return 'restored session' }")
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state["resume"]["status"] == "restored" and state["trip"]["id"] == saved_id,
                      label + " restores the old trip against the available negative source")
                phone_scenario_at(origin, 150)
                phone_state("p1", "present", origin + 90)
                if mixed_positive:
                    phone_state("p2", "present", origin + 150)
                phone_scenario_at(origin, 150, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(not state.get("trip") and not state.get("arrival"), label + " late pre-start presence revoked the restored permission")
                check(json.loads(command("{ ReadingsVal('Geo.Test','gp_trip_checkpoint','{}') }"))["status"] == "none",
                      label + " historical revocation reaches the checkpoint")
                phone_scenario_at(origin, 200)
                request("Home", 1, motion="automotive")
                phone_scenario_at(origin, 203, tick=True)
                phone_scenario_at(origin, 264, tick=True)
                check(command("{ ReadingsVal('door','state','') }") == "untouched"
                      and command("{ ReadingsVal('garage','state','') }") == "untouched",
                      label + " mixed or historical presence and later Home issue no old opening")

            for case in ("combined_stale", "separate_stale", "early_pending_home", "early_newer_position", "fresh_valid"):
                origin = begin_phone_scenario()
                phone_scenario_at(origin, 50)
                for sensor in ("p1", "p2"):
                    phone_state(sensor, "absent", origin + 50)
                phone_scenario_at(origin, 50, tick=True)
                phone_scenario_at(origin, 80)
                check(request("Home", 0)[0] == 200, "accepts Home departure")
                phone_scenario_at(origin, 80, tick=True)
                phone_scenario_at(origin, 82, tick=True)
                phone_scenario_at(origin, 85, tick=True)
                phone_scenario_at(origin, 100)
                check(request("Outer", 0)[0] == 200, "accepts independent Geo departure")
                phone_scenario_at(origin, 100, tick=True)
                phone_scenario_at(origin, 102, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state["trip"]["armed"] and not state["trip"].get("phone_qualification"),
                      "departure is qualified without a phone completion")
                received = 170 if case.startswith("early_") else 230
                if case == "early_pending_home":
                    phone_scenario_at(origin, 165)
                    request("Home", 1, motion="walking")
                    phone_scenario_at(origin, 165, tick=True)
                    phone_scenario_at(origin, 167, tick=True)
                    state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                    check(state.get("arrival"), "newer Home is waiting before the delayed short return")
                else:
                    if case == "early_newer_position":
                        phone_scenario_at(origin, 160)
                        request("R05Near", 1)
                        phone_scenario_at(origin, 162, tick=True)
                    phone_scenario_at(origin, received - 5, tick=True)
                phone_scenario_at(origin, received)
                phone_state("p1", "present", origin + (180 if case == "fresh_valid" else 120))
                if case != "separate_stale":
                    phone_state("p2", "present", origin + received)
                source_time = command("{ ReadingsTimestamp('p1','presence','') }")
                phone_scenario_at(origin, received, tick=True)
                if case == "separate_stale":
                    phone_scenario_at(origin, 235)
                    phone_state("p2", "present", origin + 235)
                    phone_scenario_at(origin, 235, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                eligible = case == "fresh_valid"
                check(command("{ ReadingsVal('door','state','') }") == ("lock unlocked" if eligible else "untouched")
                      and command("{ ReadingsVal('garage','state','') }") == ("on" if eligible else "untouched"),
                      "the first relevant presence determines permission: " + case)
                check(not state.get("trip") and not state.get("arrival")
                      and json.loads(command("{ ReadingsVal('Geo.Test','gp_trip_checkpoint','{}') }"))["status"] == "none",
                      "the old trip is consumed or revoked")
                check(command("{ ReadingsTimestamp('p1','presence','') }") == source_time,
                      "source observation time stays unchanged")
                if eligible:
                    actor_reading("feedback", "pulse_state", "confirmed")
                    actor_reading("upper", "state", "closed")
                    actor_reading("lower", "state", "open")
                    actor_reading("gate", "state", "on")
                    phone_scenario_at(origin, 231, tick=True)
                else:
                    phone_scenario_at(origin, 300)
                    request("Home", 1, motion="walking")
                    phone_scenario_at(origin, 303, tick=True)
                    phone_scenario_at(origin, 364, tick=True)
                    check(command("{ ReadingsVal('door','state','') }") == "untouched"
                          and command("{ ReadingsVal('garage','state','') }") == "untouched",
                          "later Home cannot reuse the invalid old permission")

            for phone_qualified in (False, True):
                origin = begin_phone_scenario()
                phone_scenario_at(origin, 50)
                for sensor in ("p1", "p2"):
                    phone_state(sensor, "absent", origin + 50)
                phone_scenario_at(origin, 50, tick=True)
                phone_scenario_at(origin, 80)
                request("Home", 0)
                phone_scenario_at(origin, 80, tick=True)
                phone_scenario_at(origin, 82, tick=True)
                phone_scenario_at(origin, 85, tick=True)
                if phone_qualified:
                    phone_scenario_at(origin, 265, tick=True)
                else:
                    phone_scenario_at(origin, 100)
                    request("Outer", 0)
                    phone_scenario_at(origin, 100, tick=True)
                    phone_scenario_at(origin, 102, tick=True)
                returned = 300 if phone_qualified else 200
                phone_scenario_at(origin, returned)
                phone_state("p1", "present", origin + returned)
                phone_scenario_at(origin, returned, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state["phase"] == "home" and not state.get("trip") and state.get("last_trip"),
                      "the first trip completed before the later status cycle")
                old_bounds = {key: state["last_trip"][key] for key in ("id", "away_time", "away_mono")}
                check(bool(state["last_trip"].get("phone_qualification")) == phone_qualified,
                      "covers independent Geo and phone-qualified completed trips")
                actor_reading("feedback", "pulse_state", "confirmed")
                if not phone_qualified:
                    actor_reading("gate", "state", "on")
                    actor_reading("upper", "state", "closed")
                    actor_reading("lower", "state", "open")
                phone_scenario_at(origin, returned + 1, tick=True)
                command("set door untouched")
                command("set garage untouched")
                phone_scenario_at(origin, returned + 70)
                for sensor in ("p1", "p2"):
                    phone_state(sensor, "absent", origin + returned + 70)
                phone_scenario_at(origin, returned + 70, tick=True)
                phone_scenario_at(origin, returned + 220)
                request("R05Near", 1)
                phone_scenario_at(origin, returned + 222, tick=True)
                phone_scenario_at(origin, returned + 250, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state["phase"] == "away" and not state.get("trip")
                      and state["position_time"] == origin + returned + 220
                      and command("{ ReadingsVal('rr_Test','state','') }") == "absent",
                      "later absence kept the newer nearby position without a new trip")
                phone_scenario_at(origin, returned + 255)
                phone_state("p1", "present", origin + returned + 190)
                phone_state("p2", "present", origin + returned + 255)
                source_times = command("{ join('|',map { ReadingsTimestamp($_,'presence','') } qw(p1 p2)) }")
                phone_scenario_at(origin, returned + 255, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state["phone"]["state"] == "present" and state["phase"] == "home"
                      and state["position_time"] == origin + returned + 255
                      and command("{ ReadingsVal('rr_Test','state','') }") == "home",
                      "current presence updates both statuses despite the completed trip")
                check({key: state["last_trip"][key] for key in old_bounds} == old_bounds,
                      "status does not renew completed departure bounds")
                for seconds in (returned + 260, returned + 440):
                    phone_scenario_at(origin, seconds, tick=True)
                    check(command("{ ReadingsVal('Geo.Test','gp_phase','') }") == "home"
                          and command("{ ReadingsVal('rr_Test','state','') }") == "home",
                          "unchanged positive sources retain both home statuses")
                check(command("{ join('|',map { ReadingsTimestamp($_,'presence','') } qw(p1 p2)) }") == source_times,
                      "polling retains original source dates")
                check(not state.get("trip") and not state.get("arrival")
                      and command("{ ReadingsVal('door','state','') }") == "untouched"
                      and command("{ ReadingsVal('garage','state','') }") == "untouched",
                      "later presence creates no new opening")

            origin = begin_phone_scenario()
            phone_scenario_at(origin, 50)
            for sensor in ("p1", "p2"):
                phone_state(sensor, "absent", origin + 50)
            source_times = command("{ join('|',map { ReadingsTimestamp($_,'presence','') } qw(p1 p2)) }")
            phone_scenario_at(origin, 50, tick=True)
            phone_scenario_at(origin, 100)
            request("Home", 0)
            phone_scenario_at(origin, 100, tick=True)
            phone_scenario_at(origin, 102, tick=True)
            phone_scenario_at(origin, 105, tick=True)
            phone_scenario_at(origin, 120)
            request("R05Near", 1)
            phone_scenario_at(origin, 122, tick=True)
            phone_scenario_at(origin, 285, tick=True)
            state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(state["trip"]["armed"] and state["trip"]["scope"] == "local", "nearby position did not block the completed held absence")
            check(command("{ join('|',map { ReadingsTimestamp($_,'presence','') } qw(p1 p2)) }") == source_times,
                  "confirms absence without refreshing either sensor")
            phone_scenario_at(origin, 300)
            request("Home", 1, motion="walking")
            phone_scenario_at(origin, 303, tick=True)
            phone_scenario_at(origin, 361, tick=True)
            check(command("{ ReadingsVal('door','state','') }") == "lock unlocked"
                  and command("{ ReadingsVal('garage','state','') }") == "untouched",
                  "legitimate local return opens only the dummy door")
            actor_reading("feedback", "pulse_state", "confirmed")
            phone_scenario_at(origin, 362, tick=True)

            command("{ $defs{$_}{INTERVAL_NORMAL}=120 for qw(p1 p2);; return 'long measurement interval' }")
            for case in ("same_batch", "separate_batch", "after_deadline_before_poll"):
                origin = begin_phone_scenario("measurement")
                phone_scenario_at(origin, 100)
                request("Home", 0)
                phone_scenario_at(origin, 100, tick=True)
                phone_scenario_at(origin, 102, tick=True)
                phone_scenario_at(origin, 105)
                for sensor in ("p1", "p2"):
                    phone_state(sensor, "absent", origin + 105)
                phone_scenario_at(origin, 105, tick=True)
                phone_scenario_at(origin, 300)
                phone_state("p1", "absent", origin + 300)
                phone_scenario_at(origin, 300, tick=True)
                phone_scenario_at(origin, 309)
                if case == "same_batch":
                    request("Home", 1, motion="walking", observed=origin + 305)
                phone_scenario_at(origin, 310)
                phone_state("p2", "absent", origin + 310)
                if case != "after_deadline_before_poll":
                    phone_scenario_at(origin, 310, tick=True)
                if case != "same_batch":
                    phone_scenario_at(origin, 315)
                    request("Home", 1, motion="walking", observed=origin + (305 if case == "separate_batch" else 315))
                phone_scenario_at(origin, 311 if case == "same_batch" else 317, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(bool(state.get("arrival")) == (case == "after_deadline_before_poll"),
                      "applies the same completion bound: " + case)
                phone_scenario_at(origin, 378, tick=True)
                check(command("{ ReadingsVal('door','state','') }") == ("lock unlocked" if case == "after_deadline_before_poll" else "untouched")
                      and command("{ ReadingsVal('garage','state','') }") == "untouched",
                      "only a genuinely later return opens: " + case)
                if case == "after_deadline_before_poll":
                    actor_reading("feedback", "pulse_state", "confirmed")
                    phone_scenario_at(origin, 379, tick=True)

            for staggered in (False, True):
                interval = 120 if staggered else 7
                command(f"{{ $defs{{$_}}{{INTERVAL_NORMAL}}={interval} for qw(p1 p2);; return 'review sample interval' }}")
                origin = begin_phone_scenario("measurement", poll=7)
                base_mono = float(command("{ GP_Mono() }"))
                phone_scenario_at(origin, 98, tick=True)
                phone_scenario_at(origin, 100)
                request("Home", 0)
                phone_scenario_at(origin, 100, tick=True)
                phone_scenario_at(origin, 102, tick=True)
                phone_scenario_at(origin, 105)
                for sensor in ("p1", "p2"):
                    phone_state(sensor, "absent", origin + 105)
                phone_scenario_at(origin, 105, tick=True)
                for seconds in range(112, 281, 7):
                    phone_scenario_at(origin, seconds)
                    phone_state("p1", "absent", origin + seconds)
                    if not staggered or seconds == 280:
                        phone_state("p2", "absent", origin + seconds)
                    if not staggered or seconds != 280:
                        phone_scenario_at(origin, seconds, tick=True)
                phone_scenario_at(origin, 286)
                request("Home", 1, motion="walking")
                phone_scenario_at(origin, 287)
                phone_state("p1", "absent", origin + 287)
                if not staggered:
                    phone_state("p2", "absent", origin + 287)
                source_times = command("{ join('|',map { ReadingsTimestamp($_,'presence','') } qw(p1 p2)) }")
                phone_scenario_at(origin, 287, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                completion = next(event for event in state["queued_phones"] if event["kind"] == "phone_absent")
                check(completion["qualified_at"] == origin + 285
                      and abs(completion["qualified_mono"] - base_mono - 285) < 1e-6,
                      "extra measurements preserve both completion bounds")
                phone_scenario_at(origin, 288, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state.get("arrival"), "return after the actual deadline starts its normal wait")
                check(command("{ join('|',map { ReadingsTimestamp($_,'presence','') } qw(p1 p2)) }") == source_times,
                      "polling leaves source timestamps unchanged")
                phone_scenario_at(origin, 347, tick=True)
                check(command("{ ReadingsVal('door','state','') }") == "lock unlocked"
                      and command("{ ReadingsVal('garage','state','') }") == "untouched",
                      "valid return opens only the dummy door")
                actor_reading("feedback", "pulse_state", "confirmed")
                phone_scenario_at(origin, 348, tick=True)

            check(command("set GP mode debug") == "", "prepare status profile")
            check(command("attr Geo.Test sourceMode phone_only") == "", "uses phone-only status without Geo events")
            command("{ $defs{$_}{INTERVAL_NORMAL}=120 for qw(p1 p2);; return 'review source interval' }")
            for signal in ("state", "measurement"):
                origin = begin_phone_scenario(signal)
                phone_scenario_at(origin, 50)
                for sensor in ("p1", "p2"):
                    phone_state(sensor, "absent", origin + 50)
                phone_scenario_at(origin, 50, tick=True)
                if signal == "measurement":
                    phone_scenario_at(origin, 100)
                    for sensor in ("p1", "p2"):
                        phone_state(sensor, "absent", origin + 100)
                    phone_scenario_at(origin, 100, tick=True)
                phone_scenario_at(origin, 225, tick=True)
                phone_scenario_at(origin, 230, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state["phase"] == "away" and not state.get("trip") and not state.get("last_trip")
                      and command("{ ReadingsVal('rr_Test','state','') }") == "absent",
                      "full absence interval sets both statuses absent without a trip")
                phone_scenario_at(origin, 235)
                phone_state("p1", "present", origin + 120)
                phone_state("p2", "present", origin + 235)
                source_times = command("{ join('|',map { ReadingsTimestamp($_,'presence','') } qw(p1 p2)) }")
                phone_scenario_at(origin, 235, tick=True)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state["phone"]["state"] == "present" and state["phase"] == "home"
                      and command("{ ReadingsVal('rr_Test','state','') }") == "home",
                      "fresh simultaneous presence sets phone, GeoPresence and ROOMMATE home: " + signal)
                for seconds in (240, 420):
                    phone_scenario_at(origin, seconds, tick=True)
                    state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                    check(state["phase"] == "home" and command("{ ReadingsVal('rr_Test','state','') }") == "home",
                          "status remains home without another detector message")
                check(command("{ join('|',map { ReadingsTimestamp($_,'presence','') } qw(p1 p2)) }") == source_times,
                      "source dates remain unchanged")
                check(not state.get("trip") and not state.get("last_trip") and not state.get("arrival")
                      and command("{ ReadingsVal('door','state','') }") == "untouched"
                      and command("{ ReadingsVal('garage','state','') }") == "untouched",
                      "status creates no opening permission or actor output")

            command("{ no warnings 'redefine';; $main::GP_fixture_offset=GP_Now()-Time::HiRes::time();; "
                    "*GP_Now=sub { Time::HiRes::time()+$main::GP_fixture_offset };; "
                    "*GP_Mono=sub { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())+$main::GP_fixture_offset };; return 'normal fixture clock' }")
            for sensor, interval in saved_intervals.items():
                command("{ " + (f"delete $defs{{{sensor}}}{{INTERVAL_NORMAL}}" if interval is None
                                else f"$defs{{{sensor}}}{{INTERVAL_NORMAL}}={int(interval)}") + ";; return 'sensor interval restored' }")
            for text in ("set GP mode debug", "delete Z.R05Near", "attr Geo.Test phoneSignalMode state",
                         "attr Geo.Test sourceMode geofency_phone",
                         "deleteattr GP phone_absence_window", "deleteattr GP reorder_window",
                         "deleteattr GP phone_poll", "set GP mode active"):
                check(command(text) == "", "restore the original phone-source fixture: " + text)
            del zones["R05Near"]
            advance(1)

            # a valid held return can revoke an old trip even when
            # its reading was not processed within the action freshness budget.
            for pending_home in (False, True):
                command("{ GP_ResetController($defs{GP});; return 'reset' }")
                advance(40)
                phone_state("p1", "absent")
                phone_state("p2", "absent")
                advance(5)
                advance(180)
                check(request("Work", 0)[0] == 200, "accepts independent departure evidence")
                advance(3)
                advance(90)
                command("set door untouched")
                command("set garage untouched")
                if pending_home:
                    check(request("Home", 1, motion="walking")[0] == 200, "accepts a provisional Home return")
                    advance(3)
                    check(json.loads(command("get GP explain Geo.Test prod format=json"))["state"].get("arrival"),
                          "Home return is waiting before delayed phone processing")
                phone_state("p1", "present")
                observed = command("{ ReadingsTimestamp('p1','presence','') }")
                advance(100)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state["phone"]["state"] == "present" and state["phone"]["health"] == "held",
                      "still accepts the healthy held positive source")
                check(not state.get("trip") and not state.get("arrival"), "revokes trip and pending return despite the old observation")
                check(json.loads(command("{ ReadingsVal('Geo.Test','gp_trip_checkpoint','{}') }"))["status"] == "none",
                      "revoked trip cannot resume")
                check(command("{ ReadingsTimestamp('p1','presence','') }") == observed,
                      "did not manufacture a fresh positive reading")
                check(request("Home", 1, motion="automotive")[0] == 200, "accepts a subsequent fresh Home entry")
                advance(3)
                advance(61)
                check(command("{ ReadingsVal('door','state','') }") == "untouched"
                      and command("{ ReadingsVal('garage','state','') }") == "untouched",
                      "neither delayed presence nor a later Home entry reuses the old permission")

            # unchanged negatives observed before Home exit still
            # supply a new complete interval, never their previous qualification.
            command("{ GP_ResetController($defs{GP});; return 'reset' }")
            advance(40)
            phone_state("p1", "absent")
            phone_state("p2", "absent")
            advance(5)
            source_times = command("{ join('|',map { ReadingsTimestamp($_,'presence','') } qw(p1 p2)) }")
            advance(10)
            command("set door untouched")
            command("set garage untouched")
            check(request("Home", 0)[0] == 200, "accepts Home exit after the phones became absent")
            advance(3)
            advance(5)
            state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(state["phone"].get("negative_since") is not None and not state["trip"]["armed"],
                  "starts a new unqualified interval using unchanged negative states")
            advance(170)
            check(not json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["trip"]["armed"],
                  "cannot reuse elapsed time from before Home exit")
            advance(11)
            state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(state["trip"]["armed"] and state["trip"]["scope"] == "local", "full new interval confirms a local walk")
            check(command("{ join('|',map { ReadingsTimestamp($_,'presence','') } qw(p1 p2)) }") == source_times,
                  "neither sensor needed another negative message or a refreshed timestamp")
            refresh_actor_contacts()
            check(request("Home", 1, motion="walking")[0] == 200, "accepts the new walking return")
            advance(3)
            advance(58)
            check(command("{ ReadingsVal('door','state','') }") == "lock unlocked"
                  and command("{ ReadingsVal('garage','state','') }") == "untouched",
                  "a qualified local walk opens only the dummy door")
            actor_reading("feedback", "pulse_state", "confirmed")
            advance(1)

            command("{ GP_ResetController($defs{GP});; return 'reset' }")
            advance(40)
            phone_state("p1", "absent")
            phone_state("p2", "absent")
            advance(5)
            command("set door untouched")
            command("set garage untouched")
            request("Home", 0)
            advance(3)
            advance(5)
            advance(100)
            check(request("Home", 1, motion="walking")[0] == 200, "accepts Home return before absence is qualified")
            advance(81)
            state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
            check(not state.get("trip") and not state.get("arrival"), "orders Home return before a later completed absence")
            advance(61)
            check(command("{ ReadingsVal('door','state','') }") == "untouched"
                  and command("{ ReadingsVal('garage','state','') }") == "untouched",
                  "waiting cannot retroactively authorize the premature Home return")

            # Real departures with lagging indoor presence (19/20 September),
            # including negatives already qualifying before the outer webhook.
            for label, outbound, away, early_negative, motion in (
                    ("19 September", 360, 19800, False, "automotive"),
                    ("20 September", 444, 4800, False, "automotive"),
                    ("negative handover", 60, 200, True, "walking")):
                command("{ GP_ResetController($defs{GP});; return 'reset' }")
                advance(40)
                command("set door untouched")
                command("set garage untouched")
                phone_state("p1", "present")
                phone_state("p2", "absent")
                advance(5)
                log_path = root / json.loads(command("get GP logStatus format=json"))["file"]
                log_start = len(log_path.read_text())
                check(request("Home", 0)[0] == 200, f"{label}: Home departure accepted")
                advance(3)
                evidence = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                home_exit = evidence["trip"]["home_exit"]
                if early_negative:
                    phone_state("p1", "absent")
                    advance(5)
                    negative_since = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["phone"]["negative_since"]
                advance(outbound)
                check(request("Outer", 0, motion="automotive")[0] == 200, f"{label}: outer departure accepted for evaluation")
                advance(3)
                evidence = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(evidence.get("trip", {}).get("home_exit") == home_exit and
                      evidence["trip"]["scope"] == "local" and not evidence["trip"]["armed"],
                      f"{label}: rejected outer event preserves only the unarmed Home exit")
                check(evidence["position_time"] == home_exit, f"{label}: rejected event does not supersede phone negatives")
                if early_negative:
                    check(evidence["phone"].get("negative_since") == negative_since,
                          "outer rejection preserves the running negative qualification")
                else:
                    phone_state("p1", "absent")
                    advance(5)
                advance(180)
                evidence = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(evidence.get("trip", {}).get("armed") and evidence["trip"]["scope"] == "local",
                      f"{label}: unchanged negative readings qualify local departure")
                check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "absent",
                      f"{label}: real ROOMMATE is absent after qualification")
                advance(away)
                request("Outer", 1)
                advance(3)
                advance(260)
                refresh_actor_contacts()
                check(request("Home", 1, motion=motion)[0] == 200, f"{label}: real Home return accepted")
                advance(3)
                evidence = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                wait = 10 if motion == "automotive" else 60
                check(evidence.get("arrival", {}).get("wait") == wait and evidence["phase"] == "returning",
                      f"{label}: appropriate arrival timer starts")
                check(command("{ ReadingsVal('door','state','unknown') }") == "untouched" and
                      command("{ ReadingsVal('garage','state','unknown') }") == "untouched",
                      f"{label}: neither actor opens before confirmation")
                advance(wait - 2)
                check(command("{ ReadingsVal('door','state','unknown') }") == "lock unlocked" and
                      command("{ ReadingsVal('garage','state','unknown') }") == ("on" if motion == "automotive" else "untouched"),
                      f"{label}: confirmation opens only the authorized dummy actors")
                diagnostic = log_path.read_text()[log_start:]
                rows = [json.loads(line[line.index("{"):]) for line in diagnostic.splitlines() if "{" in line]
                check(any(row.get("reason") == "departure rejected; pending Home exit retained" and
                          row.get("phone_health") == ("handover" if early_negative else "held") for row in rows),
                      f"{label}: diagnostic explains retained Home exit and local presence")
                check(any(row.get("reason") == "phone absence qualified" and row.get("departure_armed") == "1" for row in rows),
                      f"{label}: diagnostic distinguishes status-only absence from opening permission")
                actor_reading("feedback", "pulse_state", "confirmed")
                if motion == "automotive":
                    actor_reading("gate", "state", "on")
                    actor_reading("upper", "state", "closed")
                    actor_reading("lower", "state", "open")
                advance(1)
            # A changed Home circle on departure (26 September) must revoke old
            # permission, but retain a new suspicion and requalify phone absence.
            for same_batch in (True, False):
                command("{ GP_ResetController($defs{GP});; return 'reset' }")
                advance(40)
                phone_state("p1", "absent")
                phone_state("p2", "absent")
                advance(5)
                advance(180)
                check(json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["phone"]["qualified"],
                      "pre-change phone absence qualified")
                log_path = root / json.loads(command("get GP logStatus format=json"))["file"]
                log_start = len(log_path.read_text())
                command("set door untouched")
                command("set garage untouched")
                old_radius = zones["Home"][2]
                zones["Home"] = ("home", 0, old_radius + 25)
                changed_exit = event_body("Home", 0)
                check(http_request("POST", "/fhem/geopresence", changed_exit, auth_headers())[0] == 200,
                      "geometry-changing departure accepted")
                advance(3)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state.get("trip", {}).get("home_exit") and not state["trip"]["armed"]
                      and state["trip"]["scope"] == "local" and not state["phone"].get("qualified"),
                      "changed Home exit starts only a new unarmed local trip")
                phone_state("p1", "absent")
                phone_state("p2", "absent")
                advance(5)
                negative_start = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["phone"]["negative_since"]
                advance(5)
                http_request("POST", "/fhem/geopresence", changed_exit, auth_headers())
                advance(3)
                check(json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["phone"]["negative_since"] == negative_start,
                      "departure retry does not restart new phone qualification")
                advance(165)
                check(not json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["trip"]["armed"],
                      "new absence window must complete before permission is granted")
                advance(10)
                check(json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["trip"]["armed"],
                      "unchanged post-change negatives qualify after a full new window")
                advance(90)
                home = event_body("Home", 1)
                http_request("POST", "/fhem/geopresence", home, auth_headers())
                advance(1 if same_batch else 3)
                http_request("POST", "/fhem/geopresence", home + "&motion=walking", auth_headers())
                advance(3)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state["arrival"]["motion"] == "walking" and state["arrival"]["wait"] == 60,
                      "duplicate fills walking before confirmation; same_batch=" + str(same_batch))
                check(command("{ ReadingsVal('door','state','unknown') }") == "untouched",
                      "enrichment cannot issue an immediate door command")
                refresh_actor_contacts()
                advance(57)
                check(command("{ ReadingsVal('door','state','unknown') }") == "lock unlocked"
                      and command("{ ReadingsVal('garage','state','unknown') }") == "untouched",
                      "return after circle change opens only the dummy door")
                actor_reading("feedback", "pulse_state", "confirmed")
                advance(1)
                http_request("POST", "/fhem/geopresence", home + "&motion=walking", auth_headers())
                advance(3)
                rows = [json.loads(line[line.index("{"):]) for line in log_path.read_text()[log_start:].splitlines() if "{" in line]
                check(sum(row.get("reason") == "actor command dispatched" and row.get("kind") == "door_open" for row in rows) == 1,
                      "diagnostic proves one door request despite duplicates")
                check(any(row.get("zone") == "Z.Home" and row.get("geometry_changes") == f"radius: {old_radius} -> {old_radius + 25}"
                          for row in rows), "diagnostic attributes geometry values to Home")
            # an accepted Home entry keeps its arrival identity after a
            # newer empty entry. Its late walking data must still veto garage.
            for phone_return in (False, True):
                command("{ GP_ResetController($defs{GP});; return 'reset' }")
                advance(40)
                phone_state("p1", "absent")
                phone_state("p2", "absent")
                advance(5)
                check(request("Outer", 0)[0] == 200, "remote departure accepted")
                advance(3)
                advance(90)
                refresh_actor_contacts()
                command("set door untouched")
                command("set garage untouched")
                log_path = root / json.loads(command("get GP logStatus format=json"))["file"]
                log_start = len(log_path.read_text())
                home = event_body("Home", 1)
                check(http_request("POST", "/fhem/geopresence", home, auth_headers())[0] == 200,
                      "original empty Home entry accepted")
                advance(3)
                first = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["arrival"]
                check(first["vehicle_eligible"], "initially has the remote vehicle fallback")
                advance(2)
                check(request("Home", 1)[0] == 200, "newer empty Home entry accepted")
                advance(3)
                latest = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["arrival"]["latest_home"]
                check(latest["time"] > first["event"]["time"], "position advanced during the same arrival")
                advance(1)
                check(http_request("POST", "/fhem/geopresence", home + "&motion=walking", auth_headers())[0] == 200,
                      "older walking supplement accepted")
                if phone_return:
                    phone_state("p1", "present")
                advance(5 if phone_return else 3)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(state["motion"] == "walking" and state["motion_time"] == first["event"]["time"],
                      "walking keeps the original observation time")
                if not phone_return:
                    pending = state["arrival"]
                    check(pending["latest_home"] == latest and state["position_time"] == latest["time"],
                          "supplement does not rewind the newer Home evidence")
                    check(pending["started"] == first["started"] and pending["start_mono"] == first["start_mono"]
                          and pending["due_mono"] == first["due_mono"] and not pending["vehicle_eligible"],
                          "walking changes permission without restarting the original wait")
                    check(command("{ ReadingsVal('door','state','') }") == "untouched",
                          "supplement itself issues no opening")
                    refresh_actor_contacts()
                    advance(max(0, pending["due_mono"] - float(command("{ GP_Mono() }"))) + 0.1)
                check(command("{ ReadingsVal('door','state','') }") == "lock unlocked"
                      and command("{ ReadingsVal('garage','state','') }") == "untouched",
                      "confirms only the door, phone_return=" + str(phone_return))
                actor_reading("feedback", "pulse_state", "confirmed")
                advance(1)
                http_request("POST", "/fhem/geopresence", home + "&motion=walking", auth_headers())
                advance(3)
                rows = [json.loads(line[line.index("{"):]) for line in log_path.read_text()[log_start:].splitlines() if "{" in line]
                check(sum(row.get("reason") == "actor command dispatched" and row.get("kind") == "door_open" for row in rows) == 1
                      and not any(row.get("reason") == "actor command dispatched" and row.get("kind") == "garage_open" for row in rows),
                      "diagnostics prove one door request without any garage request")
            # the accepted approach precedes Home in a separate
            # timer batch, with an equal or older observation timestamp.
            # The preceding installation checks deliberately omitted Drive.
            for text in ("set GP mode debug", "define Z.Drive GeoPresence location Geo.Test approach",
                         "attr Z.Drive zoneId Drive", "set GP mode active"):
                check(command(text) == "", "prepares the optional approach: " + text)
            advance(40)
            check(request("Drive", 1)[0] == 200, "initializes productive approach geometry")
            advance(3)
            for same_time in (True, False):
                for phone_return in (False, True):
                    command("{ GP_ResetController($defs{GP});; return 'reset' }")
                    advance(40)
                    phone_state("p1", "absent")
                    phone_state("p2", "absent")
                    advance(5)
                    advance(180)
                    check(request("Outer", 0)[0] == 200, "remote departure accepted")
                    advance(3)
                    advance(90)
                    departure = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                    check(departure["trip"]["armed"], "departure is qualified before the approach")
                    refresh_actor_contacts()
                    command("set door untouched")
                    command("set garage untouched")
                    approach = event_body("Drive", 1)
                    check(http_request("POST", "/fhem/geopresence", approach, auth_headers())[0] == 200,
                          "empty approach accepted")
                    advance(3)
                    state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                    observed = state["zones"]["Z.Drive"]["time"]
                    check(state["phase"] == "returning" and not state.get("arrival"),
                          "approach alone starts no Home wait")
                    home_fields = dict(urllib.parse.parse_qsl(event_body("Home", 1)))
                    if same_time:
                        home_fields["date"] = dict(urllib.parse.parse_qsl(approach))["date"]
                    check(http_request("POST", "/fhem/geopresence", urllib.parse.urlencode(home_fields), auth_headers())[0] == 200,
                          "subsequent empty Home accepted")
                    advance(3)
                    first = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["arrival"]
                    check(first["vehicle_eligible"] and (first["event"]["time"] == observed if same_time
                                                       else first["event"]["time"] > observed),
                          "reproduces the remote fallback and observation order")
                    advance(1)
                    check(http_request("POST", "/fhem/geopresence", approach + "&motion=walking", auth_headers())[0] == 200,
                          "original approach walking supplement accepted")
                    if phone_return:
                        phone_state("p1", "present")
                    advance(5 if phone_return else 3)
                    state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                    check(state["motion"] == "walking" and state["motion_time"] == observed,
                          "walking retains the original approach time")
                    if not phone_return:
                        pending = state["arrival"]
                        check(pending["event"] == first["event"] and not pending["vehicle_eligible"]
                              and pending["start_mono"] == first["start_mono"] and pending["due_mono"] == first["due_mono"],
                              "changes garage permission without changing Home evidence or its wait")
                        refresh_actor_contacts()
                        advance(max(0, pending["due_mono"] - float(command("{ GP_Mono() }"))) + 0.1)
                    check(command("{ ReadingsVal('door','state','') }") == "lock unlocked"
                          and command("{ ReadingsVal('garage','state','') }") == "untouched",
                          f"opens only the door; same_time={same_time} phone_return={phone_return}")
                    actor_reading("feedback", "pulse_state", "confirmed")
                    advance(1)
            # a nearby place advances position without ending the
            # approach. A delayed exit between that approach and Home must
            # revoke its automotive origin, whether received before or after Home.
            zones["Near"] = ("place", 0.0009, 20)
            for text in ("set GP mode debug", "define Z.Near GeoPresence location Geo.Test place",
                         "attr Z.Near zoneId Near", "set GP mode active"):
                check(command(text) == "", "prepares a nearby place: " + text)
            advance(40)
            check(request("Near", 1)[0] == 200, "initializes nearby place geometry")
            advance(3)
            for after_home in (False, True):
                command("{ GP_ResetController($defs{GP});; return 'reset' }")
                advance(40)
                phone_state("p1", "absent")
                phone_state("p2", "absent")
                advance(5)
                advance(180)
                check(request("Drive", 0)[0] == 200, "local departure accepted")
                advance(3)
                advance(90)
                departure = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                check(departure["trip"]["armed"] and departure["trip"]["scope"] == "local",
                      "has no remote vehicle fallback")
                refresh_actor_contacts()
                command("set door untouched")
                command("set garage untouched")
                approach = event_body("Drive", 1)
                check(http_request("POST", "/fhem/geopresence", approach, auth_headers())[0] == 200,
                      "empty approach accepted")
                advance(3)
                observed = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["zones"]["Z.Drive"]["time"]
                advance(17)
                check(request("Near", 1)[0] == 200, "newer nearby observation accepted")
                advance(3)
                position = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["position_time"]
                exit_fields = dict(urllib.parse.parse_qsl(event_body("Drive", 0)))
                exit_fields["date"] = datetime.datetime.fromtimestamp(observed + 10, datetime.timezone.utc).isoformat()
                delayed_exit = urllib.parse.urlencode(exit_fields)
                if not after_home:
                    check(http_request("POST", "/fhem/geopresence", delayed_exit, auth_headers())[0] == 200,
                          "delayed exit accepted before Home")
                    advance(3)
                    state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                    check(not state.get("approach") and state["position_time"] == position,
                          "late exit removes the approach without rewinding position")
                advance(7 if after_home else 4)
                check(request("Home", 1)[0] == 200, "later Home entry accepted")
                advance(3)
                first = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["arrival"]
                if after_home:
                    advance(2)
                    check(request("Home", 1)[0] == 200, "newer Home entry accepted")
                    advance(3)
                    latest = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["arrival"]["latest_home"]
                    check(http_request("POST", "/fhem/geopresence", delayed_exit, auth_headers())[0] == 200,
                          "delayed exit accepted after Home")
                    advance(3)
                    pending = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["arrival"]
                    check(pending["event"] == first["event"] and pending["latest_home"] == latest
                          and pending["start_mono"] == first["start_mono"] and pending["due_mono"] == first["due_mono"],
                          "exit before Home preserves its original wait and newest evidence")
                advance(1 if after_home else 7)
                check(http_request("POST", "/fhem/geopresence", approach + "&motion=automotive", auth_headers())[0] == 200,
                      "interrupted automotive supplement received")
                advance(3)
                pending = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["arrival"]
                check(not pending["vehicle_eligible"] and pending["motion"] == "unknown",
                      "interrupted approach cannot qualify the garage")
                refresh_actor_contacts()
                advance(max(0, pending["due_mono"] - float(command("{ GP_Mono() }"))) + 0.1)
                check(command("{ ReadingsVal('door','state','') }") == "lock unlocked"
                      and command("{ ReadingsVal('garage','state','') }") == "untouched",
                      "confirms only the door; exit received after_home=" + str(after_home))
                actor_reading("feedback", "pulse_state", "confirmed")
                advance(1)
            # revoking a pre-Home origin must not age the latched
            # Home walking veto into the remote fallback. Also remove a real
            # earlier automotive proof while preserving the later foot veto.
            for text in ("set GP mode debug", "attr GP motion_max_age 20", "set GP mode active"):
                check(command(text) == "", "configures the supported short TTL: " + text)
            for prior_auto, phone_return in ((False, False), (False, True), (True, False)):
                command("{ GP_ResetController($defs{GP});; return 'reset' }")
                advance(40)
                phone_state("p1", "absent")
                phone_state("p2", "absent")
                advance(5)
                advance(180)
                check(request("Outer", 0)[0] == 200, "remote departure accepted")
                advance(3)
                advance(90)
                refresh_actor_contacts()
                command("set door untouched")
                command("set garage untouched")
                approach = event_body("Drive", 1, motion="automotive" if prior_auto else None)
                check(http_request("POST", "/fhem/geopresence", approach, auth_headers())[0] == 200,
                      "approach accepted")
                advance(3)
                observed = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["zones"]["Z.Drive"]["time"]
                advance(7)
                check(request("Home", 1, motion="walking")[0] == 200, "fresh Home walking accepted")
                advance(3)
                first = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["arrival"]
                check(bool(first["vehicle_eligible"]) == prior_auto and first["motion"] == "walking",
                      "initial decision distinguishes preceding automotive from the remote fallback")
                advance(27)
                exit_fields = dict(urllib.parse.parse_qsl(event_body("Drive", 0)))
                exit_fields["date"] = datetime.datetime.fromtimestamp(observed + 5, datetime.timezone.utc).isoformat()
                check(http_request("POST", "/fhem/geopresence", urllib.parse.urlencode(exit_fields), auth_headers())[0] == 200,
                      "pre-Home exit received after the motion TTL")
                advance(3)
                state = json.loads(command("get GP explain Geo.Test prod format=json"))["state"]
                pending = state["arrival"]
                check(float(command("{ GP_Now() }")) - state["motion_time"] > 20,
                      "surviving Home walking has aged beyond its TTL")
                check(not pending["vehicle_eligible"] and pending["motion"] == "walking",
                      "retains or recovers the accepted foot veto after revoking older evidence")
                check(pending["event"] == first["event"] and pending["start_mono"] == first["start_mono"]
                      and pending["due_mono"] == first["due_mono"] and pending["origin_time"] == first["event"]["time"],
                      "preserves Home evidence and its deadline while revoking approach origins")
                refresh_actor_contacts()
                if phone_return:
                    advance(1)
                    phone_state("p1", "present")
                    advance(5)
                else:
                    advance(max(0, pending["due_mono"] - float(command("{ GP_Mono() }"))) + 0.1)
                check(command("{ ReadingsVal('door','state','') }") == "lock unlocked"
                      and command("{ ReadingsVal('garage','state','') }") == "untouched",
                      f"confirms only the door; prior_auto={prior_auto} phone_return={phone_return}")
                actor_reading("feedback", "pulse_state", "confirmed")
                advance(1)
            for text in ("set GP mode debug", "deleteattr GP motion_max_age"):
                check(command(text) == "", "restores default motion validity: " + text)
            check(command("delete Z.Near") == "", "removes its nearby fixture location")
            del zones["Near"]
            check(command("delete Z.Drive") == "", "approach regressions restore the fixture without an approach")
            # Geo-only production: real HTTP, timer and ROOMMATE, dummy actors.
            old_sources = command("{ AttrVal('Geo.Test','phoneProxies','') }")
            old_signal = command("{ AttrVal('Geo.Test','phoneSignalMode','state') }")
            for text in ("deleteattr Geo.Test phoneProxies", "deleteattr Geo.Test phoneSignalMode",
                         "attr Geo.Test sourceMode geofency_only", "set Geo.Test mode active", "set GP mode active"):
                check(command(text) == "", "geo-only profile transition: " + text)
            advance(40)
            command("set door untouched")
            command("set garage untouched")
            check(request("Home", 0)[0] == 200, "geo-only accepts authenticated departure")
            advance(3)
            advance(200)
            view = json.loads(command("get GP explain Geo.Test prod format=json"))
            check(view["state"]["phase"] == "away" and not view["state"]["trip"]["armed"],
                  "geo-only Home exit and long pause synchronize absence without permission")
            check(command("{ ReadingsVal('Geo.Test','gp_phone_state','') }") == "disabled",
                  "production phone reading explicitly disabled")
            phone_state("p1", "present")
            advance(5)
            check(command("{ ReadingsVal('rr_Test','state','unknown') }") == "absent",
                  "real positive PRESENCE event cannot arrive in geo-only")
            request("Home", 1, motion="automotive")
            advance(15)
            check(command("{ ReadingsVal('door','state','') }") == "untouched" and
                  command("{ ReadingsVal('garage','state','') }") == "untouched",
                  "automotive and elapsed time cannot replace distance evidence")
            request("Outer", 0)
            advance(3)
            advance(70)
            refresh_actor_contacts()
            request("Home", 1, motion="automotive")
            advance(3)
            check(json.loads(command("get GP explain Geo.Test prod format=json"))["state"]["arrival"]["wait"] == 10,
                  "geo-only outer proof starts normal automotive wait")
            advance(8)
            check(command("{ ReadingsVal('door','state','') }") == "lock unlocked" and
                  command("{ ReadingsVal('garage','state','') }") == "on",
                  "geo-only confirmed return opens both dummy actors without phone sources")
            actor_reading("feedback", "pulse_state", "confirmed")
            actor_reading("gate", "state", "on")
            actor_reading("upper", "state", "closed")
            actor_reading("lower", "state", "open")
            advance(1)
            for text in ("set GP mode debug", "attr Geo.Test sourceMode geofency_phone",
                         "attr Geo.Test phoneProxies " + old_sources, "attr Geo.Test phoneSignalMode " + old_signal):
                check(command(text) == "", "restore combined fixture: " + text)
            check(command("set GP mode active") == "", "existing residents remain active during new enrollment")
            command("{ my $s=GP_State($defs{GP},'Geo.Test',0);; $s->{mode_review_marker}='keep';; return 'marked' }")
            neighbour_session = command("{ $defs{GP}{helper}{gp}{epoch} }")
            manual = (repo / "doc/GeoPresence_Handbuch.md").read_text()
            def recipe(section):
                match = re.search(r"^### " + re.escape(section) + r" .*?\n(.*?)(?=^### |^## |\Z)", manual, re.M | re.S)
                check(bool(match), f"manual section {section} exists")
                return re.findall(r"```text\n(.*?)\n```", match.group(1), re.S)

            for definition in ("define Phone.PERSON.RAUM1 PRESENCE event rr_PERSON:FakeAbsent rr_PERSON:FakePresent",
                               "define Phone.PERSON.RAUM2 PRESENCE event rr_PERSON:FakeAbsent rr_PERSON:FakePresent"):
                check(command(definition) == "", "isolated existing phone sources prepared for generic resident recipe")
            for block in recipe("3.1") + recipe("3.2"):
                if "sourceMode geofency_only" in block:
                    continue
                for line in block.splitlines():
                    line = line.replace("System.GeoPresence", "GP")
                    line = line.replace("__ZUFALLSKENNWORT__", password)
                    result = command(line)
                    check("stored" in result if "webhookPassword" in line else result == "",
                          "generic resident recipe command accepted")

            def person_request(zone, entry, *, debug=True, device_id="person-device", credential=password):
                payload = {"device": device_id, "id": "person-" + zone.lower(), "name": zone,
                           "entry": entry, "latitude": 0, "longitude": 0,
                           "radius": {"Home": 50, "UMGEBUNG": 4500, "ORT": 25}[zone],
                           "date": datetime.datetime.fromtimestamp(float(command("{ GP_Now() }")), datetime.timezone.utc).isoformat()}
                headers = {"Content-Type": "application/x-www-form-urlencoded",
                           "Authorization": "Basic " + base64.b64encode(f"geo_person:{credential}".encode()).decode()}
                if debug:
                    payload["isTest"] = "true"
                return http_request("POST", "/fhem/geopresence", urllib.parse.urlencode(payload), headers)

            check(command("{ AttrVal('Geo.PERSON','deviceId','unset') }") == "unset",
                  "generic recipe needs no manually copied device ID")
            check_resident_status(command, http_request, admin_port, check, "Geo.PERSON", "disabled")
            advance(1)  # Finish the listener restart after the last setup attribute.
            check(person_request("Home", 1)[0] == 503, "new phone cannot enroll without an explicit learning window")
            check(command("set Geo.PERSON mode learning").startswith("Learning for"), "new phone can start without identity or zones")
            check(command("{ $defs{GP}{helper}{gp}{prod}{'Geo.Test'}{mode_review_marker} }") == "keep",
                  "resident creation and learning preserve active neighbour state")
            check(command("{ $defs{GP}{helper}{gp}{epoch} }") == neighbour_session, "local setup does not reset controller session")
            advance(1)
            check("Waiting for first authenticated test webhook" in report("learnedLocations Geo.PERSON"),
                  "FHEMWEB explains the waiting state before the first webhook")
            check(command("{ (exists $defs{GP}{helper}{gp}{prod}{'Geo.PERSON'} || exists $defs{GP}{helper}{gp}{debug}{'Geo.PERSON'}) ? 1 : 0 }") == "0",
                  "real timer does not poll phones or allocate journey state while learning")
            check(person_request("Home", 1, credential="wrong")[0] == 401, "enrollment still requires the resident password")
            check(person_request("Home", 1, debug=False)[0] == 200, "real observation is acknowledged without enrollment during learning")
            check("Waiting for first authenticated test webhook" in report("learnedLocations Geo.PERSON"),
                  "real observation did not capture a phone or location")
            status, _, body = person_request("Home", 1, device_id="TEST-DEVICE")
            check(status == 422 and "already assigned" in body, "existing resident device cannot be claimed by new resident")
            check(person_request("Home", 1)[0] == 200, "first valid webhook pins a candidate")
            check(person_request("Home", 1, device_id="another-phone")[0] == 422, "candidate cannot be replaced by another phone")
            check(command("{ AttrVal('Geo.PERSON','deviceId','unset') }") == "unset", "HTTP capture does not write configuration")
            check("Confirm learning" in command("get GP locationCommands Geo.PERSON @1 home Geo.PERSON.Home"),
                  "location registration must follow confirmation")
            command("set Geo.PERSON mode disabled")
            check("No current learning data" in command("get GP learnedLocations Geo.PERSON"), "cancellation discards unconfirmed phone")
            check(command("{ AttrVal('Geo.PERSON','deviceId','unset') }") == "unset", "cancellation does not bind phone")

            for names, selectors in ((["Home", "UMGEBUNG"], [(1, "home", "Home"), (2, "outer", "UMGEBUNG")]),
                                     (["ORT"], [(1, "place", "ORT")])):
                check(command("set Geo.PERSON mode learning").startswith("Learning for"), "generic resident starts learning")
                advance(1)
                for zone in names:
                    check(person_request(zone, 1)[0] == 200, "generic phone learns location")
                first_phone = names[0] == "Home"
                learned_before = json.loads(command("get GP learnedLocations Geo.PERSON format=json"))
                if first_phone:
                    check("Not configured; confirm with set resident learnConfirm" in report("learnedLocations Geo.PERSON"),
                          "browser shows the candidate and explicit confirmation requirement")
                    check(command("{ AttrVal('Geo.PERSON','deviceId','unset') }") == "unset", "only explicit stop may configure ID")
                    check("Geo.PERSON deviceId" not in command("{ return join('|', @structChangeHist) }"),
                          "capture creates no structural deviceId change")
                result = command("set Geo.PERSON learnConfirm")
                check(result.startswith("Learning confirmed"), "generic learning stops")
                check_resident_status(command, http_request, admin_port, check, "Geo.PERSON", "disabled")
                check(command("{ AttrVal('Geo.PERSON','deviceId','unset') }") == "person-device", "confirmed device attribute set in real FHEM")
                check(json.loads(command("get GP learnedLocations Geo.PERSON format=json")) == learned_before,
                      "FHEM attribute callbacks preserve confirmed capture")
                if first_phone:
                    check("deviceId person-device configured" in result, "first completion describes the configuration change")
                    check("attr Geo.PERSON deviceId person-device" in command("{ return join('|', @structChangeHist) }"),
                          "binding uses standard FHEM unsaved-configuration tracking")
                    check("Geo.PERSON" not in (root / "test.cfg").read_text(), "confirmation does not auto-save the configuration")
                    check(re.search(r"Binding\s+: Configured", command("get GP learnedLocations Geo.PERSON")), "configured identity readable after reset")
                for number, role, zone in selectors:
                    output = command(f"get GP locationCommands Geo.PERSON @{number} {role} Geo.PERSON.{zone}")
                    check(output.startswith("define "), "manual location selection returns definitions")
                    for line in output.splitlines():
                        check(command(line) == "", "returned location definition really executed")
            check(command("{ $defs{GP}{helper}{gp}{prod}{'Geo.Test'}{mode_review_marker} }") == "keep",
                  "confirmed identity and new locations preserve active neighbour")
            for block in recipe("5.1"):
                for line in block.splitlines():
                    if not line.strip():
                        continue
                    result = command(line.replace("System.GeoPresence", "GP"))
                    check(result.startswith("OK:") if line.startswith("get ") else result == "", "manual light recipe accepted")
            for setting in ("attr rr_PERSON alias Jörg", "attr test.dev.licht alias Außenlicht 🌙",
                            "attr Geo.PERSON.ORT label Große Straße"):
                check(command(setting) == "", "Unicode label accepted through actual FHEM input")
            command("set Geo.PERSON mode debug")
            advance(40)
            command("set GP debugReset Geo.PERSON")
            command("set GP debugPhoneMode Geo.PERSON simulated")
            command("set GP debugPhone Geo.PERSON absent")
            for zone in ("Home", "UMGEBUNG", "ORT"):
                check(person_request(zone, 1)[0] == 200, "generic debug geometry synchronized")
                advance(5)
            check(person_request("ORT", 1)[0] == 200, "generic debug zone entry accepted")
            advance(5)
            trace = json.loads(command("get GP debugTrace Geo.PERSON format=json"))
            check(any(row["reason"] == "would execute; debug suppressed" and row.get("kind") == "switch_on" for row in trace),
                  "PERSON/ORT recipe produces the documented debug light plan")
            check(command("{ ReadingsVal('test.dev.licht','state','unset') }") == "unset", "debug light recipe leaves real dummy untouched")
            command("set Geo.Test mode disabled")
            check(command("set Geo.PERSON mode active") == "", "new resident activation validates")
            check(command("set GP mode active") == "", "generic example controller activates")
            check_resident_status(command, http_request, admin_port, check, "Geo.PERSON", "active")
            advance(40)
            for zone in ("Home", "UMGEBUNG", "ORT"):
                check(person_request(zone, 1, debug=False)[0] == 200, "independent productive geometry accepted")
                advance(5)
            check(command("{ ReadingsVal('test.dev.licht','state','unset') }") == "unset", "initial geometry does not turn on the light")
            check(person_request("ORT", 1, debug=False)[0] == 200, "productive light event accepted")
            advance(5)
            check(command("{ ReadingsVal('test.dev.licht','state','unset') }") == "on", "active switch adapter turns dummy lamp on")
            normal = (root / "log/fhem.log").read_text()
            check('Jörg: Entered area “Große Straße”.' in normal, "real zone log preserves configured UTF-8 labels")
            check('Jörg: Switch-on requested for “Außenlicht 🌙”.' in normal,
                  "real action log preserves Unicode without doubled encoding")
            for suffix in ("Debug", "Disabled", "Unset"):
                for line in (f"define rr_{suffix} ROOMMATE",
                             f"attr rr_{suffix} rr_locationUnderway underway",
                             f"define Geo.{suffix} GeoPresence resident GP rr_{suffix}",
                             f"attr Geo.{suffix} sourceMode phone_only",
                             f"attr Geo.{suffix} phoneProxies p1,p2"):
                    check(command(line) == "", "prepare restart resident: " + line)
                check(command(f"{{ ReadingsVal('Geo.{suffix}','mode','missing') }}") == "disabled",
                      "a newly defined resident has an explicit disabled mode")
            check(command("set Geo.Debug mode debug") == "", "prepare saved debug resident")
            check(command("set GP mode debug") == "", "prepare timing persistence regression")
            administrative_builds = command(
                "{ no warnings 'redefine';; my $calls=0;; my $original=\\&GP_Catalog;; "
                "GP_InvalidateConfig($defs{GP});; "
                "{ local *GP_Catalog=sub { $calls++;; return $original->(@_) };; "
                "CommandAttr(undef,'GP reorder_window 1');; CommandAttr(undef,'GP action_max_age 2') };; "
                "return $calls }")
            check(administrative_builds == "0", "real cold AttrFn callbacks do not compile discarded catalogues")
            check(command("set GP mode active") == "", "reactivate with a valid short timing pair")
            # Earlier tests advance GP_Now into the future. Future-dated mode
            # readings mask defaults written by Define when fhem.save is loaded:
            # FHEM restores a reading only if its saved timestamp is newer.
            # Keep the operator modes but date them before the real process start.
            saved_mode_time = datetime.datetime.fromtimestamp(time.time() - 86400).strftime("%Y-%m-%d %H:%M:%S")
            check("Learning for 15" in command("set Geo.Test mode learning"), "prepare saved transient learning mode")
            check(command("{ ReadingsVal('Geo.PERSON','mode','') }") == "active", "other resident stays productive")
            saved_modes = {"GP": "active", "Geo.PERSON": "active", "Geo.Debug": "debug",
                           "Geo.Disabled": "disabled", "Geo.Test": "learning"}
            for name in saved_modes:
                command("{ $defs{'" + name + "'}{READINGS}{mode}{TIME}='" + saved_mode_time + "';; return 'dated' }")
            command("{ delete $defs{'Geo.Unset'}{READINGS}{mode};; return 'missing mode fixture' }")
            check(command("save").startswith("Wrote configuration"), "save mode readings with ordinary FHEM mechanism")
            saved_config = (root / "test.cfg").read_text()
            saved_state = (root / "log/fhem.save").read_text()
            check("attr GP action_max_age 2" in saved_config and "attr GP reorder_window 1" in saved_config
                  and saved_config.index("attr GP action_max_age 2") < saved_config.index("attr GP reorder_window 1"),
                  "FHEM saves the valid pair in the formerly failing alphabetical order")
            check(not re.search(r"^attr (?:GP|Geo\.\S+) (?:operatingMode|mode) ", saved_config, re.M), "configuration contains no mode attributes")
            check(all(re.search(r"^setstate " + re.escape(name) + r" \S+ \S+ mode " + mode + r"$", saved_state, re.M)
                      for name, mode in saved_modes.items()),
                  "fhem.save holds requested modes")
            check(all(f"setstate {name} {saved_mode_time} mode {mode}" in saved_state
                      for name, mode in saved_modes.items()), "saved modes predate the real restart")
            command("shutdown")
            process.wait(timeout=10)
            process = subprocess.Popen(["perl", "fhem.pl", "test.cfg"], cwd=root,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            restart_deadline = time.monotonic() + 15
            while time.monotonic() < restart_deadline:
                try:
                    if command("{ $init_done }") == "1":
                        break
                except OSError:
                    pass
                time.sleep(.1)
            else:
                raise AssertionError("Private FHEM failed to restart")
            check(command("{ AttrVal('GP','action_max_age',0) }") == "2"
                  and command("{ AttrVal('GP','reorder_window',0) }") == "1",
                  "real restart preserves both saved timing values instead of replacing age by 90")
            check(command("{ ReadingsVal('GP','mode','') }") == "active", "restart restores active controller")
            check(command("{ ReadingsVal('Geo.PERSON','mode','') }") == "active", "restart restores active resident")
            check(command("{ ReadingsVal('Geo.Test','mode','') }") == "disabled", "restart never resumes transient learning")
            for name, mode in (("Geo.Debug", "debug"), ("Geo.Disabled", "disabled"), ("Geo.Unset", "disabled")):
                check(command(f"{{ ReadingsVal('{name}','mode','missing') }}") == mode,
                      "restart retains or defaults operator mode: " + name)
                check_resident_status(command, http_request, admin_port, check, name, mode)
            for name in ("GP", "Geo.PERSON", "Geo.Debug", "Geo.Disabled"):
                check(command(f"{{ ReadingsTimestamp('{name}','mode','') }}") == saved_mode_time,
                      "restoration preserves the original operator timestamp: " + name)
            check_resident_status(command, http_request, admin_port, check, "Geo.PERSON", "active")
            check_resident_status(command, http_request, admin_port, check, "Geo.Test", "disabled")
            check("No current learning data" in command("get GP learnedLocations Geo.Test"), "restart cannot restore learning candidates")
            restored = json.loads(command("get GP explain Geo.PERSON format=json"))
            check(not restored["state"].get("trip") and not restored["state"].get("arrival"), "restart without a valid qualified checkpoint creates no permission")
            check(command("reload 98_GeoPresence.pm") == "", "reload after restart succeeds")
            for name, mode in (("GP", "active"), ("Geo.PERSON", "active"), ("Geo.Debug", "debug"), ("Geo.Disabled", "disabled")):
                check(command(f"{{ ReadingsVal('{name}','mode','') }}") == mode,
                      "module reload preserves requested mode: " + name)
            check(command("set GP mode debug") == "", "prepare controller debug precedence for rereadcfg")
            command("{ $defs{GP}{READINGS}{mode}{TIME}='" + saved_mode_time + "';; return 'dated' }")
            check(command("rereadcfg") == "", "reload saved configuration through the real core")
            check(command("{ AttrVal('GP','action_max_age',0) }") == "2"
                  and command("{ AttrVal('GP','reorder_window',0) }") == "1",
                  "real rereadcfg preserves the complete valid timing pair")
            check(command("{ ReadingsVal('GP','mode','') }") == "debug", "rereadcfg restores debug controller")
            check(command("{ ReadingsVal('Geo.PERSON','mode','') }") == "active", "rereadcfg retains personal active request")
            check_resident_status(command, http_request, admin_port, check, "Geo.PERSON", "debug")
            check_resident_status(command, http_request, admin_port, check, "Geo.Disabled", "disabled")
            check(command("{ ReadingsTimestamp('Geo.PERSON','mode','') }") == saved_mode_time,
                  "rereadcfg does not replace saved operator timestamps")
            for name in ("Geo.PERSON", "Geo.Debug"):
                for view in ("prod", "debug"):
                    restored = json.loads(command(f"get GP explain {name} {view} format=json"))
                    check(not restored["state"].get("trip") and not restored["state"].get("arrival")
                          and not restored["state"].get("intents"), "mode restoration creates no opening plan")
            check(command("deleteattr GP action_max_age") == "", "restore default age for recovery scenarios")
            check(command("deleteattr GP reorder_window") == "", "restore default reorder window for recovery scenarios")
            # Real state-file recovery: use past observations before the first
            # shutdown, then reboot the Perl process without preserving clocks.
            # Every output device in this scenario is a newly defined dummy.
            check(command("set GP mode debug") == "", "prepare private restart fixture")
            for resident in ("Geo.PERSON", "Geo.Debug", "Geo.Test"):
                command(f"set {resident} mode disabled")
            for name in ("recoveryDoor", "recoveryContact", "recoveryFeedback", "recoveryGarage",
                         "recoveryGate", "recoveryUpper", "recoveryLower", "recoveryLamp"):
                check(command(f"define {name} dummy") == "", "define isolated recovery actuator: " + name)
            for line in ("define rr_Recovery ROOMMATE", "attr rr_Recovery rr_locationUnderway underway", "attr rr_Recovery alias Rückkehr 🌙",
                         "define Geo.Recovery GeoPresence resident GP rr_Recovery",
                         "attr Geo.Recovery sourceMode geofency_only", "attr Geo.Recovery deviceId recovery-device",
                         "attr Geo.Recovery webhookUser recovery-user", "attr Geo.Recovery allowDoor 1",
                         "attr Geo.Recovery allowGarage 1", f"set Geo.Recovery webhookPassword {password}"):
                result = command(line)
                check("stored" in result if "webhookPassword" in line else result == "", "configure recovery resident")
            recovery_zones = {"Home": ("home", 0, 50), "Outer": ("outer", 0, 4500), "Work": ("place", .1, 100)}
            for name, (role, lat, radius) in recovery_zones.items():
                geometry = json.dumps({"lat": lat, "lon": 0, "radius": radius, "time": 1700000000,
                                       "changed": 1700000000, "id": "recovery-" + name.lower(),
                                       "device": "recovery-device", "blocked": 0}, separators=(",", ":"))
                for line in (f"define Geo.Recovery.{name} GeoPresence location Geo.Recovery {role}",
                             f"attr Geo.Recovery.{name} zoneId recovery-{name.lower()}",
                             f"setstate Geo.Recovery.{name} 2023-11-14 22:13:20 gp_geometry {geometry}"):
                    check(command(line) == "", "configure saved recovery geometry")
            check(command("attr Geo.Recovery.Work label Ausflug Straße 🌲") == "", "set Unicode checkpoint location")
            for line in (
                "define A.RecoveryDoor GeoPresence action GP door_open", "attr A.RecoveryDoor target recoveryDoor",
                "attr A.RecoveryDoor command lock unlocked", "attr A.RecoveryDoor contact recoveryContact",
                "attr A.RecoveryDoor feedbackDevice recoveryFeedback",
                "define A.RecoveryGarage GeoPresence action GP garage_open", "attr A.RecoveryGarage target recoveryGarage",
                "attr A.RecoveryGarage command on", "attr A.RecoveryGarage stateDevice recoveryGate",
                "attr A.RecoveryGarage upperContact recoveryUpper", "attr A.RecoveryGarage lowerContact recoveryLower"):
                check(command(line) == "", "configure isolated recovery adapter")
            for kind, action in (("Door", "A.RecoveryDoor"), ("Garage", "A.RecoveryGarage")):
                for line in (f"define R.Recovery{kind} GeoPresence rule GP", f"attr R.Recovery{kind} residents Geo.Recovery",
                             f"attr R.Recovery{kind} trigger arrival", f"attr R.Recovery{kind} action {action}"):
                    check(command(line) == "", "configure recovery rule")
            command("attr R.RecoveryGarage arrivalFilter vehicle")
            for line in ("define A.RecoveryLight GeoPresence action GP switch_on", "attr A.RecoveryLight target recoveryLamp",
                         "attr A.RecoveryLight command on", "define R.RecoveryLight GeoPresence rule GP",
                         "attr R.RecoveryLight residents Geo.Recovery", "attr R.RecoveryLight trigger enter",
                         "attr R.RecoveryLight locations Geo.Recovery.Work", "attr R.RecoveryLight action A.RecoveryLight",
                         "attr R.RecoveryLight cooldown 0"):
                check(command(line) == "", "configure ordinary recovery consumption")
            actor_time = datetime.datetime.fromtimestamp(time.time() - 360).strftime("%Y-%m-%d %H:%M:%S")
            for name, reading, value in (("recoveryContact", "state", "closed"), ("recoveryFeedback", "pulse_state", "idle"),
                                         ("recoveryGate", "state", "off"), ("recoveryUpper", "state", "open"),
                                         ("recoveryLower", "state", "closed")):
                command(f"setstate {name} {actor_time} {reading} {value}")
            command("{ no warnings 'redefine';; $main::GP_fixture_fixed_wall=undef;; $main::GP_fixture_offset=0;; "
                    "*GP_Now=sub { Time::HiRes::time()+$main::GP_fixture_offset };; "
                    "*GP_Mono=sub { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())+$main::GP_fixture_offset };; return 'real clock' }")
            check(command("set Geo.Recovery mode active") == "", "activate recovery resident")
            check(command("set GP mode active") == "", "activate recovery controller")
            # Date only the empty session boundary backwards. The HTTP event
            # is an 80-second delayed, still-fresh departure; checkpoint writes
            # and scheduler deadlines use the real wall clock before shutdown.
            command("{ my $rt=$defs{GP}{helper}{gp};; $rt->{resident_start}{'Geo.Recovery'}=GP_Now()-120;; "
                    "$rt->{resident_mono}{'Geo.Recovery'}=GP_Mono()-120;; delete $rt->{prod}{'Geo.Recovery'};; return 'earlier session' }")
            command("{ GeoPresence_Timer($defs{GP});; return 'listener ready' }")
            check(command("get GP validate Geo.Recovery").startswith("OK:"), "recovery configuration and listener are ready")

            def recovery_request(name, entry, motion=None, observed=None):
                role, lat, radius = recovery_zones[name]
                payload = {"device": "recovery-device", "id": "recovery-" + name.lower(), "entry": entry,
                           "date": observed or datetime.datetime.fromtimestamp(float(command("{ GP_Now() }")) - (80 if name == "Work" else 0), datetime.timezone.utc).isoformat(),
                           "latitude": lat, "longitude": 0, "radius": radius}
                if motion:
                    payload["motion"] = motion
                headers = {"Content-Type": "application/x-www-form-urlencoded",
                           "Authorization": "Basic " + base64.b64encode(f"recovery-user:{password}".encode()).decode()}
                return http_request("POST", "/fhem/geopresence", urllib.parse.urlencode(payload), headers)

            departure_observed = datetime.datetime.fromtimestamp(float(command("{ GP_Now() }")) - 80, datetime.timezone.utc).isoformat()
            check(recovery_request("Work", 1, observed=departure_observed)[0] == 200, "real authenticated departure accepted before restart")
            time.sleep(2.2)
            command("{ GeoPresence_Timer($defs{GP});; return 'departure processed' }")
            check(json.loads(command("{ ReadingsVal('Geo.Recovery','gp_trip_checkpoint','{}') }"))["status"] == "qualified",
                  "qualified trip is stored before real process shutdown")
            check(command("{ ReadingsVal('recoveryLamp','state','') }") == "on", "ordinary visit dispatched the dummy switch")
            command("set recoveryLamp untouched")
            checkpoint_before_retry = command("{ ReadingsVal('Geo.Recovery','gp_trip_checkpoint','') }")
            checkpoint_timestamp = command("{ ReadingsTimestamp('Geo.Recovery','gp_trip_checkpoint','') }")
            compact = json.loads(checkpoint_before_retry)
            check(compact["version"] == 2 and compact["state"]["action_visits"] == {
                "A.RecoveryLight|enter|location:Geo.Recovery.Work": 1}, "real checkpoint stores one current consumption slot")
            check(not {"notify_seen", "notify_order", "notify_last"} & compact["state"].keys(),
                  "real checkpoint contains no legacy action history")
            check(recovery_request("Work", 1, observed=departure_observed)[0] == 200, "identical departure retry accepted by real HTTP listener")
            time.sleep(2.2)
            command("{ GeoPresence_Timer($defs{GP});; return 'retry processed' }")
            check(command("{ GP_State($defs{GP},'Geo.Recovery',0)->{last_reason} }") == "duplicate event",
                  "identical departure really reached duplicate handling")
            check(command("{ ReadingsVal('Geo.Recovery','gp_trip_checkpoint','') }") == checkpoint_before_retry
                  and command("{ ReadingsTimestamp('Geo.Recovery','gp_trip_checkpoint','') }") == checkpoint_timestamp,
                  "duplicate webhook preserved checkpoint content and timestamp in real FHEM")
            check(command("{ ReadingsVal('recoveryLamp','state','') }") == "untouched", "identical retry did not repeat the switch")
            legacy = json.loads(checkpoint_before_retry)
            legacy["version"] = 1
            legacy["state"]["notify_seen"] = {"A.RecoveryLight|enter|1|location:Geo.Recovery.Work": 1}
            legacy["state"]["notify_order"] = list(legacy["state"]["notify_seen"])
            legacy["state"]["notify_last"] = legacy["state"].pop("action_last")
            legacy["state"].pop("action_visits")
            check(command(f"setstate Geo.Recovery {checkpoint_timestamp} gp_trip_checkpoint "
                          + json.dumps(legacy, separators=(",", ":"))) == "", "prepare an ordinary version 1 checkpoint")
            command("{ delete $defs{GP}{helper}{gp}{prod}{'Geo.Recovery'};; return 'old process state discarded' }")
            check(command("reload 98_GeoPresence.pm") == "", "real reload imports the legacy checkpoint")
            command("{ GeoPresence_Timer($defs{GP});; return 'legacy recovery processed' }")
            migrated = json.loads(command("{ ReadingsVal('Geo.Recovery','gp_trip_checkpoint','{}') }"))
            check(migrated["version"] == 2 and migrated["trip"]["id"] == compact["trip"]["id"]
                  and migrated["trip"]["away_time"] == compact["trip"]["away_time"],
                  "legacy import preserves the original qualified trip")
            check(migrated["state"]["action_visits"] == compact["state"]["action_visits"]
                  and migrated["state"]["action_last"] == compact["state"]["action_last"],
                  "legacy import preserves current consumption and cooldown")
            new_work_time = datetime.datetime.fromtimestamp(float(command("{ GP_Now() }")) + .25, datetime.timezone.utc).isoformat()
            check(recovery_request("Work", 1, observed=new_work_time)[0] == 200, "new observation of the recovered current visit accepted")
            time.sleep(2.2)
            command("{ GeoPresence_Timer($defs{GP});; return 'recovered visit processed' }")
            check(command("{ ReadingsVal('recoveryLamp','state','') }") == "untouched",
                  "legacy recovery did not repeat the consumed visit even with zero cooldown")
            checkpoint_before_retry = command("{ ReadingsVal('Geo.Recovery','gp_trip_checkpoint','') }")
            checkpoint_timestamp = command("{ ReadingsTimestamp('Geo.Recovery','gp_trip_checkpoint','') }")
            saved_state = json.loads(command("get GP explain Geo.Recovery format=json"))["state"]
            saved_location = saved_state["location"]
            saved_trip_id = saved_state["trip"]["id"]
            previous_generation = saved_state["generation"]
            for attempt in range(2):
                check(command("save").startswith("Wrote configuration"), "save recovery fixture through normal FHEM")
                if not attempt:
                    check('gp_trip_checkpoint {"' in (root / "log/fhem.save").read_text(), "checkpoint reaches actual fhem.save")
                command("shutdown")
                process.wait(timeout=10)
                process = subprocess.Popen(["perl", "fhem.pl", "test.cfg"], cwd=root,
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    try:
                        if command("{ $init_done }") == "1":
                            command("{ GeoPresence_Timer($defs{GP});; return 'initialized' }")
                            break
                    except OSError:
                        pass
                    time.sleep(.1)
                else:
                    raise AssertionError("Recovery FHEM failed to restart")
                restored = json.loads(command("get GP explain Geo.Recovery format=json"))["state"]
                check(restored["generation"] != previous_generation, "each real process restart gets a fresh session identity")
                previous_generation = restored["generation"]
                check(bool(restored.get("trip", {}).get("armed")) == (attempt == 0),
                      "real restart restores a qualified trip once, never a consumed one")
                check(not restored.get("arrival") and not restored.get("intents"), "real startup creates no pending action")
                if not attempt:
                    check(restored["resume"]["status"] == "restored", "real recovery reason is visible in explain")
                    check(restored["trip"]["id"] == saved_trip_id, "real restart preserves the unfinished trip ID")
                    check(restored["location"] == saved_location, "Unicode location survives checkpoint and real state-file restoration")
                    check(command("{ ReadingsVal('Geo.Recovery','gp_trip_checkpoint','') }") == checkpoint_before_retry
                          and command("{ ReadingsTimestamp('Geo.Recovery','gp_trip_checkpoint','') }") == checkpoint_timestamp,
                          "real process restart retained the unchanged checkpoint and its saved_at")
                command("set recoveryDoor untouched")
                command("set recoveryGarage untouched")
                check(command("{ ReadingsVal('recoveryDoor','state','') }") == "untouched", "startup has not opened the dummy door")
                check(command("{ ReadingsTimestamp('recoveryContact','state','') }") == actor_time,
                      "contact timestamp stays pre-restart, without fabricated refresh")
                command("{ no warnings 'redefine';; $main::GP_fixture_offset=0;; "
                        "*GP_Now=sub { Time::HiRes::time()+$main::GP_fixture_offset };; "
                        "*GP_Mono=sub { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())+$main::GP_fixture_offset };; return 'return clock' }")
                advance(1)
                check(recovery_request("Home", 1, "automotive")[0] == 200, "new Home event accepted after real restart")
                advance(4)
                advance(11)
                check(command("{ ReadingsVal('recoveryDoor','state','') }") == ("lock unlocked" if not attempt else "untouched"),
                      "fresh return opens the door once using saved held contact")
                check(command("{ ReadingsVal('recoveryGarage','state','') }") == ("on" if not attempt else "untouched"),
                      "fresh car return opens garage once using saved held end contacts")
                check(json.loads(command("{ ReadingsVal('Geo.Recovery','gp_trip_checkpoint','{}') }"))["status"] == "none",
                      "real return consumes the persistent trip checkpoint")
            advance(40)
            next_departure = datetime.datetime.fromtimestamp(float(command("{ GP_Now() }")), datetime.timezone.utc).isoformat()
            check(recovery_request("Work", 1, observed=next_departure)[0] == 200, "new departure accepted after the consumed-trip restart")
            advance(3)
            next_trip = json.loads(command("get GP explain Geo.Recovery format=json"))["state"]["trip"]
            check(next_trip["armed"] and next_trip["id"] != saved_trip_id, "new trip after real restart has its own ID")
            check(json.loads(command("{ ReadingsVal('Geo.Recovery','gp_trip_checkpoint','{}') }"))["trip"]["id"] == next_trip["id"],
                  "real checkpoint stores the new trip identity")
            check(command("{ ReadingsVal('recoveryDoor','state','') }") == "untouched"
                  and command("{ ReadingsVal('recoveryGarage','state','') }") == "untouched",
                  "new departure does not replay an opening")
            command("delete GP")
            check(command("{ scalar grep { /^GeoPresenceHTTP:/ } keys %selectlist }") == "0", "undef releases all listener select entries")
            log = (root / "log/fhem.log").read_text()
            check(not re.search(r" GP GeoPresence \w+ \{", log), "structured module diagnostics never enter FHEM log")
            # The Git mirror omits SVN version captures. apptime intentionally
            # replaces the two core dispatchers. Exclude only those stock warnings.
            relevant = "\n".join(line for line in log.splitlines()
                                 if not ("uninitialized value $" in line and "fhem.pl line 2993" in line)
                                 and not re.search(r"Subroutine (?:HandleTimeout|CallFn) redefined at ./FHEM/98_apptime.pm line \d+", line))
            check("PERL WARNING" not in relevant and "ERROR" not in relevant, "FHEM log contains no module warnings or errors")
            print(f"PASS: {checks} integration checks with real FHEM/HTTP/ROOMMATE, encoding={encoding} and FHEMWEB attack regression; dummy actuators only")
        except Exception:
            log = root / "log/fhem.log"
            if log.exists():
                print(log.read_text().replace(password, "<test password>"))
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fhem-dir", type=Path, required=True)
    parser.add_argument("--encoding", choices=("bytestream", "unicode"), default="bytestream")
    parser.add_argument("--help-only", action="store_true", help="Check module and contextual help only")
    args = parser.parse_args()
    run(args.fhem_dir.resolve(), args.encoding, args.help_only)
