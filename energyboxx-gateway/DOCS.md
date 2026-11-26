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

## How it works

1. Reads the connection code and connects to the Energyboxx broker over TLS.
2. Connects to Home Assistant over its WebSocket API, reads all states and follows `state_changed` events.
3. Publishes each matching sensor in the layout of Home Assistant's `mqtt_statestream`:
   `<base>/sensor/<object_id>/unit_of_measurement` (retained), `.../last_updated` and `.../state` (QoS 1).
4. Reconnects by itself when the broker or Home Assistant is unavailable.

## Troubleshooting

Problems show up as a notification in Home Assistant (the bell in the sidebar).

- **"cannot start: no connection code is set" / "not valid" / "incomplete"** — copy the code again from the Energyboxx platform; it is one long line of letters and digits.
- **"broker rejected the connection code"** — the code was regenerated or revoked. Generate a new one on the platform.
- **A sensor is missing** — check that it has a unit and a device class (Settings → Entities → the sensor → Settings). Set `log_level` to `debug` to see every value sent.

## For platform developers: connection code format

The code is URL-safe base64 (padding optional) of a JSON object:

```json
{"v": 1, "host": "ess.grexxconnect.com", "port": 8883,
 "user": "<broker user>", "pass": "<broker password>",
 "base": "eb/<env>/<secret>"}
```

| Field | Required | Notes |
|---|---|---|
| `v` | yes | Format version, must be `1`. |
| `user`, `pass` | yes | Broker credentials. |
| `base` | yes | The home's `homeBaseTopic`: exactly 3 non-empty segments, no `+` or `#`. While a shared broker account is used, make the last segment a random secret (at least 128 bits) so homes cannot write to each other's topics. Regenerate it to revoke a code. |
| `host`, `port` | no | Default `ess.grexxconnect.com:8883`. |

Extra fields are ignored. The broker account needs write access to `base/#` only; with a shared account, give it write-only access so it cannot discover other homes' topics:

```
user <shared user>
topic write eb/#
```

Generate a test code:

```bash
python3 -c 'import base64,json;print(base64.urlsafe_b64encode(json.dumps({"v":1,"user":"u","pass":"p","base":"eb/dev/secret"}).encode()).decode().rstrip("="))'
```
