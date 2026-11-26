# Energyboxx Flow Params Add-on

Home Assistant add-on that shows your Energyboxx community's live power flow and prices. It subscribes to the Energyboxx community MQTT topics, exposes each subtopic as a `sensor.community_*` entity, and keeps an "Energyboxx Flow Params" dashboard up to date.

## Configuration

| Option | Required | Description |
|---|---|---|
| `energyboxx_mqtt_username` | yes | Your Energyboxx broker username. |
| `energyboxx_mqtt_password` | yes | Your Energyboxx broker password. |
| `community_topic` | yes | MQTT topic pattern to subscribe to. Default: `community/#`. |
| `flip_power_result_kw` | no | Show community export as positive. Default: on. |
| `log_level` | no | `debug`, `info` (default), `warning` or `error`. |

## Usage

1. Install the add-on in Home Assistant.
2. Set your Energyboxx username and password.
3. Start the add-on.

Each MQTT message under `community_topic` is published to a Home Assistant sensor entity, named after the last part of the topic, for example `community/community_power_result_kw` → `sensor.community_power_result_kw`.

See [DOCS.md](DOCS.md) for details.
