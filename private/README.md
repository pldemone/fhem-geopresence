# Private Betriebsdaten

Dieses Verzeichnis ist die lokale Ablage für Daten aus deiner eigenen
FHEM-Installation. Logs, Testberichte, Konfigurationskopien und Webhook-Mitschnitte
können reale Personen, Orte, Koordinaten, Gerätekennungen und Zugangsdaten
enthalten. Die öffentlichen Softwaretests verwenden dagegen erfundene Personen
und Orte sowie künstliche Geometrie und benötigen diese privaten Dateien nicht.

Diese README ist die einzige Datei in `private/`, die für Git freigegeben ist.
Alle weiteren Dateien und Unterverzeichnisse werden durch `.gitignore`
ausgeschlossen. Die Testanwendung liest die tatsächlich eingerichteten Personen
und Ortsdaten aus FHEM; sie verschiebt keine produktiven Konfigurationen in dieses
Verzeichnis.

## Ablage

| Verzeichnis | Verwendung |
| --- | --- |
| `reports/` | Ergebnisberichte der Betreiber-Testanwendung. |
| `logs/` | Eigene Kopien von FHEM- und GeoPresence-Logs. |
| `config/` | Private Konfigurationskopien und Sicherungen. |
| `captures/` | Eigene Webhook-Mitschnitte und andere Eingangsdaten. |

Die Testanwendung `tools/geopresence_test.py` schreibt standardmäßig nach
`private/reports/geopresence-test-YYYYMMDD-HHMMSS.json`, relativ zu ihrem
Arbeitsverzeichnis. Sie legt fehlende Verzeichnisse `private/` und
`private/reports/` mit Zugriffsrechten `0700` an; neue Berichte erhalten `0600`
und überschreiben keine vorhandene Datei. Mit `--report DATEI` kann eine andere
neue Datei gewählt werden; deren übergeordnetes Verzeichnis muss vorhanden sein.
`--log` darf weiterhin direkt auf das Diagnoselog der FHEM-Installation zeigen.

## Lokale Zugriffsrechte

Git speichert keine Zugriffsrechte für Verzeichnisse. Nach dem Klonen kannst du
die privaten Unterverzeichnisse aus dem Wurzelverzeichnis des Repositorys anlegen
und auf Zugriff durch deinen Benutzer beschränken:

```sh
mkdir -p private/reports private/logs private/config private/captures
chmod 700 private private/reports private/logs private/config private/captures
```

Ignore-Regeln entfernen keine bereits versionierten Dateien und lassen sich mit
`git add -f` umgehen. Die privaten Betriebsdaten gehören deshalb auch bei einer
manuellen Dateiauswahl nicht in den öffentlichen Bestand.

## Daten weitergeben

Vor einer Weitergabe von Logauszügen oder anderen Betriebsdaten Personen und
Ortsnamen durch Phantasienamen und Koordinaten durch künstliche Werte ersetzen.
Telefon- und Ortskennungen, Hostnamen, IP-Adressen, lokale Benutzerpfade sowie
Details zum Haushalt oder seinen Abläufen ebenfalls anonymisieren. Zugangsdaten,
Kennwortprüfwerte, Authorization-Header und private Metadaten aus vollständigen
HTTP-Anfragen entfernen. Auch Kommentare und Nachrichtentexte prüfen.
