# GeoPresence für FHEM

[English](README.md) | [Deutsch](README.de.md)

GeoPresence kombiniert Geofency-Webhooks und lokale Telefonsensoren, erkennt Anwesenheit, bestätigt Abwesenheit und Rückkehr und führt konfigurierbare Aktionen aus. Es kann eine Tür oder Garage öffnen, Geräte schalten oder Nachrichten versenden, wenn eine Person zurückkehrt oder einen Ort betritt oder verlässt. Personen, Orte, Aktionen und Regeln werden als Geräte in FHEM eingerichtet.

Geofency und lokale Telefonsensoren können einzeln oder gemeinsam verwendet werden:

- `geofency_phone` kombiniert Ortsmeldungen mit lokaler Telefonerkennung. Die Telefonsensoren helfen, Abwesenheit und Rückkehr zu bestätigen und kurze Empfangslücken zu überbrücken.
- `geofency_only` verwendet Geofency ohne lokale Telefonsensoren. Eine Öffnungsberechtigung benötigt weiterhin einen zusätzlichen Entfernungsnachweis; eine Home-Meldung allein erteilt keine Berechtigung.
- `phone_only` verwendet lokale Telefonsensoren ohne Geofency. Eine bestätigte Telefonabwesenheit und eine spätere Erkennung liefern die Anwesenheitsinformationen.

Konfigurierbare Bestätigungszeiten, Bewegungsinformationen und Entfernungsnachweise helfen, eine Rückkehr von GPS-Sprüngen zu unterscheiden. Der Lernmodus übernimmt Telefon- und Ortskennungen sowie Geometrie aus den Webhooks. Der Debug-Modus simuliert die Wege einer Person und zeichnet geplante Aktionen auf, ohne Aktorbefehle, Nachrichten oder produktive ROOMMATE-Änderungen auszuführen. Die Diagnoseausgabe lässt sich auch im normalen Betrieb einschalten.

## Dokumentation und Einrichtung

Die ausführliche Dokumentation ist auf Deutsch verfügbar. Das Modul enthält eine englische Befehls- und Attributreferenz, die in FHEM mit `help GeoPresence EN` aufgerufen werden kann.

1. Installiere [FHEM/98_GeoPresence.pm](FHEM/98_GeoPresence.pm) im Verzeichnis `FHEM/` deiner FHEM-Installation. Ein aktualisiertes Modul wird mit `reload 98_GeoPresence.pm` geladen.
2. Folge dem [Handbuch](doc/GeoPresence_Handbuch.md), um den Controller und den Webhook-Zugang einzurichten, Personen anzulegen und ihre Orte zu lernen.
3. Definiere Aktionen und Regeln anhand der Beispiele im Handbuch und validiere anschließend die Konfiguration.
4. Nutze die [Testanleitung](doc/GeoPresence_Testanleitung.md), um Wege zu simulieren und eigene Regeln zu prüfen, bevor du eine Person aktivierst.

Die [Architektur](doc/Architektur_GeoPresence.md) erklärt die Verarbeitung von Beobachtungen, Öffnungsberechtigungen, Aktorrückmeldungen und die Wiederherstellung nach einem Neustart. Die [nginx-Vorlage](doc/GeoPresence_nginx.conf) zeigt, wie der Webhook-Pfad an den eigenen HTTP-Listener des Moduls weitergeleitet wird.

## Verzeichnisstruktur

| Verzeichnis | Inhalt |
| --- | --- |
| `FHEM/` | Das GeoPresence-Modul. |
| `doc/` | Handbuch, Architektur, Testanleitung und nginx-Vorlage. |
| `tools/` | Die Testanwendung `geopresence_test.py` für den Betreiber. |
| `t/` | Perl- und Python-Tests einschließlich isolierter FHEM-Integrationsprüfungen. |
| `private/` | Hinweise zur privaten Ablage und lokale Betriebsdaten. |

## Private Daten

Die Personen und benannten Orte der Softwaretests sind erfunden; die Tests verwenden künstliche Geometrie. Sie enthalten alle benötigten Testdaten und sind ohne private Dateien ausführbar. Die Testanwendung unter `tools/` liest die tatsächlich eingerichteten Personen und Ortsdaten aus der angegebenen FHEM-Installation.

Lege eigene Logs unter `private/logs/`, Konfigurationskopien unter `private/config/` und Webhook-Mitschnitte unter `private/captures/` ab. Die Testanwendung speichert Ergebnisberichte standardmäßig unter `private/reports/geopresence-test-YYYYMMDD-HHMMSS.json`, relativ zum Arbeitsverzeichnis. Sie legt `private/` und `private/reports/` bei Bedarf mit Zugriffsrechten `0700` an; Berichte erhalten `0600`. Mit `--report DATEI` kann eine andere neue Datei gewählt werden; deren übergeordnetes Verzeichnis muss vorhanden sein.

In `private/` ist nur die [README zur privaten Ablage](private/README.md) für Git freigegeben; alle Betriebsdaten werden ignoriert. Sie erklärt die Unterverzeichnisse, lokalen Zugriffsrechte und die Anonymisierung vor einer Weitergabe. `.gitignore` schließt außerdem typische Betriebsdateien, Logs, bisherige Testberichte, lokale Umgebungsdateien, Schlüsseldateien und Python-Cachedateien aus. Bereits versionierte Dateien werden durch Ignore-Regeln nicht nachträglich entfernt.

## Tests für die Entwicklung

Aus dem Wurzelverzeichnis des Repositorys ausführen:

```sh
perl -c FHEM/98_GeoPresence.pm
prove t/geopresence*.t
PYTHONDONTWRITEBYTECODE=1 python3 t/geopresence_test_app.py
```

Die Integrationsprüfungen benötigen zusätzlich eine vorhandene FHEM-Installation. Ersetze `/pfad/zu/fhem` durch deren Installationsverzeichnis:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 t/geopresence_fhem_integration.py --fhem-dir /pfad/zu/fhem
PYTHONDONTWRITEBYTECODE=1 python3 t/geopresence_acceptance_integration.py --fhem-dir /pfad/zu/fhem
```

Die Integrationsprüfungen erstellen eine temporäre FHEM-Installation mit Dummy-Aktoren. Die Anwendung unter `tools/` verbindet sich dagegen mit der vom Betreiber angegebenen Installation; Voraussetzungen, Parameter und erwartete Ergebnisse stehen in der Testanleitung.
