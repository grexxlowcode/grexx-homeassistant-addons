# Changelog

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
