# Energyboxx Flow Params — Documentation

Requires Home Assistant 2024.11.0 or newer on a 64-bit system (`aarch64` or `amd64`). Older cores cannot render the dashboard's `heading` cards, so the Supervisor will not offer the add-on there.

## Options

| Option | Required | Description |
|---|---|---|
| `energyboxx_mqtt_username` | yes | Your Energyboxx broker username. |
| `energyboxx_mqtt_password` | yes | Your Energyboxx broker password. |
| `community_topic` | yes | MQTT topic pattern to subscribe to (default `community/#`). |
| `flip_power_result_kw` | no | "Show community export as positive". On (default): `sensor.community_power_result_kw` is positive while the community exports more than it imports. Off: the broker's sign, positive while importing. |
| `log_level` | no | `debug`, `info` (default), `warning` or `error`. Hidden under "Show unused optional configuration options". `debug` logs every MQTT message and sensor update. |

The broker host (`ess.grexxconnect.com`) and TLS port (`8883`) are fixed in the add-on.

## How it works

1. Connects to `ess.grexxconnect.com:8883` over TLS using the bundled CA certificate.
2. Authenticates with the configured username and password.
3. Subscribes to `community_topic`.
4. For every MQTT message, sets the state of a Home Assistant sensor named `sensor.<subtopic>` via the Supervisor REST API.
5. If the connection drops or is refused, it retries every 30 seconds.
6. If Home Assistant restarts while the add-on keeps running, the add-on notices within two minutes and reconnects, so the broker resends the latest values.

Topic transformation example:

- `community/community_power_result_kw` → `sensor.community_power_result_kw`
- `community/prices/import_eur` → `sensor.prices_import_eur`

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
- **Add-on** — the add-on's update entity, looked up at start. Its id depends on the name the add-on had when it was installed: `update.energyboxx_integration_update` on older installs, `update.energyboxx_flow_params_update` on new ones.

The explanation of the `power_result_kw` sign follows the `flip_power_result_kw` option, so it stays correct whichever way you set it.

The layout lives in `dashboard.json` and is written over the Home Assistant WebSocket API. **Manual edits to this dashboard are overwritten the next time the add-on starts** — copy it to a new dashboard if you want to customise it. Dashboard failures are logged as warnings and never stop MQTT ingest.

## Troubleshooting

Connection problems show up as a notification in Home Assistant (the bell in the sidebar). The notification disappears once data arrives again.

- **"rejected your username or password"** — verify `energyboxx_mqtt_username` / `energyboxx_mqtt_password`.
- **"Cannot reach the Energyboxx broker"** — check the internet connection of your Home Assistant. The add-on keeps retrying.
- **No entities appear** — set `log_level` to `debug` and confirm messages are arriving on the configured topic.
- **TLS errors** — restart the add-on; the CA certificate is reinstalled to `/config/ssl/grexxconnect_ca.crt` on every start.
