# Energyboxx Integration Add-on

This Home Assistant add-on provides integration for Energyboxx devices, including an MQTT bridge and service automation.

## Configuration
Edit the `config.yaml` to set the following options:

- `energyboxx_mqtt_host`: Remote MQTT broker host (default: `ess.grexxconnect.com`)
- `energyboxx_mqtt_port`: Remote MQTT broker port (default: `8883`)
- `energyboxx_mqtt_username`: Username for remote broker
- `energyboxx_mqtt_password`: Password for remote broker
- `mqtt_statestream_base_topic`: Base topic for MQTT Statestream integration
- `mqtt_client_cafile_b64`: Base64-encoded CA certificate (optional)
- `mqtt_client_certfile_b64`: Base64-encoded client certificate (optional)
- `mqtt_client_keyfile_b64`: Base64-encoded client key (optional)

## Usage
1. Install the add-on in Home Assistant.
2. Configure the add-on options as needed.
3. Start the add-on. It will:
    - Configure and start Mosquitto with a bridge to the remote broker
    - Update `configuration.yaml` with the correct MQTT Statestream base topic
    - Set up service call automation if not already present
    - Publish discovery and service information to Home Assistant
4. Go to the Settings > Devices & Services > Integrations page and add the MQTT integration that should now be available in the Discovered section.

## Ports
- The add-on exposes port `1885` for local MQTT connections.

