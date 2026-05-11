# Energyboxx Integration — Documentation

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

## Troubleshooting

- **Auth errors** — verify `energyboxx_mqtt_username` / `energyboxx_mqtt_password`.
- **No entities appear** — check the add-on log for `mosquitto_sub` errors and confirm messages are arriving on the configured topic.
- **TLS errors** — restart the add-on; the CA certificate is reinstalled to `/config/ssl/grexxconnect_ca.crt` on every start.
