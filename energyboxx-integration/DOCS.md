# Energyboxx Integration — Documentation

## Required options

| Option | Description |
|---|---|
| `energyboxx_mqtt_username` | Your Energyboxx broker username. |
| `energyboxx_mqtt_password` | Your Energyboxx broker password. |

## Optional

| Option | Description |
|---|---|
| `tailscale_authkey` | Tailscale/headscale auth key. When set, Tailscale starts automatically and the broker is reached via the tunnel. |

## Advanced

These options are pre-filled and should only be changed when you know what you're doing.

| Option | Default | Description |
|---|---|---|
| `energyboxx_mqtt_host` | `ess.grexxconnect.com` | Remote MQTT broker hostname. |
| `energyboxx_mqtt_port` | `8883` | Remote MQTT broker port (TLS). |
| `community_topic` | `community/#` | MQTT topic pattern subscribed to. |
| `use_mqtt_bridge` | `false` | Run a local mosquitto bridge on `1885/tcp` exposing the remote topics locally. |
| `use_mqtt_sensors` | `false` | Write MQTT sensor entries to `configuration.yaml` instead of using `input_text` helpers. |
| `tailscale_enabled` | `false` | Force Tailscale on without an auth key (e.g. when state already persisted in `/config/tailscale.state`). Normally leave `false` — providing `tailscale_authkey` is enough. |

## How it works

By default the add-on:

1. Resolves the remote broker over TLS (CA bundled in the image).
2. If `tailscale_authkey` is set, starts `tailscaled` and authenticates against `https://headscale.grexx.io`.
3. Subscribes to `community_topic` on the remote broker.
4. For every message, creates or updates an `input_text.community_*` helper in Home Assistant via the Supervisor REST API.

If `use_mqtt_bridge` is enabled, an additional local mosquitto instance bridges the remote broker on port `1885` so other add-ons can consume the same topics over plain MQTT.

If `use_mqtt_sensors` is enabled, MQTT sensor configuration is written to `configuration.yaml` instead of the helper approach.

## Troubleshooting

- **Auth errors in log** — verify username/password.
- **Cannot resolve broker** — check internet/DNS, or set `tailscale_authkey` if the broker is only reachable via Tailscale.
- **Helpers not appearing** — confirm `homeassistant_api: true` (it is by default) and that the Supervisor token is being injected (visible in the log line `SUPERVISOR_TOKEN is set.`).
- **Force recreation of helpers** — delete `/data/created_helpers.txt` inside the add-on and restart.
