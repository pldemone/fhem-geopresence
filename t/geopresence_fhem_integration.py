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
    secret = command("{ (getKeyValue('GeoPresence_Geo.Test_auth'))[1] }")
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
    check(command("{ (getKeyValue('GeoPresence_Geo.Test_auth'))[1] }") == secret,
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

        def event_body(zone, entry, motion=None, *, test=False):
            current = float(command("{ GP_Now() }"))
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

        def request(zone, entry, *, debug=False, auth=True, motion=None):
            status, _, body = http_request("POST", "/fhem/geopresence",
                                           event_body(zone, entry, motion, test=debug), auth_headers(auth))
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

        def phone_state(name, value):
            # Actual PRESENCE processing and FHEM event filtering; advance the
            # reading clock only for an explicitly supplied detector message.
            return command("{ my $h=$defs{" + name + "};; readingsBeginUpdate($h);; "
                           "$h->{'.updateTimestamp'}=strftime('%Y-%m-%d %H:%M:%S',localtime(GP_Now()));; "
                           "$h->{'.updateTime'}=GP_Now();; PRESENCE_ProcessState($h,'" + value + "');; "
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
            check(stats["runs"] >= 20 and stats["last_device_scans"] == 1
                  and stats["last_config_builds"] == 1, "one catalogue scan and configuration per idle callback")
            check(0 <= stats["last_ms"] <= stats["max_ms"] and 0 <= stats["mean_ms"] <= stats["max_ms"],
                  "timer statistics contain consistent measured millisecond durations")
            check(command("{ $main::GP_fixture_user_readings }") == "0", "idle statistics create no debug Reading callbacks")
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
            command("set GP mode debug")
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
            # Real state-file recovery: use past observations before the first
            # shutdown, then reboot the Perl process without preserving clocks.
            # Every output device in this scenario is a newly defined dummy.
            check(command("set GP mode debug") == "", "prepare private restart fixture")
            for resident in ("Geo.PERSON", "Geo.Debug", "Geo.Test"):
                command(f"set {resident} mode disabled")
            for name in ("recoveryDoor", "recoveryContact", "recoveryFeedback", "recoveryGarage",
                         "recoveryGate", "recoveryUpper", "recoveryLower"):
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

            def recovery_request(name, entry, motion=None):
                role, lat, radius = recovery_zones[name]
                payload = {"device": "recovery-device", "id": "recovery-" + name.lower(), "entry": entry,
                           "date": datetime.datetime.fromtimestamp(float(command("{ GP_Now() }")) - (80 if name == "Work" else 0), datetime.timezone.utc).isoformat(),
                           "latitude": lat, "longitude": 0, "radius": radius}
                if motion:
                    payload["motion"] = motion
                headers = {"Content-Type": "application/x-www-form-urlencoded",
                           "Authorization": "Basic " + base64.b64encode(f"recovery-user:{password}".encode()).decode()}
                return http_request("POST", "/fhem/geopresence", urllib.parse.urlencode(payload), headers)

            check(recovery_request("Work", 1)[0] == 200, "real authenticated departure accepted before restart")
            time.sleep(2.2)
            command("{ GeoPresence_Timer($defs{GP});; return 'departure processed' }")
            check(json.loads(command("{ ReadingsVal('Geo.Recovery','gp_trip_checkpoint','{}') }"))["status"] == "qualified",
                  "qualified trip is stored before real process shutdown")
            saved_location = json.loads(command("get GP explain Geo.Recovery format=json"))["state"]["location"]
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
                check(bool(restored.get("trip", {}).get("armed")) == (attempt == 0),
                      "real restart restores a qualified trip once, never a consumed one")
                check(not restored.get("arrival") and not restored.get("intents"), "real startup creates no pending action")
                if not attempt:
                    check(restored["resume"]["status"] == "restored", "real recovery reason is visible in explain")
                    check(restored["location"] == saved_location, "Unicode location survives checkpoint and real state-file restoration")
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
