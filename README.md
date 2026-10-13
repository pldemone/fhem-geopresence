# GeoPresence for FHEM

[English](README.md) | [Deutsch](README.de.md)

GeoPresence combines Geofency webhooks and local phone sensors to track presence, confirm departures and returns, and run configurable actions. It can open a door or garage, switch devices, or send notifications when a resident returns or enters or leaves a location. Residents, locations, actions and rules are configured as FHEM devices.

Geofency and local phone sensors can be used separately or together:

- `geofency_phone` combines location events with local phone detection. Phone sensors help confirm departures and returns and bridge short reception gaps.
- `geofency_only` uses Geofency without local phone sensors. Opening permission still requires additional evidence that the resident moved away; a Home event alone does not grant permission.
- `phone_only` uses local phone sensors without Geofency. Confirmed phone absence and a subsequent detection provide the presence information.

Configurable confirmation times, movement information and distance evidence help distinguish a return from GPS jumps. Learning captures phone and location identifiers and geometry from webhooks. Debug mode simulates the resident's journey and records planned actions without sending actuator commands, notifications or productive ROOMMATE updates. Diagnostic logging can also be enabled during normal operation.

## Documentation and setup

The detailed documentation is currently available in German. The module includes an English command and attribute reference, accessible in FHEM with `help GeoPresence EN`.

1. Install [FHEM/98_GeoPresence.pm](FHEM/98_GeoPresence.pm) in your FHEM installation's `FHEM/` directory. Load an updated module with `reload 98_GeoPresence.pm`.
2. Follow the [handbook](doc/GeoPresence_Handbuch.md) to create the controller, configure webhook access, add residents and learn their locations.
3. Define actions and rules using the handbook's examples, then validate the configuration.
4. Use the [test guide](doc/GeoPresence_Testanleitung.md) to simulate journeys and check custom rules before activating a resident.

The [architecture](doc/Architektur_GeoPresence.md) explains observation handling, opening permission, actuator feedback and restart recovery. The [nginx example](doc/GeoPresence_nginx.conf) shows how to forward the webhook path to the module's dedicated HTTP listener.

## Repository layout

| Directory | Contents |
| --- | --- |
| `FHEM/` | The GeoPresence module. |
| `doc/` | Handbook, architecture, test guide and nginx configuration example. |
| `tools/` | The operator's test application, `geopresence_test.py`. |
| `t/` | Perl and Python tests, including isolated FHEM integration tests. |
| `private/` | Private storage documentation and local operational data. |

## Private data

The residents and named places in the software tests are fictional, and their geometry is synthetic. The tests include all required test data and run without private files. The operator application under `tools/` reads the actual residents and location data from the specified FHEM installation.

Store your logs in `private/logs/`, configuration copies in `private/config/`, and webhook captures in `private/captures/`. The operator application writes reports to `private/reports/geopresence-test-YYYYMMDD-HHMMSS.json` by default, relative to the working directory. It creates `private/` and `private/reports/` with permissions `0700` when needed; report files receive `0600`. Use `--report FILE` to select another new file; its parent directory must already exist.

Only the [private storage README](private/README.md) (in German) is eligible for Git inside `private/`; all operational data is ignored. It explains the subdirectories, local access permissions, and anonymization before sharing data. `.gitignore` also excludes typical operational files, logs, previous report filenames, local environment files, key files, and Python caches. Ignore rules do not remove files already tracked by Git.

## Development tests

Run these commands from the repository root:

```sh
perl -c FHEM/98_GeoPresence.pm
prove t/geopresence*.t
PYTHONDONTWRITEBYTECODE=1 python3 t/geopresence_test_app.py
```

Integration tests also require an existing FHEM installation. Replace `/path/to/fhem` with its installation directory:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 t/geopresence_fhem_integration.py --fhem-dir /path/to/fhem
PYTHONDONTWRITEBYTECODE=1 python3 t/geopresence_acceptance_integration.py --fhem-dir /path/to/fhem
```

The integration tests create a temporary FHEM installation with dummy actuators. The application under `tools/` connects to the installation specified by the operator; its prerequisites, parameters and expected results are described in the test guide.
