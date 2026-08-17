# Energyboxx Integration — Documentation

Requires Home Assistant 2024.11.0 or newer. Older cores cannot render the dashboard's `heading` cards, so the Supervisor will not offer the add-on there.

## Options

| Option | Required | Description |
|---|---|---|
| `energyboxx_mqtt_username` | yes | Your Energyboxx broker username. |
| `energyboxx_mqtt_password` | yes | Your Energyboxx broker password. |
| `community_topic` | yes | MQTT topic pattern to subscribe to (default `community/#`). |

The broker host (`ess.grexxconnect.com`) and TLS port (`8883`) are fixed in the add-on.

## How it works

1. Connects to `ess.grexxconnect.com:8883` over TLS using the bundled CA certificate.
2. Authenticates with the configured username and password.
3. Subscribes to `community_topic`.
4. For every MQTT message, sets the state of a Home Assistant sensor named `sensor.community_<subtopic>` via the Supervisor REST API.

Topic transformation example:

- `community/temp/sensor1` → `sensor.community_temp_sensor1`
- `community/power/main` → `sensor.community_power_main`

Numeric values get the `state_class: measurement` attribute, so they show up as charts in Home Assistant.

## Units

Numeric sensors get metadata so Home Assistant renders and records them properly:

| Entity suffix | Unit | Device class |
|---|---|---|
| `*_kw` | `kW` | `power` |
| `*_price_eur` | `€/kWh` | — |

If these sensors already had history without a unit, Home Assistant raises a one-off "units changed" repair notice after upgrading. Dismissing it is safe.

## Dashboard

On every start the add-on creates or updates a dashboard called **Energyboxx Flow Params** (URL path `energyboxx-flow-params`), shown in the sidebar. It has five sections:

- **Power flow** — explanatory text, `sensor.community_power_result_kw` as a large tile with a last-changed timestamp, `sensor.community_power_import_kw` and `sensor.community_power_export_kw` side by side, and a 24-hour history graph of all three.
- **Grid prices** — `sensor.community_import_price_eur` and `sensor.community_export_price_eur` plus a 24-hour history graph.
- **Community prices** — `sensor.community_shared_import_price_eur` and `sensor.community_shared_export_price_eur` plus a 24-hour history graph.
- **Sun** — sunrise and sunset, from `sensor.sun_next_rising` and `sensor.sun_next_setting`. These come from Home Assistant's built-in Sun integration; if they have been disabled the tiles show as unavailable.
- **Add-on** — `update.energyboxx_integration_update`.

The explanation of the `power_result_kw` sign follows the `flip_power_result_kw` option, so it stays correct whichever way you set it.

The layout lives in `dashboard.json` and is written over the Home Assistant WebSocket API. **Manual edits to this dashboard are overwritten the next time the add-on starts** — copy it to a new dashboard if you want to customise it. Dashboard failures are logged as warnings and never stop MQTT ingest.

## Troubleshooting

- **Auth errors** — verify `energyboxx_mqtt_username` / `energyboxx_mqtt_password`.
- **No entities appear** — check the add-on log for `mosquitto_sub` errors and confirm messages are arriving on the configured topic.
- **TLS errors** — restart the add-on; the CA certificate is reinstalled to `/config/ssl/grexxconnect_ca.crt` on every start.
