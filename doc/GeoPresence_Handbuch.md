# GeoPresence – Handbuch

**Version 2.15 · Stand 13.10.2026 · Architektur 0.53**

GeoPresence ist eine Anwesenheits- und Ortssteuerung für FHEM. Es wertet aus, wer zu Hause ist, wer das Haus verlassen hat und wer zurückkehrt, und verbindet diese Informationen mit konfigurierbaren Automationen. So lässt sich beispielsweise beim Betreten eines Gartenbereichs ein Licht einschalten, beim Erreichen eines Arbeitsortes eine Nachricht senden oder bei einer berechtigten Heimkehr die vorhandene Tür- und Garagensteuerung ansprechen. Ziel ist, solche Aktionen passend zur Situation auszuführen und Fehlreaktionen auf einzelne unzuverlässige Meldungen zu vermeiden.

Als Informationsquellen unterstützt GeoPresence **Geofencing und lokale Telefonerkennung**. Für Geofencing wird die App **Geofency auf dem iPhone** verwendet: Du legst dort Orte mit einem Radius fest, und die App meldet deren Betreten oder Verlassen an FHEM. Die lokale Telefonerkennung liefert dagegen Hinweise direkt aus dem Haus, etwa über vorhandene Bluetooth- oder WLAN-Anwesenheitssensoren, die in FHEM als `PRESENCE`-Geräte bereitstehen. GeoPresence wertet diese Sensoren aus; die eigentliche Funkerkennung übernimmt deren bereits eingerichtete Steuerung.

**Beide Quellen lassen sich einzeln oder gemeinsam verwenden.** Weder Geofencing noch lokale Telefonerkennung ist für jeden Bewohner zwingend vorgeschrieben; mindestens eine Quelle muss eingerichtet sein. Du kannst pro Person wählen: nur Geofency, nur lokale Telefonerkennung oder die Kombination aus beiden. Geofency ist deshalb nur erforderlich, wenn Ortsmeldungen genutzt werden sollen. Der reine Telefonbetrieb eignet sich zur Anwesenheitsanzeige und Statusführung; automatische Tür- oder Garagenöffnungen sind in diesem Profil nicht vorgesehen.

Reines Geofencing ist insbesondere unmittelbar am Haus eingeschränkt: GPS-Positionen können über eine Ortsgrenze springen, und bei schlechtem Mobilfunkempfang können Meldungen verspätet oder gar nicht eintreffen. Ein Verlassen und erneutes Betreten des Home-Kreises beweist deshalb noch keinen tatsächlichen Ausflug. Ohne lokale Sensoren verlangt GeoPresence für eine Öffnung einen zusätzlichen Entfernungsnachweis, beispielsweise den Austritt aus einem größeren Außenkreis oder das Erreichen eines ausreichend entfernten Ortes. Ein kleiner Spaziergang innerhalb dieses Außenkreises benötigt dann einen passenden Helferort.

**Den größten Nutzen bietet die Kombination beider Quellen.** Geofency liefert den Verlauf außerhalb des Hauses, während die lokale Telefonerkennung die Anwesenheit zu Hause unabhängig davon bestätigen kann. Ein weiterhin erkanntes Telefon hilft, falsche Geo-Abgänge zurückzuweisen; eine qualifizierte Telefonabwesenheit kann zusammen mit einem Home-Austritt einen kleinen Spaziergang bestätigen. Bei der Rückkehr kann ein neu erkanntes Telefon eine fehlende Home-Meldung ersetzen oder eine laufende Ankunftsprüfung früher abschließen. Mehrere Empfänger im Haus ergänzen sich: Ein positiver Sensor genügt, und ein Raumwechsel mit kurzer Empfangslücke zählt nicht als neuer Ausflug.

Personen, Orte, Ortsgruppen, Aktionen und Regeln werden **direkt in FHEM konfiguriert**. Du bestimmst, für wen eine Regel gilt, welcher Ort sie auslöst und ob zuvor ein anderer Ort oder eine Gruppe verlassen worden sein muss. Bewegungsabhängige Wartezeiten ermöglichen unterschiedliche Ankunftsfristen für Fußwege, Radfahrten und Autofahrten; persönliche Berechtigungen legen fest, wer Tür oder Garage öffnen darf. Diese Einstellungen und die Auswahl der vorhandenen Aktionsarten erfordern keine Änderungen am Modulcode.

Ein getrennter Debug-Betrieb ermöglicht es, Abläufe zu simulieren und geplante Aktionen zu prüfen, ohne Geräte zu schalten, Nachrichten zu senden oder den produktiven Anwesenheitsstatus zu ändern. Lesbare Zustandsberichte und eine bei Bedarf auch produktiv zuschaltbare Diagnose helfen, Entscheidungen nachzuvollziehen. Dieses Handbuch führt Schritt für Schritt von der Installation über die Einrichtung einer Person und ihrer Orte bis zu eigenen Regeln, Tests und der Produktivfreigabe.

## Inhalt

- [[#1. Das System verstehen|1. Das System verstehen]]
- [[#2. GeoPresence installieren und erreichbar machen|2. GeoPresence installieren und erreichbar machen]]
- [[#3. Eine Person einrichten und das Telefon einlernen|3. Eine Person einrichten und das Telefon einlernen]]
- [[#4. Orte anlegen und in Gruppen zusammenfassen|4. Orte anlegen und in Gruppen zusammenfassen]]
- [[#5. Aktionen und Regeln einrichten|5. Aktionen und Regeln einrichten]]
- [[#6. Die Konfiguration testen|6. Die Konfiguration testen]]
- [[#7. Produktiv schalten und speichern|7. Produktiv schalten und speichern]]
- [[#8. Das System im Alltag bedienen|8. Das System im Alltag bedienen]]
- [[#9. Parameter und Befehle nachschlagen|9. Parameter und Befehle nachschlagen]]
- [[#10. Fehler finden|10. Fehler finden]]

## 1. Das System verstehen

### 1.1 Geräte und Aufgaben

| Gerätetyp | Aufgabe | Beispielname |
|---|---|---|
| `controller` | Gemeinsamer Webhook-Eingang, Betriebsmodus, Zeitvorgaben und Diagnose | `System.GeoPresence` |
| `resident` | Eine Person mit eigenem Telefonzugang und einem vorhandenen ROOMMATE-Gerät | `Geo.PERSON` |
| `location` | Ein Geofency-Ort dieser Person mit technischer Funktion und optionalen Gruppen | `Geo.PERSON.ORT` |
| `action` | Auftrag an eine vorhandene Gerätesteuerung oder Nachrichtenfunktion | `Geo.Action.Licht` |
| `rule` | Anlass, Personenauswahl und Bedingungen für eine Aktion | `Geo.Rule.ORTLicht` |

ROOMMATE ist ein eigenständiges FHEM-Modul zur Darstellung der Anwesenheit einer Person. GeoPresence verwendet dessen Status `home` und `absent`; FHEMWEB ist die Weboberfläche, in der Geräte und Attribute gepflegt werden. Die eigentliche Telefonerkennung im Haus kommt bei Bedarf von vorhandenen `PRESENCE`-Geräten, beispielsweise mehreren Empfängern in verschiedenen Räumen.

Eine Ortsgruppe ist kein zusätzliches FHEM-Gerät. Sie entsteht, indem Ortsgeräte im Attribut `groups` denselben frei gewählten Namen erhalten. Jede Person behält ihre eigene Gruppenanwesenheit; zwei Personen mit der Gruppe `Arbeitsorte` teilen ihre Ortsereignisse nicht miteinander.

### 1.2 Die Beispiele lesen

`PERSON`, `ORT`, `ORT2`, `RUECKWEG`, `FHEM_HOST` und `PUBLIC_HOST` sind Platzhalter. Ersetze `PERSON` durch einen kurzen Namen ohne Leerzeichen und verwende diese Schreibweise überall gleich, zum Beispiel in `rr_PERSON` und `Geo.PERSON`. `ORT` bezeichnet im durchgehenden Beispiel einen Gartenbereich, bei dessen Betreten ein Testlicht eingeschaltet werden soll; zusätzliche Beispiele verwenden beliebige Arbeits- und Rückwegorte. Gerätenamen beginnen mit einem Buchstaben und enthalten Buchstaben, Ziffern, Punkt, Unterstrich oder Bindestrich.

| Kennzeichnung | Wo eingeben? |
|---|---|
| **FHEM** | Telnet oder FHEMWEB-Kommandozeile, einen Befehl je Zeile |
| **Shell** | Betriebssystem-Konsole des FHEM-Hosts, außerhalb des FHEM-Prompts |
| **Geofency** | App auf dem Telefon der betreffenden Person |
| **nginx** | Konfiguration des eigenen Reverse-Proxys |

Eine leere Antwort auf `define`, `attr` oder `modify` bedeutet normalerweise Erfolg. Bei einer Fehlermeldung zuerst deren Ursache beheben. Eine bereits vorhandene Definition nicht erneut eingeben. `attr ... residents` und andere Listenattribute ersetzen die gesamte bisherige Liste; bestehende Einträge bei Erweiterungen mit angeben.

### 1.3 Quellenprofil wählen

| `sourceMode` | Voraussetzungen | Verhalten |
|---|---|---|
| `geofency_phone` | Geofency sowie einzelne Haussensoren in `phoneProxies` | Standard; Geo-Orte und lokale Telefonerkennung, einschließlich Telefon-Fallback bei fehlendem Home-Eintritt |
| `geofency_only` | Geofency; keine Haussensoren | Anwesenheit und berechtigte Rückkehr aus Geo-Meldungen; kein Telefon-Fallback |
| `phone_only` | Haussensoren; keine Geofency-Konfiguration | Nur Anwesenheitsstatus; keine automatischen Öffnungen und kein Ortslernen |

Ein Home-Eintritt allein berechtigt keine Öffnung. Es braucht einen bestätigten Ausflug, ausreichende Abwesenheit und eine bestätigte Rückkehr. Im kombinierten Profil kann ein Home-Austritt mit anschließender qualifizierter Telefonabwesenheit einen kleinen Spaziergang bestätigen. Bei `geofency_only` reichen Home-Austritt, Wartezeit und Home-Eintritt nicht aus: Zusätzlich ist ein gültiger Außenkreis-Austritt oder ein hinreichend entfernter registrierter Ort notwendig. Ein Helferort am Spazierweg kann diesen Nachweis liefern; er muss geometrisch ausreichend von Home entfernt sein.

Die Fahrzeugentscheidung erkennt kein bestimmtes eigenes Auto. Sie verwendet frische Bewegungsdaten und gegebenenfalls den bestätigten Fernbereich. Fußweg- oder Radfahrdaten können eine ansonsten aus dem Fernbereich abgeleitete Fahrzeugankunft ausschließen.

### 1.4 Betrieb, Lernen, Simulation und Diagnose unterscheiden

Betriebszustände werden mit **set**, dauerhafte Konfigurationsparameter mit **attr** geändert. Controller und Person verwenden denselben Befehl `set GERÄT mode WERT`; beide starten nach dem Anlegen deaktiviert. Ein Moduswechsel der Person betrifft nur diese Person. Der Controller gibt den gemeinsamen Rahmen vor.

| Controller `mode` | Person `mode` | Wirksamer Betrieb |
|---|---|---|
| `disabled` | Beliebig | Keine neue Verarbeitung; Lernfenster werden abgebrochen |
| `debug` oder `active` | `disabled` | Keine neue Verarbeitung dieser Person |
| `debug` oder `active` | `learning` | Nur Einrichtungsdaten aus Geofency-Testmeldungen sammeln |
| `debug` | `debug` oder `active` | Simulation für diese Personen |
| `active` | `debug` | Nur diese Person bleibt in Simulation |
| `active` | `active` | Produktive Anwesenheit und konfigurierte Aktionen |

```text
set System.GeoPresence mode debug
set Geo.PERSON mode learning
```

Der erste Befehl verhindert produktive Ausgaben für das ganze System. Der zweite öffnet nur für PERSON ein Lernfenster. Bei laufendem Betrieb anderer Personen genügt der zweite Befehl; der Controller darf `active` bleiben. Nach `learnConfirm` oder Ablauf der 15 Minuten ist die lernende Person `disabled`. Erst ein ausdrückliches `set Geo.PERSON mode debug` startet ihre Simulation, `set Geo.PERSON mode active` ihre Produktivfreigabe.

Geofencys Testbuttons **Betreten** und **Verlassen** senden `isTest=true`. Im Lernmodus erfassen sie Telefonkennung und Ortsdaten; außerhalb des Lernmodus werden sie ausschließlich simuliert, auch bei produktivem Betrieb. Bei deaktivierter Person oder deaktiviertem Controller werden sie abgewiesen. Alle Meldungen verwenden dieselbe URL. Testbuttons erstellen in Geofency keinen Aufenthalt und werden nicht automatisch wiederholt.

`mode` ist ein normales Reading und wird mit FHEMs Zustandsdatei gespeichert. Ein Modulreload erhält die aktuellen Modi `active`, `debug` und `disabled`; bei einem FHEM-Neustart oder `rereadcfg` werden diese aus der Zustandsdatei übernommen. Eine zuvor aktive Person arbeitet anschließend automatisch wieder aktiv, sofern auch der Controller aktiv ist. Nur eine neue Person beziehungsweise ein neuer Controller ohne gespeicherten Modus beginnt mit `disabled`. Speichere den gewünschten Betriebsstand mit `save`; bei einem Absturz gilt der zuletzt erfolgreich geschriebene Stand der Zustandsdatei.

`effectiveMode` und `modeReason` an der Person erklären, welcher Modus durch den Controller tatsächlich gilt. Reload oder Neustart beenden Lernen. Ein bereits bestätigter und noch offener produktiver Ausflug kann aus seinem gespeicherten Checkpoint übernommen werden; neue Rückkehrbeobachtungen sind weiterhin nötig. Unbestätigte Reisen und alte Ankunftstimer werden verworfen. Modusänderungen verwerfen die betroffenen Reisen einschließlich Checkpoint. Wiederholtes Setzen desselben Modus setzt keine Reise zurück und verlängert kein Lernfenster.

Der **Gerätestatus** der Person in FHEMWEB und `list` zeigt den wirksamen Betriebsmodus aus `effectiveMode`: `disabled`, `learning`, `debug` oder `active`. Eine neu angelegte Person zeigt `disabled`; nach Bestätigung oder Ablauf des Lernfensters kehrt die Anzeige ebenfalls zu `disabled` zurück. Ist die Person auf `active` gestellt, der Controller aber auf `debug`, zeigt ihr Gerätestatus `debug`. Die persönliche Einstellung bleibt im Reading `mode` sichtbar; `modeReason` erklärt den Einfluss des Controllers. Nach Reload oder Neustart wird die Anzeige aus den gültigen Modi neu berechnet. Anwesenheit wie `home` oder `absent` steht weiterhin beim verknüpften ROOMMATE; der Gerätestatus erteilt keine Öffnungsberechtigung.

`debugLog` steuert unabhängig davon die Dateidiagnose: `auto` für Simulation und Lernen, `1` zusätzlich für Produktion, `0` ausgeschaltet. Weder Lernen noch Simulation ändern produktive ROOMMATE-Werte, schalten Geräte oder versenden Nachrichten. Bereits vorher produktiv gestartete Aktorvorgänge werden weiter auf ihren Abschluss beobachtet.

### 1.5 Befehle in FHEMWEB ausführen

Öffne die Detailseite des betreffenden Geräts. Wähle in der Zeile **set** den Befehl und daneben seinen Parameter; erst **set** führt ihn aus. **attr** konfiguriert dagegen zum Beispiel Quellen, Zeitwerte und Regelreferenzen. Die englische Hilfe erscheint beim Auswählen.

| Gerät | Set-Befehl | Parameter |
|---|---|---|
| Controller | `mode` | `active`, `debug`, `disabled` |
| Person | `mode` | `active`, `debug`, `disabled`; bei Geofency zusätzlich `learning` |
| Person | `learnConfirm` | Kein Parameter; erfasste Einrichtung bestätigen |
| Person | `webhookPassword` | Eigenes zufälliges Kennwort |
| Controller | `applyGeometry` | Person auswählen |
| Controller | `debugReset` | Person oder Person plus `keepGeometry` |
| Controller | `debugPhoneMode` | Person plus `live` oder `simulated` |
| Controller | `debugPhone` | Person plus `present` oder `absent` |
| Controller | `debugAdvance` | Person und Sekunden, zum Beispiel `Geo.PERSON 180` |

`learnConfirm` und das Kennwort gehören zur Person. Geometrie- und Testwerkzeuge am Controller bieten passende Personen als Dropdown an. Alternativ kannst du die vollständigen Befehle in die FHEMWEB-Kommandozeile oder Telnet eingeben. Alle Voraussetzungen stehen in [[#9.4 Bedienbefehle|Abschnitt 9.4]].

## 2. GeoPresence installieren und erreichbar machen

### 2.1 Voraussetzungen

Du benötigst eine funktionierende FHEM-Installation, Zugriff auf deren Modulverzeichnis und Kommandozeile sowie für Geo-Betrieb Geofency auf dem iPhone. Das Modul verwendet die Perl-Bibliotheken JSON::PP, Digest::SHA, MIME::Base64, Encode, Time::Local, Time::HiRes, POSIX und IO::Socket::INET. FHEM muss diese laden können. Für automatische Tests wird Python ab Version 3.9 auf dem FHEM-Host benötigt; zusätzliche Python-Pakete sind nicht erforderlich.

Lege `98_GeoPresence.pm` im Verzeichnis `FHEM` deiner Installation ab. Kopiere bei Bedarf `tools/geopresence_test.py` auf denselben Host. Das Modul wird beim ersten `define` geladen; nach Austausch einer bereits geladenen Moduldatei wird `reload 98_GeoPresence.pm` verwendet.

Für private Daten im Repository-Arbeitsverzeichnis sind `private/logs/`, `private/config/` und `private/captures/` vorgesehen. Die Testanwendung legt ihre Berichte standardmäßig unter `private/reports/` ab. In `private/` ist nur die [README zur privaten Ablage](../private/README.md) für Git freigegeben; die Betriebsdaten werden ignoriert. Die Softwaretests verwenden eigene erfundene Personen, Orte und künstliche Geometrie. Einrichtung und Betrieb lesen ihre realen Daten weiterhin aus FHEM. Die README erklärt außerdem lokale Zugriffsrechte und die Anonymisierung vor einer Weitergabe.

Für `geofency_phone` und `phone_only` müssen die tatsächlichen Haussensoren bereits als `PRESENCE`-Geräte funktionieren. GeoPresence richtet deren Bluetooth-, WLAN- oder sonstige Scanner nicht ein. Mit `list TYPE=PRESENCE` lassen sich vorhandene Geräte anzeigen. Wenn keine solchen Sensoren vorhanden sind, verwende `geofency_only`.

### 2.2 Controller anlegen

**FHEM, nur wenn noch kein GeoPresence-Controller existiert:**

```text
define System.GeoPresence GeoPresence controller
attr System.GeoPresence room Presence
set System.GeoPresence mode debug
attr System.GeoPresence webhookPath geopresence
attr System.GeoPresence webhookPort 8090
attr System.GeoPresence logFile ./log/geopresence-%Y-%m.log
attr System.GeoPresence debugLog auto
```

Es gibt genau einen Controller. Der Logpfad ist relativ zum Arbeitsverzeichnis von FHEM; das Verzeichnis muss vorhanden und für den FHEM-Prozess beschreibbar sein. Ein absolutes Verzeichnis ist ebenfalls möglich.

**FHEM, nach einigen Sekunden:**

```text
get System.GeoPresence logStatus
get System.GeoPresence validate
```

**Erwartet:** Der Diagnosebericht zeigt einen verwendbaren Dateipfad ohne Fehler. Die Validierung meldet keine Transportfehler. Solange noch keine Person eingerichtet ist, beweist dies nur, dass der Controller bereit ist.

### 2.3 Netzwerk und HTTPS einrichten

Ohne weiteres Attribut lauscht der Webhook nur auf `127.0.0.1`. Ein Reverse-Proxy auf demselben Rechner kann `http://127.0.0.1:8090` als Backend verwenden. Ein Proxy auf einem anderen Rechner benötigt eine konkrete lokale IPv4-Adresse des FHEM-Hosts und eine Freigabe seiner eigenen Quelladresse.

**FHEM, nur für einen Proxy auf einem anderen Rechner; Beispieladressen vorher ersetzen:**

```text
attr System.GeoPresence webhookBindAddress 192.0.2.20
attr System.GeoPresence webhookAllowedPeers 192.0.2.10
```

`192.0.2.20` steht hier für die tatsächlich am FHEM-Host konfigurierte lokale Adresse; `192.0.2.10` für die vom FHEM-Host gesehene Adresse des Proxys. Dies sind Dokumentationsadressen und keine verwendbaren Vorgaben. Die Firewall muss TCP 8090 vom Proxy zum FHEM-Host zulassen. Nach außen wird HTTPS am Proxy bereitgestellt.

Die [nginx-Vorlage](GeoPresence_nginx.conf) enthält den passenden exakten Pfad. Ersetze die Backend-Adresse und integriere die Blöcke in deinen HTTPS-Server. Für diesen Pfad muss der `Authorization`-Header an GeoPresence weitergegeben werden; eine zusätzliche, abweichende Basic-Authentifizierung des Proxys würde die Geofency-Anmeldung verhindern. Andere FHEM-Pfade behalten ihren eigenen Zugangsschutz.

Die gemeinsame externe URL lautet im Beispiel `https://PUBLIC_HOST/fhem/geopresence`. Der Pfad muss den GeoPresence-Port erreichen, nicht FHEMWEB. Unterpfade sind nicht gültig.

**Shell auf dem Proxy beziehungsweise einem erlaubten Rechner:**

```sh
curl -i http://FHEM_HOST:8090/fhem/geopresence
curl -i --data '' https://PUBLIC_HOST/fhem/geopresence
```

**Erwartet:** Der erste Aufruf liefert `405 POST required`, der zweite `401 Authentication required`. Beide Antworten sind bei diesen Aufrufen richtig: Sie belegen Erreichbarkeit, aber noch keine gültige Personenanmeldung. Ein Aufruf des nackten Ports ohne `/fhem/geopresence` liefert `Unknown webhook`. Wenn nur `localhost` funktioniert, zuerst Bind-Adresse, freigegebene Quelladresse und Firewall prüfen.

## 3. Eine Person einrichten und das Telefon einlernen

### 3.1 ROOMMATE vorbereiten

Jede GeoPresence-Person benötigt ein eigenes ROOMMATE-Gerät. Wenn dieses bereits existiert, verwende es. Für eine neue Testinstallation kann die folgende Struktur angelegt werden; eine vorhandene RESIDENTS-Gruppe nicht erneut definieren.

**FHEM, nur für noch nicht vorhandene Geräte:**

```text
define rgr_HAUSHALT RESIDENTS
define rr_PERSON ROOMMATE rgr_HAUSHALT
attr rr_PERSON rr_locationUnderway underway
```

GeoPresence verwaltet die Anwesenheit dieses ROOMMATE-Geräts. Parallel arbeitende Automationen, die denselben Status oder dieselben Türaktionen auslösen, müssen vor der Produktivfreigabe bewusst abgegrenzt werden. Ein externer Wechsel auf `home` gilt als manuelle Heimkehr und widerruft die laufende Öffnungsberechtigung.

### 3.2 Person und Quellen einrichten

Der vorhandene Controller darf aktiv bleiben. Die neue Person startet automatisch `disabled`; die Einrichtung setzt andere Personen nicht zurück. Für das Lernen muss der Controller `active` oder `debug` sein.

**FHEM:**

```text
define Geo.PERSON GeoPresence resident System.GeoPresence rr_PERSON
attr Geo.PERSON room Presence
attr Geo.PERSON webhookUser geo_person
```

Wähle anschließend **genau eines** der beiden Geofency-Profile. Der kombinierte Betrieb benötigt die realen Sensorgerätenamen deines Telefons; die hier genannten Namen sind Platzhalter.

**FHEM, mit Haussensoren:**

```text
attr Geo.PERSON sourceMode geofency_phone
attr Geo.PERSON phoneProxies Phone.PERSON.RAUM1,Phone.PERSON.RAUM2
attr Geo.PERSON phoneSignalMode state
```

**FHEM, alternativ ohne Haussensoren:**

```text
attr Geo.PERSON sourceMode geofency_only
```

Ein einzelner positiver Haussensor genügt für Anwesenheit. Alle eingetragenen Sensoren müssen für die Abwesenheitsqualifikation negativ sein; ein Raumwechsel oder mehrere gleichzeitig positive Sensoren ergeben keine neue Heimkehr. `state` ist für Sensoren bestimmt, die unveränderte Werte nicht regelmäßig erneut melden; Fehler müssen die Sensorgeräte selbst erkennbar melden.

Erzeuge jetzt ein neues zufälliges Webhook-Kennwort mit 24–128 zulässigen Zeichen, beispielsweise aus Buchstaben, Ziffern, `_` und `-`. Verwende für jede Person einen eigenen Account und ein eigenes Kennwort.

**FHEM, Platzhalter vor dem Eingeben ersetzen:**

```text
set Geo.PERSON webhookPassword __ZUFALLSKENNWORT__
```

**Erwartet:** `Webhook password stored in the FHEM key store`. Das Kennwort ist kein Reading und kein Attribut. Eine Gerätekennung `deviceId` wird noch nicht eingetragen; sie wird beim Lernen übernommen.

Für `phone_only` stattdessen nach `define` ausschließlich dieses Quellenprofil, `phoneProxies` und gegebenenfalls `phoneSignalMode` setzen. Webhook-Account, Kennwort, Geofency-Lernen und Ortsanlage entfallen; prüfe den Statuswechsel mit den Telefon-Debug-Befehlen in [[#9.4 Bedienbefehle|Abschnitt 9.4]]. Dieses Profil erhält keine Tür- oder Garagenregeln.

### 3.3 Geofency konfigurieren

Lege auf dem Telefon zunächst **Home**, einen größeren Kreis **UMGEBUNG** um Home und für das Lichtbeispiel **ORT** an. Namen und Radien werden in Geofency gepflegt; Home muss vollständig innerhalb des UMGEBUNG-Kreises liegen. Jeder Ort hat je Telefon eine eigene Kennung, selbst wenn mehrere Personen denselben geografischen Ort benutzen.

Für jeden dieser Orte in Geofency konfigurieren:

| Einstellung | Wert |
|---|---|
| Eintritt-URL und Austritt-URL | Beide `https://PUBLIC_HOST/fhem/geopresence` |
| Webhook senden | Für beide Richtungen einschalten |
| HTTP-Methode | `POST` |
| Account | `geo_person` |
| Kennwort | Genau das in FHEM gesetzte Kennwort |
| SSL-Zertifikate prüfen | Einschalten |
| Bewegungsaktivität | Einschalten, wenn bewegungsabhängige Rückkehrfristen genutzt werden sollen |
| Bei Fehler wiederholen | Für echte Meldungen einschalten |
| Nur WLAN | Ausschalten, wenn unterwegs über Mobilfunk zugestellt werden soll |

Die Anfrage muss die normalen Geofency-Formulardaten enthalten; keine eigenen FHEM-Befehle an die URL anhängen. Ein Browser-GET kann keinen Eintritt simulieren.

### 3.4 Telefon und Ortskennungen lernen

Alle vorbereitenden FHEM-Attribute müssen vor dem Lernstart gesetzt sein. Der Lernempfang läuft 15 Minuten.

**FHEM:**

```text
set Geo.PERSON mode learning
```

**Erwartet:** `Learning for 15 minutes` mit Hinweis auf `learnConfirm`. Die Person hat `mode learning`. Ihr Telefon wird in dieser Zeit nicht abgefragt; normale automatische Geofency-Meldungen werden bestätigt, aber nicht ausgewertet oder nachgeholt.

**Geofency:** Am Ort Home den Testbutton **Betreten** drücken. Anschließend denselben Test für UMGEBUNG und ORT auslösen. Es ist nicht nötig, die Orte tatsächlich zu besuchen. Der erste gültige Test lernt die Telefonkennung und den ersten Ort; weitere Tests müssen von demselben Telefon kommen.

**FHEM:**

```text
get System.GeoPresence learnedLocations Geo.PERSON
set Geo.PERSON learnConfirm
get System.GeoPresence learnedLocations Geo.PERSON
```

**Erwartet:** Die Liste enthält drei Orte mit Name, Nummer, Ortskennung und Radius. Nach `learnConfirm` ist die Person `disabled` und die Telefonbindung konfiguriert; eine bereits vorhandene Kennung wird nicht ersetzt. Notiere die tatsächlichen Nummern, beispielsweise `@1` für Home, `@2` für UMGEBUNG und `@3` für ORT. Die Reihenfolge ist die Empfangsreihenfolge und muss nicht diesem Beispiel entsprechen.

`learnConfirm` bestätigt Telefon und Orte, legt aber keine Ortsgeräte an und führt kein `save` aus. Nach 15 Minuten endet nur der Empfang: Die Person wird deaktiviert, und die erfassten Daten können noch geprüft und mit `set Geo.PERSON learnConfirm` bestätigt werden. Mit `set Geo.PERSON mode disabled` verwirfst du eine unbestätigte Erfassung; anschließend kannst du ein neues Lernfenster starten. Eine leere Erfassung kann nicht bestätigt werden. Bestätigte Lerndaten bleiben im aktuellen Prozess verfügbar, bis ein neuer Lernstart sie ersetzt, die Identität geändert oder FHEM neu gestartet wird.

## 4. Orte anlegen und in Gruppen zusammenfassen

### 4.1 Aus Lerndaten echte Ortsgeräte anlegen

Beim Lernen hat GeoPresence die von Geofency gesendeten Orte gesammelt: Name, Kennung, Koordinaten und Radius. Diese **Lernliste ist noch keine FHEM-Konfiguration**. GeoPresence weiß daraus beispielsweise noch nicht, welchen Ort du als Zuhause verwenden möchtest und wie das zugehörige Gerät in FHEM heißen soll.

In diesem Abschnitt legst du deshalb für jeden benötigten Geofency-Ort ein **Ortsgerät** an. Es verbindet den Ort auf dem Telefon mit einer Funktion in GeoPresence, beispielsweise `home` für Zuhause. Regeln können später auf diese Geräte oder ihre Ortsgruppen Bezug nehmen. Das Anlegen eines Ortsgeräts öffnet keine Tür und erzeugt noch keine eigene Aktionsregel.

**Welcher Modus ist dafür richtig?** Schließe zuerst das Lernen aus [[#3.4 Telefon und Ortskennungen lernen|Abschnitt 3.4]] mit `set Geo.PERSON learnConfirm` ab. Dieser Befehl bestätigt die empfangenen Daten, beendet den Lernempfang und setzt die Person automatisch auf **`disabled`**. Lass sie für die folgenden Einrichtungsschritte in diesem Zustand. Du musst dafür weder erneut `learning` starten noch auf `debug` wechseln. Der Controller darf weiterhin `active` sein, damit andere Personen weiterarbeiten können.

`set Geo.PERSON mode disabled` ist kein Ersatz für `learnConfirm`: Vor der Bestätigung würde dieser Befehl die unbestätigte Erfassung verwerfen. Ist das Lernen bereits bestätigt, kannst du unmittelbar fortfahren.

**Schritt 1: Die bestätigte Lernliste ansehen**

Gib in FHEM ein:

```text
get System.GeoPresence learnedLocations Geo.PERSON
```

Unter **Device learning** muss `Confirmation: Confirmed` stehen; `Reception: Stopped` bedeutet, dass keine weiteren Lernmeldungen erwartet werden. Unter **Captured locations** stehen die erfassten Orte. Im folgenden Beispiel wurden sie in dieser Reihenfolge empfangen:

| Number | Name aus Geofency | Geplanter Zweck in FHEM |
|---|---|---|
| `@1` | Home | Zuhause erkennen |
| `@2` | UMGEBUNG | Einen Ausflug über den größeren Außenkreis nachweisen |
| `@3` | ORT | Gartenbereich für das spätere Lichtbeispiel |

Die Nummern beziehen sich nur auf diese Lernliste. **`@1` bedeutet nicht automatisch Home.** Wenn Home bei dir beispielsweise als `@2` aufgeführt ist, verwendest du für Home im nächsten Befehl `@2`. Zeigt die Abfrage `No current learning data`, führe zunächst das Lernen aus Abschnitt 3.4 durch. Zeigt sie noch eine ausstehende Bestätigung, prüfe die Liste und führe `set Geo.PERSON learnConfirm` aus.

**Schritt 2: Funktion und Gerätenamen festlegen**

Die Funktion beschreibt, wie GeoPresence den Ort auswertet. Sie wird beim Anlegen ausdrücklich gewählt und nicht aus dem Namen in Geofency abgeleitet:

| Funktion | Bedeutung |
|---|---|
| `home` | Zuhause; ein Eintritt kann die Prüfung einer Heimkehr starten. Genau ein solcher Ort je Geofency-Person. |
| `outer` | Größerer Kreis um Zuhause; sein Austritt kann einen Fernausflug nachweisen. Genau ein solcher Ort je Geofency-Person. |
| `place` | Gewöhnlicher Ort, etwa Garten, Arbeit, Schule, Sport oder ein entfernter Helferpunkt. Beliebig viele nach Bedarf. |
| `approach` | Optionaler Kreis zwischen Home und outer; liefert Annäherungs- und Bewegungsinformationen. Höchstens einmal je Person; für die Grundeinrichtung nicht erforderlich. |

Für den Grundbetrieb genügen `home` und `outer`. Der zusätzliche Ort `ORT` gehört zum durchgehenden Gartenlicht-Beispiel dieses Handbuchs.

Als Gerätenamen verwenden wir `Geo.PERSON.Home`, `Geo.PERSON.UMGEBUNG` und `Geo.PERSON.ORT`. Diese Namen wählst du in FHEM selbst; sie müssen noch frei sein. Ersetze `PERSON` überall durch den Namen deiner bereits angelegten Person. Ein Geofency-Name wie `Home`, die Funktion `home` und der FHEM-Gerätename `Geo.PERSON.Home` haben unterschiedliche Aufgaben und müssen nicht gleich geschrieben sein.

**Schritt 3: Die Befehle für Home erzeugen lassen**

Statt die lange Geofency-Kennung von Hand zu übertragen, lässt du GeoPresence die beiden benötigten FHEM-Befehle vorbereiten. Für Home aus der Beispiel-Lernliste lautet die Abfrage:

```text
get System.GeoPresence locationCommands Geo.PERSON @1 home Geo.PERSON.Home
```

Die Bestandteile bedeuten:

| Bestandteil | Bedeutung |
|---|---|
| `get` | Eine Ausgabe abfragen; dieser Aufruf legt noch kein Gerät an. |
| `System.GeoPresence` | Der vorhandene Controller, der die Lerndaten verwaltet. |
| `locationCommands` | Die passenden `define`- und `attr`-Befehle für einen gelernten Ort anzeigen. |
| `Geo.PERSON` | Die Person, deren Lernliste verwendet wird und der das Ortsgerät gehören soll. |
| `@1` | Den Ort mit dieser Nummer aus ihrer Lernliste auswählen. Alternativ ist dessen vollständige `Zone ID` möglich. |
| `home` | Diesem Ort die GeoPresence-Funktion Zuhause zuweisen. |
| `Geo.PERSON.Home` | Name des neu anzulegenden FHEM-Ortsgeräts. |

Der Befehl bedeutet also: „Zeige mir die Befehle, mit denen ich den gelernten Ort Nummer 1 dieser Person als Zuhause unter dem Gerätenamen Geo.PERSON.Home anlege.“

**Schritt 4: Die zurückgegebenen Befehle wirklich ausführen**

Die Ausgabe sieht beispielsweise so aus; **die folgende Kennung ist erfunden und muss nicht mit deiner übereinstimmen**:

```text
define Geo.PERSON.Home GeoPresence location Geo.PERSON home
attr Geo.PERSON.Home zoneId 11111111-2222-4333-8444-555555555555
```

Kopiere **die beiden Zeilen aus deiner eigenen FHEM-Ausgabe** und führe sie nacheinander in FHEM aus. In FHEMWEB findest du sie unter **Commands to copy**; Telnet gibt die beiden Befehle direkt aus.

`define` legt das Ortsgerät an und ordnet es der Person sowie der Funktion `home` zu. `attr ... zoneId` verknüpft dieses Gerät mit genau dem Ort aus Geofency. `zoneId` enthält die Ortskennung aus der Meldung, nicht die Lernnummer `@1`, den Ortsnamen oder die Telefonkennung `deviceId`.

**Erst nach diesen beiden Befehlen existiert das fertig zugeordnete Ortsgerät.** Eine leere Antwort bedeutet normalerweise Erfolg. Falls FHEM einen Fehler meldet, behebe ihn vor dem nächsten Schritt. Ein bereits angelegtes Ortsgerät nicht erneut definieren.

**Schritt 5: Die übrigen Orte auf dieselbe Weise anlegen**

Für die Beispiel-Lernliste erzeugst du anschließend die Befehle für den Außenkreis und den Gartenort:

```text
get System.GeoPresence locationCommands Geo.PERSON @2 outer Geo.PERSON.UMGEBUNG
get System.GeoPresence locationCommands Geo.PERSON @3 place Geo.PERSON.ORT
```

Passe auch hier die Nummern an deine tatsächliche Lernliste an. **Führe nach jeder Abfrage das zurückgegebene Befehlspaar aus**, wie bei Home. Die beiden `get`-Aufrufe allein erzeugen weder den Außenkreis noch den Gartenort.

**Schritt 6: Ergebnis prüfen und die Einrichtung fortsetzen**

Nachdem alle drei Geräte angelegt sind, gib dem Gartenort noch einen lesbaren Anzeigenamen und prüfe die Zuordnung:

```text
attr Geo.PERSON.ORT label Garten
list TYPE=GeoPresence:FILTER=SUBTYPE=location:FILTER=PARENT=Geo.PERSON PARENT ROLE zoneId groups label
get System.GeoPresence validate Geo.PERSON
```

**Erwartet:** Die Liste enthält `Geo.PERSON.Home` mit `ROLE home`, `Geo.PERSON.UMGEBUNG` mit `ROLE outer` und `Geo.PERSON.ORT` mit `ROLE place`. Bei allen drei Geräten steht `PARENT Geo.PERSON` und eine eigene `zoneId`. `label Garten` ändert nur die Bezeichnung in GeoPresence, nicht den Gerätenamen, die Funktion oder den Ort in der App. Die Validierung meldet `OK: configuration valid`; sie führt keine Aktionen aus.

Koordinaten und Radius kommen weiterhin aus Geofency und werden nicht als zusätzliche Attribute eingetragen. Die Ortsanlage allein bestätigt noch nicht die produktive Speicherung dieser Geometrie; diese ausdrückliche Übernahme erfolgt mit `applyGeometry` bei der [[#6.1 Voraussetzungen und Diagnose|Testvorbereitung]] beziehungsweise vor der [[#7. Produktiv schalten und speichern|Produktivfreigabe]].

Lass die Person vorerst `disabled`. Als Nächstes richtest du in [[#5. Aktionen und Regeln einrichten|Kapitel 5]] ihre Aktionen und Regeln ein, prüfst diese in [[#6. Die Konfiguration testen|Kapitel 6]] im Debug-Modus und schaltest sie erst nach erfolgreicher Prüfung in [[#7. Produktiv schalten und speichern|Kapitel 7]] produktiv.

### 4.2 Einen weiteren Ort hinzufügen

Starte `set Geo.PERSON mode learning` und sende in Geofency einen Test für den neuen Ort. Andere Personen können produktiv bleiben. Schließe mit `set Geo.PERSON learnConfirm` ab, lies die neue Nummer mit `learnedLocations` und rufe `locationCommands` mit der gewünschten Funktion und einem noch freien Gerätenamen auf. Führe das ausgegebene Befehlspaar aus und validiere erneut. Bereits angelegte Orte nicht löschen oder nochmals definieren.

Bei einer weiteren Person werden deren eigene Orte nach demselben Verfahren gelernt. Die Ortskennung eines anderen Telefons wird nicht übernommen. Neue Ortsgeräte müssen nicht allein aufgrund ihres Namens dieselben Aktionen bekommen; dafür werden Regeln und gegebenenfalls Gruppen benötigt.

### 4.3 Ortsgruppen verwenden

Das folgende Beispiel setzt zwei bereits gelernte und angelegte `place`-Orte `Geo.PERSON.ORT` und `Geo.PERSON.ORT2` voraus. Verwende diese Namen hier für deine beiden zusammengehörigen Arbeitsorte; das Gartenlichtbeispiel ist ein separater Anwendungsfall und benötigt diese Gruppierung nicht.

**FHEM, solange alle von der Änderung betroffenen Personen deaktiviert oder im Debug sind:**

```text
attr Geo.PERSON.ORT groups Arbeitsorte
attr Geo.PERSON.ORT2 groups Arbeitsorte
```

Eine Gruppe darf frei benannt werden, beispielsweise `Arbeitsorte` oder `Sport`. Mehrere Zuordnungen werden ohne Leerzeichen durch Kommas getrennt, etwa `Arbeitsorte,Sport`. Groß- und Kleinschreibung sind relevant. Eine gemeinsame Regel mit `locationGroup Arbeitsorte` meldet den ersten Gruppeneintritt und den letzten Gruppenaustritt; ein Wechsel zwischen zwei gleichzeitig betretenen Gruppenorten ist kein neuer Gruppenbesuch.

Gruppen werden aus ausdrücklich akzeptierten Ein-/Austritten geführt. Eine fehlende Austrittsmeldung wird nicht aus Zeitablauf oder einer geometrisch unvereinbaren anderen Position erfunden. Dadurch kann bei verlorenen Meldungen eine Gruppennachricht ausbleiben. Eine bestätigte Heimkehr verwirft überholte entfernte Mitgliedschaften und beendet die Reisebedingungen, ohne eine fehlende Austrittsnachricht nachträglich zu erzeugen.

### 4.4 Eine Ortsfunktion ändern

**FHEM, Beispiel für einen gewöhnlichen Ort:**

```text
set Geo.PERSON mode disabled
modify Geo.PERSON.ORT location Geo.PERSON place
get System.GeoPresence validate
```

`modify` erhält `zoneId`, Attribute und Geometrie-Readings. Die Personenzuordnung darf damit nicht geändert werden. Home und outer müssen nach der Änderung weiterhin eindeutig vorhanden sein; erst nach erfolgreicher Validierung wieder aktivieren.

## 5. Aktionen und Regeln einrichten

### 5.1 Erstes vollständiges Beispiel – ORT schaltet ein Licht ein

Für dieses Beispiel ist `ORT` der in Abschnitt 4.1 angelegte Gartenbereich. Das folgende `dummy`-Gerät macht den ersten Test ohne vorhandene Lampenhardware nachvollziehbar. Wenn `test.dev.licht` bereits existiert, sein `define` auslassen.

**FHEM, solange alle von der Änderung betroffenen Personen deaktiviert oder im Debug sind:**

```text
define test.dev.licht dummy
define Geo.Action.Licht GeoPresence action System.GeoPresence switch_on
attr Geo.Action.Licht target test.dev.licht
attr Geo.Action.Licht command on
define Geo.Rule.ORTLicht GeoPresence rule System.GeoPresence
attr Geo.Rule.ORTLicht residents Geo.PERSON
attr Geo.Rule.ORTLicht trigger enter
attr Geo.Rule.ORTLicht locations Geo.PERSON.ORT
attr Geo.Rule.ORTLicht action Geo.Action.Licht
get System.GeoPresence validate
```

**Erwartet:** `OK: configuration valid`. Die Aktion beschreibt `set test.dev.licht on`; die Regel beschreibt **wer**, **wann** und **wo** diesen Auftrag anfordert. Der Eintritt in ORT genügt für diese normale Lichtaktion. Eine Tür- oder Garagenöffnung verlangt dagegen eine bestätigte `arrival`.

Nach erfolgreichem Test kann `target` bei pausierter betroffener Person durch ein reales FHEM-Gerät ersetzt werden, das `set ... on` unterstützt. Dieselbe Hardware darf nicht gleichzeitig als gewöhnliches Lichtziel und als geschütztes Tür-/Garagenziel konfiguriert sein.

### 5.2 Eine Nachricht beim Gruppenwechsel

Nachrichtenaktionen benötigen eine in FHEM geladene Funktion `pushMsg(channel, priority, message)`. GeoPresence richtet keinen Nachrichtendienst ein; ohne diese Funktion meldet `validate` einen Fehler. Wer noch keinen solchen Adapter verwendet, kann die Regel zunächst mit der Lichtaktion testen und die Nachrichtenintegration später ergänzen.

**FHEM, wenn `pushMsg` eingerichtet ist und die Gruppe Arbeitsorte existiert:**

```text
define Geo.Action.Ortsnachricht GeoPresence action System.GeoPresence notify
attr Geo.Action.Ortsnachricht message %resident% entered the area
attr Geo.Action.Ortsnachricht channel 0
attr Geo.Action.Ortsnachricht priority 0
define Geo.Rule.Gruppeneintritt GeoPresence rule System.GeoPresence
attr Geo.Rule.Gruppeneintritt residents Geo.PERSON
attr Geo.Rule.Gruppeneintritt trigger enter
attr Geo.Rule.Gruppeneintritt locationGroup Arbeitsorte
attr Geo.Rule.Gruppeneintritt action Geo.Action.Ortsnachricht
get System.GeoPresence validate
```

Für eine Austrittsnachricht eine eigene Aktion mit passendem Text und eine eigene Regel mit `trigger exit` anlegen. Die folgenden Befehle ergänzen das Eintrittsbeispiel:

```text
define Geo.Action.Austrittsnachricht GeoPresence action System.GeoPresence notify
attr Geo.Action.Austrittsnachricht message %resident% left the area
define Geo.Rule.Gruppenaustritt GeoPresence rule System.GeoPresence
attr Geo.Rule.Gruppenaustritt residents Geo.PERSON
attr Geo.Rule.Gruppenaustritt trigger exit
attr Geo.Rule.Gruppenaustritt locationGroup Arbeitsorte
attr Geo.Rule.Gruppenaustritt action Geo.Action.Austrittsnachricht
get System.GeoPresence validate
```

Eigene Aktionen halten die Wiederholungsfristen unterschiedlicher Nachrichten unabhängig. Ohne gesetzte Werte gelten channel 0 und priority 0. `%resident%` wird durch den Alias des ROOMMATE-Geräts oder dessen Namen ersetzt.

### 5.3 Eine Richtung mit afterExit prüfen

Angenommen, `Geo.PERSON.RUECKWEG` ist ein weiterer angelegter `place`-Ort. Die folgenden Befehle erstellen eine Nachricht und melden dessen Austritt nur, wenn zuvor die gesamte Gruppe Arbeitsorte verlassen wurde; auch hier muss die Nachrichtenfunktion pushMsg vorhanden sein:

```text
define Geo.Action.Rueckwegnachricht GeoPresence action System.GeoPresence notify
attr Geo.Action.Rueckwegnachricht message %resident% passed the return location
define Geo.Rule.Rueckweg GeoPresence rule System.GeoPresence
attr Geo.Rule.Rueckweg residents Geo.PERSON
attr Geo.Rule.Rueckweg trigger exit
attr Geo.Rule.Rueckweg locations Geo.PERSON.RUECKWEG
attr Geo.Rule.Rueckweg afterExit group:Arbeitsorte
attr Geo.Rule.Rueckweg action Geo.Action.Rueckwegnachricht
get System.GeoPresence validate
```

Für einen einzelnen vorherigen Ort lautet die Bedingung beispielsweise `afterExit location:Geo.PERSON.ORT`. Der Austritt muss zeitlich **vor** dem auslösenden Ereignis liegen und zum aktuellen Ausflug derselben Person gehören. Ein erneuter Eintritt in diesen Ort beziehungsweise die Gruppe widerruft den Nachweis. Heimkehr, Reset und widersprochene Reisen erhalten ihn nicht für spätere Ausflüge. Ohne gesetztes `afterExit` besteht diese zusätzliche Bedingung nicht; mit `deleteattr Geo.Rule.Rueckweg afterExit` wird sie entfernt.

`locations` und `locationGroup` sind alternative Auswahlen. Mehrere konkrete Orte in `locations` werden einzeln ausgewertet; sie bilden keine zusammengefasste Gruppenanwesenheit. Eine `arrival`-Regel braucht keine Ortsauswahl, weil Home beziehungsweise der Telefon-Fallback bereits zur Person gehören.

### 5.4 Fahrzeugankünfte unabhängig von der Aktion auswählen

Das folgende Beispiel schaltet dasselbe Licht erst bei einer bestätigten Fahrzeugankunft ein. Verwende für eine eindeutige Prüfung entweder dieses Beispiel oder die ORT-Eintrittsregel; beide gleichzeitig hätten verschiedene gewollte Auslöser für dasselbe Licht.

```text
define Geo.Rule.Fahrzeuglicht GeoPresence rule System.GeoPresence
attr Geo.Rule.Fahrzeuglicht residents Geo.PERSON
attr Geo.Rule.Fahrzeuglicht trigger arrival
attr Geo.Rule.Fahrzeuglicht arrivalFilter vehicle
attr Geo.Rule.Fahrzeuglicht action Geo.Action.Licht
get System.GeoPresence validate
```

`arrivalFilter any` ist der Standard ohne zusätzliche Bewegungsbeschränkung. `vehicle` verwendet frisches `automotive` oder einen bestätigten Fernausflug ohne entgegenstehenden aktuellen Fuß-/Lauf-/Radfahrnachweis. Die Entscheidung bleibt während der Ankunftswartezeit erhalten. Ein zusätzliches `afterExit` kann beide Bedingungen verknüpfen; keine davon ersetzt die Ausflugs- und Rückkehrprüfung.

### 5.5 Tür und Garage anschließen

Die vorhandenen Aktortreiber haben konkrete Schnittstellen. Prüfe vor dem Einrichten, ob deine Geräte diese erfüllen; ein Attributname allein passt ein beliebiges Schloss nicht an.

| Typ | Auftrag | Benötigte Rückmeldung |
|---|---|---|
| `door_open` | `set TARGET lock unlocked` | `contact` mit `state closed/open`; `feedbackDevice` mit `pulse_state pending`, anschließend neuem `confirmed`, `failed` oder `cancelled` |
| `garage_open` | `set TARGET on` | `stateDevice state off/on/movup/movdown` sowie oberer und unterer Kontakt mit `state open/closed` |
| `switch_on` | `set TARGET on` | Erfolgreiche Befehlsübergabe; keine physische Abschlussprüfung |
| `notify` | `pushMsg(channel, priority, message)` | Erfolgreicher Funktionsaufruf; kein Zustellnachweis |

Bei der Garage bedeutet **geschlossen**: Zustand `off`, oberer Kontakt `open`, unterer `closed`. **Offen** bedeutet `on`, oberer `closed`, unterer `open`. Während `movup` oder `movdown` sind beide Kontakte `open`. Andere Kombinationen verhindern eine Öffnung.

`positionSignalMode state` ist für Tür-/Garagenaktionen der Standard. Positionen gelten als gehaltene Zustände: Ein unveränderter Kontakt muss nach einem FHEM-Neustart nicht erst nochmals melden. Die Quellen müssen Zustandswechsel melden und ihren tatsächlichen Zustand nach Ausfällen abgleichen. Unbekannte oder widersprüchliche Werte, zukünftige Zeitstempel, deaktivierte Sensoren und gemeldete Geräte-/IO-Verbindungsfehler sperren die Öffnung. Ein vollständig stummer Ausfall ohne Fehlerhinweis ist aus einem unveränderten Reading allein nicht erkennbar.

`positionSignalMode measurement` verlangt dagegen für jeden Positionswert eine Messung nach Beginn der Controller-Sitzung. Verwende diesen Modus bei Quellen, die regelmäßige Messungen oder eine Aktualisierung beim Start garantieren. Die Rückmeldung über einen **gesendeten Auftrag** benötigt in beiden Modi einen neuen passenden Abschluss; alte `confirmed`-Werte werden nicht wiederverwendet.

**FHEM, Türbeispiel mit vorher durch echte Gerätenamen zu ersetzenden Zielgeräten:**

```text
define Geo.Action.Tuer GeoPresence action System.GeoPresence door_open
attr Geo.Action.Tuer target Door.Control
attr Geo.Action.Tuer command lock unlocked
attr Geo.Action.Tuer contact Door.Contact
attr Geo.Action.Tuer feedbackDevice Door.Feedback
attr Geo.PERSON allowDoor 1
define Geo.Rule.Tuerankunft GeoPresence rule System.GeoPresence
attr Geo.Rule.Tuerankunft residents Geo.PERSON
attr Geo.Rule.Tuerankunft trigger arrival
attr Geo.Rule.Tuerankunft action Geo.Action.Tuer
```

**FHEM, optionales Garagenbeispiel:**

```text
define Geo.Action.Tor GeoPresence action System.GeoPresence garage_open
attr Geo.Action.Tor target Gate.Control
attr Geo.Action.Tor command on
attr Geo.Action.Tor stateDevice Gate.State
attr Geo.Action.Tor upperContact Gate.Upper
attr Geo.Action.Tor lowerContact Gate.Lower
attr Geo.PERSON allowGarage 1
define Geo.Rule.Torankunft GeoPresence rule System.GeoPresence
attr Geo.Rule.Torankunft residents Geo.PERSON
attr Geo.Rule.Torankunft trigger arrival
attr Geo.Rule.Torankunft arrivalFilter vehicle
attr Geo.Rule.Torankunft action Geo.Action.Tor
get System.GeoPresence validate
```

Öffnungsaktionen sind ausschließlich an `arrival` erlaubt; der Garagentreiber benötigt `arrivalFilter vehicle`. `allowDoor` und `allowGarage` sind persönliche Berechtigungen und standardmäßig `0`. Für mehrere Personen die komplette `residents`-Liste der passenden Regel angeben und jede persönliche Berechtigung getrennt setzen.

GeoPresence sendet pro berechtigtem Ausflug und Aktor höchstens einen Auftrag. Gleichzeitige Ankünfte dürfen einen noch laufenden Auftrag teilen. Fehlende Rückmeldung führt nach `actor_timeout` zu `uncertain`; es wird nicht automatisch ein zweiter Impuls gesendet. Die tatsächliche Dauer der Entriegelung bestimmt deine Türsteuerung.

## 6. Die Konfiguration testen

### 6.1 Voraussetzungen und Diagnose

**FHEM:**

```text
get System.GeoPresence validate Geo.PERSON
get System.GeoPresence explain Geo.PERSON debug
set System.GeoPresence applyGeometry Geo.PERSON
set Geo.PERSON mode debug
set System.GeoPresence mode active
get System.GeoPresence explain Geo.PERSON debug
get System.GeoPresence logStatus
```

Die Geometrieübernahme ist bei `phone_only` auszulassen. Nach bestätigtem Lernen stehen die Metadaten für die angelegten Orte bereits bereit; vor der Übernahme die Radien in `explain` prüfen.

**Erwartet:** Gültige Konfiguration, `Debug ready` mit Wert `Yes` und aktive Dateidiagnose. Andere aktive Personen können weiter produktiv arbeiten; PERSON bleibt simuliert. Alternativ darf der Controller für alle Personen auf `debug` bleiben. Während eines Testlaufs keine Attribute oder Modi ändern.

### 6.2 Den Lichtweg erstmals vollständig prüfen

Dieses Beispiel verwendet ausschließlich die ORT-Lichtregel aus Abschnitt 5.1. Die ausführliche [Testanleitung](GeoPresence_Testanleitung.md) beschreibt zusätzlich Gruppen-, Richtungs- und Öffnungstests.

**Shell auf dem FHEM-Host:** Die in `logStatus` genannte Datei verfolgen, zum Beispiel `tail -n 0 -F /PFAD/ZUR/AKTUELLEN/LOGDATEI`. Der Dateiname wird vom konfigurierten Muster abgeleitet.

| Schritt | Bedienung | Erwartung |
|---|---|---|
| 1 | FHEM: `set System.GeoPresence debugReset Geo.PERSON`; anschließend mindestens 35 Sekunden warten | Neue isolierte Reise und Anlaufgrenze abgewartet, keine produktive Änderung |
| 2 | Geofency: Home, UMGEBUNG und ORT jeweils **Verlassen** testen; zwischen Meldungen mindestens 8 Sekunden warten | HTTP `OK debug accepted; no actions`; fehlende Geometrie wird übernommen, noch kein Lichtplan |
| 3 | FHEM: `get System.GeoPresence explain Geo.PERSON debug` | Alle benötigten Ortszeilen mit Radius und `known`; `Not learned` zuerst mit einem weiteren Testbutton synchronisieren |
| 4 | Geofency: ORT **Betreten**, mindestens 8 Sekunden warten | Diagnose mit `would execute; debug suppressed`, `kind: switch_on`, `rule: Geo.Rule.ORTLicht` |
| 5 | Geofency: ORT erneut **Betreten**, mindestens 8 Sekunden warten | Kein zweiter Lichtplan für denselben Besuch |
| 6 | FHEM: `list test.dev.licht state` und `list rr_PERSON state` | Keine produktive Änderung durch die Simulation |
| 7 | FHEM: `set System.GeoPresence debugReset Geo.PERSON keepGeometry` | Testreise verworfen; Ortsgeometrie für weitere Prüfungen erhalten |

Die erste Pause beträgt mindestens `future_tolerance + 5` Sekunden. Die acht Sekunden zwischen den folgenden Schritten reichen für die Standard-Poll-/Sortierfristen; bei geänderten Zeiten mindestens `max(phone_poll, reorder_window) + 3` Sekunden und die sichtbare Verarbeitung abwarten. Ein erneuter Besuch braucht ORT-Austritt, neuen Eintritt und den Ablauf von `cooldown` seit dem letzten Plan. Geofencys Testbuttons erzeugen auch im aktiven Betrieb keine reale Lichtschaltung.

### 6.3 Automatische Öffnungstests verwenden

Die Anwendung benötigt konfigurierte Türregeln, `allowDoor 1` und bekannte Ortsgeometrie. Bei einer reinen Lichtkonfiguration stattdessen den obigen Test verwenden. Für eine Person ohne Garage `--door-only` ergänzen.

**Shell, kombinierter Betrieb ohne Arbeits-/Rückwegregeln:**

```sh
python3 tools/geopresence_test.py --url https://PUBLIC_HOST/fhem/geopresence --resident Geo.PERSON --log ./log/geopresence-%Y-%m.log --tests 3,4,6,7,8,9,11,12,13
```

**Shell, nur Geofency:**

```sh
python3 tools/geopresence_test.py --url https://PUBLIC_HOST/fhem/geopresence --resident Geo.PERSON --log ./log/geopresence-%Y-%m.log --tests all
```

Die Aufrufe verwenden den Logpfad der Einrichtung in diesem Handbuch; bei anderer Konfiguration `--log` entsprechend anpassen. Das Webhook-Kennwort wird verdeckt abgefragt. Die Anwendung wartet reale Fristen ab, sendet ausschließlich Test-Webhooks und prüft die dazugehörigen neuen Logzeilen. Sie ändert keine Konfigurationsattribute oder realen Geräte. Ergebnis und Fehlerdetails stehen in einer neuen privaten JSON-Datei. Die genaue Testauswahl und Arbeitsgruppenparameter stehen in der Testanleitung.

## 7. Produktiv schalten und speichern

Aktiviere nur eine vollständig validierte und getestete Person. Die Webhook-URL bleibt unverändert.

**Bei einem Geofency-Profil zuerst die geprüfte Geometrie bestätigen, solange die Person noch im Debug-Betrieb ist:**

```text
get System.GeoPresence explain Geo.PERSON debug
set System.GeoPresence applyGeometry Geo.PERSON
```

Alle registrierten Orte müssen in `explain Geo.PERSON debug` ihren korrekten Radius und `known` zeigen. Fehlende Orte mit Geofencys Testbuttons senden und mindestens acht Sekunden auf die Auswertung warten; eine noch laufende Erfassung zuvor mit `set Geo.PERSON learnConfirm` bestätigen und danach `set Geo.PERSON mode debug` wählen. Bei erhöhtem `phone_poll` oder `reorder_window` den größeren Wert plus drei Sekunden abwarten. Nach `learnConfirm` können passende Lerndaten die bereits definierten Ortsgeräte mit Metadaten versorgen. Unbestätigte Erfassungen oder noch nicht angelegte Ortsgeräte genügen nicht. Die Übernahme ist auch bei deaktivierter Person mit bestätigten Lerndaten möglich.

`applyGeometry` speichert ausschließlich die geprüfte Geometrie in den normalen `gp_geometry`-Readings und verwirft die bisherigen Reisen dieser Person. Die Rückmeldung beginnt mit `Geometry applied for ... location(s); trips reset; no actions.` Unveränderte Geometrien werden nicht erneut geschrieben; eine Anzahl von null ist deshalb ebenfalls erfolgreich. Der Controller darf dabei `active` bleiben, wenn die Person debug oder mit bestätigten Lerndaten disabled ist. Das Telefonprofil `phone_only` überspringt diesen Schritt.

Anschließend bleibt die Geometrie bei Moduswechsel und Reload verfügbar. Testaufenthalte und Öffnungsberechtigungen werden nicht übernommen. Die Übernahme löst keine Ortsereignisse, `userReadings`, Statusänderungen, Nachrichten oder Aktoraufträge aus und ruft nicht selbst `save` auf. Fehlende Daten, widersprüchliche Kreise, falsche Kennungen, ein mit `debugAdvance` verschobener Zeitbezug und ein älterer abweichender Stand gegenüber produktiver Geometrie führen zur Ablehnung ohne Teilübernahme.

**FHEM:**

```text
get System.GeoPresence validate
set System.GeoPresence mode active
set Geo.PERSON mode active
get System.GeoPresence explain Geo.PERSON
```

Für die Produktivprüfung müssen echte, nicht mit `isTest` markierte Geofency-Meldungen eintreffen. Nach bestätigter Geometrie kann ein neuer echter Besuch beziehungsweise Ausflug die Regeln bereits auswerten. Ohne vorheriges `applyGeometry` oder bei später erneut geänderter Geometrie löst das Ereignisbündel der Übernahme keine Aktion aus. Ein gültiger Home-Austritt kann dabei bereits einen neuen unbestätigten Ausflug beginnen; für eine spätere Öffnung sind neue Abwesenheits- und Ankunftsnachweise erforderlich. Das Verhalten bei Änderungen beschreibt [[#8.3 Radius oder Koordinaten ändern|Abschnitt 8.3]].

Beim Lichtbeispiel wird `test.dev.licht` beim echten neuen ORT-Eintritt `on`. Bei Öffnungsregeln einen neuen qualifizierten Ausflug und anschließend die bestätigte Rückkehr beobachten. Im kombinierten Profil reale Telefonsensoren prüfen; bei `geofency_only` den zusätzlichen Entfernungsnachweis einplanen. Aktorauftrag und mechanische Rückmeldung getrennt kontrollieren.

**FHEM, erst nach erfolgreicher Prüfung:**

```text
save
```

`save` sichert den vollständigen aktuellen FHEM-Konfigurationsstand, nicht nur GeoPresence. Vorhandene SAVE-Automationen können zusätzliche Aktionen ausführen. Readings werden über FHEMs reguläre Zustandsdatei gespeichert. Ein bestätigter, noch offener Ausflug kann nach einem Neustart wiederhergestellt werden; die Details stehen in [[#8.4 Neustart während eines Ausflugs|Abschnitt 8.4]].

## 8. Das System im Alltag bedienen

### 8.1 Zustand und Protokolle lesen

`get System.GeoPresence explain Geo.PERSON` zeigt den vollständigen produktiven Zustand dieser Person. Das gilt auch dann, wenn der Controller oder die Person gerade im Debug-Modus ist. Mit dem zusätzlichen Wort `debug` erhältst du stattdessen die Simulation; `prod` wählt ausdrücklich den produktiven Zustand. Jede Abfrage enthält sämtliche Bereiche: Status, Ankunftsaktionen, Regeln, jüngste Entscheidungen, Telefonquellen, Ortsgeometrie, Aktorrückmeldungen und technische Daten; die Simulation ergänzt die Debug-Bereitschaft.

**Beispiele in FHEM:**

```text
get System.GeoPresence explain Geo.PERSON
get System.GeoPresence explain Geo.PERSON prod
get System.GeoPresence explain Geo.PERSON debug
```

Die erste Zeile lautet **=== PRODUCTION ===** oder **=== DEBUG ===** und benennt die angezeigten Daten. `Resident mode`, `Controller mode`, `Effective mode` und `Mode reason` unter **Status** zeigen eigene Einstellung, Controller-Vorgabe und wirksamen Betriebsmodus samt Begründung. Die Auswahl der Ausgabe schaltet diesen Modus nicht um und löst keine Aktion aus. Eine noch nicht initialisierte Ansicht zeigt `Not initialized`; pausierte Produktivverarbeitung und deaktivierter Betrieb werden ausdrücklich bezeichnet. Auch bei aktivem Betrieb kann eine separate Simulation aus Geofency-Testmeldungen existieren.

**In FHEMWEB:** Öffne die Detailseite von `System.GeoPresence`, wähle im Get-Menü `explain` und anschließend die Person im Dropdown. `Geo.PERSON` und `Geo.PERSON prod` zeigen Produktion, `Geo.PERSON debug` zeigt Simulation. Klicke auf **get**. Der vollständige HTML-Bericht enthält die unteren Bereiche eingeklappt; sie lassen sich einzeln öffnen. Auf der Detailseite eines Bewohners reicht die Auswahl `prod` oder `debug`, denn die Person steht dort bereits fest. Neu angelegte oder gelöschte Personen erscheinen nach Aktualisierung der Controller-Detailseite in der Auswahl.

**In Telnet:** GROSSBUCHSTABEN und Trennlinien kennzeichnen die Abschnitte; Statuswerte sind eingerückt und ausgerichtet. Regeln, Sensoren und Orte erscheinen jeweils als eigener Block mit einem Feld pro Zeile und einer Leerzeile zwischen den Einträgen. GeoPresence fügt innerhalb von Werten oder Erläuterungen keine Zeilenumbrüche ein; eine eventuelle Darstellung langer Zeilen hängt vom Terminal ab. Kennungen und kopierbare Befehle bleiben vollständig.

**Die Angaben einordnen:** `Presence` beschreibt Anwesenheit, nicht die Erlaubnis zum Öffnen. `Current assessment` nennt die Voraussetzungen der jeweiligen Ankunftsaktion; eine Berechtigung ist noch keine Versandbestätigung. Ergebnisse früherer Aufträge stehen unter **Actuator feedback**; noch laufende produktive Vorgänge werden in der Debug-Ausgabe ausdrücklich als produktiv markiert. **Locations and geometry** nennt fehlende Orte und jeden bekannten Radius. `Geometry ready` unter **Debug readiness** bestätigt die für Öffnungen nötige Geometrie; die Testanwendung braucht zusätzlich alle registrierten gewöhnlichen Orte, die unter `Missing location geometry` aufgeführt sind.

**Recent decisions:** Dieser Bereich steht direkt unter **Status** und ist in FHEMWEB beim Öffnen des Berichts ausgeklappt. Ein Klick auf die Überschrift klappt ihn ein oder wieder aus. Der folgende Bereich **Arrival actions** startet eingeklappt. Die jüngsten fünf fachlichen Entscheidungen werden mit dem neuesten Eintrag zuerst angezeigt. `Rule / source` nennt die gespeicherte Regel, den betroffenen Ort, die Telefonbeobachtung oder das Aktor-Ziel. Beispielsweise bezeichnet `phone_snapshot` einen gehaltenen Telefonstatus nach dem Sitzungsstart und `phone_absent` eine qualifizierte Telefonabwesenheit. `Not recorded` bedeutet, dass der Eintrag keine Quelle enthält; das kann bei älteren oder internen Entscheidungen auftreten. GeoPresence ergänzt keine vermutete Quelle aus späteren Ereignissen.

Für Programme `format=json` ergänzen, etwa `get System.GeoPresence explain Geo.PERSON debug format=json`. Die vollständigen Daten der gewählten Ansicht stehen unter `state` und `geometry`; `view` enthält `debug` oder `production`, `mode` den wirksamen Betriebsmodus. `requested_mode`, `controller_mode` und `mode_reason` erklären die beiden Einstellungen und deren Zusammenspiel. Weitere Felder sind `initialized`, `geometry_ready`, `geometry_errors`, `missing_geometry`, `pending_actors` und `errors`; die Debug-Ansicht enthält außerdem `debug_ready` und `debug_blockers`. Die Testanwendung fragt ausdrücklich `explain Geo.PERSON debug format=json` ab und prüft die gemeldete Ansicht vor dem ersten Test. `get System.GeoPresence debugTrace Geo.PERSON limit=20` zeigt mehr Einträge des aufgezeichneten Simulationsverlaufs. Keiner dieser Aufrufe verarbeitet Ereignisse oder bestätigt eine Ankunft.

Normale englische Aktionsmeldungen stehen im FHEM-Log. Ausführliche technische Diagnosen erscheinen ausschließlich in der mit `logFile` gewählten Datei. Mit `attr System.GeoPresence debugLog 1` kann die Diagnose im Produktivbetrieb eingeschaltet werden, ohne den Betriebsmodus zu ändern; `auto` aktiviert sie bei Simulation, `0` deaktiviert sie. FHEMs `verbose` beeinflusst die normalen Logmeldungen.

### 8.2 Konfiguration ändern oder eine weitere Person aufnehmen

Eine neue Person und ihre privaten Orte können bei aktivem Controller eingerichtet werden. Für Änderungen an einer bestehenden Person diese mit `set Geo.PERSON mode disabled` oder `debug` pausieren; ihre Reisen werden verworfen, andere Personen bleiben unbeeinflusst. Änderungen an gemeinsam verwendeten Regeln oder Aktionen erfordern das Pausieren aller betroffenen Personen, einschließlich bisheriger und neu hinzugefügter Regelmitglieder. Alternativ setzt `set System.GeoPresence mode debug` alle freigegebenen Personen in Simulation. Controller-Parameter benötigen Controller debug oder disabled. Ablehnungen nennen die noch aktiven Betroffenen. Nach Validierung die zuvor produktiven Personen ausdrücklich wieder aktivieren.

Eine weitere Person durchläuft Kapitel 3 bis 7 mit eigenen Namen, Zugangsdaten und Ortskennungen. Gemeinsame Aktionen können wiederverwendet werden; die `residents`-Listen der gewünschten Regeln ausdrücklich erweitern. Für eine gemeinsame Gruppenregel müssen alle ausgewählten Personen passende eigene Orte mit demselben Gruppennamen besitzen.

FHEMWEB bietet feste Werte als Dropdowns und Geräteverweise als Auswahl an. Bei Regeln entscheidet `trigger`, ob Ortsauswahl oder `arrivalFilter` relevant ist. `locations` und `locationGroup` schließen sich aus: Vor dem Wechsel das bisherige Attribut mit `deleteattr` entfernen. Auch nach einem Quellenwechsel nennt `validate` unbenutzte gespeicherte Attribute, die du ausdrücklich löschen kannst.

### 8.3 Radius oder Koordinaten ändern

Ändere die Geometrie in Geofency. Sie wird bei einer aktuellen Meldung dieses Orts übernommen und anhand von Home-/Außenkreisverschachtelung geprüft. Eine Änderung verwirft die bisherige Reise, deren Öffnungsberechtigungen und geplante Aktionen.

Kommt die neue Geometrie mit einem gültigen **Home-Austritt**, merkt GeoPresence diesen als Beginn eines neuen, zunächst unbestätigten Ausflugs vor. Eine vorher bereits bestätigte Telefonabwesenheit wird nicht übernommen: Im kombinierten Profil muss sich die Abwesenheit nach dem Austritt erneut über `phone_absence_window` qualifizieren, standardmäßig 180 Sekunden. Frische positive Telefonnachweise können den Verdacht widerlegen. Ein späterer gültiger Entfernungsnachweis kann die Abwesenheit ebenfalls nach dem normalen Quellenvertrag bestätigen; bei `geofency_only` ist dieser zusätzliche Nachweis zwingend. Bei der Rückkehr gilt anschließend die normale Bestätigung durch Ankunftsfrist oder Telefon. Ein **Home-Eintritt** mit neuer Geometrie allein öffnet weiterhin nicht.

Beispiel: Du vergrößerst Home von 100 auf 150 Meter und verlässt danach den Bereich. Im Diagnoselog steht `geometry_changes` mit `radius: 100 -> 150`, gefolgt von `Home departure pending after geometry update; new departure confirmation required`. Nach vollständiger erneuter Telefonabwesenheit zeigt `phone absence qualified` den Wert `departure_armed: 1`. Bei einer späteren Rückkehr mit `walking` folgt die konfigurierte Fußwegfrist und danach der Türplan, sofern die übrigen Bedingungen der Regel erfüllt sind. Zeit allein genügt nicht, um einen unbestätigten Ausflug freizugeben.

Für eine sofortige Überprüfung die Person auf `mode debug` stellen, die Anlaufschutzfrist abwarten und die Geofency-Testbuttons verwenden; das aktualisiert zunächst ausschließlich die **Debug-Geometrie**. Nach Prüfung mit `explain Geo.PERSON debug` die Änderung mit `set System.GeoPresence applyGeometry Geo.PERSON` ausdrücklich übernehmen und erst anschließend die Person wieder aktivieren. Der vollständige Ablauf steht in [[#7. Produktiv schalten und speichern|Kapitel 7]]. Alternativ synchronisiert eine echte Geofency-Meldung die produktive Geometrie automatisch. Ein Testbutton allein und `keepGeometry` stellen keine Produktivübernahme dar.

### 8.4 Neustart während eines Ausflugs

Ein Neustart während deiner Abwesenheit kann den bereits bestätigten Ausflug fortsetzen. GeoPresence speichert dafür `gp_trip_checkpoint` als zusammengehöriges Reading in FHEMs normaler Zustandsdatei. Der Stand enthält den ursprünglichen Abwesenheitsnachweis, die lokale/ferne Reichweite, den Ortsverlauf und bereits verbrauchte Aktionen. Keine zusätzliche Datenbank ist erforderlich. Reines `absent`, ein noch unbestätigter Home-Austritt oder ein Debug-Ausflug reichen dafür nicht.

Nach Neustart, rereadcfg oder Modulreload prüft GeoPresence den gespeicherten Stand. Identität, Kennwortbindung, Quellenprofil, relevante Konfiguration und Geometrie müssen passen; eine spätere lokale Anwesenheit oder ein späteres ROOMMATE `home` widerspricht dem Ausflug. Die ursprüngliche Abwesenheitsbestätigung darf standardmäßig höchstens 48 Stunden alt sein. `trip_resume_max_age` am Controller legt diese Grenze in Sekunden fest; Speichern oder wiederholtes Neustarten erneuert den Nachweis nicht.

**Beispiel:** Du verlässt Home, deine Telefonabwesenheit qualifiziert den Spaziergang, und FHEM startet währenddessen neu. Der Ausflug wird wieder als `away` geführt. Dein anschließender neuer Home-Eintritt startet die normale Fußweg-Ankunftsfrist; danach kann die Tür öffnen. Ein gespeicherter Fernausflug kann bei einer neuen berechtigten Fahrzeugankunft zusätzlich die Garage erlauben. Fehlende neue Bewegungsdaten machen einen alten Fahrzeugnachweis nicht automatisch frisch; die üblichen Fahrzeug- und Fußwegregeln gelten weiterhin.

Beim Start selbst gibt es keine Öffnung oder nachgeholte Nachricht. Bereits begonnene Ankunftswartezeiten und wartende Befehle werden verworfen; für eine Öffnung ist eine neue gültige Rückkehrmeldung nötig. Bei erfolgreich übernommenem Checkpoint kann eine Home-Beobachtung direkt nach dem neuen Sitzungsbeginn verarbeitet werden, ohne zusätzlich 30 Sekunden Anlaufzeit abzuwarten. Vor oder beim Start entstandene Meldungen bleiben ausgeschlossen; die normale bewegungsabhängige Ankunftsfrist gilt weiterhin. Ohne gültigen Checkpoint bleibt der bisherige Anlaufschutz bestehen. Bei abgeschlossener Heimkehr wird der Checkpoint vor den Gerätebefehlen entwertet. Moduswechsel, relevante Konfigurationsänderungen, Uhrsprünge, manuelle Heimkehr oder widersprüchliche Nachweise widerrufen ihn ebenfalls.

**FHEM, nach dem Start prüfen:**

```text
get System.GeoPresence explain Geo.PERSON
list Geo.PERSON gp_resume_status gp_resume_reason gp_arrival_armed
```

`Restart recovery` im Statusbericht sowie `gp_resume_status=restored` erklären eine erfolgreiche Übernahme. `rejected` nennt den Ablehnungsgrund; `none` bedeutet, dass kein qualifizierter Stand übernommen wurde. Im Diagnoselog erscheint `qualified unfinished trip restored; waiting for a new return` mit Quelle `restart`. Der originale Ortsverlauf bleibt bei Übernahme für Bedingungen wie `afterExit` verfügbar.

Ein geordnetes Beenden von FHEM schreibt dessen Zustandsdatei. GeoPresence ruft nicht automatisch `save` auf. Bei abruptem Absturz ist nur der zuletzt erfolgreich geschriebene Stand verfügbar, und während eines Ausfalls verpasste Orts- oder Sensoränderungen lassen sich nicht rekonstruieren. Die Positionsquellen aus [[#5.5 Tür und Garage anschließen|Abschnitt 5.5]] müssen ihren eigenen Zustandsvertrag erfüllen.

## 9. Parameter und Befehle nachschlagen

### 9.1 Controller

| Attribut | Standard / Werte | Wirkung |
|---|---|---|
| `webhookPath` | `geopresence` | Einfacher Pfadname unter `/fhem/` |
| `webhookPort` | `8090`; 1024–65535 | Eigener TCP-Listener |
| `webhookBindAddress` | `127.0.0.1` | Konkrete lokale IPv4-Adresse; kein Hostname oder Wildcard |
| `webhookAllowedPeers` | Loopback, solange nicht anders konfiguriert | 1–16 explizite IPv4-Quelladressen, kommagetrennt |
| `logFile` | Kein Standard; im Beispiel `./log/geopresence-%Y-%m.log` | Ohne Attribut keine Diagnosedatei; Platzhalter `%Y`, `%m`, `%d`, `%H`, `%M` |
| `debugLog` | `auto`, `0`, `1`; Standard `auto` | Diagnose bei Simulation und Lernen, aus oder zusätzlich produktiv |

Alle folgenden Zeiten sind Sekunden; `departure_margin` ist eine Entfernung in Metern. Numerische Controllerwerte müssen größer als 0 und höchstens 172800 sein; Ankunftsfristen und `arrival_motion_max_age` zusätzlich höchstens 300.

| Attribut | Standard | Wirkung |
|---|---:|---|
| `action_max_age` | 90 | Höchstalter von Beobachtung und Empfang für Aktionsverarbeitung |
| `future_tolerance` | 30 | Toleranz für zukünftige Beobachtungszeiten; auch Schutz nach neuem Sitzungsbeginn |
| `reorder_window` | 2 | Kurze Sammlung zur zeitlichen Sortierung eingehender Meldungen |
| `departure_grace` | 60 | Home-Austritt vor vorläufigem `absent`; allein keine Öffnungsberechtigung |
| `minimum_away` | 60 | Mindestabstand von bestätigender Entfernungsbeobachtung bis Rückkehr |
| `phone_absence_window` | 180 | Zusammenhängende vollständige Telefonabwesenheit |
| `phone_poll` | 5 | Abfrage der einzelnen Haussensoren bei Telefonprofilen |
| `motion_max_age` | 180 | Gültigkeit von Bewegung für Fahrzeugentscheidung; auch Fußwegfrist-Auswahl |
| `arrival_motion_max_age` | 30 | Höchstalter für schnellere Fristen anhand von Laufen, Rad oder Auto |
| `arrival_wait_walking` | 60 | Rückkehrbestätigung bei Fußweg |
| `arrival_wait_running` | 30 | Rückkehrbestätigung bei Laufen |
| `arrival_wait_cycling` | 20 | Rückkehrbestätigung bei Radfahrt |
| `arrival_wait_automotive` | 10 | Rückkehrbestätigung bei Autofahrt |
| `arrival_wait_unknown` | 60 | Rückkehrbestätigung ohne verwertbare Bewegung |
| `approach_timeout` | 600 | Ablauf eines optionalen Annäherungskontexts ohne Home-Rückkehr |
| `zone_display_max_age` | 43200 | Alter sichtbarer Ortsbeobachtungen; erzeugt keinen Gruppenaustritt |
| `actor_timeout` | 60 | Wartezeit auf Rückmeldung eines bereits gesendeten Öffnungsauftrags |
| `trip_resume_max_age` | 172800 | Höchstalter der ursprünglichen Abwesenheitsbestätigung für Wiederherstellung eines offenen Ausflugs nach Neustart/Reload; 48 Stunden |
| `departure_margin` | 200 | Zusätzlicher Abstand zwischen Home-Kreis und entferntem Ortskreis |

Die Ankunftsfrist beginnt beim Empfang des ersten gültigen Home-Eintritts eines berechtigten Ausflugs. Eine neue Austrittsmeldung bricht die Vormerkung ab; ein neuer lokaler Telefon-Ankunftsnachweis kann sie im kombinierten Profil früher bestätigen. Wiederholte Eintritte starten die Frist nicht beliebig neu. Für `geofency_only` muss ein umschließender Entfernungsnachweis zusätzlich auch an seiner Home nächstgelegenen Grenze mehr als `departure_margin` Abstand besitzen.

### 9.2 Personen und Orte

| Gerät / Attribut | Standard / Parameter | Wirkung |
|---|---|---|
| Person: `sourceMode` | `geofency_phone`, `geofency_only`, `phone_only`; Standard kombiniert | Quellenvertrag aus Abschnitt 1.3 |
| Person: `deviceId` | Gelernte Geofency-Kennung | Telefonbindung; automatisch mit `learnConfirm` bestätigt |
| Person: `webhookUser` | Eigener eindeutiger Account | HTTP-Basic-Benutzer für beide Geofency-Profile |
| Person: `phoneProxies` | Nicht leere Liste bestehender PRESENCE-Geräte | Einzelne Raumquellen für beide Telefonprofile |
| Person: `phoneSignalMode` | `state` oder `measurement`; Standard `state` | Gehaltene Zustände oder regelmäßig erneuerte Messungen |
| Person: `allowDoor`, `allowGarage` | Je `0` oder `1`; Standard `0` | Persönliche Öffnungsberechtigung in Geofency-Profilen |
| Ort: `zoneId` | Gelernte Ortskennung dieses Telefons | Zuordnung eingehender Meldungen |
| Ort: `label` | Bei Systemorten Funktion, sonst Gerätename | Lesbarer Ortsname in Status und Log |
| Ort: `groups` | 1–16 eindeutige Namen, kommagetrennt | Freie Gruppen; Namen höchstens 64 Zeichen, beginnend mit Buchstaben |

Im Messmodus muss jeder Sensor wiederholt aktuelle Messungen liefern; deren Gültigkeitszeit beträgt zweimal das längere konfigurierte Scanintervall plus 30 Sekunden. Im Zustandsmodus bleibt ein Wert bis zur Änderung oder erkennbaren Störung gültig. Einen vollständig stummen, vom Sensor nicht gemeldeten Ausfall kann GeoPresence damit nicht erkennen.

### 9.3 Regeln und Aktionen

| Regelattribut | Standard / Parameter | Wirkung |
|---|---|---|
| `enabled` | `1` oder `0`; Standard `1` | Regel auswerten oder auslassen |
| `residents` | Nicht leere Personenliste | Betroffene GeoPresence-Personen |
| `trigger` | `enter`, `exit`, `arrival`; erforderlich | Auslöser |
| `locations` | Liste konkreter Ortsgeräte | Einzelortauswahl für enter/exit; alternativ zu locationGroup |
| `locationGroup` | Ein Gruppenname | Zusammengefasste Ortsanwesenheit je Person für enter/exit |
| `afterExit` | Ungesetzt oder `location:DEVICE` / `group:GROUP` | Zusätzlicher vorheriger Austritt im aktuellen Ausflug |
| `arrivalFilter` | `any` oder `vehicle`; Standard `any` | Zusätzlicher Filter nur für arrival |
| `action` | Ein vorhandenes GeoPresence-Aktionsgerät | Auszuführender Auftrag |
| `cooldown` | 300; ganze Sekunden 0–86400 | Mindestabstand von Nachrichten-/Schaltplänen derselben Aktion je Person |

`cooldown 0` hebt den Schutz gegen Wiederholung desselben Besuchs nicht auf. Eine Richtungsregel mit `afterExit` wird für denselben Ausflug und gewählten Ort beziehungsweise dieselbe Gruppe nicht wiederholt. Öffnungsaufträge haben unabhängig davon ihren eigenen Schutz je Ausflug und Aktor.

| Aktionsattribut | Verwendet bei | Bedeutung |
|---|---|---|
| `target` | Tür, Garage, Licht | Tatsächliches FHEM-Zielgerät |
| `command` | Tür: `lock unlocked`; Garage/Licht: `on` | Fester unterstützter Befehl |
| `contact`, `feedbackDevice` | Tür | Öffnungskontakt und Impulsabschlussgerät |
| `stateDevice`, `upperContact`, `lowerContact` | Garage | Bewegungszustand und Endkontakte |
| `message` | Nachricht | Text mit optionalem `%resident%`, höchstens 500 Zeichen |
| `channel` | Nachricht; `0`, `1`, `2`, `10`; Standard `0` | Kanal des vorhandenen pushMsg-Adapters |
| `positionSignalMode` | Tür/Garage; `state` oder `measurement`; Standard `state` | Gehaltene Positionen oder notwendige Messungen seit Sitzungsbeginn; Abschlussrückmeldungen benötigen in beiden Fällen neue Ereignisse |
| `priority` | Nachricht; `0`, `1`, `2`; Standard `0` | Priorität des vorhandenen Adapters |

Nachrichtentexte dürfen keine Steuerzeichen, Semikolons, geschweiften Klammern oder Backslashes enthalten. Kanalbedeutung und Zustellung hängen von der eingerichteten `pushMsg`-Funktion ab. Die allgemeinen FHEM-Attribute `room`, `alias`, `verbose` und Reading-Attribute besitzen ihre normale Framework-Bedeutung.

### 9.4 Bedienbefehle

| Befehl | Parameter und Wirkung |
|---|---|
| `set System.GeoPresence mode WERT` | `active`, `debug`, `disabled`; globaler Rahmen; Standard disabled; normales gespeichertes Reading |
| `set Geo.PERSON mode WERT` | `active`, `debug`, `disabled` oder bei Geofency `learning`; Standard disabled; betrifft nur diese Person |
| `set Geo.PERSON webhookPassword KENNWORT` | Eigenes zufälliges Kennwort, 24–128 Zeichen; Person darf nicht effektiv active sein; verwirft ihre Lerndaten und Reisen |
| `set Geo.PERSON mode learning` | 15 Minuten nur Einrichtungsdaten sammeln; Controller active oder debug; bei neuem Lernfenster bisherige Liste ersetzen |
| `set Geo.PERSON learnConfirm` | Telefonkennung und Orte bestätigen; Empfang beenden; Person bleibt disabled |
| `set System.GeoPresence applyGeometry Geo.PERSON` | Vollständige geprüfte Debug-Geometrie für registrierte Orte in normalen Readings bestätigen; Person muss effektiv debug oder disabled mit bestätigten Lerndaten sein; keine Aktionen oder Ereignisse, eigene Reisen werden verworfen; normales FHEM-Speichern übernimmt die Readings in die Zustandsdatei |
| `set System.GeoPresence debugReset Geo.PERSON` | Vollständiger Debug-Reset: Testreise, Debug-Geometrie und Uhrverschiebung verwerfen; während learning nicht verfügbar |
| `set System.GeoPresence debugReset Geo.PERSON keepGeometry` | Testreise, Ankunftsvormerkungen und Öffnungsberechtigungen verwerfen, aber Debug-Geometrie für weitere Tests im Speicher behalten; nicht nach debugAdvance verwendbar |
| `set System.GeoPresence debugPhoneMode Geo.PERSON simulated` | Telefonprofile: lokale Sensorwerte für die Simulation ersetzen; `live` liest wieder echte Quellen |
| `set System.GeoPresence debugPhone Geo.PERSON present` | In Telefon-Simulation `present` oder `absent` für alle konfigurierten Quellen liefern |
| `set System.GeoPresence debugAdvance Geo.PERSON 180` | Kontrollierte synthetische Tests: Debug-Uhr um 1–86400 Sekunden ändern; nur mit Telefon-Simulation oder geofency_only |
| `get System.GeoPresence validate` | Konfiguration prüfen; optional eine Person als weiterer Parameter |
| `get System.GeoPresence explain Geo.PERSON` | Vollständiger produktiver Bericht; optional `prod` ausdrücklich angeben; auch im Debug-Betrieb bleibt Produktion der Standard |
| `get System.GeoPresence learnedLocations Geo.PERSON` | Gelernte Kennungen und Orte anzeigen |
| `get System.GeoPresence locationCommands Geo.PERSON @1 place Geo.PERSON.ORT` | Ortsbefehle anzeigen; anschließend selbst ausführen |
| `get System.GeoPresence explain Geo.PERSON debug` | Vollständiger Simulationsbericht einschließlich Ortsgeometrie und Debug-Bereitschaft; kein Moduswechsel |
| `get System.GeoPresence debugTrace Geo.PERSON` | Jüngste Debug-Entscheidungen; optional `limit=ANZAHL` |
| `get System.GeoPresence logStatus` | Diagnosepfad, Freigabe und Schreibfehler anzeigen |
| `get System.GeoPresence timerStats` | Arbeitsdauer, Startverspätung sowie Zeitpunkt und Verarbeitungsschritte langsamer Timerläufe anzeigen; `format=json` liefert vollständige Messreihen |
| `help GeoPresence EN` | Englische integrierte Modulhilfe |

Get-Berichte unterstützen `format=text`, `format=html` und `format=json`. `debugTrace` zeigt standardmäßig die jüngsten Einträge; JSON enthält ohne Limit den gespeicherten Puffer. Kein Get-Befehl bestätigt eine Ankunft oder löst eine Aktion aus.

Während echter Handytests und der Testanwendung kein `debugAdvance` verwenden: Deren Webhooks tragen reale Zeitstempel. Zum Test von `phone_only` nach `debugReset` auf `simulated` stellen, `present` melden und die Verarbeitung abwarten; der simulierte Status wird `home`. Nach `absent` und vollständiger Qualifikationsfrist wird er `absent`, nach neuem `present` wieder `home`. Abschließend `debugReset` und `debugPhoneMode live` setzen.

## 10. Fehler finden

| Beobachtung | Prüfen und nächste Handlung |
|---|---|
| Verbindung nur über localhost möglich | Listener-Bind-Adresse, erlaubte tatsächliche Proxy-IP, Firewall und Backend-Port |
| HTTP 401 | Geofency-Account und Kennwort dieser Person, Weiterleitung des Authorization-Headers, zusätzliche Proxy-Authentifizierung |
| Lernen liefert keine Orte | Person hat mode learning, Controller active/debug, Testbutton mit isTest=true, richtige Person und Zugangsdaten; Lernfenster nach Konfigurationsänderung neu starten |
| Lernliste vorhanden, validate vermisst Home/outer | Die ausgegebenen define-/zoneId-Befehle tatsächlich ausführen und technische Funktionen prüfen |
| validate ist OK, die Testanwendung vermisst aber Ortsgeometrie | `Geometry ready: Yes` im Debug-Bericht bestätigt nur die Öffnungsgeometrie; weitere Orte können noch `Not learned` sein. Bei Person im Debug-Modus für jeden fehlenden registrierten Ort einen Geofency-Testbutton drücken, Verarbeitung abwarten und die Anwendung ohne zwischenzeitlichen Reset starten; siehe [Testvorbereitung](GeoPresence_Testanleitung.md). |
| Nach jedem automatischen Test verschwinden erneut Ortsgeometrien | Modul und Testanwendung gemeinsam aktualisieren; `explain Geo.PERSON debug` muss unter `Geometry-preserving reset` den Wert `Supported` zeigen. Die Anwendung erhält Geometrie bei Vorbereitung und Abschluss mit `debugReset ... keepGeometry`. |
| Nach Wechsel von debug auf active fehlt Geometrie wieder | App-Testmeldungen aktualisieren zunächst nur Debug. Vor dem Moduswechsel die bekannte Geometrie mit `applyGeometry` bestätigen; anschließend `validate` im Produktivmodus prüfen. `keepGeometry` allein gilt nur für Debug-Resets. |
| Unbekannter oder doppelter Ort | Telefonkennung und Ortskennung gehören zusammen; eigene Kennungen je Person lernen |
| Gruppenregel wird nicht angeboten oder validiert nicht | enter/exit wählen, alternative locations entfernen, Tag auf den Ortsgeräten aller betroffenen Personen setzen |
| Rückwegnachricht fehlt | Früherer tatsächlicher Einzel-/Gruppenaustritt im aktuellen Ausflug; erneuter Eintritt, verlorene Meldung oder gleicher Zeitstempel widerrufen beziehungsweise verhindern den Nachweis |
| Status home, aber keine Öffnung | explain: bestätigte Entfernung, aktuelle Reise, Mindestabwesenheit, Bewegung, Ankunftsfrist, persönliche Berechtigung und Aktorzustand prüfen |
| Home-Radius geändert, danach fehlt die Öffnungsberechtigung | Die alten Nachweise wurden verworfen. Ein neuer gültiger Home-Austritt kann den Ausflug beginnen; danach muss die Abwesenheit erneut bestätigt werden. Geometrieänderung erst beim Home-Eintritt: zunächst nur Heimstatus, keine Öffnung. Details stehen in [[#8.3 Radius oder Koordinaten ändern|Abschnitt 8.3]]. |
| geofency_only öffnet beim kleinen Spaziergang nicht | Zusätzlich einen ausreichend entfernten registrierten Helferort oder einen gültigen äußeren Austritt beobachten; Zeit allein genügt nicht |
| Aktor meldet uncertain | Abschlussrückmeldung fehlt oder passt nicht zum Auftrag; Aktortreiber prüfen, keinen automatischen Folgeimpuls erwarten |
| Person ist nach Neustart disabled | `mode` am Controller und an der Person sowie deren `modeReason` prüfen. Gespeicherte active/debug/disabled werden wiederhergestellt; ein zuvor laufendes Lernen endet dagegen deaktiviert. Ohne gespeicherten Modus gilt disabled. |
| Rückkehr nach Neustart öffnet nicht | Restart recovery in explain beziehungsweise gp_resume_status/gp_resume_reason prüfen. Ein gültiger qualifizierter Checkpoint, aktive Modi und eine neue gültige Rückkehr sind erforderlich. Nach Konfigurationsänderung, späterer Heimkehr oder Ablauf der 48-Stunden-Grenze ist der alte Stand nicht mehr gültig. |
| Nach Reload oder Moduswechsel fehlt die Berechtigung | Neue Reise beginnen; alte Nachweise werden absichtlich nicht wiederhergestellt |
| Ausführliche Diagnose fehlt | logStatus prüfen, Verzeichnisrechte korrigieren, debugLog auto oder 1 setzen |

Für eine nachvollziehbare Fehleranalyse den vollständigen Ausflug aus dem Diagnosefile, den passenden Zeitraum des FHEM-Logs und `explain` gemeinsam betrachten. Private Kennungen, Zugangsdaten und Ortskoordinaten vor einer Veröffentlichung entfernen.

### 10.1 Freezes und langsame Timer untersuchen

Eine Freezemon-Zeile mit `GeoPresence_Timer` nennt einen Kandidaten aus dem beobachteten Zeitraum. Sie belegt allein nicht, dass dieser Timer die Verzögerung verursacht hat. FHEM verarbeitet viele Aufgaben nacheinander: Ein blockierender Verbindungsaufbau eines anderen Geräts verzögert auch GeoPresence. Umgekehrt kann ein von GeoPresence aufgerufenes `set` synchron weitere DOIFs, Notifies und Gerätetreiber ausführen; deren Zeit gehört dann zur gemessenen GeoPresence-Laufzeit.

**FHEM, zeitnah nach einer neuen Freeze-Meldung abfragen und die Ausgaben sichern:**

```text
get System.GeoPresence timerStats
get System.GeoPresence timerStats format=json
apptime max top
apptime maxDly top
```

`Timer work` beschreibt die Dauer im GeoPresence-Aufruf einschließlich synchron ausgelöster Folgefunktionen. `Delayed starts` beschreibt dagegen die Wartezeit vor seinem tatsächlichen Beginn. Viele verspätete Starts bei kurzer eigener Arbeitsdauer sprechen für eine Verzögerung außerhalb des gemessenen Timerlaufs. In apptime gehört `TS Max call` zum längsten ausgeführten Aufruf; daraus lässt sich nicht der Zeitpunkt des Werts `maxDly` ableiten.

`Slowest profiled run` nennt Zeitpunkt, Arbeitsdauer, Startverspätung und den größten gemessenen Verarbeitungsanteil. `Phase breakdown of slowest run` zeigt die sechs größten Anteile. `Elapsed` enthält darunter aufgerufene gemessene Funktionen; `Self` zieht diese ab. Deshalb inklusive Zeiten nicht addieren. Die ungefähre Prozess-CPU-Zeit hilft, Rechenarbeit von Wartezeit zu unterscheiden, hat aber eine plattformabhängige Auflösung und benennt nicht selbst die Ursache einer Wartezeit.

| Verarbeitungsschritt | Was gemessen wird | Nächster Prüfpunkt bei hoher Dauer |
|---|---|---|
| `actor_command` | Aktorbefehl einschließlich seiner synchronen Folgefunktionen | Angegebenes Gerät, dessen Notifies/DOIFs und Treiber in apptime |
| `roommate_command` | ROOMMATE-Statuswechsel einschließlich Folgefunktionen | ROOMMATE-Regeln und nachgelagerte Automationen |
| `resident_reading_callbacks`, `geometry_reading_callbacks` | FHEM-Callbacks beim Veröffentlichen geänderter Readings | userReadings und abonnierende Geräte |
| `notification` | Aufruf von pushMsg einschließlich synchroner Arbeit | Nachrichtentreiber und aufgerufene Dienste |
| `diagnostic_file`, `normal_log` | Dateizugriff des Diagnoselogs beziehungsweise FHEM-Logausgabe | Datenträger, Dateisystem und Log-Empfänger |
| `configuration`, `validation`, `phone`, `observation`, `processing` | Jeweiliger interner Verarbeitungsschritt; Self jeweils ohne separat gemessene Unteraufrufe | Messreihe und vollständige Konfiguration für eine gezielte Modulprüfung |

Die Messung läuft automatisch und unabhängig vom Betriebsmodus oder `debugLog`; sie löst keine Events oder Aktionen aus. Im Speicher bleiben der langsamste Lauf, der am stärksten verspätete Start und jeweils die letzten zwölf Läufe mit mindestens 500 ms Arbeitsdauer beziehungsweise Startverspätung erhalten. Die lesbare Ausgabe zeigt die neuesten fünf Einträge pro Verlauf, JSON die vollständigen Details. `Profiling since` benennt den Beginn der Detailmessungen; frühere Maximalwerte können noch aus einer älteren Modulversion stammen. Nach Modulreload bleiben vorhandene Messreihen erhalten, nach FHEM-Neustart beginnen sie neu.

Ist die Dateidiagnose aktiv, enthält `timer_slow` zusätzlich Zeitpunkt, Verarbeitungsschritt und Zielgerät. Diese Ausgabe bleibt im GeoPresence-Diagnoselog. Der abschließende Wert in `timerStats` umfasst auch das Schreiben dieser Diagnose; die Diagnosezeile selbst kann ihre eigene Schreibdauer noch nicht enthalten. Für ein frisches apptime-Messfenster zuerst die bisherigen Ausgaben sichern und dann bei Bedarf `apptime clear` ausführen; das löscht ausschließlich die apptime-Messhistorie.
