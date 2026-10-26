# GeoPresence – Architektur

**Version 0.62 · Stand 26.10.2026 · Handbuch 2.24**

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

Gerätesuche, gemeinsame Identitäts- und Hardwarekonfliktprüfungen sowie statische Personen-, Regel- und Aktivierungsprüfungen werden zwischen relevanten Änderungen wiederverwendet. Definitionen, Änderungen, Löschungen, Umbenennungen und Attribute referenzierter Geräte entwerten die betroffenen Ableitungen. Ein unbeteiligtes `MODIFIED` erzeugt keine Bestands- oder Oberflächenaufbereitung. `DEFINED`, `DELETED` und `RENAMED` aktualisieren weiterhin die Geräteauswahl einschließlich der PRESENCE-Geräte. Diagnose- und reine Oberflächenattribute wie `room` erfordern weder beim gezielten Setzen noch beim gezielten Löschen einen Neuaufbau. Das Löschen aller Attribute oder eines Musters mit Fachattributen entwertet die Konfiguration weiterhin.

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

Der Listener begrenzt Header, Body, Verbindungsdauer, gleichzeitige Verbindungen und Warteschlange. Der Body darf höchstens 16 KiB umfassen; mehr als 120 Anfragen pro Minute werden zurückgewiesen. Mehrdeutige HTTP-Header, Transfer-Encoding und FHEM-Steuerfelder werden nicht als Webhooks akzeptiert. Ein HTTP 200 bestätigt die Annahme in der aktuellen Sitzung, nicht eine physische Aktion oder dauerhafte Zustellung.

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

Ein aktueller, widerspruchsfreier Home-Austritt in diesem Bündel darf nach der Geometrieprüfung einen neuen lokalen, unbestätigten Ausflug beginnen. Dafür müssen die erforderliche Geometrie vollständig und widerspruchsfrei sowie Sitzung, Ereignisreihenfolge und Frische gültig sein; eine neuere lokale Telefonerkennung widerspricht diesem Austritt. Es werden keine Fernbereichsnachweise oder bisherigen Berechtigungen übernommen. Im Profil `geofency_phone` müssen Negativbeobachtungen nach diesem Austritt eine neue vollständige Qualifikation über `phone_absence_window` durchlaufen; eine vorher bereits bestätigte Telefonabwesenheit genügt nicht. Neue unabhängige Geo-Entfernungsnachweise bleiben nach dem normalen Quellenvertrag möglich; `geofency_only` benötigt einen solchen Nachweis weiterhin zwingend. Erst eine danach bestätigte Rückkehr kann Aktionen erlauben.

Ein Home-Eintritt mit geänderter Geometrie synchronisiert den Heimstatus und gewährt keine Öffnungsberechtigung. Ein noch im selben Bündel auf den Austritt folgender Home-Eintritt verwirft auch dessen neuen Verdacht. Andere Ortsmeldungen des Geometrieänderungsbündels erzeugen ebenfalls keine Aktionspläne. Die Diagnose nennt den betreffenden Ort, dessen tatsächliche Beobachtungs- und Empfangszeit und die geänderten Werte unter `geometry_changes`; ein neuer Home-Verdacht wird als `Home departure pending after geometry update; new departure confirmation required` erklärt.

Der lokale FHEM-Befehl `applyGeometry Geo.PERSON` ermöglicht eine ausdrücklich bestätigte Übernahme der vollständigen Debug-Geometrie in die normalen Ortsreadings, solange die Person effektiv debug oder individuell disabled mit bestätigten Lerndaten ist. Nach learnConfirm können passende Erfassungen die Geometrie registrierter Orte liefern; unbestätigte Daten bleiben ausgeschlossen. Das explizite Lernfenster muss beendet sein. Geometrie, Kennungen, Zeitstempel, Kreisverschachtelung und Konfliktmarkierungen werden vor jeder Änderung vollständig geprüft; ein älterer abweichender Stand darf neuere produktive Geometrie nicht überschreiben. Mit `debugAdvance` erzeugte Zeitbezüge sind nicht zulässig. Unveränderte widerspruchsfreie Produktivgeometrie behält ihre vorhandenen Metadaten.

Die Übernahme verwirft beide Reisen und die wartenden Ereignisse dieser Person und schreibt nur Geometrie mit unveränderten Beobachtungszeitstempeln. FHEMs `setReadingsVal` aktualisiert dafür normale Readings ohne Events, `userReadings` oder `stateFormat` auszuwerten. Es entstehen keine Ortsereignisse, Anwesenheitsbestätigungen, Nachrichten oder Öffnungsberechtigungen; andere Personen und Rückmeldungen bereits laufender Aktoraufträge bleiben unberührt. Der Webhook und die Testanwendung können diese Übernahme nicht auslösen. Sie ruft nicht selbst `save` auf; die dauerhafte Sicherung erfolgt über FHEMs reguläre Zustandsdatei.

Die Konfigurationsvalidierung prüft Definitionen und Referenzen. `geometry_ready` prüft die Geometrie von Home, outer und einer gegebenenfalls registrierten approach-Zone sowie Geometriekonflikte; gewöhnliche place-Orte dürfen ihre Geometrie später liefern. Berichte weisen auf noch fehlende Ortsgeometrie hin, ohne dadurch die Konfiguration ungültig zu machen. Die Testanwendung benötigt darüber hinaus die Geometrie aller registrierten Orte, um vollständige Testwebhooks zu erzeugen; sie kann dazu bestätigte Lerndaten, gespeicherte produktive Geometrie oder die aktuelle Debug-Geometrie verwenden.

Entfernungsnachweis eines gewöhnlichen Ortes bedeutet: Der Abstand zwischen den Kreismittelpunkten muss größer als die Summe aus Home-Radius, Ortsradius und `departure_margin` sein. Auch ein ausreichend weit entfernter Helferort kann deshalb bestätigen, dass Home verlassen wurde. Eine Bewegungsklassifikation allein ist kein Entfernungsnachweis.

Veraltete Geometrie überschreibt keine neuere Geometrie. Unterschiedliche Geometrien mit identischem Zeitstempel sperren die Entscheidung, bis eine neuere widerspruchsfreie Beobachtung eintrifft. Das Ändern einer Kennung macht Geometrie einer anderen Identität unbrauchbar.

### 4.2 Reihenfolge und Frische

GeoPresence speichert Beobachtungszeit und Empfangszeit getrennt. Eine kurze Warteschlange von standardmäßig zwei Sekunden ordnet Ereignisse je Person und Betriebsbereich nach ihrer Beobachtungszeit. Der erste Empfang bestimmt die feste Bündelfrist anhand der monotonen Uhr. Sobald eine Meldung dieses Kontexts fällig ist, verarbeitet der nächste Timerlauf alle bis dahin vorliegenden Meldungen dieses Kontexts gemeinsam. Spätere Eingänge verlängern die Frist nicht; Produktiv- und Debug-Bereich sowie unterschiedliche Personen besitzen jeweils eigene Bündel. Ein leerer Geo-Puffer hält Telefonereignisse und fällige Ankunftsbestätigungen nicht zurück.

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

### 5.3 Verwerfen von Berechtigungen

Bestätigte Heimkehr verbraucht die Reiseberechtigung. Ein neuer Ausflug beginnt mit neuen Nachweisen. Manuelles ROOMMATE `home`, relevante Konfigurationsänderung, Identitätswechsel, Geometrieänderung, Uhrsprung oder widersprüchliche Beobachtungen widerrufen alte Berechtigungen. Ein Neustart darf ausschließlich den in [[#11. Persistenz und Lebenszyklus|Kapitel 11]] beschriebenen gültigen, noch offenen Ausflug fortsetzen.

Der Status `absent` ist kein Arbeitsort. Ein Ortslabel beschreibt einen tatsächlich beobachteten Ort; der allgemeine Abwesenheitsort lautet `underway`. Ortsnamen und Gruppen haben keine fest programmierte Sonderwirkung auf ROOMMATE.

## 6. Telefonquellen

### 6.1 Aggregation mehrerer Haussensoren

`phoneProxies` enthält die einzelnen PRESENCE-Geräte des Telefons. Ein gesunder positiver Sensor genügt für Anwesenheit. Für Abwesenheit müssen alle konfigurierten Sensoren gesund und negativ sein. Unknown, disabled oder ein erkennbarer Sensorfehler zählen nicht als negatives Messergebnis.

Ein Raumwechsel kann einen Sensor verlieren und einen anderen gewinnen; mehrere Sensoren dürfen gleichzeitig positiv sein. Eine kurze Empfangslücke hält Anwesenheit als `present/handover`. Rückkehr eines Signals innerhalb dieser Phase ist keine neue Heimkehr. Die Entfernungssperre berücksichtigt diese gehaltene Anwesenheit ebenfalls.

### 6.2 Messvertrag

| `phoneSignalMode` | Positiver Wert | Negativer Wert |
|---|---|---|
| `state` | Bleibt bis zum Zustandswechsel oder erkennbaren Fehler gültig | Alle gesunden negativen Zustände müssen über `phone_absence_window` bestehen; erneute identische Meldungen sind nicht erforderlich |
| `measurement` | Benötigt periodisch erneuerte Messungen und gültige Messzeit | Benötigt frische Messungen aller Sensoren und erneute Messungen innerhalb der Qualifikation |

`state` ist der Standard für zustandsmeldende Sensoren. Es kann einen still ausgefallenen Sensor mit unverändertem gesundem Zustand nicht selbst erkennen; die Quelle muss Fehler kenntlich machen. `measurement` ist nur für Sensoren geeignet, die ihren unveränderten Zustand tatsächlich regelmäßig bestätigen. Reines Polling durch GeoPresence erzeugt keine neue Messzeit.

Die Standarddauer für qualifizierte Abwesenheit ist 180 Sekunden. Neue Geo-Positionsbeobachtungen setzen eine zeitliche Grenze: Alte negative Telefonwerte dürfen eine frisch bestätigte Heimkehr oder Annäherung nicht wieder zu `away` machen. Eine Heimkehr beendet die vorherige Negativqualifikation.

## 7. Rückkehr und Bewegungsdaten

### 7.1 Rückkehr bestätigen

Ein gültiger Home-Eintritt nach einem berechtigten, mindestens `minimum_away` langen Ausflug startet eine vorgemerkte Rückkehr. Beide Zeitachsen müssen die Mindestabwesenheit bestätigen. Die Vorgabe beträgt 60 Sekunden; sie ist unabhängig von der Ankunftsfrist.

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

Ein bestätigter, noch nicht abgeschlossener produktiver Ausflug wird im versionierten Reading `gp_trip_checkpoint` als ein zusammengehöriger JSON-Datensatz gespeichert. Er enthält ursprünglichen Beginn und Abwesenheitsnachweis, lokale/ferne Reichweite, beobachtete Orte und Gruppen, explizite Austritte sowie verbrauchte Aktionen und Nachrichten. Zugangsdaten, Aktoraufträge, Ereigniswarteschlangen, Telefonqualifikationstimer und Ankunftswartezeiten werden nicht gespeichert. Die Größe ist auf 64 KiB begrenzt; ein zu großer oder nicht darstellbarer Stand wird als nicht wiederherstellbar markiert. Das Schreiben erfolgt ohne FHEM-Ereignisse oder userReadings-Callbacks; unveränderte Timerläufe serialisieren den Stand nicht erneut.

Nach INITIALIZED oder REREADCFG sowie bei Modulreload wird unter aktiven Modi ein neuer Laufzeitkontext aufgebaut und ein vorhandener qualifizierter Checkpoint geprüft. Version und Struktur, Personen-/Telefon-/ROOMMATE-Bindung einschließlich Kennwortprüfwertbindung, Quellenprofil, Geometrie, Regeln und Aktoradapter müssen passen. Spätere gespeicherte Heimzustände des ROOMMATE oder lokale Telefonanwesenheit widersprechen dem Abwesenheitsnachweis. Zeitstempel müssen plausibel sein; die ursprüngliche Abwesenheitsbestätigung darf höchstens `trip_resume_max_age` alt sein, standardmäßig 172800 Sekunden beziehungsweise 48 Stunden. Speichern oder weitere Neustarts erneuern diesen Nachweis nicht. Ein abgelehnter Checkpoint wird entwertet; reine `absent`- oder `gp_arrival_armed`-Readings ohne vollständigen Checkpoint erzeugen keine Berechtigung.

Ein gültiger Ausflug behält seine Kennung und seinen Ortsverlauf, startet im neuen Kontext als `away` und wartet auf eine neue gültige Home- oder Telefon-Rückkehr. Vorherige monotone Timerwerte werden nicht übernommen; Zeitabstände werden aus den ursprünglichen absoluten Nachweiszeiten auf die neue monotone Uhr abgebildet. Nach einem validierten Checkpoint darf eine neue Geo-Beobachtung unmittelbar nach dem Sitzungsbeginn verarbeitet werden; Ereignisse mit Beobachtungszeit vor oder gleich dem neuen Start bleiben ausgeschlossen. Ohne validierten Checkpoint gilt weiterhin die zusätzliche Geo-Anlaufgrenze durch future_tolerance. Bewegungsabhängige Ankunftsfristen und normale Frischeprüfung bleiben wirksam. Der Start selbst sendet keine Öffnung oder historische Nachricht. `gp_resume_status`, `gp_resume_reason` und der Bereich Restart recovery in explain nennen Übernahme oder Ablehnung.

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

Die Lebenszyklustests verwenden einen echten FHEM-Prozess mit Speichern, Beenden, erneutem Start, Modulreload und rereadcfg. Die gespeicherten Moduszeitstempel und die Nachweise des Neustarttests liegen ausdrücklich vor dem realen Neustart, unabhängig von zuvor vorgestellten Testuhren. Geprüft werden aktive, simulierte, deaktivierte und fehlende Modi, das Ende von learning, die Controller-Vorrangregeln, erhaltene Zeitstempel, wiederhergestellte gültige Ausflüge, frische anschließende Rückkehr sowie der Verzicht auf alte Timer und Aufträge. Ein zweiter Prozessneustart darf eine bereits verbrauchte Berechtigung nicht erneut nutzen. Dummy-Kontakte behalten dafür ihre alten Zeitstempel; ihre Positionen werden nicht künstlich aufgefrischt.

Regressionstests prüfen eine Radiusänderung beim Home-Austritt mit zuvor qualifizierter Telefonabwesenheit, die vollständige erneute Qualifikation und eine anschließende Türöffnung nach Fußwegfrist. Gegenproben umfassen GPS-Sprünge, neuere lokale Anwesenheit, ungültige oder widersprüchliche Geometrie, alte Meldungen und das reine Geo-Profil. Bewegungsdaten werden in Wiederholungen innerhalb desselben Bündels und in späteren Timerläufen ergänzt; dabei werden Fristen, Originalzeitstempel, Garagenausschluss bei Fußweg und ausbleibende doppelte Aktionen geprüft. Die FHEM-Integration bestätigt den HTTP-/Timer-Ablauf und die Diagnose mit Dummy-Aktoren.

Laufzeittests unterscheiden einen fremden blockierenden Timer von einem synchronen, absichtlich verzögerten Notify am Dummy-Aktor. Weitere Prüfungen decken Reading-Callbacks, Dateiausgabe einschließlich der eigenen Slow-Run-Diagnose, begrenzte Historien, unveränderte Ausführung und die Trennung inklusiver und exklusiver Messzeiten ab.

Die Ausgaberegressionen prüfen manuelle Heimsetzung während des Türbefehls, abgelaufene und noch gültige Folgeaufträge, Rückrufe von Nachrichten und Licht, kleine Uhrkorrekturen, veränderte Konfiguration und die Bereinigung nicht ausgegebener Reservierungen. Die reale FHEM-Integration verwendet zusätzlich einen Home-setzenden Notify und einen echten Rückruf mit 1,5 Sekunden Wartezeit am Dummy-Türaktor. Die Garage bleibt jeweils unverändert; die Rückmeldung der bereits angeforderten Tür wird weiter übernommen. Eine Gegenprobe richtet im Tür-Rückruf eine unbeteiligte Person ein; der weiterhin berechtigte Garagenbefehl wird dabei ausgeführt.

Weitere Regressionen prüfen Aliasänderungen und Aliaslöschungen innerhalb des Türbefehls, Controller-Sammellöschungen vor und nach der Übernahme, gemeinsam wiederhergestellte Zeitstandardwerte sowie kleine Uhrkorrekturen während Warteschlange und Ankunftsfrist. Die reale FHEM-Gegenprobe stellt die Systemzeit während der Ankunftsfrist um zehn Sekunden zurück und verzögert anschließend den Tür-Rückruf tatsächlich um 2,5 Sekunden; die Garage erhält keine verlängerte Frist.

Die Nachprüfung ergänzt verschiedene Aliaslöschmuster am ROOMMATE bei warmen und kalten Caches sowie die Erneuerung gespeicherter Fehler nach der Musterlöschung von Altattributen. Reale FHEM-Befehle prüfen dabei sowohl den weiter ausgegebenen Garagenbefehl als auch eine erfolgreiche Validierung und Aktivierung nach der Bereinigung.

Die erste Etappe von R-03 prüft einen kontinuierlichen Webhook-Strom, unabhängige Produktiv- und Debug-Fristen sowie jüngere Gegenbeobachtungen vor der Ankunftsbestätigung. Für 64 frische Geo-Meldungen mit unterschiedlichen Beobachtungszeiten begrenzt die Regression die insgesamt verbleibenden Konfliktaufrufe auf höchstens 64; der vorherige Ablauf erzeugte 2.079. Die reale FHEM-Integration prüft dieselbe Bündelverarbeitung über HTTP. Diese Aufrufzähler sind keine Messung eines zeitlichen oder prozentualen Leistungsgewinns.

Die F-11-Regressionen ergänzen ältere akzeptierte Eintritte nach mehreren neueren Home-Meldungen. Sie prüfen ursprüngliche Zeitanker, unveränderte Mitgliedschaften und Besuchszähler, den Vorrang neuerer Bewegung sowie den Ausschluss unbekannter Ursprünge, geänderter alter Geometrie und abgebrochener Ankünfte. Eine verspätete Austrittsmeldung muss weiterhin beim tatsächlich neuesten Home-Eintritt eine neue vollständige Frist beginnen. Die reale FHEM-Integration prüft den späten Fußwegnachtrag über HTTP mit regulärer Timerbestätigung und mit vorzeitiger Telefonbestätigung; Diagnose und Dummy-Aktoren belegen jeweils genau eine Türanforderung und keine Garagenanforderung.

GP-F11-001 ergänzt den Übergang einer zuvor akzeptierten Annäherung zu Home mit gleicher und mit späterer Home-Beobachtungszeit, jeweils mit Timer- und Telefonbestätigung. Der verspätete Fußwegnachtrag muss die Garage sperren, ohne den Home-Zeitanker zu ändern. Weitere Gegenproben schließen vor Home unterbrochene, abgelaufene oder durch eine neuere Annäherung ersetzte Ursprünge aus. Eine vor erfüllter Mindestabwesenheit beobachtete Annäherung darf eine danach berechtigt begonnene Home-Frist durch ihren Nachtrag nicht vorzeitig bestätigen oder verwerfen.

GP-F11-002 prüft verspätete Home-, Annäherungs- und Outer-Austritte nach einer neueren nahen Ortsmeldung, jeweils bei Empfang vor und nach Home. Ein nachgereichter Automotive-Ursprung vor der Unterbrechung darf die Garage nicht freigeben. Gegenproben erhalten neuere Home-Bewegung, einen späteren gültigen Annäherungseintritt und den aktuellen Ursprung bei einem noch älteren Austritt. Eine abweichende alte Geometrie wird weiterhin verworfen. Weitere Austritte während der Home-Frist müssen den tatsächlich neuesten Home-Nachweis verwenden. Die reale FHEM-Integration prüft den nahen Ort und beide Empfangsvarianten über HTTP mit Dummy-Aktoren.

GP-F11-003 setzt `motion_max_age` auf zulässige 20 Sekunden. Ein verspäteter Austritt vor Home trifft erst nach Ablauf dieses Werts ein; die gespeicherte Home-Walking-Sperre muss bei Timer- und Telefonbestätigung erhalten bleiben. Gegenproben entfernen einen früheren Automotive-Nachweis und berücksichtigen spätere Walking-, Running- oder Cycling-Daten weiterhin anhand ihrer angenommenen Gültigkeit. Eine tatsächlich unterbrochene alte Fußwegsperre darf entfallen, und ein neuer gültiger Automotive-Nachweis darf die Entscheidung ändern. Die reale FHEM-Integration prüft die Walking-Sperre mit Timer und Telefon sowie die Teilentwertung eines Automotive-Nachweises.

## 13. Änderungen seit der letzten Version

Änderungen von Version 0.61 auf 0.62:

- GP-F11-003: Ein verspäteter Austritt vor Home erhält die bestehende Home-Vormerkung samt unbetroffener Fahrzeugentscheidung.
- Gemeinsame Bewegungsbewertung für neue Hinweise und Teilentwertung; verbliebene Daten behalten bei Teilentwertung ihren ursprünglichen Bewertungszeitpunkt.
- Kein vollständiger Neuaufbau der Home-Vormerkung und keine Neubewertung, wenn keine Bewegungsdaten entfallen.

Änderungen von Version 0.60 auf 0.61:

- GP-F11-002: Verspätete Austritte unterbrechen bereits den Annäherungsabschnitt, auch nach einer neueren Ortsmeldung und vor der Home-Vormerkung.
- Eine gemeinsame Ursprungszeit begrenzt Austrittsprüfung und Bewegungsergänzung ohne zusätzliche Ereignishistorie.
- Vor Home liegende Unterbrechungen erhalten eine bereits begonnene gültige Home-Frist, entwerten aber frühere Bewegungsursprünge und deren Fahrzeugentscheidung.

Änderungen von Version 0.59 auf 0.60:

- GP-F11-001: Die aktuelle Annäherungsbeobachtung wird beim Home-Eintritt derselben wartenden Ankunft zugeordnet; ihr gültiger Bewegungsnachtrag bleibt wirksam.
- Der vorhandene Annäherungskontext speichert dafür einen Ereignisschlüssel zusätzlich zur Ablaufzeit. Abbrüche löschen ihn auch vor Beginn einer Home-Frist.
- Ältere Annäherungsnachträge prüfen die Mindestabwesenheit anhand des bereits qualifizierten Home-Eintritts und lösen keine vorzeitige Bestätigung aus.

Änderungen von Version 0.58 auf 0.59:

- F-11: Akzeptierte Eintritte bleiben ihrer offenen Ankunft zugeordnet; neuere bewegungslose Meldungen verwerfen ihre Bewegungsnachträge nicht mehr.
- Gemeinsame Ergänzungsprüfung für Geometrie-Vorfilter und Duplikatverarbeitung; vorhandener begrenzter Duplikatspeicher wird weiterverwendet.
- Der neueste Home-Nachweis bleibt bei älteren Ergänzungen erhalten, damit verspätete Austritte die Ankunft weiterhin korrekt unterbrechen.

Änderungen von Version 0.57 auf 0.58:

- Erste Etappe von R-03: Feste Bündelfrist ab erstem Empfang korrigiert F-06; neue Meldungen verschieben ältere nicht mehr beliebig.
- F-05: Chronologisch gruppierte Konfliktprüfung ersetzt den Vergleich sämtlicher Paare; nur gleiche Zeitstempel werden miteinander verglichen.
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
