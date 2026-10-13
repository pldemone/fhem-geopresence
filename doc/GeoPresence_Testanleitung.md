# GeoPresence – Testanleitung

**Version 4.11 · Stand 13.10.2026 · Handbuch 2.15 · Architektur 0.53**

Diese Anleitung beschreibt die Prüfung einer eingerichteten GeoPresence-Anlage. Die Testanwendung simuliert Alltagswege und prüft deren neue Diagnosezeilen; gezielte App-Tests prüfen eigene Orts- und Gruppenregeln. Einrichtung, Begriffe und Parameter stehen im [Handbuch](GeoPresence_Handbuch.md).

## Inhalt

- [[#1. Test vorbereiten|1. Test vorbereiten]]
- [[#2. Automatische Alltagstests ausführen|2. Automatische Alltagstests ausführen]]
- [[#3. Geprüfte Szenarien|3. Geprüfte Szenarien]]
- [[#4. Eine eigene Ortsregel am Telefon prüfen|4. Eine eigene Ortsregel am Telefon prüfen]]
- [[#5. Gruppen und vorherige Austritte prüfen|5. Gruppen und vorherige Austritte prüfen]]
- [[#6. Optionen und Ergebnisse|6. Optionen und Ergebnisse]]
- [[#7. Produktiven Betrieb freigeben|7. Produktiven Betrieb freigeben]]
- [[#8. Wiederherstellung nach Neustart prüfen|8. Wiederherstellung nach Neustart prüfen]]

## 1. Test vorbereiten

### 1.1 Voraussetzungen

Ersetze `PERSON`, `ORT` und `PUBLIC_HOST` durch deine Namen. Person, Geofency-Telefonbindung und Ortsgeräte müssen tatsächlich vorhanden sein; eine Lernliste allein reicht nicht. Für automatische Tests muss außerdem die Geometrie aller registrierten Orte aus bestätigtem Lernen, gespeicherten produktiven Readings oder der aktuellen Simulation verfügbar sein.

**FHEM:**

```text
set Geo.PERSON mode debug
get System.GeoPresence validate
attr System.GeoPresence debugLog auto
get System.GeoPresence explain Geo.PERSON debug
get System.GeoPresence logStatus
```

**Erwartet:** `OK: configuration valid`, Kopf `=== DEBUG ===`, nach dem nächsten Timerlauf `Debug ready` mit Wert `Yes` und `Simulation diagnostics` mit Wert `Enabled`. Die Ortsansicht muss für alle benötigten Orte bekannte Geometrie zeigen. Modul und Testanwendung müssen gemeinsam auf dem aktuellen Stand sein; die Anwendung prüft die Debug-Ansicht sowie sichere Testverarbeitung und Geometrieerhaltung vor dem ersten Test. Die vollständigen Prüfmerkmale stehen unter **Debug readiness** und sind außerdem mit `format=json` abrufbar. Der Diagnosepfad muss beschreibbar sein und mit dem späteren `--log`-Argument übereinstimmen. Ein noch laufendes Einlernen mit `set Geo.PERSON learnConfirm` bestätigen und danach ausdrücklich `set Geo.PERSON mode debug` wählen, bevor ein Testlauf beginnt.

**Konfiguration gültig bedeutet nicht, dass alle Ortsdaten vorliegen.** `Geometry ready` mit Wert `Yes` unter **Debug readiness** bestätigt die Geometrie für Home, den Außenbereich und eine gegebenenfalls konfigurierte Annäherungszone sowie die Prüfung auf Geometriekonflikte. Gewöhnliche `place`-Orte können trotzdem `Not learned` anzeigen; der Debug-Bericht nennt diese unter `Missing location geometry`. Die Testanwendung muss Koordinaten und Radius aller registrierten Orte kennen, um deren Webhooks nachzubilden und die Simulation vorzubereiten.

### Fehlende Geometrie vor dem Start ergänzen

Wenn `explain Geo.PERSON debug` unter **Locations and geometry** einen Ort mit `Not learned` zeigt oder die Testanwendung fehlende Geometrie meldet, führe diese Vorbereitung aus:

| Schritt | Handlung | Erwartung |
|---|---|---|
| 1 | Person in `mode debug` lassen; der Controller darf `active` bleiben | Nur diese Person wird simuliert |
| 2 | Nach einem gerade erfolgten Moduswechsel oder Reload zunächst 35 Sekunden warten; bei erhöhtem `future_tolerance` dessen Wert plus fünf Sekunden | Die Anlaufschutzfrist ist abgelaufen |
| 3 | In Geofency den betroffenen, bereits registrierten Ort öffnen und einmal den Testbutton **Betreten** oder **Verlassen** drücken | `isTest=true` an die bestehende Webhook-URL; `OK debug accepted; no actions` |
| 4 | Mindestens acht Sekunden warten; bei erhöhtem `phone_poll` oder `reorder_window` den größeren Wert plus drei Sekunden verwenden; Schritte 3 und 4 für jeden fehlenden Ort wiederholen | Neue Geometrie erzeugt im Diagnoselog `geometry learned or changed; trip and pending actions revoked`; ein gültiger Home-Austritt kann danach `Home departure pending after geometry update; new departure confirmation required` erzeugen, sonst folgt `geometry synchronization; no actions`. Daraus entsteht noch keine Öffnungsberechtigung. |
| 5 | `get System.GeoPresence explain Geo.PERSON debug` ausführen | Alle Ortszeilen zeigen Radius und `known`; kein Ort zeigt `Not learned` oder `conflicting` |
| 6 | Die Testanwendung starten | Sie übernimmt die verfügbaren Geometriedaten und bereitet ihre Szenarien selbst vor |

Für bereits registrierte Orte ist kein Lernmodus, kein erneutes `define` und kein manuelles Setzen von Koordinaten nötig. Zwischen Schritt 3 und dem Start der Anwendung kein vollständiges `debugReset` ohne Zusatz, keinen Reload und keine Modus- oder Konfigurationsänderung ausführen: Dadurch können die gerade empfangenen Debug-Daten verloren gehen. Die Anwendung verwendet `debugReset Geo.PERSON keepGeometry`, erhält vorhandene Geometrie und ergänzt nur noch fehlende Geometrie aus dem eingelesenen Lernbestand beziehungsweise produktiven Readings.

Die Testanwendung speichert Debug-Geometrie nicht als produktives Reading. Bei normalem Abschluss und abgefangenem Abbruch oder Fehler verwendet die Anwendung ebenfalls `keepGeometry`: Die Testreise samt Ankunftsvormerkungen und Öffnungsberechtigungen wird verworfen, die Geometrie bleibt für den nächsten Aufruf im Speicher erhalten. Ein zweiter Aufruf benötigt deshalb keine erneuten App-Testmeldungen. Moduswechsel, relevante Konfigurationsänderungen, Reload, Neustart oder ein Reset ohne `keepGeometry` können diese flüchtigen Daten weiterhin verwerfen. Vor der Produktivfreigabe kann der Betreiber die geprüfte Geometrie mit `applyGeometry` bestätigen; siehe [[#7. Produktiven Betrieb freigeben|Kapitel 7]]. Eine als **gesperrt** gemeldete Geometrie braucht eine neuere, eindeutige Geofency-Meldung; ein Reset mit `keepGeometry` hebt die Sperre nicht auf.

Der Controller kann debug oder active sein. Unter active bleibt ausschließlich die Person mit `mode debug` in Simulation; andere aktive Personen können weiterarbeiten. Während eines automatischen Laufs den Modus und die Konfiguration nicht verändern und keine zusätzlichen Testbuttons dieser Person drücken.

### 1.2 Welcher Test passt?

| Konfiguration | Geeignete Prüfung |
|---|---|
| Nur Anwesenheit oder normale Lichtregeln | Gezielter App-Test aus Kapitel 4 beziehungsweise Telefonstatus-Test aus dem Handbuch |
| Türöffnung mit `geofency_phone` | Automatische Tests 3,4,6,7,8,9,11,12,13 |
| Zusätzlich Arbeitsorte und Nachrichten | Tests 1,2,5,10 ergänzen; 1,2,5 benötigen einen Rückweg-Ort |
| `geofency_only` | Tests 8,14,15,16,18; mit entferntem Helferort zusätzlich 17 |
| Mehrere Orte in einer gemeinsamen Gruppe | Ergänzende Gruppenprüfung aus Kapitel 5 |

Die automatische Anwendung benötigt eine arrival-Türregel und `allowDoor 1`. Für eine Person ohne Garage `--door-only` angeben; für eine Person mit Garage sind Garagenregel, `allowGarage 1` und `arrivalFilter vehicle` erforderlich. Die Anwendung erteilt keine Berechtigungen und ändert kein Quellenprofil.

Die Arbeitswegtests erwarten eine frei benannte Gruppe mit enter- und exit-Nachrichtenregel. Die Rückwegregel verwendet exit am ausgewählten Rückweg-Ort sowie `afterExit group:GRUPPE`. Zusätzliche eigene Regeln werden nicht automatisch als erwartetes Verhalten akzeptiert: Ein unerwarteter Aktionsplan lässt den Test fehlschlagen.

### 1.3 Zugang auf dem FHEM-Host

Die Anwendung läuft direkt auf dem FHEM-Host mit Python 3.9 oder neuer. Benötigt werden die aktuelle Datei [tools/geopresence_test.py](../tools/geopresence_test.py), lokaler Telnet-Zugang auf `127.0.0.1:7072`, Leserechte für das Diagnoselog und Schreibrechte für einen Ergebnisbericht. Es sind keine zusätzlichen Python-Pakete erforderlich.

Die Webhook-URL muss ausdrücklich angegeben werden. Alle Anfragen tragen `isTest=true`; Kennwörter werden interaktiv verdeckt abgefragt und nicht im Ergebnisbericht gespeichert. HTTPS-Zertifikate werden geprüft. Die Anwendung sendet keine produktiven Webhooks und benutzt keine Zeitsprünge der produktiven FHEM-Instanz.

Ergebnisberichte liegen standardmäßig unter `private/reports/`, relativ zum Arbeitsverzeichnis. Für eigene Logkopien ist `private/logs/` vorgesehen, für Konfigurationskopien `private/config/` und für Webhook-Mitschnitte `private/captures/`. Das Repository ignoriert die Betriebsdaten in `private/`; nur die [README zur privaten Ablage](../private/README.md) ist für Git freigegeben. Der mit `--log` angegebene Pfad darf weiterhin direkt auf das Diagnoselog der FHEM-Installation zeigen.

## 2. Automatische Alltagstests ausführen

### 2.1 Tür und optional Garage im kombinierten Profil

**Shell auf dem FHEM-Host, aus dem Verzeichnis oberhalb von tools:**

```sh
python3 tools/geopresence_test.py --url https://PUBLIC_HOST/fhem/geopresence --resident Geo.PERSON --log ./log/geopresence-%Y-%m.log --tests 3,4,6,7,8,9,11,12,13
```

Ersetze den Logpfad durch den tatsächlichen Pfad aus `logStatus`; ein relativer Pfad bezieht sich auf das Arbeitsverzeichnis der Anwendung. Wenn keine Garage freigegeben ist, ergänze `--door-only`. Nach der Kennwortabfrage zeigt die Anwendung die einzelnen Schritte und wartet die tatsächlich konfigurierten Fristen ab. Mehrere Szenarien benötigen deshalb mehrere Minuten.

### 2.2 Arbeits- und Rückwegregeln ergänzen

**Shell, wenn Gruppe Arbeitsorte sowie ORT und RUECKWEG eingerichtet sind:**

```sh
python3 tools/geopresence_test.py --url https://PUBLIC_HOST/fhem/geopresence --resident Geo.PERSON --log ./log/geopresence-%Y-%m.log --tests 1,2,5,10 --work-group Arbeitsorte --work Geo.PERSON.ORT --waypoint Geo.PERSON.RUECKWEG
```

Bei mehreren Arbeitsorten den Aufruf mit `--work Geo.PERSON.ORT2` wiederholen. Ohne Rückweg-Ort nur Test 10 wählen; dieser prüft Arbeitsankunft, Arbeitsabgang und die anschließende Fußweg-Rückkehr. `--tests all` wählt im kombinierten Profil alle Tests 1 bis 13 und setzt deshalb auch die dafür nötigen Nachrichtenregeln voraus.

Gruppen mit mehreren passenden enter-/exit-Regeln oder mehrere Rückweg-Orte müssen über die Auswahloptionen eindeutig zugeordnet werden. Geprüft werden die vorhandenen Regeln; die Anwendung legt keine Regeln an.

### 2.3 Ohne Haussensoren

**Shell für eine Person mit `sourceMode geofency_only`:**

```sh
python3 tools/geopresence_test.py --url https://PUBLIC_HOST/fhem/geopresence --resident Geo.PERSON --log ./log/geopresence-%Y-%m.log --tests all
```

Hier bedeutet all die Tests 8,14,15,16,18. Telefon-Fallback und rein über Telefonabwesenheit qualifizierte Spaziergänge gehören nicht zu diesem Profil. Eine unpassende Testauswahl wird vor dem Versand zurückgewiesen.

Für einen Spaziergang mit zusätzlichem Entfernungsnachweis muss ein gelernter `place`-Ort vorhanden sein, dessen gesamter Kreis weiter als `departure_margin` vom Home-Rand entfernt liegt. **Shell:**

```sh
python3 tools/geopresence_test.py --url https://PUBLIC_HOST/fhem/geopresence --resident Geo.PERSON --log ./log/geopresence-%Y-%m.log --tests all --checkpoint Geo.PERSON.HELFERORT
```

Damit wird Test 17 ergänzt. Ein solcher Helferort ist eine normale location mit Funktion place; `--checkpoint` ist nur die Auswahloption der Testanwendung. Bei vorhandenen Arbeits- und Rückwegregeln sind außerdem die Tests 1,2,5,10 ausdrücklich wählbar.

## 3. Geprüfte Szenarien

„Tür“ und „Garage“ bedeuten in dieser Tabelle **Aktionsplan im Debug**, keine reale Öffnung. Bei `--door-only` erwartet die Anwendung ausschließlich die Tür und ausdrücklich keinen Garagenplan. Eine gemeldete Rückkehr vor Ablauf der Ankunftsfrist genügt noch nicht als Plan.

| Test | Simulierter Ablauf | Erwartetes Ergebnis |
|---|---|---|
| 1 – Haus zur Arbeit | Home verlassen, Abwesenheit qualifizieren, outer verlassen, Rückweg-Ort betreten/verlassen, Arbeitsort betreten | Keine Hinweg-Nachricht; genau eine Arbeitsankunft-Nachricht |
| 2 – Arbeit nach Hause | Arbeitsort verlassen, Rückweg-Ort betreten/verlassen, outer betreten, Home betreten und Frist abwarten | Arbeitsabgang-Nachricht, Rückweg-Nachricht, Tür und Garage nach bestätigter Ankunft |
| 3 – Spaziergang | Home verlassen, negative Telefonzustände über die Qualifikation, Home mit walking betreten | Tür nach walking-Frist; keine Garage |
| 4 – Kurze Sprünge und Spaziergang | Home verlassen bei weiterhin erkanntem Telefon, nach 10 s Home betreten, nach 10 s erneut verlassen, dann echter simulierter Spaziergang | Keine Aktion während der Sprünge; Tür erst bei berechtigter Rückkehr |
| 5 – Arbeitsweg ohne outer-Austritt | Wie Test 1, jedoch fehlender Außenkreis-Austritt | Keine Hinweg-Nachricht; Arbeitsankunft-Nachricht und Entfernung durch entfernte Orte erkannt |
| 6 – Home-Webhook fehlt | Berechtigter Fernausflug, Rückkehr ausschließlich über neue Telefonanwesenheit | Tür und Garage aus Fernbereichsnachweis; bei door-only ausschließlich Tür |
| 7 – Raumwechsel und falscher Fernbereich | Kurze Telefonempfangslücke, irrtümlicher äußerer Austritt, Home-Rückkehr | Anwesenheit bleibt erhalten; keine neue Öffnung |
| 8 – Home ohne Ausflug | Home-Eintritt ohne vorherige Abwesenheitsberechtigung | Home-Status, keine Öffnung |
| 9 – Doppelte Heimkehr und Retry | Berechtigter Fernausflug, Rückkehr, gleicher und nochmals neuer Home-Webhook | Jede Öffnung höchstens einmal für diesen Ausflug |
| 10 – Fernausflug zu Fuß | Arbeitsankunft und -abgang, Heimkehr mit walking | Arbeitsnachrichten und Tür, keine Garage |
| 11 – 15-Sekunden-Home-Sprung | Berechtigter Spaziergang, Home-Eintritt, Austritt nach 15 s, spätere echte Rückkehr | Früher Sprung öffnet nicht; spätere bestätigte Rückkehr öffnet Tür |
| 12 – Telefon bestätigt früher | Berechtigte Home-Rückkehr, neue Telefonanwesenheit vor Ende der walking-Frist | Genau ein früher bestätigter Türplan |
| 13 – Autoankunft | Berechtigter Fernausflug, Home mit automotive | Tür und Garage nach der kürzeren Autofrist |
| 14 – Nur Geofency ohne Entfernung | Home verlassen, lange warten, Home betreten | Abwesenheits-/Heimstatus möglich, keine Öffnungsberechtigung |
| 15 – Nur Geofency mit Fernausflug | Entfernung bestätigt, Autoankunft, wiederholter Home-Eintritt | Tür und Garage einmalig nach Autofrist |
| 16 – Nur Geofency mit Home-Sprung | Fernausflug, kurzer Home-Eintritt mit walking und erneuter Austritt | Keine vorzeitige Öffnung |
| 17 – Nur Geofency mit Helferort | Home verlassen, ausreichend entfernten Helferort erreichen, zu Fuß zurückkehren | Tür nach bestätigter Rückkehr, keine Garage |
| 18 – Nur Geofency ohne Home-Rückkehr | Fernausflug, Home-Eintritt fehlt | Keine erfundene Telefonbestätigung, keine Öffnung |

Jedes Szenario stellt seinen Ausgangszustand selbst her. Vorbereitungsaktionen, etwa eine Arbeitsankunft zum Herstellen der Startposition, werden getrennt geprüft. Das Programm kontrolliert sowohl erwartete Pläne als auch ausdrücklich ausbleibende Pläne und passende Diagnosegründe.

Die Software-Regressionstests prüfen zusätzlich Geometrieänderungen beim Home-Austritt und Wiederholungen mit erst nachgelieferten Bewegungsdaten. Sie verwenden kontrollierte Zeitabläufe und eine temporäre FHEM-Installation mit Dummy-Aktoren; die Alltagstest-Anwendung verändert dafür keine Radien in deiner Anlage. Erwartet wird ein neuer unbestätigter Ausflug nach einem gültigen Austritt, eine vollständig erneuerte Telefonabwesenheitsqualifikation und genau ein Türauftrag nach bestätigter Fußweg-Rückkehr. Doppelte Home-Meldungen mit zunächst fehlender Bewegung und anschließend `walking` dürfen weder eine Garagenfreigabe durch fehlende Bewegung noch einen zweiten Öffnungsauftrag erzeugen; der ursprüngliche Beobachtungszeitpunkt und der Beginn der Ankunftsfrist bleiben erhalten.

## 4. Eine eigene Ortsregel am Telefon prüfen

Dieser Test benötigt das vollständige Lichtbeispiel aus dem Handbuch: `Geo.PERSON.ORT`, `Geo.Action.Licht`, `Geo.Rule.ORTLicht` und `test.dev.licht`. Er benötigt keine Türberechtigung. Lernempfang muss beendet und der Bewohner im Debug sein.

**Shell, parallel zur App öffnen; eigenen Pfad einsetzen:**

```sh
tail -f /PFAD/ZUM/LOG/geopresence-YYYY-MM.log
```

Bei allen Schritten werden die Testbuttons des jeweils genannten Geofency-Ortes verwendet. Sie simulieren keine Fahrt zwischen Orten, sondern senden genau die angegebene Meldung. Bei Standard-`reorder_window 2` nach jedem Versand mindestens fünf Sekunden warten; bei abweichendem Wert entsprechend länger.

| Schritt | Geofency | FHEM-Befehl | Warten | Erwartete Diagnose und Bedeutung |
|---|---|---|---|---|
| 1 | Nichts | `set System.GeoPresence debugReset Geo.PERSON` | 35 s | Neuer Simulationszustand; Anlaufgrenze von future_tolerance plus Reserve abgewartet |
| 2 | In Home, UMGEBUNG und ORT jeweils einmal Betreten | Nichts | Je 5 s | Bei neuer Geometrie `geometry learned or changed; trip and pending actions revoked`; zunächst nur Synchronisation |
| 3 | In ORT Verlassen | Nichts | 5 s | `zone observation processed`; die reine Eintrittsregel führt nichts aus |
| 4 | In ORT Betreten | Nichts | 5 s | `would execute; debug suppressed`, `kind=switch_on`, `rule=Geo.Rule.ORTLicht` |
| 5 | Nichts | `get System.GeoPresence debugTrace Geo.PERSON` und `list test.dev.licht` | Keine | Plan lesbar; echtes Dummy-Gerät unverändert |
| 6 | In ORT nochmals Betreten | Nichts | 5 s | Kein zweiter Lichtplan für denselben Besuch |

**Bestanden:** Genau der erwartete Eintrittsplan wird erzeugt, ohne den tatsächlichen Lichtzustand oder ROOMMATE zu ändern. Wenn schon andere Regeln für diese Person existieren, deren zusätzliche Pläne ausdrücklich zuordnen; ein Diagnoseeintrag ohne richtigen Regelnamen genügt nicht als Nachweis für dieses Beispiel.

## 5. Gruppen und vorherige Austritte prüfen

### 5.1 Testkonfiguration

Die folgenden Zusatzregeln verwenden ein eigenes Testlicht. Voraussetzung sind drei bereits angelegte und geometrisch gelernte `place`-Orte ORT, ORT2 und RUECKWEG sowie Home und UMGEBUNG. ORT und ORT2 sollen für den Überlappungstest geometrisch überlappen und ausreichend weit von Home entfernt sein; zwei zeitgleich betretene, disjunkte Orte wären stattdessen ein Positionswiderspruch.

**FHEM, Konfiguration im Controller-Debug:**

```text
set System.GeoPresence mode debug
set Geo.PERSON mode debug
attr Geo.PERSON.ORT groups Testorte
attr Geo.PERSON.ORT2 groups Testorte
define test.dev.gruppe dummy
define Geo.Test.Action.Gruppentest GeoPresence action System.GeoPresence switch_on
attr Geo.Test.Action.Gruppentest target test.dev.gruppe
attr Geo.Test.Action.Gruppentest command on
define Geo.Test.Rule.Gruppeneintritt GeoPresence rule System.GeoPresence
attr Geo.Test.Rule.Gruppeneintritt residents Geo.PERSON
attr Geo.Test.Rule.Gruppeneintritt trigger enter
attr Geo.Test.Rule.Gruppeneintritt locationGroup Testorte
attr Geo.Test.Rule.Gruppeneintritt action Geo.Test.Action.Gruppentest
attr Geo.Test.Rule.Gruppeneintritt cooldown 0
define Geo.Test.Rule.Gruppenaustritt GeoPresence rule System.GeoPresence
attr Geo.Test.Rule.Gruppenaustritt residents Geo.PERSON
attr Geo.Test.Rule.Gruppenaustritt trigger exit
attr Geo.Test.Rule.Gruppenaustritt locationGroup Testorte
attr Geo.Test.Rule.Gruppenaustritt action Geo.Test.Action.Gruppentest
attr Geo.Test.Rule.Gruppenaustritt cooldown 0
define Geo.Test.Rule.Richtungspruefung GeoPresence rule System.GeoPresence
attr Geo.Test.Rule.Richtungspruefung residents Geo.PERSON
attr Geo.Test.Rule.Richtungspruefung trigger exit
attr Geo.Test.Rule.Richtungspruefung locations Geo.PERSON.RUECKWEG
attr Geo.Test.Rule.Richtungspruefung afterExit group:Testorte
attr Geo.Test.Rule.Richtungspruefung action Geo.Test.Action.Gruppentest
attr Geo.Test.Rule.Richtungspruefung cooldown 0
get System.GeoPresence validate
```

Bestehende Gruppenlisten nicht überschreiben: Falls ORT bereits Gruppen hat, `Testorte` zur vollständigen Liste ergänzen. Die folgende Vorbereitung stellt die Geometrie nach dem Zurücksetzen wieder her, falls sie noch nicht produktiv gespeichert ist. Nach der Synchronisation nicht nochmals debugReset ausführen: Dieser Befehl würde die nur im Debug empfangene Geometrie wieder löschen. Für das kombinierte Profil Telefonmodus simulated mit absent verwenden, damit reale Anwesenheit im Haus keinen absichtlich simulierten Fernausflug widerlegt.

**FHEM vor dem Ablauf:**

```text
set System.GeoPresence debugReset Geo.PERSON
```

**Zusätzlich nur bei `geofency_phone`:**

```text
set System.GeoPresence debugPhoneMode Geo.PERSON simulated
set System.GeoPresence debugPhone Geo.PERSON absent
```

### 5.2 Ablauf am Telefon

Nach dem Zurücksetzen 35 Sekunden warten; bei erhöhtem future_tolerance entsprechend länger. Zur Vorbereitung Home, UMGEBUNG, ORT, ORT2 und RUECKWEG jeweils einmal mit **Verlassen** senden und je fünf Sekunden warten. Danach `get System.GeoPresence explain Geo.PERSON debug` prüfen: Alle Geometrien müssen bereit sein. Jetzt Home **Betreten** senden und die eventuell laufende Ankunftsfrist vollständig abwarten, bis der Statusbereich von `get System.GeoPresence explain Geo.PERSON debug` den Status Home zeigt. Diese Vorbereitung kann eigene Debug-Pläne erzeugen; sie zählt noch nicht zum folgenden Test.

Zwischen jedem folgenden Schritt mindestens fünf Sekunden warten. Die App-Testbuttons erzeugen so unterschiedliche Beobachtungszeiten und abgeschlossene Auswertungen. Die Tabelle nennt nur die drei Zusatzregeln; bereits vorhandene Regeln können ebenfalls Pläne melden.

| Schritt | App-Testbutton | Erwartung für die Zusatzregeln |
|---|---|---|
| 1 | Home Verlassen | Neuer Ausflug; kein Gruppen- oder Richtungsplan |
| 2 | RUECKWEG Betreten, anschließend Verlassen | Keine Richtungsaktion; `required prior exit not observed in this trip` |
| 3 | ORT Betreten | Ein Plan für Geo.Test.Rule.Gruppeneintritt |
| 4 | ORT2 Betreten | Kein zweiter Gruppeneintritt |
| 5 | ORT Verlassen | Kein Gruppenaustritt, weil ORT2 noch betreten ist |
| 6 | RUECKWEG Betreten, anschließend Verlassen | Weiterhin keine Richtungsaktion; fehlender letzter Gruppenaustritt wird nicht abgeleitet |
| 7 | ORT2 Verlassen | Ein Plan für Geo.Test.Rule.Gruppenaustritt |
| 8 | RUECKWEG Betreten, anschließend Verlassen | Ein Plan für Geo.Test.Rule.Richtungspruefung |
| 9 | ORT Betreten | Neuer Gruppenbesuch; alter Austrittsnachweis widerrufen |
| 10 | RUECKWEG Betreten, anschließend Verlassen | Keine neue Richtungsaktion; vorheriger Austritt nicht mehr gültig |

**Bestanden:** Erster Eintritt und letzter Austritt stimmen; vorherige Austritte gelten nur innerhalb desselben Ausflugs und bis zum erneuten Gruppeneintritt. `test.dev.gruppe` bleibt unverändert. Ein verlorener ORT2-Austritt in Schritt 7 muss dazu führen, dass Schritt 8 keine Richtungsaktion erhält.

### 5.3 Testdefinitionen entfernen

Die Zusatzregeln dienen nur dieser Prüfung. Vor Produktivfreigabe im Controller-Debug entfernen; bereits vorher vorhandene Geräte niemals als Testreste löschen.

```text
delete Geo.Test.Rule.Richtungspruefung
delete Geo.Test.Rule.Gruppenaustritt
delete Geo.Test.Rule.Gruppeneintritt
delete Geo.Test.Action.Gruppentest
delete test.dev.gruppe
```

Die vorher notierten Gruppenlisten von ORT und ORT2 wiederherstellen. Waren diese vorher leer, `deleteattr ... groups` verwenden. Danach `validate` ausführen und den gewünschten Betriebsmodus wiederherstellen.

## 6. Optionen und Ergebnisse

### 6.1 Kommandozeilenoptionen

| Option | Bedeutung |
|---|---|
| `--url URL` | Erforderliche HTTPS-Webhook-URL, ohne Zugangsdaten oder Zusatzpfad |
| `--resident Geo.PERSON` | Erforderlicher Bewohnername |
| `--controller NAME` | Standard System.GeoPresence |
| `--tests all` oder `--tests 3,4` | Profilgerechte Standardauswahl oder einzelne Nummern |
| `--work-group GRUPPE` | Arbeitsortgruppe bei mehreren möglichen Gruppen |
| `--work ORTGERAET` | Gewählter Arbeitsort dieser Gruppe |
| `--waypoint ORTGERAET` | Gewählter Rückweg-Ort |
| `--checkpoint ORTGERAET` | Entfernter place-Helfer für Test 17 |
| `--door-only` | Erwartet keine Garagenberechtigung und keinen Garagenplan |
| `--log PFAD` | Diagnoselog; Standard /var/log/fhem/geopresence-%Y-%m.log; Datumsplatzhalter erlaubt |
| `--telnet-port PORT` | Lokaler FHEM-Telnet-Port, Standard 7072 |
| `--telnet-password-prompt` | Zusätzlich Telnet-Kennwort verdeckt abfragen |
| `--report DATEI` | Neue JSON-Ergebnisdatei; Standard `private/reports/geopresence-test-YYYYMMDD-HHMMSS.json`; bestehende Datei wird nicht überschrieben; eigenes übergeordnetes Verzeichnis muss vorhanden sein |
| `--list` | Szenarien ohne Verbindung und ohne Pflicht-URL auflisten |

### 6.2 Ergebnis lesen

Ohne `--report` legt die Anwendung die Verzeichnisse `private/` und `private/reports/` bei Bedarf mit Zugriffsrechten `0700` an. Der neue Bericht erhält `0600`. Er enthält Personenreferenzen und tatsächliche Diagnosezeilen und gehört deshalb zu den privaten Betriebsdaten. Vor einer Weitergabe die [Hinweise zur Anonymisierung](../private/README.md#daten-weitergeben) beachten.

Ein erfolgreicher Test weist die passenden HTTP-Antworten, Diagnosezeilen und Aktionspläne nach. Debug prüft keinen realen Türimpuls, keine tatsächliche Bewegung des Tores und keine Zustellung an einen Nachrichtendienst. Das bleibt Teil der bewussten Produktivabnahme.

Bei einem Fehler nennt das Programm den betroffenen Schritt und erwartete beziehungsweise empfangene Pläne. Der Bericht enthält die zugehörigen neuen Diagnosezeilen. Ein leerer Logausschnitt kann einen falschen Pfad oder ausgeschaltete Dateidiagnose bedeuten. Zusätzliche Pläne deuten auf weitere passende Regeln hin; fehlende Pläne sollten mit `explain` und `debugTrace` anhand der genannten Entscheidung untersucht werden.

Bei Freezes zusätzlich `get System.GeoPresence timerStats` sowie `apptime max top` und `apptime maxDly top` sichern. Die Timerdiagnose nennt Zeitpunkt und Verarbeitungsschritte langsamer Aufrufe und trennt diese von verspäteten Starts. `format=json` enthält die begrenzte Messhistorie einschließlich Gerätenamen; Details zur Auswertung stehen im Handbuch unter „Freezes und langsame Timer untersuchen“. Diese passive Messung verändert keine Testaktionen.

Die Anwendung setzt nur Simulationsbefehle ab: `debugReset ... keepGeometry` und, bei Telefonprofilen, debugPhoneMode sowie debugPhone. Sie stellt bei normalem Abschluss oder abgefangenem Fehler den zuvor vorhandenen Debug-Telefonmodus wieder her und räumt die Testreise auf. Die Ortsgeometrie bleibt für weitere Läufe erhalten. Nach hartem Abbruch den Testzustand mit `set System.GeoPresence debugReset Geo.PERSON keepGeometry` selbst verwerfen; bei Telefonprofilen gegebenenfalls `debugPhoneMode ... live` setzen. Die Person bleibt im Debug, bis du sie ausdrücklich freigibst.

Nach einem manuellen `debugAdvance` ist `keepGeometry` nicht zulässig, weil die Geometrie dann künstliche Zeitstempel enthalten kann. Vor einem Test mit echten Zeitstempeln einen vollständigen `debugReset` ohne Zusatz ausführen und noch fehlende Geometrie mit den App-Testbuttons ergänzen. Die automatische Anwendung verwendet selbst kein `debugAdvance`.

## 7. Produktiven Betrieb freigeben

Nach erfolgreicher Prüfung Testregeln entfernen, Quellenmodus und Gerätebezüge kontrollieren und `validate` erneut ausführen. Konfigurationsänderungen können flüchtige Debug-Geometrie verwerfen; dann die fehlenden registrierten Orte nochmals mit den App-Testbuttons senden. Solange die Person noch im Debug ist, die vollständige Geometrie prüfen und ausdrücklich übernehmen:

```text
get System.GeoPresence explain Geo.PERSON debug
set System.GeoPresence applyGeometry Geo.PERSON
```

Erst nach erfolgreicher Übernahme den gewünschten Bewohner auf active setzen; ein noch globaler Controller-Debug muss ebenfalls aufgehoben werden. Die Geometrie bleibt nun in normalen Readings erhalten, eigene Reisen und Öffnungsberechtigungen werden dagegen zurückgesetzt. Die Testanwendung ruft `applyGeometry` niemals automatisch auf. Die genaue Befehlsfolge steht im Handbuch unter „Produktiv schalten und speichern“.

Geofency behält dieselbe URL. Für die erste echte Abnahme einen neuen Ausflug mit den erforderlichen Abwesenheitsnachweisen verwenden. Normales Log, `explain` und bei Bedarf `debugLog 1` belegen den produktiven Ablauf. Erst wenn tatsächlicher Aktorauftrag und Rückmeldung dem gewünschten Verhalten entsprechen, den vollständigen FHEM-Stand speichern; dabei werden die Geometrie-Readings regulär in FHEMs Zustandsdatei gesichert.

## 8. Wiederherstellung nach Neustart prüfen

Die Wiederherstellung betrifft ausschließlich produktive, bestätigte Ausflüge. Die Geofency-Buttons Betreten/Verlassen senden `isTest=true` und können dafür keinen produktiven Checkpoint erzeugen. Ein normaler Debug-Lauf bleibt ebenfalls flüchtig. Verwende zur praktischen Abnahme einen tatsächlichen Ausflug einer aktiven Person und beobachte die Readings beziehungsweise explain. Ein Moduswechsel zur Vorbereitung würde die vorhandene Reise widerrufen.

| Schritt | Handlung | FHEM-Abfrage | Erwartung |
|---|---|---|---|
| 1 | Tatsächlich Home verlassen und den normalen Abwesenheitsnachweis entstehen lassen | `get System.GeoPresence explain Geo.PERSON` | Departure ist Confirmed; ein aktiver lokaler oder ferner Trip ist vorhanden. Reines absent ohne Bestätigung genügt nicht. |
| 2 | FHEM bei einem beabsichtigten Neustarttest regulär neu starten | Vorher `list Geo.PERSON gp_trip_checkpoint` sichern | Der gespeicherte JSON-Stand hat status qualified. Ein geordnetes Beenden schreibt FHEMs Zustandsdatei. |
| 3 | Nach dem Start ungefähr zwei Sekunden für den ersten Timerlauf abwarten | `get System.GeoPresence explain Geo.PERSON` | Aktive Modi, bestätigte Abwesenheit und Restart recovery: Restored; keine Öffnung allein durch den Start. |
| 4 | Tatsächlich nach Hause zurückkehren; Geofency meldet einen neuen Home-Eintritt | Normales Log und explain beobachten | Die normale bewegungsabhängige Ankunftsfrist startet. Bei walking öffnet nur die Tür; bei berechtigter Fahrzeugankunft kann zusätzlich die Garage öffnen. Eine neue Telefon-Rückkehr kann den Home-Webhook im kombinierten Profil ersetzen. |
| 5 | Nach bestätigter Heimkehr den Checkpoint lesen | `list Geo.PERSON gp_trip_checkpoint` | status none: Der abgeschlossene Ausflug kann nicht erneut verwendet werden. |
| 6 | Bei einer späteren regulären Neustartprüfung zu Hause bleiben | `get System.GeoPresence explain Geo.PERSON` | Kein aktiver bestätigter Ausflug, kein nachgeholter Öffnungsimpuls. |

Im Diagnosefile heißt die erfolgreiche Übernahme `qualified unfinished trip restored; waiting for a new return`, Quelle restart. `gp_resume_status=rejected` beziehungsweise Restart recovery: Rejected nennt einen konkreten Grund, etwa abweichende Konfiguration, spätere Heimkehr oder einen abgelaufenen Abwesenheitsnachweis. Der Standard für die Wiederaufnahme beträgt 48 Stunden ab ursprünglicher Abwesenheitsbestätigung; die Ankunftsfristen selbst werden dadurch nicht verändert.

Die Softwaretests prüfen diese Verträge zusätzlich in einem echten temporären FHEM-Prozess mit Dummy-Aktoren: normal speichern, Prozess beenden, neu starten, eine neue Rückkehr melden und beide Öffnungsbefehle prüfen. Die alten Kontaktzeitstempel bleiben dabei bestehen. Ein weiterer Neustart mit anschließender Home-Meldung darf keinen verbrauchten Auftrag wiederholen. Modultests decken zusätzlich Spaziergänge, Telefon-Fallback, sofortige neue Rückkehr, bewahrte explizite Austritte, ungültige oder widersprüchliche Checkpoints, Moduswechsel und neue Abschlussrückmeldungen ab.
