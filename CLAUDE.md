# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Home Assistant add-on repository for the Energyboxx Integration. The add-on creates an MQTT bridge between a remote Energyboxx broker (ess.grexxconnect.com) and Home Assistant to subscribe to community topics and automatically create helpers or sensors for each subtopic.

## Repository Structure

- `energyboxx-integration/` - Main add-on directory
  - `run.sh` - Main entrypoint script (bashio-based)
  - `config.yaml` - Add-on configuration schema and defaults
  - `Dockerfile` - Alpine-based container with mosquitto, tailscale, and utilities
  - `mosquitto.conf` - Template for mosquitto bridge configuration
  - `mqtt_helper_listener.sh` - Background script for helper creation/updates (helper approach)
  - `automation.json` - Unused (legacy file, kept for compatibility)
  - `statestream-config.yaml` - Unused (legacy file, kept for compatibility)

## Development Environment

The repository includes a devcontainer configuration for Home Assistant add-on development.

### Starting Development Environment

```bash
# In VSCode with devcontainer support, the container will auto-start
# Run the default task to start Home Assistant
supervisor_run
```

The devcontainer maps:
- Port 7123 → Home Assistant web UI (8123)
- Port 7357 → Debug port (4357)
- Workspace to `/mnt/supervisor/addons/local/energyboxx-addon`

## Architecture

### MQTT Bridge Flow

1. **Initialization** (`run.sh:1-48`):
   - Resolves remote broker IP (handles Tailscale if enabled)
   - Optionally starts Tailscale daemon for secure connectivity
   - Overrides `/etc/hosts` to ensure correct broker resolution

2. **Mosquitto Configuration** (`run.sh:50-89`):
   - Generates `/etc/mosquitto/mosquitto.conf` from template
   - Replaces tokens: `HOST_REPLACE_TOKEN`, `USERNAME_REPLACE_TOKEN`, `PASSWORD_REPLACE_TOKEN`, `CLIENT_ID_REPLACE_TOKEN`, `COMMUNITY_TOPIC_REPLACE_TOKEN`
   - Decodes base64-encoded CA certificate to `/config/ssl/` for TLS verification
   - Starts mosquitto bridge on port 1885
   - Subscribes one-way to community topic (no publishing back to remote broker)

3. **Home Assistant Integration** (`run.sh:91-140`):
   - Waits for Home Assistant API to be available
   - Based on `use_mqtt_sensors` feature flag, either:
     - **Helper Approach (default)**: Starts `mqtt_helper_listener.sh` to create input_text helpers
     - **MQTT Sensor Approach**: Configures MQTT sensor integration in `configuration.yaml`

4. **Helper Listener** (`mqtt_helper_listener.sh`):
   - Subscribes to community topic on local broker (127.0.0.1:1885)
   - Converts MQTT topics to entity IDs (e.g., `community/temp/sensor1` → `input_text.community_temp_sensor1`)
   - Creates `input_text` helpers via Home Assistant REST API
   - Updates helper values when MQTT messages arrive
   - Tracks created helpers in `/data/created_helpers.txt` to avoid duplicates

### Certificate Handling

The add-on uses CA-only TLS verification:
- CA certificate is decoded from `mqtt_client_cafile_b64` config option
- No client certificates required (removed in refactoring)
- TLS connection to remote broker uses CA for server verification only

### Topic Transformation

MQTT topics are transformed to entity IDs (`mqtt_helper_listener.sh`):
- Remove `community/` prefix
- Replace slashes (`/`) with underscores (`_`)
- Remove invalid characters (keep only alphanumeric and underscore)
- Prefix with `input_text.community_`
- Example: `community/temp/sensor1` → `input_text.community_temp_sensor1`

### Feature Flag: Helper vs Sensor Approach

**Helper Approach** (`use_mqtt_sensors: false` - default):
- Active listener script (`mqtt_helper_listener.sh`) runs in background
- Dynamically creates `input_text` helpers for each subtopic
- Updates helper values via Home Assistant REST API
- Last updated tracked via entity `last_updated` attribute (automatic in HA)

**MQTT Sensor Approach** (`use_mqtt_sensors: true`):
- Configures MQTT sensor integration in `configuration.yaml`
- Requires manual sensor definitions or MQTT discovery protocol
- Sensors auto-created by Home Assistant MQTT integration
- Simpler setup, but less dynamic than helper approach

## Configuration Options

All configuration is in `energyboxx-integration/config.yaml`:

- `energyboxx_mqtt_host` - Remote broker hostname (default: ess.grexxconnect.com)
- `energyboxx_mqtt_port` - Remote broker port (default: 8883)
- `energyboxx_mqtt_username/password` - Credentials for remote broker
- `mqtt_client_cafile_b64` - Base64-encoded CA certificate for TLS verification
- `community_topic` - MQTT topic pattern to subscribe to (default: "community/#")
- `use_mqtt_sensors` - Feature flag: false = helpers (default), true = MQTT sensors
- `tailscale_enabled` - Enable Tailscale connectivity (default: false)
- `tailscale_authkey` - Tailscale authentication key

## Building and Testing

### Building the Add-on

Home Assistant add-ons are built automatically by the Supervisor when installed locally or from the repository. The build uses the `Dockerfile` with the following dependencies:

```dockerfile
apk add --no-cache jq mosquitto mosquitto-clients tailscale iptables ip6tables iproute2
```

### Testing Changes

1. Make changes to files in `energyboxx-integration/`
2. Rebuild the add-on in Home Assistant (Settings → Add-ons → Energyboxx Integration → Rebuild)
3. Restart the add-on
4. Check logs in the add-on's Log tab

### Debugging

The add-on logs extensively using `bashio::log.info`, `bashio::log.warning`, and `bashio::log.error`. Key debug points:

- Broker IP resolution: `run.sh:12-17`
- Tailscale status: `run.sh:23-48`
- SSL certificate files: `run.sh:82-83`
- Supervisor API responses: `run.sh:109-110`
- MQTT messages received: `mqtt_helper_listener.sh:96`
- Helper creation/updates: `mqtt_helper_listener.sh:42, 72`

## Important Notes

### Token Replacement in mosquitto.conf

The mosquitto.conf uses token-based replacement (`run.sh:61-65`). When modifying the template:
- Use `sed -i` for in-place replacement
- Tokens must match exactly: `HOST_REPLACE_TOKEN`, `USERNAME_REPLACE_TOKEN`, `PASSWORD_REPLACE_TOKEN`, `CLIENT_ID_REPLACE_TOKEN`, `COMMUNITY_TOPIC_REPLACE_TOKEN`

### Helper Tracking

The helper listener tracks created helpers in `/data/created_helpers.txt`:
- Persists across container restarts
- Prevents duplicate API calls for existing helpers
- Delete file to force recreation of all helpers

### Home Assistant API Endpoints

The add-on uses these Home Assistant REST API endpoints:

**Create Helper:**
```bash
POST http://supervisor/core/api/services/input_text/create
Body: {"name": "helper_name", "min": 0, "max": 255, "initial": ""}
```

**Update Helper:**
```bash
POST http://supervisor/core/api/services/input_text/set_value
Body: {"entity_id": "input_text.community_sensor1", "value": "new_value"}
```

### Last Updated Tracking

Both helpers and sensors automatically track when they were last updated via the `last_updated` attribute:
- Access in templates: `states['input_text.community_sensor1'].last_updated`
- No additional configuration required

### Tailscale Login Server

Tailscale uses a custom headscale server: `https://headscale.grexx.io` (`run.sh:34`)

### Process Architecture

When using helper approach (default):
```
run.sh (PID 1)
├── mosquitto (background)
├── tailscaled (background, if enabled)
└── mqtt_helper_listener.sh (background)
    └── mosquitto_sub (pipes to while loop)
```