# GeoPresence – Architektur

**Version 0.75 · Stand 30.10.2026 · Handbuch 2.37**

Diese Beschreibung spezifiziert den aktuellen Aufbau von `FHEM/98_GeoPresence.pm`. Einrichtung und Bedienung stehen im [Handbuch](GeoPresence_Handbuch.md); Prüfabläufe und Testprogramm sind in der [Testanleitung](GeoPresence_Testanleitung.md) beschrieben. Gerätenamen wie `Geo.PERSON` und `Geo.PERSON.ORT` sind austauschbare Beispiele.

## Inhalt

- [[#1. Aufgabe und Grenzen|1. Aufgabe und Grenzen]]
- [[#2. Geräte und Konfiguration|2. Geräte und Konfiguration]]
- [[#3. Webhook und Lernen|3. Webhook und Lernen]]
- [[#4. Geometrie und Ereignisordnung|4. Geometrie und Ereignisordnung]]
- [[#5. Anwesenheit und Ausflug|5. Anwesenheit und Ausflug]]
- [[#6. Telefonquellen|6. Telefonquellen]]
- [[#7. Rückkehr und Bewegungsdaten|7. Rückkehr und Bewegungsdaten]]
- [[#8. Ortsgruppen und Regeln|8. Ortsgruppen und Regeln]]
- [[#9. Aktionen und Rückmeldungen|9. Aktionen und Rückmeldungen]]
- [[#10. Simulation, Diagnose und Oberfläche|10. Simulation, Diagnose und Oberfläche]]
- [[#11. Persistenz und Lebenszyklus|11. Persistenz und Lebenszyklus]]
- [[#12. Ausführung und Prüfung|12. Ausführung und Prüfung]]
- [[#13. Änderungen seit der letzten Version|13. Änderungen seit der letzten Version]]

## 1. Aufgabe und Grenzen

GeoPresence verarbeitet Geofency-Webhooks und optional lokale Telefonanwesenheit, führt je Person einen Anwesenheits- und Ausflugszustand und wertet konfigurierte Regeln aus. ROOMMATE zeigt den daraus abgeleiteten Status. Aktoraktionen gehen an vorhandene FHEM-Geräte; die elektrische Tür- oder Torsteuerung bleibt Aufgabe dieser Geräte.

Die wichtigsten Verträge:

- Anwesenheit und Öffnungsberechtigung sind getrennt. Ein `home`-Status allein löst keine Öffnung aus.
- Ein GPS-Sprung über die Home-Grenze, ein doppelter Webhook oder eine kurze Telefonempfangslücke darf keine neue Öffnungsberechtigung erzeugen.
- Fehlende Fernbereichsmeldungen können durch einen tatsächlich beobachteten, ausreichend entfernten Ort ersetzt werden. Fehlende historische Austritte für Richtungsregeln werden nicht erfunden.
- Zeitlich ältere Daten dürfen eine neuere Rückkehr nicht rückgängig machen oder verbrauchte Berechtigungen wiederbeleben.
- Simulation erzeugt keine produktiven ROOMMATE-Änderungen, Gerätebefehle oder Nachrichten.
- Neustart, Reload und rereadcfg können einen gespeicherten, bestätigten und noch offenen produktiven Ausflug nach erneuter Prüfung fortsetzen. Relevante Konfigurations- und Modusänderungen widerrufen ihn. Eine neue Rückkehrbeobachtung ist erforderlich; gespeicherte Öffnungsaufträge werden nicht nachgeholt.

Webhooks können verloren gehen oder verspätet eintreffen. Ohne geeignete zusätzliche Beobachtung kann GeoPresence eine reale Bewegung nicht sicher von einem GPS-Fehler unterscheiden. Die Rückkehrfristen begrenzen dieses Risiko; sie beweisen keinen ununterbrochenen Aufenthalt, wenn eine widersprechende Meldung nicht ankommt.

## 2. Geräte und Konfiguration

### 2.1 Datenmodell

| Gerät | Definition | Verantwortung |
|---|---|---|
| Controller | `define System.GeoPresence GeoPresence controller` | Ein Eingang, gemeinsame Zeitparameter, Laufzeitverwaltung, Diagnose |
| Person | `define Geo.PERSON GeoPresence resident System.GeoPresence rr_PERSON` | Eigene Identität, Quellenprofil, ROOMMATE, Berechtigungen |
| Ort | `define Geo.PERSON.ORT GeoPresence location Geo.PERSON place` | Eine Geofency-Kennung, Systemfunktion, Anzeige und Gruppen |
| Aktion | `define Geo.Action.Licht GeoPresence action System.GeoPresence switch_on` | Ziel und festgelegter Ausführungsadapter |
| Regel | `define Geo.Rule.Licht GeoPresence rule System.GeoPresence` | Personen, Auslöser, Ortsauswahl, Zusatzbedingungen und Aktion |

Es gibt genau einen Controller. Die Person ist Eigentümerin ihrer Orte; zwei Personen dürfen geografisch dieselben Orte mit unterschiedlichen Geofency-Kennungen verwenden. Regeln und Aktionen gehören zum Controller und können mehrere Personen bedienen. Berechtigungen und Verlauf werden dennoch je Person geprüft.

### 2.2 Technische Ortsfunktionen

| Funktion in der Definition | Anzahl je Geo-Person | Bedeutung |
|---|---|---|
| `home` | Genau 1 | Innerer Heimkreis; Eintritt kann eine Rückkehr einleiten |
| `outer` | Genau 1 | Umgebender Kreis; Austritt kann Fernbereichsabwesenheit bestätigen |
| `approach` | Optional, höchstens 1 | Zusätzlicher Annäherungskreis für Rückkehrkontext und Bewegungsdaten |
| `place` | Beliebig | Normaler Ort, beispielsweise Garten, Büro, Sportstätte oder Helferort |

Home muss geometrisch vollständig in outer liegen. Ein optionaler approach-Kreis muss Home enthalten und selbst in outer liegen. Ein approach-Eintritt öffnet kein Gerät; geschützte Öffnungen erfolgen erst bei bestätigter Rückkehr.

Arbeitsorte oder Wegpunkte sind `place`-Orte. Fachliche Zuordnungen entstehen über frei benannte `groups`, nicht über fest programmierte Arbeits- oder Schulrollen. Die interne FHEM-Anzeige `ROLE` enthält die technische Ortsfunktion, nicht eine Regelbedingung.

Die Funktion eines vorhandenen Ortes lässt sich mit `modify Geo.PERSON.ORT location Geo.PERSON place` ändern. Dafür müssen die betroffenen Personen effektiv debug oder disabled sein; andere Personen können aktiv bleiben. Kennung, Attribute und Readings bleiben erhalten; ein Wechsel der übergeordneten Person ist damit nicht erlaubt.

### 2.3 Quellenprofile

| Profil | Verwendete Quellen | Öffnungsvertrag |
|---|---|---|
| `geofency_phone` | Geofency und individuelle PRESENCE-Sensoren | Home-Austritt plus qualifizierte Telefonabwesenheit oder eigenständiger Entfernungsnachweis; Rückkehr durch Home oder neue Telefonanwesenheit |
| `geofency_only` | Nur Geofency | Zusätzlicher Entfernungsnachweis erforderlich; Home-Austritt und Zeit allein reichen nicht; Rückkehr durch Home |
| `phone_only` | Nur PRESENCE-Sensoren | Nur Statusführung, keine Geo-Öffnungen, keine Geofency-Identität und kein Ortslernen |

`geofency_phone` ist der Standard. Inaktive Quellen werden weder ausgewertet noch für Validierung, Geometrie oder Simulation vorausgesetzt. Quellenwechsel verändern den Öffnungsvertrag und setzen den Laufzeitzustand zurück. Vorhandene, nun unpassende Attribute werden nicht stillschweigend gelöscht; sie müssen ausdrücklich bereinigt werden.

### 2.4 Aufbereitete Konfiguration

Ein kleiner Bestandsindex hält Gerätenamen und Gerätetypen des Controllers vor. Bewohnerlisten und Modusanzeigen verwenden ausschließlich diesen Index. Ein getrennt und bei Bedarf aufgebauter Abhängigkeitsindex enthält Personenreferenzen und Hardwareziele für die Schutzprüfung von Konfigurationsänderungen. Diese Verwaltungszugriffe bereiten weder Aktorparameter noch ausführbare Regeln oder statische Validierungen auf. Attributänderungen erhalten den Gerätebestand und entwerten nur die davon abhängigen Ableitungen. Während des Einlesens werden Zwischenstände lediglich entwertet; die vollständige Sitzung wird nach der Wiederherstellung einmal zurückgesetzt.

Die vollständige Konfiguration wird erst für Verarbeitung, Validierung oder einen Bericht aufbereitet. Pro Aktion werden ausschließlich die Parameter ihres festen Adapters übernommen. Regeln, Bewohner und geplante Aktionen referenzieren denselben Parameterdatensatz. Nachschlagewerke ordnen Webhook-Benutzer, Ortskennungen, Gruppen sowie Regeln nach Bewohner, Auslöser und Ortsauswahl direkt zu.

Gerätesuche, gemeinsame Identitäts- und Hardwarekonfliktprüfungen sowie statische Personen-, Regel- und Aktivierungsprüfungen werden zwischen relevanten Änderungen wiederverwendet. Definitionen, Änderungen, Löschungen, Umbenennungen und Attribute referenzierter Geräte entwerten die betroffenen Ableitungen. Ein unbeteiligtes `MODIFIED` erzeugt keine Bestands- oder Oberflächenaufbereitung. Bei `DEFINED` und `RENAMED` wird die Geräteauswahl für GeoPresence- und PRESENCE-Geräte aktualisiert; ein sicher bekannter anderer Typ erfordert keinen Neuaufbau der Auswahllisten. Bei unbekanntem Typ und bei `DELETED` bleibt die vorsorgliche Aktualisierung erhalten. Der Widerruf abhängiger Ausgaben und die fachliche Konfigurationsentwertung erfolgen unabhängig von dieser Oberflächenentscheidung. Eine reine Änderung der Ortsfunktion mit `modify` verändert ebenfalls keine Auswahlwerte und baut die Attributlisten nicht neu auf. Diagnose- und reine Oberflächenattribute wie `room` erfordern weder beim gezielten Setzen noch beim gezielten Löschen einen Neuaufbau. Das Löschen aller Attribute oder eines Musters mit Fachattributen entwertet die Konfiguration weiterhin.

Der Attributcallback prüft interaktive Änderungen vor der Übernahme; erst ein späterer Verarbeitungspunkt baut die vollständige Konfiguration aus den tatsächlich übernommenen Werten auf. Abgelehnte Änderungen ersetzen keinen laufenden Stand. Beim Start und bei `rereadcfg` erfolgen Einzelwertprüfungen sofort, Beziehungen wie `reorder_window < action_max_age` dagegen erst am vollständig eingelesenen Stand. Damit bleiben gültige gespeicherte Werte unabhängig von der alphabetischen Attributreihenfolge erhalten. Ein ungültiger Gesamtstand sperrt die Verarbeitung und wird nicht durch stillschweigend verwendete Standardwerte ersetzt. INITIALIZED, REREADCFG und Modulreload verwerfen den aufbereiteten Stand ebenfalls.

Auch Löschmuster und vollständige Attributlöschungen werden vor der Übernahme anhand der Fachattribute des jeweiligen Gerätetyps geprüft. Sie durchlaufen gemeinsam den Aktiv-Schutz, die Prüfung der resultierenden Zeitwerte und eine einmalige Rücksetzung; gleichzeitig gelöschte Werte gelten dabei zusammen als Standardwerte. Reine Aliasänderungen widerrufen keine Aktionspläne. Ein ROOMMATE-Alias aktualisiert beim nächsten Konfigurationszugriff den Nachrichtenbezeichner, ohne laufende Freigaben zu ändern.

Die globale Entwertung löst Löschmuster vor der Relevanzentscheidung in Attributnamen auf. Für externe Geräte verwendet sie deren FHEM-Attributbeschreibung; für eigene Geräte zusätzlich die bekannten, vom Validator beanstandeten Altattribute `mode`, `operatingMode`, `role` und `condition`. So erhalten Aliaslöschmuster wie `^alias$` dieselbe Behandlung wie die direkte Löschung. Die Bereinigung beanstandeter Altattribute verwirft den gespeicherten Prüfstand, ohne während der Attributübernahme einen neuen Katalog aufzubauen.

Produktive und simulierte Geometrie besitzen getrennte abgeleitete Ansichten. Neue Koordinaten, Radien oder Konfliktmarkierungen erneuern nur die Ansicht der betroffenen Person und des betroffenen Bereichs. Ein neuer Beobachtungszeitstempel bei unveränderten Kreisen löst weder eine erneute Regelaufbereitung noch eine erneute Prüfung der Kreisverschachtelung aus. Moduswechsel und Debug-Reset verwerfen die jeweils betroffenen Ansichten entsprechend ihrem Geometrievertrag.

Sensorwerte, Quellenstörungen, Scanintervalle, aktuelle Aktorrückmeldungen, die Verfügbarkeit von `pushMsg` und Listenerfehler bleiben Laufzeitdaten und werden weiterhin aktuell ausgewertet. Berichtsaufbereitung und Darstellung verwenden denselben Konfigurationsstand. Die Konfigurationsbindung übernimmt ausschließlich verwendete Adapterparameter; `room` und ungenutzte Aktorattribute beeinflussen deshalb keinen neuen Checkpoint. Ältere Checkpoints, deren Fingerabdruck noch solche zusätzlichen Aktorattribute enthält, werden beim ersten Versionswechsel sicher verworfen; danach ist ein neuer Abwesenheitsnachweis erforderlich.

## 3. Webhook und Lernen

### 3.1 Transport und Authentifizierung

Ein eigener, nicht blockierender IPv4-HTTP-Listener verarbeitet genau `POST /fhem/<webhookPath>`. Der Standardport ist 8090, die Standardadresse `127.0.0.1`, der Standardpfad `geopresence`. Ohne das Attribut `webhookPort` oder nach dessen Löschen gilt Port 8090; ein gesetzter ungültiger Wert wird abgewiesen. Der Eingang ist unabhängig vom FHEMWEB-Befehlsparser. Er ist keine allgemeine FHEM-Schnittstelle.

Für einen entfernten Reverse-Proxy werden eine konkrete lokale `webhookBindAddress` und explizite `webhookAllowedPeers` konfiguriert. Der tatsächliche TCP-Absender wird geprüft; weitergereichte IP-Header erteilen keine Rechte. HTTPS wird am Proxy terminiert. Die [nginx-Vorlage](GeoPresence_nginx.conf) leitet nur den exakten Pfad an den eigenen Listener und weist Unterpfade ab.

Jede Person erhält einen eigenen `webhookUser` und ein über `set ... webhookPassword` gesetztes Kennwort. Der FHEM-Schlüsselspeicher hält einen gesalzenen SHA-256-Prüfwert. Erfolgreiche Basic-Authentifizierung ordnet eine Anfrage genau einer Person zu; deren Geofency-Gerätekennung und Ortskennung müssen anschließend passen. Zugangsdaten erscheinen nicht in Readings oder Diagnoseausgaben.

Die Schlüsselkennung besteht aus `GeoPresence_auth_v2_` und dem SHA-256-Hexwert des Personengerätenamens. Damit enthält sie keine Regex-Sonderzeichen, die FHEMs Schlüssel-API als Suchmuster auswerten könnte. Bei kaltem Authentifizierungscache werden der neue und der bisherige Schlüssel `GeoPresence_<Personenname>_auth` aus einem einzigen mit `FileRead` gelesenen Bestand per exaktem Zeichenvergleich ausgewählt. Ein vorhandener neuer Schlüssel hat unabhängig von seiner Position Vorrang, auch bei leerem oder ungültigem Inhalt; ein altes Kennwort wird dadurch nicht wieder gültig. Bei mehrfach vorhandenen gleichnamigen Einträgen zählt weiterhin der erste passende Eintrag. Dieser Lesezugriff schreibt nichts; der vorhandene Authentifizierungscache vermeidet wiederholte Dateizugriffe. Kennwortvergabe und Umbenennung schreiben das neue Format, beim Löschen werden beide Formate entfernt. Die Altbereinigung verwendet FHEMs `FileRead`/`FileWrite` mit demselben gemeinsam ermittelten Dateipfad wie der Lesezugriff und die Schlüssel-API. Sie entfernt ausschließlich die exakten alten Einträge und verwendet dafür die lokale Zeilenliste weiter; vom ursprünglichen Bestand bleibt nur die Anzahl für die Änderungsprüfung erhalten. Ohne entfernten Alteintrag erfolgt kein zusätzlicher Schreibzugriff.

Der HTTP-Handler ermittelt und prüft den exakten Pfad einmal und trägt die passende Route vor weiteren Ablehnungen in den vorhandenen Diagnosehash ein. Der Wrapper ergänzt darin Status und Antwortgrund für die Protokollierung, ohne einen weiteren Hash zu kopieren. Die Benutzerzuordnung wird direkt aus der gemeinsamen Katalogliste gelesen; fehlende oder mehrdeutige Zuordnungen werden weiterhin abgewiesen, und die Liste bleibt unverändert.

Der Listener begrenzt Header, Body, Verbindungsdauer, gleichzeitige Verbindungen und Warteschlange. Der Body darf höchstens 16 KiB umfassen. Mehrdeutige HTTP-Header, Transfer-Encoding und FHEM-Steuerfelder werden nicht als Webhooks akzeptiert. Ein HTTP 200 bestätigt die Annahme in der aktuellen Sitzung, nicht eine physische Aktion oder dauerhafte Zustellung.

Nach erfolgreicher Anmeldung gilt ein eigenes Kontingent von 120 Anfragen je Person und festem 60-Sekunden-Fenster. Das Fenster beginnt mit der ersten authentifizierten Anfrage und wird ausschließlich anhand der monotonen Uhr erneuert; Systemzeitkorrekturen verlängern oder verkürzen es nicht. Weitere authentifizierte Anfragen erhalten bis zum Ablauf HTTP 429. Auch anschließend wegen Inhalt oder Betriebsmodus abgewiesene Anfragen zählen. Fehlende, unbekannte oder falsche Zugangsdaten erhalten HTTP 401 und verbrauchen kein Personenkontingent. Produktion, Debug und Lernen teilen das Kontingent derselben Person; Moduswechsel erneuern es nicht.

Der Controller hält dafür nur Fensterbeginn und einen auf 120 begrenzten Zähler je authentifizierter Person. Beim Löschen der Person wird ihr Eintrag entfernt; eine neue Controller-Sitzung beginnt ohne alte Kontingente. Die Begrenzung ersetzt keine äußere Drosselung am HTTPS-Proxy. Die gemeinsamen Verbindungs-, Größen- und Warteschlangengrenzen gelten weiterhin unabhängig davon.

Die authentifizierte Person wird vor der Kontingentprüfung der Diagnose zugeordnet. Dadurch behält auch HTTP 429 den Personenbezug; `debugLog auto` berücksichtigt deren Debug-/Lernmodus unter einem aktiven Controller über die vorhandene Modusableitung. Fehlgeschlagene Anmeldungen erhalten keine ungeprüfte Personenzuordnung.

### 3.2 Nutzdaten und Testkennzeichen

Erwartet werden Geofency-Formulardaten mit Telefon- und Ortskennung, Ein-/Austritt, Beobachtungszeit und Kreisgeometrie. Bewegungsangaben sind optional. Ein fehlendes oder unbekanntes Bewegungsfeld löscht keinen noch frischen bekannten Bewegungsnachweis. Menschlich lesbare mehrzeilige Zusatzfelder wie eine Adresse werden kontrolliert ignoriert; Identitäts- und Steuerfelder bleiben strikt geprüft.

`isTest=true` beziehungsweise `1` führt im expliziten Lernmodus nur zur Erfassung von Einrichtungsdaten; sonst erzwingt es den getrennten Simulationszustand, auch wenn die Person produktiv arbeitet. Das Kennzeichen erweitert keine Rechte. `false`, `0` oder ein fehlendes Kennzeichen verwenden den wirksamen Betriebsmodus; andere Schreibweisen und mehrdeutige Kennzeichen werden zurückgewiesen. Es gibt einen gemeinsamen Pfad für echte Beobachtungen, Lernen und Tests.

### 3.3 Lernen einer unbekannten Person

Voraussetzungen sind ein definiertes resident-Gerät mit ROOMMATE, Geofency-Quellenprofil, Account und Kennwort sowie Controller active oder debug. Die Person darf unvollständig konfiguriert sein; das Lernfenster ist ihr eigener Modus learning. Eine manuell beschaffte `deviceId` ist nicht erforderlich.

1. `set Geo.PERSON mode learning` öffnet für 15 Minuten ein Lernfenster.
2. Der erste frische authentifizierte Testwebhook bindet einen Kandidaten für die Gerätekennung; weitere Meldungen müssen von demselben Kandidaten kommen.
3. Testmeldungen erfassen bis zu 32 Ortskennungen mit Name und Geometrie. Bereits anderen Personen zugeordnete Gerätekennungen werden zurückgewiesen.
4. `set Geo.PERSON learnConfirm` bestätigt eine bisher ungebundene Gerätekennung über den normalen FHEM-Attributweg. Eine bereits konfigurierte `deviceId` wird nicht ersetzt. Die Person bleibt disabled; Bestätigung ist keine Produktivfreigabe.
5. `learnedLocations Geo.PERSON` zeigt den erfassten Bestand. `locationCommands` erzeugt die Definition und das `zoneId`-Attribut für einen ausgewählten Ort; der Betreiber führt beide Befehle selbst aus.

Lernen führt weder Telefonpolling noch Simulation oder produktive Aktionen aus und legt keine Ortsgeräte automatisch an. Echte Beobachtungen während des Lernfensters werden quittiert, aber nicht ausgewertet oder nachgeholt. Nach 15 Minuten wird die Person disabled; der Kandidat bleibt zur ausdrücklichen Bestätigung erhalten. Ein ausdrückliches mode disabled verwirft unbestätigte Lerndaten auch nach Ablauf. Relevant geänderte Identität, Zugangsdaten, Konfiguration, Reload oder Neustart beenden unbestätigtes Lernen. Wiederholtes mode learning verlängert das Fenster nicht. Bestätigte Lerndaten überleben einen Reload im selben Prozess, aber keinen Neustart; ein neuer Lernstart ersetzt sie.

Debug-Befehle sind während learning gesperrt. Nach learnConfirm und Anlage der Ortsgeräte kann applyGeometry die geprüften Metadaten übernehmen, während die Person disabled bleibt. Der anschließende Wechsel zu debug erlaubt Tests, active erlaubt nach erfolgreicher Validierung die produktive Verarbeitung. Kein Übergang stellt frühere Öffnungsrechte wieder her.

## 4. Geometrie und Ereignisordnung

### 4.1 Einmalige Datenquelle für Radien

Latitude, Longitude und Radius werden ausschließlich in Geofency gepflegt. GeoPresence übernimmt sie aus akzeptierten Webhooks und legt produktive Geometrie in `gp_geometry` des Ortsgeräts ab. Debug-Geometrie und Lernbestand sind davon getrennt. Neue oder geänderte Geometrie widerruft den bisherigen Ausflug, seine Entfernungsnachweise, offene Aktionspläne und die bisherige Telefonabwesenheitsqualifikation. Das betroffene Ereignisbündel führt keine Regeln aus.

Ein aktueller, widerspruchsfreier Home-Austritt in diesem Bündel darf nach der Geometrieprüfung einen neuen lokalen, unbestätigten Ausflug beginnen. Dafür müssen die erforderliche Geometrie vollständig und widerspruchsfrei sowie Sitzung, Ereignisreihenfolge und Frische gültig sein; eine neuere lokale Telefonerkennung widerspricht diesem Austritt. Es werden keine Fernbereichsnachweise oder bisherigen Berechtigungen übernommen. Im Profil `geofency_phone` muss nach diesem Austritt eine neue vollständige Telefonabwesenheitsfrist über `phone_absence_window` durchlaufen werden; eine vorher bereits bestätigte Telefonabwesenheit genügt nicht. Zustandsquellen dürfen dafür weiterhin gültige gehaltene Negativwerte verwenden, Messquellen benötigen neue und erneuerte Messungen. Neue unabhängige Geo-Entfernungsnachweise bleiben nach dem normalen Quellenvertrag möglich; `geofency_only` benötigt einen solchen Nachweis weiterhin zwingend. Erst eine danach bestätigte Rückkehr kann Aktionen erlauben.

Ein Home-Eintritt mit geänderter Geometrie synchronisiert den Heimstatus und gewährt keine Öffnungsberechtigung. Ein noch im selben Bündel auf den Austritt folgender Home-Eintritt verwirft auch dessen neuen Verdacht. Andere Ortsmeldungen des Geometrieänderungsbündels erzeugen ebenfalls keine Aktionspläne. Die Diagnose nennt den betreffenden Ort, dessen tatsächliche Beobachtungs- und Empfangszeit und die geänderten Werte unter `geometry_changes`; ein neuer Home-Verdacht wird als `Home departure pending after geometry update; new departure confirmation required` erklärt.

Der lokale FHEM-Befehl `applyGeometry Geo.PERSON` ermöglicht eine ausdrücklich bestätigte Übernahme der vollständigen Debug-Geometrie in die normalen Ortsreadings, solange die Person effektiv debug oder individuell disabled mit bestätigten Lerndaten ist. Nach learnConfirm können passende Erfassungen die Geometrie registrierter Orte liefern; unbestätigte Daten bleiben ausgeschlossen. Das explizite Lernfenster muss beendet sein. Geometrie, Kennungen, Zeitstempel, Kreisverschachtelung und Konfliktmarkierungen werden vor jeder Änderung vollständig geprüft; ein älterer abweichender Stand darf neuere produktive Geometrie nicht überschreiben. Mit `debugAdvance` erzeugte Zeitbezüge sind nicht zulässig. Unveränderte widerspruchsfreie Produktivgeometrie behält ihre vorhandenen Metadaten.

Die Übernahme verwirft beide Reisen und die wartenden Ereignisse dieser Person und schreibt nur Geometrie mit unveränderten Beobachtungszeitstempeln. FHEMs `setReadingsVal` aktualisiert dafür normale Readings ohne Events, `userReadings` oder `stateFormat` auszuwerten. Es entstehen keine Ortsereignisse, Anwesenheitsbestätigungen, Nachrichten oder Öffnungsberechtigungen; andere Personen und Rückmeldungen bereits laufender Aktoraufträge bleiben unberührt. Der Webhook und die Testanwendung können diese Übernahme nicht auslösen. Sie ruft nicht selbst `save` auf; die dauerhafte Sicherung erfolgt über FHEMs reguläre Zustandsdatei.

Die Konfigurationsvalidierung prüft Definitionen und Referenzen. `geometry_ready` prüft die Geometrie von Home, outer und einer gegebenenfalls registrierten approach-Zone sowie Geometriekonflikte; gewöhnliche place-Orte dürfen ihre Geometrie später liefern. Berichte weisen auf noch fehlende Ortsgeometrie hin, ohne dadurch die Konfiguration ungültig zu machen. Die Testanwendung benötigt darüber hinaus die Geometrie aller registrierten Orte, um vollständige Testwebhooks zu erzeugen; sie kann dazu bestätigte Lerndaten, gespeicherte produktive Geometrie oder die aktuelle Debug-Geometrie verwenden.

Entfernungsnachweis eines gewöhnlichen Ortes bedeutet: Der Abstand zwischen den Kreismittelpunkten muss größer als die Summe aus Home-Radius, Ortsradius und `departure_margin` sein. Auch ein ausreichend weit entfernter Helferort kann deshalb bestätigen, dass Home verlassen wurde. Eine Bewegungsklassifikation allein ist kein Entfernungsnachweis.

Veraltete Geometrie überschreibt keine neuere Geometrie. Unterschiedliche Geometrien mit identischem Zeitstempel sperren die Entscheidung, bis eine neuere widerspruchsfreie Beobachtung eintrifft. Das Ändern einer Kennung macht Geometrie einer anderen Identität unbrauchbar.

### 4.2 Reihenfolge und Frische

GeoPresence speichert Beobachtungszeit und Empfangszeit getrennt. Eine kurze Warteschlange von standardmäßig zwei Sekunden ordnet Ereignisse je Person und Betriebsbereich nach ihrer Beobachtungszeit. Der erste Empfang bestimmt die feste Bündelfrist anhand der monotonen Uhr. Sobald eine Meldung dieses Kontexts fällig ist, verarbeitet der nächste Timerlauf alle bis dahin vorliegenden Meldungen dieses Kontexts gemeinsam. Spätere Eingänge verlängern die Frist nicht; Produktiv- und Debug-Bereich sowie unterschiedliche Personen besitzen jeweils eigene Bündel. Ein leerer Geo-Puffer hält Telefonereignisse und fällige Ankunftsbestätigungen nicht zurück.

Telefonabwesenheit wird erst nach Abschluss ihrer vollständigen Bestätigungsfrist verwendbar. Das interne Ereignis wird deshalb anhand von `qualified_at` in das gemeinsame Bündel eingeordnet; seine ursprüngliche Sensorbeobachtungszeit bleibt unverändert. Ein zeitlich früherer Home-Eintritt widerruft die noch unbestätigte Reise und die alte Telefonqualifikation, bevor deren späterer Abschluss eine Berechtigung erteilen könnte.

Nach der Entnahme gehören die Queue-Ereignisse dem aktuellen Verarbeitungslauf und werden ohne weitere Hashkopie übernommen. Der Geometriefilter sammelt akzeptierte Ereignisse direkt in der späteren Verarbeitungsliste; seine sortierte Eingabefolge wird zuvor getrennt ausgewertet. Home-Vormerkungen, der neueste Home-Nachweis und Aktionspläne behalten dagegen eigene Ereigniskopien für ihren längeren Lebenszyklus. Eine Ergänzungskopie mit ursprünglichen Empfangszeiten wird erst angelegt, wenn eine wartende Home-Vormerkung sie benötigt.

Vor der Geometrieauswertung werden Geo-Meldungen chronologisch sortiert. Die Konfliktvorprüfung übernimmt diese Reihenfolge und prüft Frische, Sitzungsgrenze und bisherige Position einmal je Meldung. Paarvergleiche erfolgen nur innerhalb gleicher Beobachtungszeitpunkte; bei unterschiedlichen Zeitstempeln entfallen sie vollständig. Ein erkannter Konflikt beendet die Vorprüfung. Gleichzeitige Meldungen können weiterhin Paarvergleiche innerhalb ihrer Gruppe benötigen. Identische Wiederholungen werden dedupliziert; zeitgleiche widersprüchliche Kreisbeobachtungen sperren die betroffenen Aktionspläne.

Eine fällige Ankunft wird erst nach der vollständigen Auswertung des fälligen Bündels bestätigt. Das schließt jüngere Gegenbeobachtungen ein, deren eigener Empfang noch keine volle Sortierfrist zurückliegt. Eine erst später begonnene, noch nicht fällige Sammlung hält die Ankunft weiterhin bis zur gemeinsamen Auswertung zurück.

Liefert eine Wiederholung desselben Home- oder Annäherungseintritts erstmals eine Bewegungsart, darf sie fehlende Transportdaten im noch aktuellen Ankunftsabschnitt ergänzen. Bereits bekannte Bewegungsarten werden dadurch nicht ersetzt. Wiederholungen innerhalb desselben Bündels werden vor dessen Reiseauswertung zusammengeführt, damit auch eine anschließende Telefonbestätigung den Fußwegnachweis berücksichtigt. Bei einer noch wartenden Rückkehr wird die passende Ankunftsfrist weiterhin vom ersten Empfang gerechnet; der ursprüngliche Beobachtungszeitpunkt bestimmt die Bewegungsfrische. Bereits abgeschlossene oder unterbrochene Ankünfte werden nicht erneut ausgeführt, Regeln und Besuche nicht wiederholt. Eine Ergänzung in einem späteren Timerlauf erscheint als `duplicate event enriched with motion`.

Während einer offenen Ankunft werden die bereits akzeptierten Eintritte im bestehenden Duplikatspeicher ihrer Ankunft zugeordnet. Beim ersten Home-Eintritt wird auch der Schlüssel der bis dahin aktuellen Annäherungsbeobachtung übernommen; dafür hält der vorhandene Annäherungskontext neben seiner monotonen Ablaufzeit den Schlüssel und den ursprünglichen Beobachtungszeitpunkt. Dieser Zeitpunkt wird als `origin_time` in die Home-Vormerkung übernommen und begrenzt die noch gültigen Bewegungsursprünge. Gleiche Beobachtungszeiten von Annäherung und Home sind zulässig. Ein Austritt, eine neue Abwesenheit oder der Ablauf des Annäherungskontexts verhindert die Übernahme. Der gemeinsame Prüfschritt `GP_MotionOrigin` verwendet Zuordnung und Zeitgrenze sowohl im Geometrie-Vorfilter als auch vor der eigentlichen Ergänzung. Ein neuerer Home-Eintritt ohne Bewegung entwertet deshalb keinen noch frischen Nachtrag eines früher akzeptierten Eintritts derselben Ankunft. Reise, Sitzung und Ankunft müssen weiterhin übereinstimmen; außerhalb einer wartenden Ankunft bleibt nur die Ergänzung der aktuellen Annäherungsbeobachtung möglich.

Ein frischer verspäteter Home-, Annäherungs- oder Outer-Austritt mit unveränderter Geometrie unterbricht den Annäherungsabschnitt auch dann, wenn eine neuere Ortsmeldung bereits die Position fortgeschrieben hat. `GP_InterruptsArrival` prüft dafür dieselbe Ursprungszeit im Vorfilter und im Fachablauf. Position, Mitgliedschaften und Besuche werden nicht zurückgesetzt. Trifft die Unterbrechung erst nach Home ein, liegt aber zeitlich vor dessen erstem Eintritt, bleibt die bestehende Home-Vormerkung erhalten. Die Ursprungsgrenze wird auf diesen Home-Eintritt gesetzt; frühere Bewegungsdaten werden entfernt. Nur wenn dadurch Bewegungsdaten entfallen, wird deren Bewertung mit `GP_UpdateArrivalMotion` angepasst. Für die Frische der verbliebenen Daten gilt dabei der gespeicherte Bewertungszeitpunkt `motion_evaluated_at`, damit eine zuvor gültige Home-Fußwegsperre nicht allein durch spätere Verarbeitung verfällt. Home-Ereignis, Empfangsanker und neuester Home-Nachweis werden nicht neu aufgebaut. Ein Austritt während der Home-Frist erfordert weiterhin einen neueren Home-Eintritt mit eigener vollständiger Frist. Austritte vor dem aktuellen Annäherungseintritt verwerfen diesen nicht.

Bei einem älteren Nachtrag muss die mitgelieferte Geometrie weiterhin mit dem aktuellen Ortsstand übereinstimmen. Die Ergänzung aktualisiert ausschließlich die fehlende Bewegung und deren Ankunftsbewertung. Ortsposition, Mitgliedschaften, Besuchszähler und der neueste Home-Nachweis werden nicht auf den älteren Stand zurückgesetzt. Neuere brauchbare Bewegung hat Vorrang. Beobachtungszeit, erster Empfang und monotoner Empfangsbezug bleiben erhalten. Die Mindestabwesenheit und der Beginn der Home-Frist richten sich weiterhin nach dem ursprünglichen Home-Eintritt, auch wenn die Annäherung schon vor erfüllter Mindestabwesenheit beobachtet wurde. Insbesondere sperrt ein gültiger Fußwegnachtrag den bisherigen Fernbereichs-Ersatz für die Garage auch nach neueren bewegungslosen Home-Meldungen und vor einer anschließenden Telefonbestätigung.

Standardmäßig dürfen Beobachtungen für neue Aktionen höchstens 90 Sekunden alt und höchstens 30 Sekunden in der Zukunft liegen. Die Zeit der ursprünglichen Meldung bleibt auch während einer vorgesehenen Ankunftsfrist erhalten; nur diese kontrollierte Frist erweitert das Ausführungsbudget. Ein Timerstau oder ein verspäteter Retry macht alte Daten nicht neu.

Beim Empfang wird zusätzlich die monotone Zeit erfasst. Die frühere Originalzeit von Beobachtung und Empfang begrenzt das Aktionsalter; ihr Unterschied wird auf den ursprünglichen monotonen Empfangszeitpunkt bezogen. Warteschlange, Ankunftsfrist und Bewegungsnachträge behalten diesen Bezug bei. Ein später erzeugter Plan übernimmt daraus seine Ablaufgrenze einschließlich der vorgesehenen Ankunftsfrist. Die Ankunftsbestätigung selbst prüft bereits diese Grenze. Unmittelbar vor der Ausgabe werden Systemzeit und monotone Zeit neu gelesen; Zeitwerte vom Anfang des Timerlaufs erteilen keine Freigabe. Dadurch verlängern weder langsame Rückrufe noch kleine rückwärts gerichtete Systemzeitkorrekturen vor oder nach der Planerzeugung die verbleibende Frist.

Für Fristen wird eine monotone Uhr verwendet. Ein deutlicher Sprung zwischen Systemzeit und monotoner Uhr setzt Öffnungsberechtigungen zurück. Nach einer neuen Sitzung gilt eine Anlaufgrenze gegen nachträglich zugestellte alte Meldungen.

## 5. Anwesenheit und Ausflug

### 5.1 Zustandsmodell je Person

| Phase | Bedeutung |
|---|---|
| `unknown` | Noch keine belastbare Beobachtung der aktuellen Sitzung |
| `home` | Anwesenheit festgestellt; daraus folgt keine neue Öffnungsberechtigung |
| `leaving` | Home-Austritt beobachtet, Abwesenheit noch in Prüfung |
| `away` | Abwesenheitsstatus oder bestätigter Ausflug; `armed` unterscheidet die Öffnungsberechtigung |
| `returning` | Annäherung oder Home-Eintritt mit noch laufender Rückkehrbestätigung |

Ein Ausflug besitzt eine Sitzungskennung, einen Beginn, gegebenenfalls einen Home-Austritt, Reichweite `local` oder `remote`, eine Abwesenheitsbestätigung und verbrauchte Aktionen. `phase=away` und ROOMMATE `absent` sind allein keine Öffnungsfreigabe.

### 5.2 Bestätigung der Abwesenheit

Ein Home-Austritt eröffnet einen lokalen Verdacht. Im kombinierten Profil können ein gültiger Home-Austritt und eine genügend lange, zeitlich passende Telefonabwesenheit diesen bestätigen. Telefonabwesenheit ohne beobachteten Geo-Abgang setzt gegebenenfalls den Status, erzeugt aber keine Geo-Öffnungsberechtigung.

Ein akzeptierter outer-Austritt oder ein ausreichend entfernter Ort liefert selbstständigen Fernbereichsnachweis. So kann eine verlorene outer-Meldung durch die tatsächlich beobachtete Ankunft an einem entfernten Ziel kompensiert werden. Eine widerlegte Fernbeobachtung darf keine Reichweite `remote` für einen späteren lokalen Spaziergang hinterlassen.

Aktuelle lokale Telefonanwesenheit kann einen widersprechenden Entfernungsnachweis zurückweisen. Dies umfasst die gehaltene positive Zustandsmeldung und die kurze `handover`-Phase beim Raumwechsel. Ein bereits beobachteter, noch unbestätigter Home-Austritt kann dabei erhalten bleiben, wenn er zeitlich nach der letzten tatsächlichen positiven Telefonbeobachtung liegt; eine später qualifizierte Abwesenheit bestätigt dann nur diesen lokalen Ausflug.

Beim Beibehalten dieses Home-Abgangs bleiben Reise-ID und bereits verbrauchte Reiseaktionen zusammen erhalten. Zurückgewiesene Entfernungs- und bisherige Austrittsnachweise werden weiterhin verworfen; es entsteht keine Öffnungsberechtigung. Ein später neu beobachteter Austritt oder ein weiterer Ortsbesuch gibt eine bereits verbrauchte `afterExit`-Aktion in derselben Reise nicht erneut frei. Erst ein tatsächlich neuer Ausflug erhält einen neuen Reiseverbrauch.

### 5.3 Verwerfen von Berechtigungen

Bestätigte Heimkehr verbraucht die Reiseberechtigung. Ein neuer Ausflug beginnt mit neuen Nachweisen. Manuelles ROOMMATE `home`, relevante Konfigurationsänderung, Identitätswechsel, Geometrieänderung, Uhrsprung oder widersprüchliche Beobachtungen widerrufen alte Berechtigungen. Ein Neustart darf ausschließlich den in [[#11. Persistenz und Lebenszyklus|Kapitel 11]] beschriebenen gültigen, noch offenen Ausflug fortsetzen.

Der Status `absent` ist kein Arbeitsort. Ein Ortslabel beschreibt einen tatsächlich beobachteten Ort; der allgemeine Abwesenheitsort lautet `underway`. Ortsnamen und Gruppen haben keine fest programmierte Sonderwirkung auf ROOMMATE.

## 6. Telefonquellen

### 6.1 Aggregation mehrerer Haussensoren

`phoneProxies` enthält die einzelnen PRESENCE-Geräte des Telefons. Ein gesunder positiver Sensor genügt für Anwesenheit. Für Abwesenheit müssen alle konfigurierten Sensoren gesund und negativ sein. Unknown, disabled oder ein erkennbarer Sensorfehler zählen nicht als negatives Messergebnis.

Ein Raumwechsel kann einen Sensor verlieren und einen anderen gewinnen; mehrere Sensoren dürfen gleichzeitig positiv sein. Eine kurze Empfangslücke hält Anwesenheit als `present/handover`. Rückkehr eines Signals innerhalb dieser Phase ist keine neue Heimkehr. Die Entfernungssperre berücksichtigt diese gehaltene Anwesenheit ebenfalls.

`GP_PhoneSamples` liest die tatsächlichen Quellen. Pro Bewohner und Timerlauf teilen sich fällige Produktions- und Live-Debug-Abfragen denselben unveränderlichen Eingangsschnappschuss; simulierte Telefonwerte bleiben davon getrennt. `GP_PhoneEvidence` prüft Gesundheit, Zeitstempel, Quellenvertrag und Reihenfolge in einem Durchlauf und ermittelt die benötigten Zeitgrenzen ohne zusätzliche Wertelisten oder Sortierungen. `GP_Phone` führt daraus die je Kontext unabhängige Anwesenheitskontinuität, Übergangslücke und Abwesenheitsfrist. Nur der geordnete Reisekern in `GP_ProcessPhone` entscheidet über Status, Widerruf und Rückkehr; die Quellenabfrage selbst erteilt keine Reiseberechtigung.

### 6.2 Messvertrag

| `phoneSignalMode` | Positiver Wert | Negativer Wert |
|---|---|---|
| `state` | Bleibt bis zum Zustandswechsel oder erkennbaren Fehler gültig | Alle gesunden negativen Zustände müssen über `phone_absence_window` bestehen; erneute identische Meldungen sind nicht erforderlich |
| `measurement` | Benötigt periodisch erneuerte Messungen und gültige Messzeit | Benötigt frische Messungen aller Sensoren und erneute Messungen innerhalb der Qualifikation |

`state` ist der Standard für zustandsmeldende Sensoren. Es kann einen still ausgefallenen Sensor mit unverändertem gesundem Zustand nicht selbst erkennen; die Quelle muss Fehler kenntlich machen. `measurement` ist nur für Sensoren geeignet, die ihren unveränderten Zustand tatsächlich regelmäßig bestätigen. Reines Polling durch GeoPresence erzeugt keine neue Messzeit.

Die Standarddauer für qualifizierte Abwesenheit ist 180 Sekunden. Neue Geo-Positionsbeobachtungen setzen eine zeitliche Grenze: Alte negative Telefonwerte dürfen eine frisch bestätigte Heimkehr oder Annäherung nicht wieder zu `away` machen. Eine Heimkehr beendet die vorherige Negativqualifikation.

Ein neuer gültiger Home-Austritt beginnt über `GP_LeaveHome` eine neue vollständige Frist. Im Zustandsmodus dürfen die negativen Zustände schon vor diesem Austritt beobachtet worden sein; ihre weiterhin gültige Kontinuität wird ab der nächsten fälligen Abfrage neu bestätigt. Bereits vor dem Austritt verstrichene Fristen werden nicht übernommen. Ausschließlich vor dem Sitzungsbeginn liegende Negativwerte erzeugen weiterhin keinen Öffnungsnachweis. Im Messmodus müssen alle Quellen nach dem Austritt neue Messungen liefern und innerhalb der Frist erneuert werden. Ein Quellenfehler unterbricht die Frist; Wiederverbindung allein macht eine entwertete alte Messung nicht wieder gültig.

Ein internes `phone_absent` behält die tatsächliche Sensorzeit in `time`, den Fristbeginn in `negative_wall` und `negative_since` sowie den frühesten fachlichen Abschluss in `qualified_at` und `qualified_mono`. Im Messmodus enthält `negative_first` nur die Quellen, deren erste erforderliche Erneuerung noch fehlt. Sobald eine solche Erneuerung akzeptiert ist, entfällt der Quelleneintrag; `negative_renewed_at` und `negative_renewed_mono` halten die spätesten dafür benötigten Zeiten auf beiden Achsen. Weitere identische Messungen bereits erneuerter Quellen verschieben diese Grenzen nicht. Der Abschluss ist das spätere Datum aus vollständigem Fristende und tatsächlich benötigten Erneuerungen. Im Zustandsmodus genügt das vollständige Fristende ohne Erneuerungsnachweis. Quellenfehler oder ungültige Messfrische setzen die laufende Qualifikation samt Erneuerungsdaten zurück.

`GP_Phone` erzeugt vollständige interne Ereignisse. Alle Telefonereignisse enthalten `generation`; jeder Abwesenheitsabschluss enthält außerdem die genannten Frist- und Abschlussfelder. `GP_ProcessPhone` prüft die Generationsgleichheit unmittelbar und verwendet die vorhandenen Pflichtfelder ohne Ersatzberechnungen oder erneute Abschlusszuweisungen. Das gilt für Produktion, Live-Debug und simulierte Quellen. Der Sortierer des gemischten Geo-/Telefonbündels verwendet weiterhin `qualified_at` oder `time`, da ausschließlich Abwesenheitsabschlüsse das erste Feld besitzen.

Die nachträgliche Abfrage verschiebt diese Grenzen nicht auf ihre eigene Zeit. Fristbeginn, Abschluss und Sensorzeit werden getrennt berücksichtigt. Die Position wird durch einen Abwesenheitsabschluss höchstens bis zum früheren Datum aus tatsächlicher Sensorzeit und Abschluss weitergeführt; eine spätere zusätzliche Negativmessung verdrängt deshalb keine gültige Rückkehr zwischen Fristende und Poll. Eine gewöhnliche nahe Zwischenposition ohne Heimkehr oder Annäherung entwertet die Kontinuität nicht; ältere gehaltene Werte setzen die bekannte Position auch beim Abschluss nicht zurück. Die Qualifikationsgeneration sperrt alte Ereignisse nach Heimkehr, neuem Home-Austritt oder anderem fachlichen Widerruf.

Ein gesammelter Abschluss bleibt bis zur geordneten Verarbeitung ausschließlich im vorhandenen begrenzten Telefonpuffer `queued_phones` erreichbar. Eine neu akzeptierte positive Quellzeit vor seinem Abschluss markiert genau diesen Datensatz als `revoked`; weitere betroffene Abschlüsse im Puffer werden ebenfalls entwertet. Eine tatsächliche Rückkehr ab dem Abschluss lässt dessen vorher gültigen Nachweis dagegen bestehen. Dafür wird die früheste neu akzeptierte positive Zeit aller Quellen berücksichtigt. Falls sie vor der gewählten Rückkehrzeit liegt, bleibt sie im Ereignis als `positive_time` erhalten. `qualified` verhindert weitere Emissionen desselben Abschlusses. Ein zusätzliches Aufbewahrungsfeld oder eine Kopie des Abschlussdatensatzes ist nicht erforderlich.

Bei weiter gültiger Negativlage beendet `qualified` den Telefonpoll vor einer erneuten Frist- und Erneuerungsrechnung. Quellenprüfung und `negative_after`-Prüfung finden davor weiterhin statt. Ein Sensorfehler oder eine neue fachliche Grenze löscht die Qualifikation; danach sind wieder gültige neue Quellenwerte und die vollständige neue Frist erforderlich.

Bestätigt dieser Abschluss einen unbestätigten Home-Abgang, referenziert die Reise denselben Datensatz unter `phone_qualification`. Dessen absolute und monotone Grenze gelten danach für jede Rückkehrprüfung und für ausstehende Ankunftsaktionen, unabhängig von der späteren Bündelzuordnung. Nach der Pufferentnahme bleibt der fachlich benötigte Nachweis an der Reise beziehungsweise der abgeschlossenen Reise erreichbar; `GP_ProcessPhone` prüft spätere positive Gegenbeweise direkt dagegen. Die Referenz und die ursprünglichen monotonen Werte werden nicht im Checkpoint gespeichert.

Der `revoked`-Marker wird ausschließlich an noch gepufferten Abschlüssen gesetzt und vor deren Übernahme geprüft. Ein erfolgreich übernommener Nachweis befindet sich nicht mehr im Telefonpuffer. Spätere Gegenbeweise widerrufen Reise und Ausgaben über den Reisekern; Prüfungen eines nachträglich gesetzten Markers an `phone_qualification` sind daher nicht erforderlich. Die absoluten und monotonen Abschlussgrenzen sowie die aktuellen Freigabeprüfungen vor dem Geräteaufruf bleiben wirksam.

Gültige lokale Telefonanwesenheit kann eine bestehende Reise und ihre wartenden Ausgaben auch nach Ablauf von `action_max_age` widerrufen. Dafür werden Freigabenummer, Reise-, Bewegungs- und Ankunftsnachweise gemeinsam entwertet. Eine jüngere bekannte Position wird nicht zurückgesetzt; ohne frische Rückkehr entstehen keine Ankunftsaktionen. Die Statusübernahme verwendet wie eine bestätigte Rückkehr das gemeinsame `GP_Home` und entfernt damit unvereinbare entfernte Mitgliedschaften, ohne Ankunftsregeln für die widerrufene Reise auszuwerten. Das gemeinsame Veto `GP_PhoneVeto` berücksichtigt gehaltene Anwesenheit und kurze Übergangslücken sowohl vor einem Geo-Abgang als auch bei späterer Verarbeitung widersprechender Telefonanwesenheit. Eine ältere positive Beobachtung vor einem noch unbestätigten Home-Austritt lässt dessen Verdacht bestehen; ein dadurch widerlegter Abwesenheitsabschluss wird dennoch entwertet. Eine frische tatsächliche Telefon-Rückkehr nach gültigem Abschluss behält den normalen Öffnungsvertrag.

Im aktuellen Telefonzweig wird zuerst nach der Beobachtungszeit unterschieden: Vor dem maßgeblichen Abgang entscheidet ausschließlich das bereits berechnete Anwesenheitsveto. Ab dem Abgang gelten die bisherigen Gründe wie fehlende Bestätigung, Frische, Mindestabwesenheit und kontinuierliche Anwesenheit mit passendem Positionsbezug. Die unabhängigen Widerrufsgründe für wiederhergestellte Reisen und widerlegte Telefonqualifikationen bleiben davor wirksam. Vor dem Abgang wird keine entscheidungsirrelevante Abwesenheitsdauer berechnet.

Für die Telefon-Rückkehr einer laufenden Reise ermittelt die Quellenprüfung die früheste neu akzeptierte positive Beobachtung ab dem maßgeblichen Abgang. `GP_DepartureTime` bestimmt diese Grenze gemeinsam für Quellenprüfung und Reisekern aus Abwesenheitsnachweis beziehungsweise Reisestart und einem gegebenenfalls späteren Home-Austritt. Die Quellenprüfung verwendet dafür ausschließlich `trip`. Ohne laufende Reise wird die jüngste gültige positive Zeit für die reine Statusführung gewählt, auch wenn ein abgeschlossener Nachweis unter `last_trip` erhalten ist. Eine gleichzeitig ältere positive Beobachtung kann dadurch eine aktuelle Anwesenheit nach einer neueren Zwischenposition oder bei `phone_only` nicht unterdrücken. Es entsteht keine neue Reiseberechtigung. Fehlt bei laufender Reise eine neue positive Beobachtung ab ihrer Grenze, bleibt ebenfalls die jüngste gültige positive Zeit für die bisherigen Status- und Anwesenheitsveto-Regeln maßgeblich. Die jüngste gültige positive Quellzeit bleibt unabhängig davon in `phone.latest` sichtbar; sie erneuert nicht das Alter einer früheren reisebezogenen Rückkehr.

Der abgeschlossene Nachweis bleibt für die Widerrufsprüfung in `GP_ProcessPhone` und die Freigabe ausstehender Ausgaben in `GP_OutputReady` erhalten. Ein späterer reiner Statuswechsel verändert weder seine Reise-ID noch die ursprünglichen Abwesenheitszeiten oder die eigenen Ereignisse und Fristen bereits geplanter Ausgaben. Die Entscheidung über neue Ankunftsaktionen verlangt weiterhin eine laufende bestätigte Reise. Ein weiterer Abwesenheits-/Anwesenheitszyklus ohne neuen Ausflug kann den abgeschlossenen Nachweis deshalb nicht erneut zum Öffnen verwenden.

Die gewählte Rückkehrzeit steht unmittelbar in `phone_present.time` beziehungsweise `phone_snapshot.time`. Reihenfolge, Frische, Mindestabwesenheit, Ereignisschlüssel und späteres Ausgabebudget verwenden dadurch denselben ursprünglichen Nachweis. Eine gleichzeitig jüngere positive Quelle darf weder eine bereits zu alte Rückkehr frisch machen noch eine kurze Rückkehr künstlich hinter die Mindestabwesenheit verschieben. Eine relevante Rückkehr vor Mindestabwesenheit widerruft die alte Reise bereits vor dem Rücksprung für ältere Positionen; sie kann dadurch auch eine wartende neuere Home-Ankunft entwerten, ohne deren Position zurückzusetzen. Es werden keine zusätzlichen Telefonereignisse oder Quellenlisten angelegt.

Diese Zeitwahl gilt auch nach Wiederherstellung: Liegt die maßgebliche positive Beobachtung vor oder gleich dem neuen Sitzungsbeginn, entsteht ein `phone_snapshot`, selbst wenn ein anderer Sensor zugleich eine aktuelle positive Meldung liefert. Er kann die ältere übernommene Reise vor einer möglichen Ankunftsaktion widerrufen. Der gleiche Zusammenhang gilt für unabhängig durch Geo bestätigte Reisen ohne Telefon-Abschlussnachweis und für drei oder mehr Sensoren. Ein zusätzlicher historischer Zeitkanal über `snapshot_time` ist nicht erforderlich. Beobachtungen vor einem tatsächlich späteren neuen Ausflug werden nicht als dessen Rückkehr gewählt. Ein historischer Widerruf führt keine Ankunftsaktion aus und überschreibt keine jüngere Position. Telefonereignisse ohne gültige aktuelle Sitzungsgeneration werden verworfen.

## 7. Rückkehr und Bewegungsdaten

### 7.1 Rückkehr bestätigen

Ein gültiger Home-Eintritt nach einem berechtigten, mindestens `minimum_away` langen Ausflug startet eine vorgemerkte Rückkehr. Beide Zeitachsen müssen die Mindestabwesenheit bestätigen. Die Vorgabe beträgt 60 Sekunden; sie ist unabhängig von der Ankunftsfrist.

Bei einer durch Telefonabwesenheit bestätigten Reise müssen die vollständige `phone_absence_window` und der tatsächlich benötigte Abschluss des gebundenen Nachweises bei der Rückkehrbeobachtung und beim monotonen Empfang vergangen sein. Das gemeinsame `GP_AwayLongEnough` prüft dies sowohl vor einer Home-Vormerkung als auch bei den Ankunftsregeln, einschließlich Telefon-Fallback. Dies gilt auch dann, wenn im Messmodus die letzte erforderliche Erneuerung erst nach dem nominellen Fristende eintrifft. Eine spätere Zustellung derselben älteren Rückkehr macht sie nicht berechtigt. Eine Rückkehr nach dem tatsächlichen Abschluss bleibt dagegen gültig, auch wenn erst der nächste Poll ihn auswertet. Ein eigenständig bestätigter Geo-Ausflug hängt weiterhin nicht von einer zusätzlichen Telefonqualifikation ab; bei `phone_only` bleibt ein gültiger positiver Sensor für den Status maßgeblich. Der gespeicherte Kennwert für telefonbestätigte Abwesenheit bleibt unverändert; Checkpoints beider bisherigen Versionen benötigen keinen Formatwechsel.

| Frischer Bewegungstyp | Standardfrist ab Empfang des Home-Eintritts |
|---|---|
| `walking` | 60 Sekunden |
| `running` | 30 Sekunden |
| `cycling` | 20 Sekunden |
| `automotive` | 10 Sekunden |
| Unbekannt oder nicht mehr frisch | 60 Sekunden |

Schnelle Bewegungsarten müssen für die verkürzte Frist höchstens `arrival_motion_max_age` alt sein, standardmäßig 30 Sekunden. Ein Fußwegnachweis bleibt bis `motion_max_age`, standardmäßig 180 Sekunden, verwendbar. Ein Home-Austritt während der Wartezeit verwirft die vorgemerkte Rückkehr. Ebenso verhindern jüngere widersprüchliche Abgänge, Geometrieänderungen oder ein verlorener Ausflugsnachweis ihre Ausführung.

Neue lokale Telefonanwesenheit darf die vorgemerkte Rückkehr vorzeitig bestätigen. Im kombinierten Profil kann sie auch einen fehlenden Home-Eintritt ersetzen. Ein unverändert gehaltener positiver Startzustand synchronisiert nur die Anwesenheit. `geofency_only` hat diese Telefonbestätigung nicht.

Eine Wiederholung ohne neue Bewegungsangabe startet die Frist nicht erneut und entfernt keinen Fußwegnachweis. Neue ausdrückliche Bewegungsdaten können die vorgemerkte Frist anpassen. Bei der bestätigten Rückkehr werden Status und Regeln ausgewertet; die konkrete Ausgabe erfolgt erst nach allen weiteren Prüfungen.

### 7.2 Fahrzeugfilter

`arrivalFilter vehicle` verwendet den Bewegungskontext des aktuellen Ankunftsabschnitts. Ein frischer `automotive`-Nachweis qualifiziert; kurze Schritte nach dem Parken heben diesen nicht sofort auf. Ohne solchen Nachweis schließt frisches walking, running oder cycling eine Fahrzeugankunft aus. Fehlen verwendbare Bewegungsdaten, darf ein bestätigter Fernausflug als Ersatznachweis dienen.

Die Entscheidung wird bei vorgemerkter Rückkehr festgehalten. Das Ablaufen eines Fußwegnachweises während der Wartezeit darf ihn nicht nachträglich in eine Garagenberechtigung umwandeln. Das gilt auch bei einem verspäteten Austritt vor dem weiterhin gültigen Home-Eintritt und bei `motion_max_age` unterhalb der Home-Frist, etwa 20 Sekunden. Muss ein früherer Automotive-Nachweis entfernt werden, wird die Wirkung der verbliebenen Bewegung anhand ihres ursprünglichen Bewertungszeitpunkts bestimmt. Neue ausdrückliche Bewegungsdaten werden dagegen zur aktuellen Verarbeitungszeit bewertet und können die Entscheidung ändern. Dieser Bewertungsbezug erneuert weder Beobachtungszeiten noch das Aktionsbudget. Der Filter ist eine Regelbedingung und kann auch für Licht oder Nachricht eingesetzt werden; er ist kein Aktortyp.

## 8. Ortsgruppen und Regeln

### 8.1 Gruppenmitgliedschaft

Ein Ort kann mit `groups Arbeitsorte,Sport` mehreren Gruppen angehören. Namen beginnen mit einem Buchstaben und umfassen höchstens 64 Zeichen aus Buchstaben, Ziffern, Punkt, Unterstrich und Bindestrich. Pro Ort sind höchstens 16 eindeutige Gruppennamen erlaubt. Groß- und Kleinschreibung unterscheiden Gruppen.

Gruppenmitgliedschaft wird pro Person aus explizit akzeptierten Ein-/Austritten geführt und von der geometrisch abgeleiteten Ortsanzeige getrennt. Erster Eintritt in ein Mitglied erzeugt einen Gruppeneintritt; der letzte Austritt aus allen ausdrücklich als betreten bekannten Mitgliedern erzeugt einen Gruppenaustritt. Nicht beobachtete Mitglieder werden nicht als betreten angenommen; auch ein erster beobachteter Austritt kann damit ein Gruppenaustritt sein, sofern kein anderes Mitglied noch ausdrücklich betreten ist.

Überlappende Gruppenorte erzeugen beim internen Wechsel keinen zweiten Gruppeneintritt und keinen vorzeitigen Gruppenaustritt. Zeitablauf der Anzeige und geometrische Verdrängung erzeugen keine fehlenden Austritte. Bestätigte Heimkehr entfernt geografisch unvereinbare entfernte Mitgliedschaften ohne nachträgliche Austrittsereignisse; Home und überlappende Kreise behalten ihre Mitgliedschaft.

### 8.2 Auslöser und Auswahl

| Regelattribut | Vertrag |
|---|---|
| `residents` | Liste der teilnehmenden resident-Geräte |
| `trigger enter` | Eintritt in einen ausgewählten Ort oder erster Eintritt in eine ausgewählte Gruppe |
| `trigger exit` | Austritt aus einem ausgewählten Ort oder letzter Austritt aus einer ausgewählten Gruppe |
| `trigger arrival` | Bestätigte berechtigte Rückkehr; keine Ortsauswahl |
| `locations` | Explizite Ortsliste; pro ausgewählter Person muss ein passender Ort vorhanden sein |
| `locationGroup` | Eine frei benannte Gruppe statt locations; muss für jede ausgewählte Person existieren |
| `afterExit` | Optional `location:ORTGERAET` oder `group:GRUPPE` |
| `arrivalFilter` | Nur bei arrival: `any` oder `vehicle`; Standard any |
| `action` | Eine vorhandene Aktion desselben Controllers |
| `cooldown` | Mindestabstand erneuter gewöhnlicher Aktionen, Standard 300 Sekunden, je Person und Aktion |
| `enabled` | 1 oder 0; ausgeschaltete Regeln werden nicht ausgeführt |

`locationGroup` ist von FHEMs allgemeinem `group`-Attribut unabhängig. `locations` und `locationGroup` sind Alternativen; eine leere Zusatzbedingung wird durch Löschen von `afterExit` ausgedrückt. Alle gesetzten Filter gelten gemeinsam. Tür- und Garagenaktionen verlangen `arrival`; gewöhnliche Licht- und Nachrichtenaktionen dürfen enter, exit oder arrival verwenden. Ein Home-enter für Licht wartet nicht auf die geschützte Rückkehrbestätigung.

Eine arrival-Regel benötigt auch bei einer Nachricht oder einem Licht einen gültigen Ausflug. Ein erstmaliger Home-Status nach Modulstart reicht dafür nicht. Regeln gleichen gemeinsam verwendete Gruppen über die jeweilige Person ab; ein Austritt einer anderen Person kann keine Bedingung erfüllen.

### 8.3 Vorheriger Austritt als Bedingung

`afterExit` akzeptiert ausschließlich einen ausdrücklich beobachteten Austritt derselben Person innerhalb des aktuellen Ausflugs. Seine Beobachtungszeit muss strikt vor dem auslösenden Ereignis liegen. Bei Wiederherstellung eines gültigen Ausflugs bleiben dessen explizite Austritte erhalten. Gleicher Zeitstempel, reine Entfernungsableitung oder eine Beobachtung aus einem abgeschlossenen früheren Ausflug genügen nicht.

Erneuter Eintritt in den referenzierten Ort oder ein Mitglied der referenzierten Gruppe widerruft den Nachweis. Bestätigte Rückkehr verbraucht den Ausflug; Reset und widersprechende lokale Anwesenheit können ihn verwerfen. Bereits geplante Aktionen prüfen den Nachweis vor der Ausgabe erneut, sodass eine spätere Gegenbeobachtung innerhalb desselben Verarbeitungsbündels die Ausgabe noch verhindern kann.

Beispiel: `trigger exit`, `locations Geo.PERSON.RUECKWEG` und `afterExit group:Arbeitsorte` verlangen einen früheren expliziten Austritt aus der Gruppe Arbeitsorte auf derselben Reise. Der morgendliche Hinweg erfüllt diese Bedingung nicht. Ein fehlender Arbeitsort-Austritt führt zu keiner Rückweg-Nachricht, auch wenn der entfernte Arbeitsort zuvor eine Öffnungsberechtigung begründet hat.

### 8.4 Deduplizierung

Geschützte Öffnungen werden je Ausflug, Aktortyp und Ziel nur einmal angefordert. Gewöhnliche Aktionen werden je Aktion, Auslöser, Besuch und Orts-/Gruppenauswahl dedupliziert; Bedingungen mit vorherigem Austritt verwenden den laufenden Ausflug als Besuchsgrenze. Zusätzlich gilt der Cooldown je Person und Aktion. Zwei absichtlich verschiedene Aktionen können unabhängig reagieren.

`action_visits` speichert pro gewöhnlicher Aktion, Auslöser und Auswahl nur den zuletzt verbrauchten Orts- beziehungsweise Gruppenbesuch. Eine neue verbrauchte Besuchsnummer ersetzt die vorige; eine Liste alter Besuche entfällt. Die Auswahl unterscheidet `location:...` und `group:...`. Ankunftsaktionen und Regeln mit `afterExit` führen ihren Verbrauch dagegen direkt in `trip.actions`. Dadurch können gewöhnliche Besuche und reisegebundene Regeln derselben Aktion und Auswahl ihre Verbrauchsstände nicht gegenseitig überschreiben. Der Abschluss oder Widerruf des Ausflugs beendet diesen Reiseverbrauch; eine gewöhnliche Austrittsregel benötigt weiterhin einen neuen beobachteten Besuch und wird nicht allein durch einen neuen Ausflug erneut freigegeben.

`trip.actions` enthält kurze Schlüssel je Öffnungstyp und Ziel beziehungsweise je gewöhnlicher Reiseaktion, Auslöser und Auswahl. Die Reise-ID wird nicht pro Eintrag wiederholt. `action_last` hält den letzten Verbrauchszeitpunkt je gewöhnlicher Aktion für den gemeinsamen Cooldown; ein durch Cooldown unterdrückter Kandidat wird nicht verbraucht. Die Anzahl der Verbrauchseinträge hängt von den konfigurierten Aktions-/Auswahlkombinationen ab, nicht von der Zahl vergangener Besuche. Produktions- und Debug-Zustände sowie verschiedene Personen besitzen weiterhin eigene veränderbare Verbrauchsstände.

## 9. Aktionen und Rückmeldungen

### 9.1 Vorhandene Adapter

| Aktortyp | Parameter | Ausführungsvertrag |
|---|---|---|
| `switch_on` | target, command | Ausschließlich `set <target> on`; keine freie Befehlskette |
| `notify` | message, channel, priority | Vorhandene Funktion `pushMsg(channel, priority, message)`; `%resident%` wird durch das Personenlabel ersetzt |
| `door_open` | target, command, contact, feedbackDevice | Ausschließlich `lock unlocked`; Türkontakt und `pulse_state` der Türsteuerung prüfen |
| `garage_open` | target, command, stateDevice, upperContact, lowerContact | Ausschließlich `on`; Torzustand und beide Endkontakte prüfen |

Die Aktortypen haben bewusst unterschiedliche Rückmeldeverträge. Es gibt keinen universellen frei programmierbaren Aktoradapter. `validate` prüft Pflichtangaben, Geräteexistenz, sichere Befehle und Konflikte gemeinsam verwendeter Ziele. Der `notify`-Adapter setzt eine geladene `pushMsg`-Funktion voraus.

`allowDoor` und `allowGarage` sind je Person standardmäßig 0 und werden vor geschützten Aktionen geprüft. Eine garage_open-Regel benötigt zusätzlich `arrivalFilter vehicle`. Eine gewöhnliche switch_on-Aktion darf kein zugleich als Tür-/Garagenziel verwendetes Gerät ansteuern.

### 9.2 Aktorvertrag und Reservierung

Vor einem Auftrag werden bekannte, widerspruchsfreie Positionen unter dem Aktionsattribut `positionSignalMode` verlangt. Standard `state` behandelt Kontakt- und Positionswerte als gehaltene Zustände: Eine unveränderte, auch aus fhem.save übernommene Position bleibt bis zu einer Änderung oder erkennbaren Störung gültig. Der Quellenvertrag verlangt die Meldung von Zustandswechseln und einen Abgleich nach Ausfällen. Deaktivierte Quellen, gemeldete Verbindungsfehler des Geräts oder seines IO-Geräts, tote Sensoren, zukünftige Zeitstempel und unbekannte oder widersprüchliche Positionen sperren die Ausgabe. Ein vollständig stummer Ausfall ist ohne zusätzlichen Quellenhinweis nicht erkennbar. `measurement` verlangt stattdessen für alle Positionen eine Aktualisierung nach dem Sitzungsbeginn.

Eine bereits offene oder gerade öffnende Tür beziehungsweise Garage bekommt keinen redundanten Impuls. Nach einem Auftrag reserviert der Controller das Ziel bis Bestätigung oder `actor_timeout`. Die Abschlussprüfung verlangt in beiden Positionsmodi eine neue Rückmeldung aus dem laufenden Auftrag; gespeicherte Abschlusswerte werden nicht als neue Bestätigung wiederverwendet.

Türkontakt: `open` bedeutet bereits offen, `closed` erlaubt die Prüfung eines neuen Auftrags. `feedbackDevice:pulse_state=pending` bedeutet laufender Impuls; ein nach Auftragsbeginn beobachtetes `confirmed` bestätigt den Abschluss. Dieses Abschlussereignis bleibt gespeichert, auch wenn das Reading vor dem nächsten Timer auf `idle` wechselt.

Garagenvertrag: `stateDevice:state=off`, oberer Kontakt `open` und unterer Kontakt `closed` bedeuten geschlossen. `on`, oberer Kontakt `closed` und unterer Kontakt `open` bedeuten offen. Andere Kombinationen erlauben keine ungesicherte neue Öffnung.

FHEM-Reading-Zeitstempel haben Sekundengenauigkeit, Auftragszeiten können Sekundenbruchteile enthalten. Eine Bestätigung in derselben Sekunde ist zulässig, wenn zusätzlich eine Änderung nach Reservierung oder ein beobachtetes Rückmeldeereignis belegt ist. Eine alte Bestätigung aus einem vorherigen Auftrag darf dafür nicht wiederverwendet werden.

### 9.3 Mehrere Bewohner und Fehler

Gleichzeitige berechtigte Ankünfte können denselben laufenden Zielauftrag teilen. Nach bestätigtem Abschluss wird die Reservierung freigegeben; eine spätere eigenständige Ankunft kann einen neuen Auftrag erhalten. Timeout ergibt `uncertain`; GeoPresence sendet keinen blinden Wiederholungsimpuls.

Produktive Aufträge werden auch bei anschließendem Debug weiterhin auf Abschluss überwacht. Debug-Aufträge erzeugen keine Reservierung eines realen Aktors. Die Türsteuerung entscheidet über Impulsdauer und Mechanik; GeoPresence setzt nicht voraus, dass jede Tür nach einem Öffnungsimpuls dauerhaft entriegelt bleibt.

### 9.4 Abschließende Freigabe

Tür, Garage, Licht und Benachrichtigung verwenden dieselbe abschließende Freigabe. Ein Plan enthält die Regel, den Auslöser, seine Originalbeobachtung, gemeinsam verwendete Aktorparameter, gegebenenfalls Reise und Austrittsnachweis sowie die Freigabenummer und monotone Ablaufgrenze. Die Regeln erfassen den Verbrauch weiterhin einmal vor der Ausgabe; die gemeinsame Planerzeugung ersetzt getrennte Konstruktionen für Öffnungs- und gewöhnliche Aktionen.

Die Ausgabe verlangt den weiterhin aktuellen produktiven beziehungsweise simulierten Zustand und den passenden Modus. Relevante Konfigurationsänderungen setzen die betroffenen Zustände zurück oder widerrufen ihre Freigabenummer anhand der bereits bekannten Geräteabhängigkeiten. Änderungen an anderen Personen lassen einen laufenden, weiterhin gültigen Plan bestehen, auch wenn der gemeinsame Konfigurationscache dadurch erneuert werden muss. Die Abschlussprüfung baut keinen Katalog auf und wiederholt keine statische Vollvalidierung. Sie prüft aktuelle Betriebsfehler, Freigabenummer, Sitzung, bereits verarbeitete Gegenbeobachtungen, erforderliche Austrittsnachweise und beide aktuellen Uhren. Ankunftsaktionen bleiben an den bestätigten Abschluss derselben berechtigten Reise gebunden; Tür und Garage prüfen zusätzlich die persönliche Berechtigung.

Die Attributrelevanz wird vor dem Widerruf bestimmt; Alias- und Diagnoseänderungen entziehen keine fachliche Berechtigung. Jeder Bewohner ist im Abhängigkeitsindex zusätzlich seinem Controller zugeordnet. Eine bereits übernommene fachliche Controlleränderung erreicht damit alle laufenden Pläne, auch nach einer Sammellöschung und bei kaltem Cache.

Bei Musterlöschungen werden Anzeigeattribute anhand der aufgelösten Namen erkannt. `deleteattr rr_PERSON ^alias$` erneuert deshalb nur den zwischengespeicherten Nachrichtenbezeichner. Ein Muster, das zusätzlich `rr_locationUnderway` entfernt, widerruft weiterhin die abhängigen Ausgaben.

Manuelles ROOMMATE `home`, Geometriewiderruf, Uhrsprung, widersprüchliche Beobachtungen und Telefon-Warteschlangenüberlauf entwerten ausstehende Ausgaben durch eine neue Freigabenummer. Das gilt auch dann, wenn eine Befehlsliste bereits lokal aus der Warteliste entnommen wurde. Ein manueller Home-Wechsel innerhalb des Türbefehls stoppt deshalb den anschließenden Garagenplan, obwohl der Bewohner bereits die Phase home hatte. Ein veralteter Gesamtvorgang bricht die restliche Liste ab; einzelne abgelaufene Pläne können keine noch gültigen anderen Pläne sperren.

Die vier festen Ausgabepfade bleiben erhalten. Der Öffnungsadapter prüft die Aktorposition, reserviert das Ziel und registriert seine Rückmeldungen vor `CommandSet`. Nach dieser Vorbereitung erfolgt die Abschlussfreigabe erneut; eine noch nicht ausgegebene, dabei abgelehnte Reservierung wird entfernt. Auftragsbeginn und Timeout verwenden die aktuelle Zeit der tatsächlichen Ausgabe. Checkpoint-Verbrauch wird weiterhin vor produktiven Adapteraufrufen gespeichert. Bereits ausgegebene Aufträge werden bei einem späteren Widerruf weiter auf Rückmeldung überwacht.

Freigabenummern und monotone Ablaufgrenzen gehören nur zur laufenden Sitzung und werden nicht als ausführbare Aufträge im Checkpoint gespeichert. Debug prüft denselben Freigabevertrag, schreibt jedoch ausschließlich den Simulationsplan und ruft keinen produktiven Adapter auf.

## 10. Simulation, Diagnose und Oberfläche

### 10.1 Getrennte Zustände

Produktiv- und Debug-Bereich besitzen getrennte Personenverläufe, Geometrien, Deduplizierung und Aktionspläne. Controller-Debug unterdrückt alle neuen produktiven Aktionen. Unter aktivem Controller kann eine einzelne Person `set Geo.PERSON mode debug` verwenden. learning ist ein eigener Zustand ohne Reiseauswertung und hat unter aktivem oder debug-Controller Vorrang vor der Simulation. `isTest=true` bleibt außerhalb des expliziten Lernmodus eine Simulation.

Debug-Telefonquellen lassen sich im kombinierten oder telefonbasierten Profil zwischen live und simulated umschalten. Geofency-only verwendet keine Telefonquelle; telefonbezogene Debug-Befehle werden dort zurückgewiesen. `debugAdvance` dient kontrollierter Simulation und ändert keine produktiven Uhren. Das externe Testprogramm wartet in realer Zeit.

`debugReset Geo.PERSON keepGeometry` trennt wiederverwendbare Geometrie von Reisebeobachtungen: Koordinaten, Radius, Identität, Zeitstempel und Konfliktmarkierungen bleiben im Debug-Speicher, während Reise, Aufenthalte, Rückkehrvormerkung, Aktionspläne, Deduplizierung, Telefon-Simulation und eigene wartende Debug-Ereignisse verworfen werden. Es entstehen weder produktive Readings noch Öffnungsberechtigungen. Ohne `keepGeometry` verwirft der Reset auch die Debug-Geometrie. Die Erhaltungsoption ist nach einer mit `debugAdvance` verschobenen Uhr nicht zulässig; der Wechsel zurück zu echten Zeitstempeln erfordert einen vollständigen Reset.

Die Testanwendung prüft vor dem ersten Reset die Modulunterstützung über `debug_reset_keep_geometry` in `explain PERSON debug format=json` und verwendet die Erhaltungsoption vor Testfällen sowie bei normalem Abschluss und abgefangenem Fehler oder Abbruch. Damit können getrennte Aufrufe dieselben Ortsdaten benutzen, ohne frühere Reisen fortzusetzen. Modus- oder Konfigurationswechsel, Reload und Neustart behalten ihre eigene Rücksetzsemantik; flüchtige Debug-Geometrie ist kein dauerhafter Datenspeicher.

### 10.2 Zwei Logausgaben

Das normale FHEM-Log enthält kurze englische Betriebsereignisse: betretene/verlassene Orte, angeforderte Geräteaktionen, Nachrichtenaufträge und relevante Betriebsfehler. Es enthält keine umfangreichen JSON-Entscheidungsdatensätze. Die allgemeinen FHEM-Logstufen bestimmen dessen Sichtbarkeit.

Die ausführliche Diagnose schreibt GeoPresence ausschließlich in das ausdrücklich konfigurierte `logFile`. Ohne dieses Attribut wird keine Diagnosedatei geschrieben; die Handbuchbeispiele verwenden eine monatliche Datei im Logverzeichnis. `debugLog auto` aktiviert sie bei effektivem Debug und Lernen, `1` auch im Produktivbetrieb und `0` unterdrückt sie. Strukturierte Daten enthalten ausgewählte Ereignis-, Zeit-, Regel- und Entscheidungsfelder, keine Passwörter oder vollständigen HTTP-Anfragen. `logStatus` zeigt Pfad, Aktivierung und Schreibfehler.

### 10.3 Bedienoberfläche

FHEMWEB zeigt Attribute passend zu Gerätetyp, Aktortyp, Quellenprofil und Regelauslöser. Feste Werte sind Auswahllisten; Referenzen verwenden vorhandene Geräte und Gruppen. Standardattribute von FHEM bleiben verfügbar. Veraltete referenzierte Namen werden angezeigt und bei Validierung beanstandet; die Oberfläche ersetzt sie nicht heimlich.

Der Gerätestatus STATE einer Person zeigt ihren wirksamen Betriebsmodus disabled, learning, debug oder active. Er entspricht effectiveMode und berücksichtigt die Vorrangregeln des Controllers. Neu angelegte Personen beginnen mit disabled; Bestätigung und Ablauf des Lernens führen ebenfalls zu disabled. Die persönliche Modusvorgabe bleibt im Reading mode, der Grund im Reading modeReason. Diese Anzeige ist von der Anwesenheit des verknüpften ROOMMATE getrennt und erteilt keine Aktionsberechtigung.

Die Abfrage `set <controller> ?` liefert FHEMs standardisierte Liste einzelner Befehle mit ihren Eingabefeldern. Bewohner und feste Parameter werden in nativen Auswahllisten angeboten; `debugAdvance` verwendet ein Textfeld für Bewohner und Sekunden. Das Ermitteln der Befehlsliste verändert keine Reisen, Geometrie oder Lernfenster. Ein Aufruf ohne Bewohner erklärt die benötigten Parameter und führt nichts aus; die vorhandenen Modus- und Quellenprüfungen gelten auch für die Oberfläche.

Englische Modulhilfe und kontextbezogene Attributhilfe gehören zur Moduldatei. Menschliche `get`-Ausgaben verwenden in FHEMWEB gegliederte HTML-Berichte und in Telnet Großbuchstabenüberschriften, Trennlinien, ausgerichtete Werte und eingerückte Blöcke. Jede Eigenschaft steht in einer eigenen Zeile; Werte und Erläuterungen enthalten keine vom Renderer eingefügten Zeilenumbrüche. Kennungen und kopierbare Befehle werden nicht gekürzt.

`explain PERSON` und `explain PERSON prod` zeigen immer den vollständigen produktiven Bericht, unabhängig vom aktuellen Betriebsmodus. `explain PERSON debug` zeigt den vollständigen Simulationsbericht. Auf einem Bewohnergerät kann der Personenname entfallen. Der Kopf markiert den Zustandsbereich mit DEBUG oder PRODUCTION; Status nennt den tatsächlichen Modus separat. Disabled, pausierte Produktivverarbeitung und nicht initialisierte Zustände werden ausdrücklich kenntlich gemacht. Die Abfrage verändert keinen Modus, erzeugt keine Laufzeitreise und initialisiert keinen Simulationszustand.

FHEMWEB erhält die registrierten Bewohner samt prod/debug-Auswahl über die native Get-Befehlsliste. Auf dem Controller ist die erste angebotene Person mit der produktiven Abfrage vorbelegt; auf dem Bewohnergerät stehen prod und debug zur Auswahl. Alle Bereiche sind im Bericht enthalten; untere HTML-Bereiche bleiben einklappbar. Regeln, Quellen, Ortsgeometrie, Rückmeldungen, jüngste Entscheidungen und technische Daten werden in Telnet vollständig ausgegeben. Produktive Aktorvorgänge, die eine Simulation noch blockieren, bleiben ausdrücklich als produktiv markiert.

Recent decisions steht in beiden Berichtsansichten unmittelbar hinter Status. In HTML ist dieser Bereich zunächst geöffnet und bleibt über seine Überschrift einklappbar; Arrival actions folgt zunächst geschlossen. Beide verwenden native details/summary-Elemente. Telnet übernimmt die Reihenfolge und gibt weiterhin alle Inhalte vollständig aus; die JSON-Datenstruktur bleibt unverändert.

Entscheidungen während der Verarbeitung einer Beobachtung speichern deren Quelle und gegebenenfalls den Ort. Dieser Diagnosekontext ist auf die aktuelle Verarbeitung beschränkt und darf nicht auf spätere Timer- oder Aktorentscheidungen übertragen werden. Die Darstellung von Rule / source verwendet die gespeicherte Regel, den Ort, die Quelle oder das Aktor-Ziel; fehlen diese Informationen, erscheint Not recorded. Das Lesen ergänzt keine Felder im gespeicherten Verlauf.

`format=json` liefert den vollständigen gewählten Bereich in `state` und `geometry` sowie `view` mit debug oder production, wirksamen `mode`, eigenen `requested_mode`, `controller_mode`, `mode_reason`, `initialized`, Geometrieprüfungen, Fehler und ausstehende Aktoren. Die Debug-Ansicht ergänzt `debug_ready` und `debug_blockers`; Modulmerkmale `test_webhook_isolation` und `debug_reset_keep_geometry` bleiben verfügbar. Die Testanwendung verlangt ausdrücklich `explain PERSON debug format=json` und prüft die gemeldete Ansicht vor Änderungen. Zur Gegenüberstellung werden beide Ansichten separat abgefragt. Alle Berichte bleiben reine Abfragen; sie verarbeiten keine Ereignisse, bestätigen keine Ankunft und lösen keine Aktionen aus.

## 11. Persistenz und Lebenszyklus

Konfiguration wird mit FHEMs normalem `save` gespeichert. Readings einschließlich produktiver Geometrie werden über den eingerichteten FHEM-statefile-Mechanismus, üblicherweise `fhem.save`, wiederhergestellt. Webhook-Prüfwerte liegen im FHEM-Schlüsselspeicher. GeoPresence besitzt keine zusätzliche SQL-Datenbank und keine eigene dauerhafte Auftragsdatei.

Der FHEM-Rename-Callback läuft nach der Umbenennung und führt eigene `CONTROLLER`-/`PARENT`-Felder samt zugehörigen Elternnamen in `DEF` nach. Der vorhandene Gerätebestand wird dabei verwendet; auch ohne vorbereiteten Bestand reicht eine Suche, deren Ergebnis beim Neuaufbau der internen Indizes weiterverwendet wird. Beim Controller werden Listener und offene Clients kontrolliert geschlossen und im neuen Laufzeitkontext unter dem neuen Namen gebunden. Laufende Aktorreservierungen bleiben für ihre Rückmeldungen erhalten.

Bei Aktions- und Regelumbenennungen wird die betroffene Regel vor dem Lesen und Zerlegen ihrer Bewohnerliste ausgewählt. Beim Personenrename bleibt die vollständige Bewohnerliste für die Auswahl erforderlich. Alle Bewohner einer betroffenen gemeinsamen Regel werden weiterhin übernommen, auch wenn die Regel deaktiviert ist.

Beim Umbenennen einer Person wird ihr Kennwortprüfwert unter den neuen Schlüsselspeichernamen übertragen und der alte Eintrag entfernt. Authentifizierungscaches werden verworfen; ein veralteter Eintrag unter dem neuen Namen wird nicht übernommen. Betroffene Zustände, Queues und Checkpoints werden entwertet, alte Laufzeitnamen entfernt und die Empfänger laufender Aktorrückmeldungen nachgeführt. Bestätigte Lerndaten und das bestehende HTTP-Personenkontingent bleiben erhalten. Ein laufendes Lernen wird beendet. Unbeteiligte Personen behalten ihre Kontexte; ein ungültig gewordener gemeinsamer Regelselektor setzt alle davon betroffenen Personen zurück.

Öffentliche Attributverweise wie `residents`, `action`, `locations`, `afterExit` oder externe Gerätebezüge werden nicht stillschweigend ersetzt. Nicht mehr passende Namen meldet die Validierung; die Referenzen müssen ausdrücklich berichtigt werden. Auch nach einem FHEM-Rename bleiben die GeoPresence-Namensregeln verbindlich. Ein außerhalb dieser Regeln umbenanntes Gerät wird als Konfigurationsfehler gemeldet.

Scheitert die Übertragung der Zugangsdaten, hält `gp_auth_error` eine reparierbare Sperre über Reload und Neustart hinweg fest. Eine Geo-Person wird deaktiviert, die Authentifizierung verwendet keinen möglichen veralteten Zielschlüssel und das Betriebslog nennt die notwendige erneute Kennwortvergabe. Erst ein erfolgreiches `set ... webhookPassword` hebt die Sperre auf. Ein nicht verwendeter Geo-Zugang sperrt keine reine Telefonquelle.

Die ROOMMATE-Statusübergabe prüft Rückgabefehler und Ausnahmen des Geräteaufrufs. Ein Fehler bleibt als `roommate_error` im aktuellen Zustand und als `gp_roommate_error` im Reading sichtbar. Der vorhandene gewünschte Status bleibt bis zum nächsten Timerlauf vorgemerkt. Die Wiederholung erfolgt nur im weiterhin gültigen produktiven Kontext und überschreibt keinen inzwischen neueren Status. Nach Bearbeitung eines Statuswunschs sichert die Freigabeprüfung hinter allen Geräte- und Log-Rückrufen gemeinsam die erneute Vormerkung und die Veröffentlichung ab; die Prüfung vor der Statusbearbeitung bleibt bestehen. Ohne Statusauftrag genügt diese erste Prüfung, weil dazwischen kein Rückruf ausgeführt wird. Ist ROOMMATE bereits im gewünschten Status oder wird die nächste Übergabe angenommen, wird der Fehler gelöscht. Gleiche aufeinanderfolgende Fehler und ihre Behebung werden jeweils nur einmal im Betriebslog gemeldet; die Dateidiagnose enthält die begrenzte Fehlerbeschreibung. Daraus entsteht keine neue Öffnungsberechtigung und kein zusätzlicher Aktorauftrag.

Ein bestätigter, noch nicht abgeschlossener produktiver Ausflug wird im versionierten Reading `gp_trip_checkpoint` als ein zusammengehöriger JSON-Datensatz gespeichert. Er enthält ursprünglichen Beginn und Abwesenheitsnachweis, lokale/ferne Reichweite, beobachtete Orte und Gruppen, explizite Austritte sowie verbrauchte Aktionen und Nachrichten. Zugangsdaten, Aktoraufträge, Ereigniswarteschlangen, Telefonqualifikationstimer und Ankunftswartezeiten werden nicht gespeichert. Die Größe ist auf 64 KiB begrenzt; ein zu großer oder nicht darstellbarer Stand wird als nicht wiederherstellbar markiert. Das Schreiben erfolgt ohne FHEM-Ereignisse oder userReadings-Callbacks; unveränderte Timerläufe serialisieren den Stand nicht erneut.

Ein eigenes Änderungsmerkmal `checkpoint_dirty` ersetzt die Trace-Sequenz als Speicheranlass. Akzeptierte Ortsbeobachtungen, neue Verbrauchsstände, gültige Bewegungsnachträge und die tatsächliche Entfernung gespeicherter Bewegungs- oder Anzeigedaten markieren den Stand zur Speicherung. Identische Wiederholungen, abgewiesene Beobachtungen, Aktorrückmeldungen und reine Diagnoseeinträge erzeugen keinen neuen Checkpoint. Die Speicherfunktion prüft die Reisequalifikation vor dem schnellen Rücksprung unabhängig von diesem Merkmal; ein Widerruf erreicht deshalb auch bei blockierter Ausgabe das Reading. Ein verändertes oder gelöschtes Checkpoint-Reading wird aus dem aktuellen Zustand berichtigt. Nach erfolgreicher Wiederherstellung im aktuellen Format bleibt ein unveränderter Checkpoint einschließlich `saved_at` erhalten.

Das JSON-Format Version 2 speichert aktuelle Verbrauchsstände aus `action_visits`, `action_last` und `trip.actions`; `notify_seen`, `notify_order` und `notify_last` entfallen im neuen Laufzeitzustand und Checkpoint. Bei der Wiederherstellung werden Verbrauchsschlüssel gegen die konfigurierten Regeln geprüft; verbrauchte Besuchsnummern dürfen den gespeicherten aktuellen Besuch nicht überschreiten. Die hierfür benötigten zulässigen Schlüssel werden je Konfiguration einmal aus dem vorhandenen Regelindex abgeleitet und zwischengespeichert.

Schreiber und Leser verwenden dieselben privaten Listen für gemeinsame Reise- und Zustandsfelder. Die Verbrauchsfelder werden für jede Formatversion ausdrücklich ergänzt; der Schreiber übernimmt weiterhin ausschließlich vorhandene Felder. Die gemeinsame Feldauswahl ersetzt keine Pflichtfeld-, Typ- oder Nachweisprüfung.

Gültige Checkpoints der Version 1 werden einmalig übernommen: Nur der aktuelle Verbrauch je Orts-/Gruppenbesuch, der Verbrauch des offenen Ausflugs und benötigte Cooldowns werden in Version 2 übertragen. Frühere Besuchsschlüssel werden verworfen. Derselbe Umstieg verdichtet beim Modulreload einen noch laufenden alten Zustand vor seiner ersten neuen Serialisierung; eine allein wegen alter Historien zu große Laufzeitkopie muss deshalb nicht zunächst als Version 1 geschrieben werden. Bereits gespeicherte Version-1-Datensätze unterliegen weiterhin der 64-KiB-Grenze und allen bisherigen Bindungs-, Struktur- und Zeitprüfungen. Die Umstellung behält Reise-ID, ursprüngliche Abwesenheitszeit und explizite Austritte; sie führt weder historische Aktionen aus noch stellt sie bereits entwertete Reisen wieder her. Nur diese Formatumstellung schreibt einen übernommenen alten Stand einmal neu; spätere unveränderte Timer-, Diagnose- und Wiederherstellungsläufe bleiben ohne erneute Serialisierung.

Nach INITIALIZED oder REREADCFG sowie bei Modulreload wird unter aktiven Modi ein neuer Laufzeitkontext aufgebaut und ein vorhandener qualifizierter Checkpoint geprüft. Version und Struktur, Personen-/Telefon-/ROOMMATE-Bindung einschließlich Kennwortprüfwertbindung, Quellenprofil, Geometrie, Regeln und Aktoradapter müssen passen. Spätere gespeicherte Heimzustände des ROOMMATE oder lokale Telefonanwesenheit widersprechen dem Abwesenheitsnachweis. Zeitstempel müssen plausibel sein; die ursprüngliche Abwesenheitsbestätigung darf höchstens `trip_resume_max_age` alt sein, standardmäßig 172800 Sekunden beziehungsweise 48 Stunden. Speichern oder weitere Neustarts erneuern diesen Nachweis nicht. Ein abgelehnter Checkpoint wird entwertet; reine `absent`- oder `gp_arrival_armed`-Readings ohne vollständigen Checkpoint erzeugen keine Berechtigung.

Ein gültiger Ausflug behält seine Kennung und seinen Ortsverlauf, startet im neuen Kontext als `away` und wartet auf eine neue gültige Home- oder Telefon-Rückkehr. Vorherige monotone Timerwerte werden nicht übernommen; Zeitabstände werden aus den ursprünglichen absoluten Nachweiszeiten auf die neue monotone Uhr abgebildet. Nach einem validierten Checkpoint darf eine neue Geo-Beobachtung unmittelbar nach dem Sitzungsbeginn verarbeitet werden; Ereignisse mit Beobachtungszeit vor oder gleich dem neuen Start bleiben ausgeschlossen. Ohne validierten Checkpoint gilt weiterhin die zusätzliche Geo-Anlaufgrenze durch future_tolerance. Bewegungsabhängige Ankunftsfristen und normale Frischeprüfung bleiben wirksam. Der Start selbst sendet keine Öffnung oder historische Nachricht. `gp_resume_status`, `gp_resume_reason` und der Bereich Restart recovery in explain nennen Übernahme oder Ablehnung.

Bei einem wiederhergestellten telefonbestätigten Ausflug liefert `saved_at` eine konservative zusätzliche Rückkehrgrenze. Sie wird auf die neue monotone Uhr abgebildet; ursprünglicher Abwesenheitsbeginn und volle Mindestfristen bleiben zusätzlich wirksam. Alte Ereignisdatensätze und Ankunftstimer werden dafür nicht übernommen. Neue Rückkehrbeobachtungen müssen ohnehin nach dem neuen Sitzungsbeginn liegen. Eine erst nach der anfänglichen Wiederherstellungsprüfung verfügbare gültige Vorstart-Anwesenheit darf die ältere übernommene Reise weiterhin widerrufen, aber keine Ankunftsaktion ausführen.

`GP_NewState` bildet jede neue Kontextkennung einmalig als Hash aus dem bisherigen Kontextbezug, einem Zufallswert, Prozesskennung sowie absoluter und monotoner Startzeit. Die Kennung hat auch bei langen Gerätenamen eine feste Länge. Neue Reise-IDs bestehen weiterhin aus der Kontextkennung und einem lokalen Zähler; zurückgesetzte Start- und Reisezähler allein erzeugen damit nach einem Prozessneustart keine alten IDs mehr. Produktion und Debug sowie wiederholte Debug-Resets erhalten jeweils eigene Kennungen, auch bei gleichen Uhrzeiten. Eine wiederhergestellte Reise behält dagegen ihre gespeicherte ID; erst spätere neue Reisen verwenden die neue Kennung. Die Berechnung erfolgt nur bei der Zustandsanlage, ohne zusätzliche Persistenz oder Änderung des Checkpoint-Formats.

Eine abgeschlossene oder widerrufene Reise schreibt einen nicht qualifizierten Checkpoint. Das gilt auch bei blockierten Ausgaben oder vorübergehend gestörtem Listener. Die Entwertung wird vor produktiven Aktoraufrufen geschrieben, sodass synchrones Speichern oder Reload innerhalb eines Gerätecalls keine bereits verbrauchte Reise wiederbelebt. Modus- und relevante Konfigurationsänderungen entwerten den Stand ausdrücklich; Debug und Lernen erzeugen keine produktiven Checkpoints. Laufende Aktorrückmeldungen können bei Reload weiterhin passiv beobachtet werden, während ein Prozessneustart daraus keine neuen Befehle erzeugt.

FHEM speichert die Checkpoint-Readings zusammen mit den übrigen Zustandsreadings. Ein geordnetes Beenden schreibt die Zustandsdatei; GeoPresence ruft nicht selbst `save` auf. Bei abruptem Absturz ist nur der zuletzt erfolgreich gespeicherte Stand verfügbar, und während eines Ausfalls verpasste Beobachtungen lassen sich nicht rekonstruieren. Eine zusätzliche SQL-Datenbank oder eigene Auftragsdatei wird nicht verwendet.

Controller und Person werden über set mode gesteuert. Neue Geräte ohne gespeicherten Modus starten disabled; mode ist ein normales gespeichertes Reading. Der Controller unterstützt active/debug/disabled, eine Geofency-Person zusätzlich learning. Controller disabled blockiert alles; unter aktivem oder debug-Controller bleibt eine disabled-Person aus und eine learning-Person im Lernempfang. Ansonsten erzwingt debug auf einer der Ebenen Simulation. Produktive Verarbeitung benötigt active auf beiden Ebenen. effectiveMode und modeReason sind abgeleitete Readings der Person. Administrative Modusreadings werden ohne Events und userReadings/stateFormat-Callbacks aktualisiert.

Während FHEM die Konfiguration einliest, legt Define kein mode-Reading mit einem neuen Zeitstempel an. FHEM lädt die Zustandsdatei erst nach den Definitionen und übernimmt gespeicherte Readings nur, wenn noch kein neuerer oder gleich alter Reading-Wert existiert. Erst INITIALIZED beziehungsweise REREADCFG ergänzt fehlende Modusreadings mit disabled; diese Ereignisse folgen auf die Wiederherstellung, auch wenn init_done bei REREADCFG noch falsch ist. Vorhandene active/debug/disabled-Werte und ihre ursprünglichen Zeitstempel bleiben erhalten. Interaktive Neudefinitionen nach dem Systemstart erhalten den Standard disabled sofort. Ein Modulreload erhält die aktuellen Modi im Speicher, während ein Prozessneustart den erfolgreich gespeicherten Stand verwendet.

STATE wird bei derselben Modusaktualisierung direkt gesetzt, auch wenn sich die abgeleiteten Readings nicht geändert haben. So ersetzt ein Reload oder INITIALIZED nach Wiederherstellung der Zustandsdatei auch eine veraltete gespeicherte Anzeige durch den wirksamen Modus. Die Statusanzeige erzeugt weder ein zusätzliches Steuerreading noch FHEM-Ereignisse oder Ausgaben an ROOMMATE und Aktoren.

Ein individueller Moduswechsel setzt nur diese Person zurück und lässt den Listener gebunden. Controller-Moduswechsel widerrufen alle Reisen, erhalten aber laufende Aktorrückmeldungen; active/debug-Wechsel erhalten Lernfenster, disabled bricht sie ab. Gleichbleibender Modus ist idempotent; ein ausdrückliches disabled verwirft dennoch einen nach Timeout verbliebenen unbestätigten Kandidaten. Fehlgeschlagene Aktivierungsvalidierung verändert weder Modus noch Reise. Bei Neustart bleiben gespeicherte active/debug/disabled erhalten; learning wird deaktiviert und niemals automatisch fortgesetzt.

Neue Personen und deren eigene Orte lassen sich bei produktivem Betrieb anderer Personen einrichten. Konfigurationsänderungen setzen nur betroffene Personen zurück; bei Regeln zählen alte und neue Personenreferenzen, bei Aktionen auch Regeln mit demselben Hardwareziel. Gemeinsame Änderungen werden abgewiesen, solange ein Betroffener effektiv active ist. Controller-Konfiguration benötigt global debug oder disabled. Unvollständige unbeteiligte Regeln und neue deaktivierte Personen blockieren nicht die laufende Validierung anderer Personen. Globale validate-Abfragen melden dagegen auch deren noch fehlende Einrichtung.

## 12. Ausführung und Prüfung

Der Controller benutzt einen einzelnen periodischen FHEM-Timer, verarbeitet kurze Ereignisbündel, prüft qualifizierte Telefonzustände, Ankunftsfristen und Aktorabschlüsse und aktualisiert relevante Readings. Konfiguration, Gerätelisten und statische Prüfergebnisse werden auch über mehrere Durchläufe hinweg wiederverwendet, bis sie entwertet werden. Bei unveränderter vorbereiteter Konfiguration melden `last_device_scans` und `last_config_builds` jeweils 0; reine Zugriffe zählen nicht als Neuaufbau. Die Diagnose `timerStats` trennt Ausführungsdauer von verspätetem Timerbeginn; die bloße Nennung in einer Freezemon-Kandidatenliste beweist keine lange Modulrechnung.

Eine passive Messung erfasst Verarbeitungsschritte einschließlich synchroner Aktor-, ROOMMATE-, Nachrichten-, Reading- und Logaufrufe. Unteraufrufe werden mit inklusiver Dauer und exklusiver Eigenzeit erfasst, damit externe Callbacks nicht zusätzlich dem aufrufenden Verarbeitungsschritt als Eigenzeit zugerechnet werden. Die abschließende Gesamtdauer umfasst die Diagnoseausgabe und die Registrierung des nächsten Timers. Perl-Aufrufkontext, Rückgabewerte und Fehlerweitergabe bleiben erhalten; die Messung erzeugt keine Readings oder Ereignisse und verändert keine Aktions- oder Fristenentscheidung.

Der Controller hält den letzten und langsamsten profilierten Lauf, den Lauf mit der größten Startverspätung sowie jeweils höchstens zwölf langsame und verspätete Läufe ab 500 ms im Speicher. Jeder Datensatz enthält Startzeit, Dauer, Startverspätung, ungefähre Prozess-CPU-Zeit, Geräte-/Konfigurationszähler und die Verarbeitungsschritte mit Gerät oder Bewohnerbereich. Betriebssystempausen und I/O-Wartezeiten sind in der verstrichenen Zeit enthalten; CPU-Zeit allein beweist keine bestimmte Ursache. Messreihen sind unabhängig von `debugLog`, überleben Sitzungsreset und Modulreload, werden aber nicht persistiert. Frühere aggregierte Maxima werden erhalten; `profile_started_at` grenzt die verfügbare Detailhistorie ab.

`timer_slow` nennt bei aktivierter Dateidiagnose den bis dahin größten gemessenen Anteil und dessen Zielgerät; die begrenzte Rate verhindert eine zusätzliche Logflut. Die Diagnosezeile kann ihre eigene Schreibdauer noch nicht enthalten, die anschließend gespeicherte In-Memory-Messung dagegen schon. Die lesbare Ausgabe zeigt die sechs größten Eigenzeitanteile des langsamsten profilierten Laufs und die neuesten fünf Einträge je Verlauf; `format=json` liefert alle gespeicherten Details. Messungen werden ausschließlich innerhalb des GeoPresence-Timers aktiviert; andere FHEM-Callbacks werden weiterhin über apptime untersucht.

Nach jeder relevanten Änderung prüft `validate` Referenzen und Verträge; Geometriehinweise beschreiben zusätzlich noch ausstehende Laufzeitdaten. Der [automatische Praxistest](GeoPresence_Testanleitung.md) nutzt authentifizierte Testwebhooks, lokale FHEM-Abfragen und die echte Diagnoseausgabe. Softwaretests prüfen ergänzend Zeitordnung, Gruppenüberlappung, Wiedereintritt, verworfene Nachweise, Quellenprofile, Feedbackauflösung, Transportisolation, Oberfläche und die ausführbaren Handbuchbeispiele in einer temporären FHEM-Instanz mit Dummy-Aktoren.

Die Prüfungen der Webhook-Anmeldung und Kontingente untersuchen fehlende, falsche und unbekannte Anmeldungen über das bisherige Kontingent hinaus, eine weiterhin angenommene gültige Ortsmeldung, unabhängige Personenfenster sowie die gemeinsame Begrenzung über Betriebsmodi hinweg. Nach 120 authentifizierten Anfragen muss HTTP 429 folgen; nach genau 60 monotonen Sekunden steht das Kontingent wieder bereit, auch bei um eine Stunde zurück- oder vorgestellter Systemzeit. Die reale FHEM-Integration verwendet dafür ausschließlich private Moduluhren im temporären Prozess und prüft außerdem die Freigabe des Kontingenteintrags beim Löschen einer Person.

Die Lebenszyklustests verwenden einen echten FHEM-Prozess mit Speichern, Beenden, erneutem Start, Modulreload und rereadcfg. Die gespeicherten Moduszeitstempel und die Nachweise des Neustarttests liegen ausdrücklich vor dem realen Neustart, unabhängig von zuvor vorgestellten Testuhren. Geprüft werden aktive, simulierte, deaktivierte und fehlende Modi, das Ende von learning, die Controller-Vorrangregeln, erhaltene Zeitstempel, wiederhergestellte gültige Ausflüge, frische anschließende Rückkehr sowie der Verzicht auf alte Timer und Aufträge. Ein zweiter Prozessneustart darf eine bereits verbrauchte Berechtigung nicht erneut nutzen. Dummy-Kontakte behalten dafür ihre alten Zeitstempel; ihre Positionen werden nicht künstlich aufgefrischt.

Die Lebenszyklusprüfungen umfassen Controller-, Personen-, Orts-, Aktions- und Regelumbenennungen mit vorbereiteten und kalten Beständen. Geprüft werden nachgeführte Definitionen, widerrufene alte Pläne, unveränderte unbeteiligte Kontexte, weiterhin beobachtete Aktoraufträge, Zugangsdatenübertragung, erhaltene Personenkontingente und sichtbare öffentliche Altverweise. Fehler beim Lesen, Schreiben und Entfernen von Kennwortschlüsseln dürfen nach Sitzungsreset keinen veralteten Zugang freigeben. Die reale FHEM-Integration prüft zusätzlich geschlossene alte HTTP-Clients, den neu gebundenen Listener, gespeicherte Elterndefinitionen und Rename-Rückrufe während eines Türbefehls. ROOMMATE-Gegenproben prüfen Fehlerwerte, Ausnahmen, eine spätere erfolgreiche Wiederholung und den Vorrang neuerer Status- oder Modusänderungen.

Regressionstests prüfen eine Radiusänderung beim Home-Austritt mit zuvor qualifizierter Telefonabwesenheit, die vollständige erneute Qualifikation und eine anschließende Türöffnung nach Fußwegfrist. Gegenproben umfassen GPS-Sprünge, neuere lokale Anwesenheit, ungültige oder widersprüchliche Geometrie, alte Meldungen und das reine Geo-Profil. Bewegungsdaten werden in Wiederholungen innerhalb desselben Bündels und in späteren Timerläufen ergänzt; dabei werden Fristen, Originalzeitstempel, Garagenausschluss bei Fußweg und ausbleibende doppelte Aktionen geprüft. Die FHEM-Integration bestätigt den HTTP-/Timer-Ablauf und die Diagnose mit Dummy-Aktoren.

Laufzeittests unterscheiden einen fremden blockierenden Timer von einem synchronen, absichtlich verzögerten Notify am Dummy-Aktor. Weitere Prüfungen decken Reading-Callbacks, Dateiausgabe einschließlich der eigenen Slow-Run-Diagnose, begrenzte Historien, unveränderte Ausführung und die Trennung inklusiver und exklusiver Messzeiten ab.

Die Ausgaberegressionen prüfen manuelle Heimsetzung während des Türbefehls, abgelaufene und noch gültige Folgeaufträge, Rückrufe von Nachrichten und Licht, kleine Uhrkorrekturen, veränderte Konfiguration und die Bereinigung nicht ausgegebener Reservierungen. Die reale FHEM-Integration verwendet zusätzlich einen Home-setzenden Notify und einen echten Rückruf mit 1,5 Sekunden Wartezeit am Dummy-Türaktor. Die Garage bleibt jeweils unverändert; die Rückmeldung der bereits angeforderten Tür wird weiter übernommen. Eine Gegenprobe richtet im Tür-Rückruf eine unbeteiligte Person ein; der weiterhin berechtigte Garagenbefehl wird dabei ausgeführt.

Weitere Regressionen prüfen Aliasänderungen und Aliaslöschungen innerhalb des Türbefehls, Controller-Sammellöschungen vor und nach der Übernahme, gemeinsam wiederhergestellte Zeitstandardwerte sowie kleine Uhrkorrekturen während Warteschlange und Ankunftsfrist. Die reale FHEM-Gegenprobe stellt die Systemzeit während der Ankunftsfrist um zehn Sekunden zurück und verzögert anschließend den Tür-Rückruf tatsächlich um 2,5 Sekunden; die Garage erhält keine verlängerte Frist.

Weitere Prüfungen untersuchen verschiedene Aliaslöschmuster am ROOMMATE bei warmen und kalten Caches sowie die Erneuerung gespeicherter Fehler nach der Musterlöschung von Altattributen. Reale FHEM-Befehle prüfen dabei sowohl den weiter ausgegebenen Garagenbefehl als auch eine erfolgreiche Validierung und Aktivierung nach der Bereinigung.

Die Prüfungen der Ereignisbündelung untersuchen einen kontinuierlichen Webhook-Strom, unabhängige Produktiv- und Debug-Fristen sowie jüngere Gegenbeobachtungen vor der Ankunftsbestätigung. Für 64 frische Geo-Meldungen mit unterschiedlichen Beobachtungszeiten begrenzt die Regression die insgesamt verbleibenden Konfliktaufrufe auf höchstens 64; der vorherige Ablauf erzeugte 2.079. Die reale FHEM-Integration prüft dieselbe Bündelverarbeitung über HTTP. Diese Aufrufzähler sind keine Messung eines zeitlichen oder prozentualen Leistungsgewinns.

Die Prüfungen nachgelieferter Bewegungsdaten ergänzen ältere akzeptierte Eintritte nach mehreren neueren Home-Meldungen. Sie prüfen ursprüngliche Zeitanker, unveränderte Mitgliedschaften und Besuchszähler, den Vorrang neuerer Bewegung sowie den Ausschluss unbekannter Ursprünge, geänderter alter Geometrie und abgebrochener Ankünfte. Eine verspätete Austrittsmeldung muss weiterhin beim tatsächlich neuesten Home-Eintritt eine neue vollständige Frist beginnen. Die reale FHEM-Integration prüft den späten Fußwegnachtrag über HTTP mit regulärer Timerbestätigung und mit vorzeitiger Telefonbestätigung; Diagnose und Dummy-Aktoren belegen jeweils genau eine Türanforderung und keine Garagenanforderung.

Weitere Fälle prüfen den Übergang einer zuvor akzeptierten Annäherung zu Home mit gleicher und mit späterer Home-Beobachtungszeit, jeweils mit Timer- und Telefonbestätigung. Der verspätete Fußwegnachtrag muss die Garage sperren, ohne den Home-Zeitanker zu ändern. Weitere Gegenproben schließen vor Home unterbrochene, abgelaufene oder durch eine neuere Annäherung ersetzte Ursprünge aus. Eine vor erfüllter Mindestabwesenheit beobachtete Annäherung darf eine danach berechtigt begonnene Home-Frist durch ihren Nachtrag nicht vorzeitig bestätigen oder verwerfen.

Weitere Prüfungen umfassen verspätete Home-, Annäherungs- und Outer-Austritte nach einer neueren nahen Ortsmeldung, jeweils bei Empfang vor und nach Home. Ein nachgereichter Automotive-Ursprung vor der Unterbrechung darf die Garage nicht freigeben. Gegenproben erhalten neuere Home-Bewegung, einen späteren gültigen Annäherungseintritt und den aktuellen Ursprung bei einem noch älteren Austritt. Eine abweichende alte Geometrie wird weiterhin verworfen. Weitere Austritte während der Home-Frist müssen den tatsächlich neuesten Home-Nachweis verwenden. Die reale FHEM-Integration prüft den nahen Ort und beide Empfangsvarianten über HTTP mit Dummy-Aktoren.

Eine Gegenprobe setzt `motion_max_age` auf zulässige 20 Sekunden. Ein verspäteter Austritt vor Home trifft erst nach Ablauf dieses Werts ein; die gespeicherte Home-Walking-Sperre muss bei Timer- und Telefonbestätigung erhalten bleiben. Gegenproben entfernen einen früheren Automotive-Nachweis und berücksichtigen spätere Walking-, Running- oder Cycling-Daten weiterhin anhand ihrer angenommenen Gültigkeit. Eine tatsächlich unterbrochene alte Fußwegsperre darf entfallen, und ein neuer gültiger Automotive-Nachweis darf die Entscheidung ändern. Die reale FHEM-Integration prüft die Walking-Sperre mit Timer und Telefon sowie die Teilentwertung eines Automotive-Nachweises.

Die Prüfungen der Checkpoint-Speicherung zählen JSON-Aufbereitungen und Checkpoint-Schreibzugriffe getrennt. Diagnosen, unveränderte Wiederholungen, abgewiesene Beobachtungen, Aktorrückmeldungen sowie ruhige Timer- und Wiederherstellungsläufe müssen ohne beides auskommen. Neue Ortsnachweise, Verbrauchsstände, Bewegungsnachträge, verspätete Bewegungswiderrufe und Zeitabläufe müssen dagegen gespeichert werden. Gegenproben entziehen eine zuvor saubere Reisequalifikation ohne Trace bei blockierter Ausgabe und berichtigen ein extern verändertes Reading. Die bestehenden Neustart- und synchronen Gerätecalls prüfen weiterhin die Speicherung des Verbrauchs vor der Ausgabe.

Die Prüfungen des Aktionsverbrauchs umfassen 2.101 aufeinanderfolgende verbrauchte Besuche mit anschließendem Neustart: Ein aktueller Verbrauchseintrag ersetzt die Historie, und der Checkpoint bleibt in dieser festen Konfiguration unter 4 KiB. Weitere Prüfungen wechseln gewöhnliche und reisegebundene Regeln derselben Aktion und Auswahl, erhalten die Trennung zwischen Einzelort und Gruppe und prüfen gemeinsame Cooldowns ohne vorzeitigen Verbrauch. Version-1-Wiederherstellung und Reload eines alten Laufzeitzustands erhalten aktuelle Nachrichten-, Schalt- und Öffnungsverbräuche, obwohl die alte vollständige Historie im Reload-Fall größer als 64 KiB wäre. Fehlende, unbekannte oder unmögliche Verbrauchsstände im neuen Format werden abgelehnt. Die reale FHEM-Integration übernimmt einen alten Checkpoint und prüft eine bereits verbrauchte Ortsaktion mit `cooldown 0` erneut; es darf kein zweiter Schaltbefehl entstehen.

Weitere Gegenproben prüfen gewöhnliche Nachrichten und Schaltaktionen während eines unbestätigten Home-Abgangs, mit `enter`/`exit`, Orts-/Gruppenauswahl und `cooldown 0`. Zweimalige Zurückweisung eines Outer-Abgangs bei gehaltener Telefonanwesenheit muss den Verbrauch derselben Reise erhalten. Neue Austrittsnachweise und neue Besuche dürfen die Aktion nicht wiederholen; ein tatsächlich neuer Ausflug darf sie mit neuen Nachweisen wieder erlauben. Die reale FHEM-Integration prüft diesen Ablauf über HTTP mit einem Dummy-Licht und unveränderten Tür-/Garagen-Dummys.

Die Prüfungen der Sitzungskennungen umfassen neue Kontexte und wiederholte Debug-Resets bei identischer absoluter und monotoner Zeit. Offene Reisen behalten ihre ID und ihren Zähler; neue Reisen und Kontexte erhalten verschiedene IDs. Gespeicherte alte IDs werden aus Checkpoints der Versionen 1 und 2 unverändert übernommen, dürfen nach Abschluss aber nicht an die nächste Reise vergeben werden. Die reale FHEM-Integration prüft neue Sitzungskennungen über zwei Prozessneustarts, die unveränderte ID der fortgesetzten Reise und einen späteren neuen Ausflug mit eigener ID und eigenem Checkpoint.

Die Prüfungen der Telefonkontinuität umfassen verspätete gültige Telefonanwesenheit mit und ohne wartende Home-Ankunft, unveränderte Quellzeitstempel, entwertete Checkpoints und ausbleibende spätere Öffnungen aus der alten Reise. Gegenproben erhalten spätere Reisen gegenüber älteren Messungen und verwerfen zukünftige oder fehlerhafte Werte. Weitere Fälle prüfen vor Home negative Zustände, eine bereits abgeschlossene alte Qualifikation, eine neue vollständige Frist ohne Wiederholungsmeldungen sowie unveränderte Mess-, Fehler- und Startgrenzen. Frühere oder zukünftig datierte Home-Eintritte und eine verspätet gemeldete frühere Telefon-Rückkehr dürfen auch nach späterer Fristbestätigung keine Berechtigung erhalten. Ein gültiger Home-Eintritt zwischen Fristende und nächstem Poll bleibt dagegen berechtigt. Die Quellenprüfung wird bei gleichzeitig fälliger Produktion und Live-Debug nur einmal aufgerufen; beide Kontinuitäten bleiben getrennt. Die reale FHEM-Integration prüft verspätete Anwesenheit, den Spaziergang mit zuvor negativen Quellen und die vorzeitige Home-Rückkehr mit Dummy-Aktoren.

Weitere Prüfungen ergänzen gesammelte Abschlüsse mit nachgelieferter widersprechender Anwesenheit, mehrere positive Sensoren mit verschiedenen Zeiten und den Erhalt eines gültigen früheren Abschlusses bei echter späterer Rückkehr. Weitere Fälle liefern Vorstart-Anwesenheit erst nach der Wiederherstellung und erhalten dabei neuere Positionen sowie spätere Reisen. Eine nahe Zwischenposition darf gehaltene Negativwerte nicht dauerhaft blockieren. Im Messmodus werden eine Rückkehr vor der letzten erforderlichen Erneuerung im selben und in getrennten Bündeln sowie eine echte Rückkehr danach vor dem nächsten Poll verglichen. Gegenproben erhalten unabhängig bestätigte Geo-Ausflüge und reine Telefonstatuswechsel. Die echte FHEM-Integration prüft diese Abläufe mit kontrollierten Quellzeiten, einschließlich Wiederherstellung eines alten Ausflugs und zulässiger späterer Rückkehr, ausschließlich an Dummy-Aktoren.

Die Prüfungen historischer Anwesenheit umfassen gemischte Vorstart- und aktuelle positive Quellen nach Wiederherstellung einer Geo-Reise, einschließlich eines dritten Sensors sowie zulässiger älterer Beobachtungen und späterer neuer Reisen. Die Prüfungen der Abwesenheitsfrist umfassen das bereits bei 285 erfüllte Fristende mit Rückkehr 286 und zusätzlicher Negativmessung 287, sowohl bei regelmäßigen als auch versetzten Quellenerneuerungen. Wiederholte negative Zustandsmeldungen dürfen die Frist ebenfalls nicht verschieben. Die echte FHEM-Integration prüft den gemischten historischen Widerruf und die gültige Rückkehr nach bereits vollständiger Erneuerung über PRESENCE und HTTP. Die vorhandenen Prüfungen für Queue-Widerrufe und tatsächlich verspätete erste Erneuerungen bleiben nach Entfernung des zusätzlichen Aufbewahrungsfelds wirksam.

Die Prüfungen verspäteter Telefonanwesenheit umfassen die verspätete Anwesenheit 120 zusammen mit aktueller Anwesenheit 230 nach unabhängig bestätigtem Geo-Abgang 100. Gemeinsame und getrennte Abfragen müssen die alte Berechtigung gleichermaßen verbrauchen oder widerrufen. Zusätzliche Fälle prüfen eine noch frische Rückkehr vor Mindestabwesenheit, drei positive Sensoren, eine jüngere Position und einen tatsächlich späteren neuen Ausflug. Auch bei neuerer Position oder bereits wartender Home-Ankunft muss eine solche zu frühe Rückkehr widerrufen. Eine berechtigte frühere Rückkehr bleibt ausführbar; ein langsamer Tür-Aufruf darf das anhand dieser ursprünglichen Rückkehr begrenzte Garagenbudget nicht verlängern. Die echte FHEM-Integration ergänzt gemeinsame und getrennte verspätete Beobachtungen, die beiden neueren Positionskontexte und eine berechtigte frische Rückkehr.

Die Prüfungen der Statusübernahme umfassen ohne Reisenachweis die gemischten positiven Beobachtungen 120 und 235 nach qualifizierter Abwesenheit 230. Die jüngste gültige Beobachtung muss den Status bei Telefon, GeoPresence und ROOMMATE auf Anwesenheit bringen; spätere Polls ohne weitere Sensormeldungen müssen ihn erhalten. Varianten prüfen vertauschte Sensoren, drei Quellen, den Messmodus und das kombinierte Profil ohne Reise. Die echte FHEM-Integration prüft Zustands- und Messmodus bei `phone_only`; dabei entstehen weder Reise- noch Öffnungsberechtigungen und die Quellzeitstempel bleiben unverändert.

Weitere Prüfungen umfassen abgeschlossene Geo- und telefonbestätigte Reisen mit einem späteren Abwesenheitszyklus, neuerer naher Ortsposition und gemischten positiven Quellzeiten. Beide Statuswerte müssen anhand der aktuellen Anwesenheit wieder `home` werden und ohne weitere Quellenmeldungen dort bleiben. Eine ältere bereits für Aktionen abgelaufene Meldung darf den reinen Status ebenfalls nicht blockieren. Gegenproben erhalten ursprüngliche Reisegrenzen, unveränderte Quellenzeiten und den Widerruf eines tatsächlich neuen laufenden Ausflugs. Ein aufbewahrter alter Ausgabeplan muss nach dem neuen Statuswechsel weiterhin an seinem eigenen abgelaufenen Budget scheitern. Die echte FHEM-Integration prüft die beiden Arten abgeschlossener Reise; der spätere Statuswechsel darf keine Öffnung wiederholen.

Die Prüfungen der Telefonverarbeitung sichern die fachlichen Abläufe im Zustands- und Messmodus ab. Direkte interne Testereignisse enthalten die Pflichtfelder des regulären Erzeugers. Eine zusätzliche Gegenprobe qualifiziert Abwesenheit im Zustands- und Messmodus, prüft unveränderte Negativwerte und meldet anschließend einen Quellenfehler. Der Fehler muss auch nach bereits bestätigter Abwesenheit erkannt werden; eine bloße Wiederverbindung mit alten Werten genügt nicht, neue Beobachtungen und eine vollständige erneuerte Frist bleiben erforderlich.

## 13. Änderungen seit der letzten Version

Änderungen von Version 0.74 auf 0.75:

- FHEM-Rename-Callback für interne Ressourcen, Elterndefinitionen, Zugangsdaten, begrenzte betroffene Kontexte und laufende Aktorrückmeldungen ergänzt.
- Kennwortfehler nach Umbenennung bleiben gesperrt und sichtbar, bis die Zugangsdaten erfolgreich neu gesetzt wurden; öffentliche Attributverweise bleiben ausdrücklich zu berichtigen.
- Regex-sichere Kennwortschlüssel und exakte Altübernahme schützen den migrierten Zugang und ähnlich benannte fremde Einträge beim Lesen, Schreiben und Löschen.
- Rückgabefehler und Ausnahmen der ROOMMATE-Statusübergabe werden angezeigt; der noch aktuelle gewünschte Status wird ohne zusätzliche Öffnungsrechte wiederholt.
- Kennwortformate aus einem gelesenen Bestand auswählen, die lokale Zeilenliste bei der Altbereinigung weiterverwenden und die Freigabe für ROOMMATE-Wiederholung und Veröffentlichung gemeinsam prüfen.
- Auswahllisten bei eindeutig auswahlfremden Definitionen und Umbenennungen sowie nach reiner Änderung einer Ortsfunktion nicht mehr wirkungslos neu aufbauen.
- Erneute Freigabe auf die tatsächliche ROOMMATE-Statusbearbeitung begrenzen und Bewohnerlisten bei Aktions- und Regelumbenennungen erst nach der Betroffenheitsauswahl aufbereiten.

Änderungen von Version 0.73 auf 0.74:

- Webhook-Kontingente erst nach erfolgreicher Anmeldung und getrennt je Person zählen; Produktion, Debug und Lernen teilen dasselbe Personenfenster.
- Das feste 60-Sekunden-Fenster mit der monotonen Uhr begrenzen; Vor- und Rückwärtskorrekturen der Systemzeit ändern seine Dauer nicht.
- Authentifizierte Person vor der Kontingentprüfung an die Diagnose übergeben; HTTP 429 bleibt zuordenbar und wird bei `debugLog auto` für Debug-/Lernpersonen auch unter aktivem Controller protokolliert.
- Doppelte Webhook-Pfadermittlung, zusätzliche Diagnosehashkopie und Kopie der Benutzerzuordnung entfernt; Pfad-, Anmelde- und Diagnoseverträge bleiben erhalten.
- Kontingente auf zwei Werte je angemeldeter Person begrenzt und beim Löschen der Person bereinigt; Regressionen prüfen Anmeldung, Personentrennung, Moduswechsel und Zeitkorrekturen auch über den echten HTTP-Listener.

Änderungen von Version 0.72 auf 0.73:

- Vollständige interne Telefonereignisse direkt verwenden; nicht benötigte Ersatzpfade und Abschlusszuweisungen entfernt.
- Aktuellen Telefonwiderruf nach der Zeitlage vor beziehungsweise ab dem Abgang aufgeteilt.
- Bereits qualifizierte gesunde Negativlagen vor erneuter Fristrechnung beenden, nach unveränderter Quellen- und Grenzprüfung.
- Zwei im vorhandenen Lebenszyklus nicht wirksame Markerprüfungen an übernommenen Reisenachweisen entfernt.

Änderungen von Version 0.71 auf 0.72:

- Nur eine laufende Reise bestimmt die ursprüngliche Telefon-Rückkehrzeit; abgeschlossene Reisen blockieren spätere reine Statuswechsel nicht.
- Abgeschlossene Nachweise und die Zeitgrenzen ihrer Ausgaben bleiben für Widerruf und Freigabe erhalten.

Änderungen von Version 0.70 auf 0.71:

- Ohne Reisenachweis verwendet die Statusübernahme die jüngste gültige positive Quellzeit; ältere gleichzeitig angenommene Meldungen blockieren frische Anwesenheit nicht.
- Bei vorhandenem Reisenachweis bleiben die ursprüngliche Rückkehrzeit und ihre Grenzen für Widerruf, Mindestabwesenheit und Ausgabe wirksam.

Änderungen von Version 0.69 auf 0.70:

- Die früheste neue positive Beobachtung ab dem maßgeblichen Abgang bestimmt Rückkehralter, Mindestabwesenheit und Ausgabebudget.
- Vorstart- und laufende Sitzungen verwenden dieselbe Zeitwahl; der zusätzliche Ereigniswert `snapshot_time` entfällt.
- Die gemeinsame Bestimmung des Abgangs verhindert doppelte Grenzlogik in Quellenprüfung und Reisekern.

Änderungen von Version 0.68 auf 0.69:

- Vorstart-Gegenbeweise bleiben bei gleichzeitig aktuellen positiven Sensoren für den Widerruf wiederhergestellter Geo-Reisen wirksam.
- Nur die erste erforderliche Erneuerung je Quelle begrenzt den Abschluss; weitere Negativmessungen verschieben eine gültige Rückkehr nicht.
- Der vorhandene Telefonpuffer übernimmt die Aufbewahrung unverarbeiteter Abschlüsse allein; das zusätzliche Referenzfeld und seine Pflegepfade entfallen.

Änderungen von Version 0.67 auf 0.68:

- Widersprochene gesammelte Telefonabschlüsse werden gezielt entwertet; gültige frühere Abschlüsse bleiben für spätere Rückkehr erhalten.
- Nachgelieferte Vorstart-Anwesenheit kann ältere wiederhergestellte Berechtigungen widerrufen, ohne historische Aktionen auszuführen.
- Nahe Zwischenpositionen sperren eine weiterhin gültige Abwesenheitskontinuität nicht.
- Ein gemeinsamer Abschlussnachweis begrenzt Rückkehr über Bündelgrenzen hinweg; der tatsächliche Abschluss bleibt auch im Messmodus maßgeblich.

Änderungen von Version 0.66 auf 0.67:

- Quellenprüfung, Telefonkontinuität und Reiseentscheidung getrennt; gemeinsame Live-Abfragen und direkte Zeitgrenzen statt zusätzlicher Listen und Sortierungen.
- Gültige verspätete Anwesenheit widerruft alte Reise- und Ausgabeberechtigungen unabhängig von der Freigabe neuer Aktionen.
- Gehaltene negative Zustände können nach einem Home-Austritt eine neue vollständige Abwesenheitsfrist erfüllen, ohne erneut gemeldet werden zu müssen.
- Gemeinsamer Home-Abgang und gemeinsames Anwesenheitsveto; Abwesenheitsabschlüsse werden anhand ihres tatsächlichen Abschlusszeitpunkts eingeordnet.

Änderungen von Version 0.65 auf 0.66:

- Neue Kontextkennungen erhalten einmalig einen zufälligen Sitzungsanteil gegen die erneute Vergabe alter Reise-IDs nach Prozessneustarts.
- Wiederhergestellte Reisen behalten ihre ID; neue Reisen verwenden die neue Kennung und den lokalen Zähler.
- Checkpoint-Format und Übernahme gültiger Daten der Versionen 1 und 2 bleiben erhalten.

Änderungen von Version 0.64 auf 0.65:

- Ein beibehaltener unbestätigter Home-Abgang erhält den Verbrauch seiner Reiseaktionen.
- Zurückgewiesene Entfernungs- und Austrittsnachweise bleiben verworfen; neue Nachweise erlauben keine erneute Ausgabe innerhalb derselben Reise.

Änderungen von Version 0.63 auf 0.64:

- Aktuelle Verbrauchsstände ersetzen die Historie alter Besuche und deren Reihenfolgeliste.
- Reisegebundener Verbrauch bleibt im Ausflug; gewöhnliche Orts-/Gruppenbesuche und gemeinsame Aktions-Cooldowns bleiben getrennt.
- Checkpoint-Version 2 mit einmaliger Übernahme gültiger Version-1-Daten und Verdichtung alter Laufzeitzustände beim Reload.

Änderungen von Version 0.62 auf 0.63:

- Checkpoints folgen Änderungen der gespeicherten Fachdaten statt Diagnoseeinträgen.
- Unveränderte Wiederherstellungen behalten den gespeicherten Stand; Bewegungs- und Anzeigeabläufe werden ausdrücklich erfasst.
- Reisequalifikation wird vor dem schnellen Rücksprung geprüft; Widerruf und Verbrauch bleiben vor produktiven Ausgaben gespeichert.

Änderungen von Version 0.61 auf 0.62:

- Ein verspäteter Austritt vor Home erhält die bestehende Home-Vormerkung samt unbetroffener Fahrzeugentscheidung.
- Gemeinsame Bewegungsbewertung für neue Hinweise und Teilentwertung; verbliebene Daten behalten bei Teilentwertung ihren ursprünglichen Bewertungszeitpunkt.
- Kein vollständiger Neuaufbau der Home-Vormerkung und keine Neubewertung, wenn keine Bewegungsdaten entfallen.

Änderungen von Version 0.60 auf 0.61:

- Verspätete Austritte unterbrechen bereits den Annäherungsabschnitt, auch nach einer neueren Ortsmeldung und vor der Home-Vormerkung.
- Eine gemeinsame Ursprungszeit begrenzt Austrittsprüfung und Bewegungsergänzung ohne zusätzliche Ereignishistorie.
- Vor Home liegende Unterbrechungen erhalten eine bereits begonnene gültige Home-Frist, entwerten aber frühere Bewegungsursprünge und deren Fahrzeugentscheidung.

Änderungen von Version 0.59 auf 0.60:

- Die aktuelle Annäherungsbeobachtung wird beim Home-Eintritt derselben wartenden Ankunft zugeordnet; ihr gültiger Bewegungsnachtrag bleibt wirksam.
- Der vorhandene Annäherungskontext speichert dafür einen Ereignisschlüssel zusätzlich zur Ablaufzeit. Abbrüche löschen ihn auch vor Beginn einer Home-Frist.
- Ältere Annäherungsnachträge prüfen die Mindestabwesenheit anhand des bereits qualifizierten Home-Eintritts und lösen keine vorzeitige Bestätigung aus.

Änderungen von Version 0.58 auf 0.59:

- Akzeptierte Eintritte bleiben ihrer offenen Ankunft zugeordnet; neuere bewegungslose Meldungen verwerfen ihre Bewegungsnachträge nicht mehr.
- Gemeinsame Ergänzungsprüfung für Geometrie-Vorfilter und Duplikatverarbeitung; vorhandener begrenzter Duplikatspeicher wird weiterverwendet.
- Der neueste Home-Nachweis bleibt bei älteren Ergänzungen erhalten, damit verspätete Austritte die Ankunft weiterhin korrekt unterbrechen.

Änderungen von Version 0.57 auf 0.58:

- Die Bündelfrist beginnt mit dem ersten Empfang; neue Meldungen verschieben ältere nicht mehr beliebig.
- Chronologisch gruppierte Konfliktprüfung ersetzt den Vergleich sämtlicher Paare; nur gleiche Zeitstempel werden miteinander verglichen.
- Alle bereits vorliegenden Gegenbeobachtungen eines fälligen Bündels bleiben vor der Ankunftsbestätigung berücksichtigt.

Änderungen von Version 0.56 auf 0.57:

- Löschmuster werden vor der Attributklassifikation aufgelöst; Aliaslöschmuster am ROOMMATE erhalten gültige Folgeaufträge.
- Die globale Cache-Entwertung berücksichtigt auch gemustert gelöschte, vom Validator beanstandete Altattribute.
- Gemeinsamer Musterabgleich und FHEM-Attributbeschreibungen ersetzen weitere Sonderfälle für einzelne Musterschreibweisen.

Änderungen von Version 0.55 auf 0.56:

- Attributrelevanz vor dem Widerruf; Aliasänderungen erhalten gültige Folgeaufträge.
- Monotone Fristen bleiben vom ursprünglichen Empfang über Warteschlange und Ankunftsfrist bis zur Ausgabe verankert.
- Controller-Abhängigkeiten und gemeinsam geprüfte Sammellöschungen schließen den Schutz vor veralteten Konfigurationsparametern.

Änderungen von Version 0.54 auf 0.55:

- [[#9.4 Abschließende Freigabe|Abschnitt 9.4]]: Gemeinsame Freigabe für alle vier Ausgabepfade, Widerruf bereits entnommener Pläne und erneute Prüfung nach synchronen Rückrufen.
- [[#4.2 Reihenfolge und Frische|Abschnitt 4.2]]: Aktuelle Uhren vor der Ausgabe und eine monotone Ablaufgrenze verhindern die Ausführung inzwischen veralteter Aufträge.
- Gemeinsame Planerzeugung, feste Öffnungsbefehle und Entfernung noch nicht ausgegebener Reservierungen; passive Rückmeldungen und Checkpoint-Verbrauch bleiben erhalten.

Änderungen von Version 0.53 auf 0.54:

- [[#2.4 Aufbereitete Konfiguration|Abschnitt 2.4]]: Gemeinsamer Katalog, direkte Nachschlagewerke, zwischengespeicherte statische Prüfungen und getrennte Geometrieansichten ersetzen wiederholte Aufbereitung im Timer und in Berichten.
- Aktorparameter werden einmal je Aktion ausgewählt und gemeinsam verwendet. Oberflächen- und ungenutzte Aktorattribute beeinflussen die Wiederherstellungsbindung nicht mehr.
- Relevante FHEM-Änderungsereignisse entwerten die aufbereiteten Daten; aktuelle Sensor- und Transportzustände bleiben davon unabhängig.
- `reorder_window` muss kleiner als `action_max_age` sein. Die Prüfung berücksichtigt auch das Löschen eines Attributs und dessen Standardwert.

Änderungen von Version 0.52 auf 0.53:

- [[#11. Persistenz und Lebenszyklus|Kapitel 11]]: Bestätigte offene Ausflüge werden über einen versionierten FHEM-Checkpoint nach Neustart, Reload und rereadcfg wiederhergestellt. Struktur-, Bindungs-, Konfigurations- und Zeitprüfung, Ablaufgrenze und ausdrückliche Entwertung verbrauchter oder widerrufener Reisen beschrieben.
- [[#9.2 Aktorvertrag und Reservierung|Abschnitt 9.2]]: `positionSignalMode` ergänzt. Gehaltene Positionen überleben Neustarts im Standardmodus state; measurement verlangt neue Messungen. Auftragsbestätigungen bleiben unabhängig davon an neue Rückmeldungen gebunden.
- [[#8.3 Vorheriger Austritt als Bedingung|Abschnitt 8.3]]: Explizite Austritte eines wiederhergestellten Ausflugs bleiben für Richtungsregeln erhalten.
- [[#12. Ausführung und Prüfung|Kapitel 12]]: Reale Prozessneustarts mit gültigem Checkpoint, späterer Tür-/Garagenöffnung und Schutz vor Wiederholung nach weiterem Neustart ergänzt.
