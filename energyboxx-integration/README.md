# Energyboxx Integration Add-on

Home Assistant add-on that subscribes to Energyboxx community MQTT topics and exposes them as Home Assistant entities.

## Configuration

Only three options are required:

- `energyboxx_mqtt_username` — your Energyboxx broker username
- `energyboxx_mqtt_password` — your Energyboxx broker password
- `tailscale_authkey` — *(optional)* Tailscale/headscale auth key for tunneled access

All other options are pre-filled with sensible defaults and only need to be changed for non-standard deployments. See [DOCS.md](DOCS.md) for the full reference.

## Usage

1. Install the add-on in Home Assistant.
2. Fill in your Energyboxx username and password (and optionally a Tailscale auth key).
3. Start the add-on. Community topics are auto-published as `input_text.community_*` helpers.

## Ports

- `1885/tcp` — local MQTT broker (only used when the local mosquitto bridge is enabled in advanced options).
