# Changelog

## [1.4.0] - 2026-11-26
### Changed
- Renamed the add-on to "Energyboxx Flow Params". The slug stays `energyboxx`, so existing installs keep their settings and updates.
- The "Flip power result" option is now called "Show community export as positive", with a description that says what each setting means.
- Per-message log lines moved to debug level. A new optional `log_level` option shows them again.
- Base image updated to Alpine 3.22.

### Added
- Connection problems and missing credentials show up as a Home Assistant notification instead of only in the log.
- The add-on reconnects every 30 seconds after a dropped or refused connection, instead of stopping.
- After a Home Assistant restart the add-on reconnects, so the community sensors come back within two minutes instead of staying empty until the next broker update.

### Removed
- Support for 32-bit systems (`armhf`, `armv7`, `i386`), which Home Assistant no longer supports.

## [1.3.0] - 2026-08-17
### Added
- Dashboard: "Grid prices" section with `sensor.community_import_price_eur` and `sensor.community_export_price_eur` plus a 24-hour history graph.
- Dashboard: "Sun" section with sunrise and sunset times.

### Removed
- Dashboard: the note about values only changing when a broker message arrives.

## [1.2.0] - 2026-08-17
### Added
- The add-on now creates or updates an "Energyboxx Flow Params" dashboard on every start, with sections for power flow, community prices, and add-on status, including 24-hour history graphs and explanatory text.
- Numeric sensors now get `unit_of_measurement` (`kW` / `€/kWh`) and, for power, `device_class: power`.

### Changed
- Requires Home Assistant 2024.11.0 or newer, for the dashboard card types used.

## [1.1.0] - 2026-05-11
### Changed
- Stripped configuration to three options: `energyboxx_mqtt_username`, `energyboxx_mqtt_password`, `community_topic`.
- Broker host and port are now fixed to `ess.grexxconnect.com:8883`.
- Removed Tailscale support, local mosquitto bridge, and the MQTT sensor config-writing mode.
- Add-on now connects directly to the remote broker and writes `sensor.community_*` entities via the HA REST API.

## [1.0.0] - 2025-08-08
### Added
- Initial public release
- Mosquitto MQTT bridge with remote broker support
- Automatic statestream base topic configuration in `configuration.yaml`
- Service call automation via MQTT
- Certificate management for secure MQTT connections
- Home Assistant discovery and service publishing
