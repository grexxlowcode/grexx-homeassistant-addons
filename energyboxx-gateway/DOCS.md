# Energyboxx Gateway — Documentation

Requires Home Assistant 2024.11.0 or newer on a 64-bit system (`aarch64` or `amd64`).

## Options

| Option | Required | Description |
|---|---|---|
| `connection_code` | yes | The code from your home's "Connect Home Assistant" page on the Energyboxx platform. |
| `log_level` | no | `debug`, `info` (default), `warning` or `error`. Hidden under "Show unused optional configuration options". `debug` logs every value sent. |

## What is sent

Only `sensor.*` entities with:

- a `device_class` of `energy`, `power`, `gas` or `battery`,
- a unit of measurement, and
- a numeric state.

Nothing else from your Home Assistant leaves your home. The log lists every sensor the add-on starts or stops sharing. A sensor that becomes `unavailable` or `unknown` is no longer sent until it has a value again. If Home Assistant itself stops responding, the add-on stops repeating values and reconnects.

For every sensor the add-on sends its state, unit and timestamp when it changes, and repeats the latest value every 20 seconds so the platform knows it is still current.

For the platform's setup page the add-on also sends an **inventory**: the list of sensors above (including ones that are currently `unavailable`) with their name, device class, unit, and the name, manufacturer and model of their device, plus which sensors you chose for grid, solar, battery and gas in the Energy dashboard (not your prices, costs or individual devices). Sensor changes are sent right away; device and Energy dashboard changes within 15 minutes. No other entities, devices or settings are sent.

## How it works

1. Reads the connection code and connects to the Energyboxx broker over TLS.
2. Connects to Home Assistant over its WebSocket API, reads all states and follows `state_changed` events.
3. Publishes each matching sensor in the layout of Home Assistant's `mqtt_statestream`:
   `<base>/sensor/<object_id>/unit_of_measurement` (retained), `.../last_updated` and `.../state` (QoS 1).
4. Publishes the inventory as retained JSON on `<base>/inventory`.
5. Reconnects by itself when the broker or Home Assistant is unavailable.

## Troubleshooting

Problems show up as a notification in Home Assistant (the bell in the sidebar).

- **"cannot start: no connection code is set" / "not valid" / "incomplete"** — copy the code again from the Energyboxx platform; it is one long line of letters and digits.
- **"broker rejected the connection code"** — the code was regenerated or revoked. Generate a new one on the platform.
- **The platform shows no devices** — the add-on log says "No entities/devices for the inventory"; Home Assistant refused to list its registries. Restart the add-on and report the log line to Energyboxx support.
- **A sensor is missing** — check that it has a unit and a device class (Settings → Entities → the sensor → Settings). Set `log_level` to `debug` to see every value sent.

## For platform developers: connection code format

The code is URL-safe base64 (padding optional) of a JSON object:

```json
{"v": 1, "host": "ess.grexxconnect.com", "port": 8883,
 "user": "<broker user>", "pass": "<broker password>",
 "base": "energyboxx/<env>/<secret>"}
```

| Field | Required | Notes |
|---|---|---|
| `v` | yes | Format version, must be `1`. |
| `user`, `pass` | yes | Broker credentials. |
| `base` | yes | Topic prefix: the device gateway's `GATEWAY_BASE_TOPIC` (e.g. `energyboxx/prod`) plus the home's `homeBaseTopic`, exactly 3 non-empty segments, no `+` or `#`. While a shared broker account is used, make the last segment a random secret (at least 128 bits) so homes cannot write to each other's topics. Regenerate it to revoke a code. |
| `host`, `port` | no | Default `ess.grexxconnect.com:8883`. |

Extra fields are ignored. The broker account needs write access to `base/sensor/#` and `base/inventory` only. With a shared account, give it write-only access so it cannot discover other homes' topics, and keep the `sensor`/`inventory` segment so it cannot overwrite `energyboxx/<env>/community/<id>/...`:

```
user <shared user>
topic write energyboxx/<env>/+/sensor/#
topic write energyboxx/<env>/+/inventory
```

## For platform developers: inventory format

Retained, QoS 1, on `<base>/inventory`:

```json
{"v": 1, "generated_at": "<ISO time>",
 "energy": {"energy_sources": [{"type": "grid", "flow_from": [{"stat_energy_from": "sensor.p1_import"}],
                                "flow_to": [{"stat_energy_to": "sensor.p1_export"}]},
                               {"type": "solar", "stat_energy_from": "sensor.solar_energy"}]},
 "sensors": [{"entity_id": "sensor.p1_power", "name": "P1 power", "device_class": "power",
              "state_class": "measurement", "unit": "W",
              "device": {"name": "P1 Meter", "manufacturer": "HomeWizard", "model": "HWE-P1"}}]}
```

`energy` is `null` when the Energy dashboard is not set up. Per source only `type` and the `stat_*` sensor fields (except `stat_cost`) are kept from Home Assistant's `energy/get_prefs`. `device` is `null` for sensors without a device, or when Home Assistant refused to list devices (the add-on logs "No devices for the inventory").

Generate a test code:

```bash
python3 -c 'import base64,json;print(base64.urlsafe_b64encode(json.dumps({"v":1,"user":"u","pass":"p","base":"energyboxx/dev/secret"}).encode()).decode().rstrip("="))'
```
