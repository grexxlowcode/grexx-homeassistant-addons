# Energyboxx Integration Add-on

Home Assistant add-on that subscribes to Energyboxx community MQTT topics and exposes each subtopic as a Home Assistant `sensor.community_*` entity.

## Configuration

Three options, all required:

| Option | Description |
|---|---|
| `energyboxx_mqtt_username` | Your Energyboxx broker username. |
| `energyboxx_mqtt_password` | Your Energyboxx broker password. |
| `community_topic` | MQTT topic pattern to subscribe to. Default: `community/#`. |

## Usage

1. Install the add-on in Home Assistant.
2. Set your Energyboxx username and password.
3. Start the add-on.

Each MQTT message under `community_topic` is published to a Home Assistant sensor entity, for example `community/temp/sensor1` → `sensor.community_temp_sensor1`.

See [DOCS.md](DOCS.md) for details.
