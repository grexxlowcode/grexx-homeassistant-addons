#!/usr/bin/with-contenv bashio

bashio::log.info "Starting Energyboxx MQTT Bridge Add-on..."

# Start tailscaled daemon in the background
bashio::log.info "Starting tailscaled daemon..."
#tailscaled --state=/config/tailscale.state --socket=/run/tailscale/tailscaled.sock &
#sleep 3

# Get config values
ENERGYBOXX_HOST=$(bashio::config 'energyboxx_mqtt_host')
ENERGYBOXX_PORT=$(bashio::config 'energyboxx_mqtt_port')
ENERGYBOXX_USER=$(bashio::config 'energyboxx_mqtt_username')
ENERGYBOXX_PASSWORD=$(bashio::config 'energyboxx_mqtt_password')

# Get Tailscale authkey from config
TAILSCALE_AUTHKEY=$(bashio::config 'tailscale_authkey')

if [ -n "$TAILSCALE_AUTHKEY" ]; then
  bashio::log.info "Running tailscale up with provided authkey..."
#  tailscale --socket=/run/tailscale/tailscaled.sock up --login-server=https://headscale.grexx.io --authkey="$TAILSCALE_AUTHKEY" --reset
  if [ $? -eq 0 ]; then
    bashio::log.info "Tailscale started successfully."
  else
    bashio::log.error "Tailscale failed to start."
  fi
else
  bashio::log.info "No Tailscale authkey provided; skipping Tailscale setup."
fi

# Create mosquitto bridge configuration
bashio::log.info "Creating mosquitto bridge configuration..."
mkdir -p /etc/mosquitto/conf.d

# Replace tokens in mosquitto.conf with values from options
MOSQUITTO_CONF_SRC="/app/mosquitto.conf"
MOSQUITTO_CONF_DEST="/etc/mosquitto/mosquitto.conf"

if [ -f "$MOSQUITTO_CONF_SRC" ]; then
  bashio::log.info "Configuring mosquitto.conf for broker..."
  cp "$MOSQUITTO_CONF_SRC" "$MOSQUITTO_CONF_DEST"
  sed -i "s|USERNAME_REPLACE_TOKEN|$ENERGYBOXX_USER|g" "$MOSQUITTO_CONF_DEST"
  sed -i "s|PASSWORD_REPLACE_TOKEN|$ENERGYBOXX_PASSWORD|g" "$MOSQUITTO_CONF_DEST"
  sed -i "s|CLIENT_ID_REPLACE_TOKEN|energyboxx-addon-$(hostname)-$ENERGYBOXX_USER|g" "$MOSQUITTO_CONF_DEST"
else
  bashio::log.error "mosquitto.conf not found at $MOSQUITTO_CONF_SRC."
fi

# Ensure MQTT integration is enabled in configuration.yaml and points to our broker
CONFIG_PATH="/config/configuration.yaml"

# Write cert and key options to files if provided (from config options, base64 support)
MQTT_CLIENT_CAFILE_B64=$(bashio::config 'mqtt_client_cafile_b64')
MQTT_CLIENT_CERTFILE_B64=$(bashio::config 'mqtt_client_certfile_b64')
MQTT_CLIENT_KEYFILE_B64=$(bashio::config 'mqtt_client_keyfile_b64')

# Ensure /config/ssl directory exists
mkdir -p /config/ssl

# Write CA file from base64 if provided
if [ -n "$MQTT_CLIENT_CAFILE_B64" ]; then
  bashio::log.info "Decoding and writing CA file to /config/ssl/grexxconnect_ca.crt"
  echo "$MQTT_CLIENT_CAFILE_B64" | base64 -d > /config/ssl/grexxconnect_ca.crt
else
  bashio::log.warning "No CA file provided in options. /config/ssl/grexxconnect_ca.crt will not be created."
fi
# Write client cert from base64 if provided
if [ -n "$MQTT_CLIENT_CERTFILE_B64" ]; then
  bashio::log.info "Decoding and writing client cert to /config/ssl/grexxconnect_client.crt"
  echo "$MQTT_CLIENT_CERTFILE_B64" | base64 -d > /config/ssl/grexxconnect_client.crt
else
  bashio::log.warning "No client cert provided in options. /config/ssl/grexxconnect_client.crt will not be created."
fi
# Write client key from base64 if provided
if [ -n "$MQTT_CLIENT_KEYFILE_B64" ]; then
  bashio::log.info "Decoding and writing client key to /config/ssl/grexxconnect_client.key"
  echo "$MQTT_CLIENT_KEYFILE_B64" | base64 -d > /config/ssl/grexxconnect_client.key
else
  bashio::log.warning "No client key provided in options. /config/ssl/grexxconnect_client.key will not be created."
fi

# print files
bashio::log.info "Contents of /config/ssl directory:"
ls -l /config/ssl
# print file contents
cat /config/ssl/grexxconnect_ca.crt
cat /config/ssl/grexxconnect_client.crt
cat /config/ssl/grexxconnect_client.key

# Start mosquitto with the updated config
bashio::log.info "Starting mosquitto with updated configuration..."
mosquitto -c /etc/mosquitto/mosquitto.conf &
sleep 5

# --- Bash logic for Home Assistant API setup ---
SUPERVISOR_API="${SUPERVISOR_API:-http://supervisor/core/api}"
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"
CURL_AUTH_HEADER="-H \"Authorization: Bearer $SUPERVISOR_TOKEN\""
CURL_JSON_HEADER="-H \"Content-Type: application/json\""

# Debug: Print first 8 characters of SUPERVISOR_TOKEN for verification
if [ -z "$SUPERVISOR_TOKEN" ]; then
  bashio::log.warning "SUPERVISOR_TOKEN is not set! API calls will fail."
else
  bashio::log.info "SUPERVISOR_TOKEN is set."
fi

# Check if the Supervisor API is reachable
bashio::log.info "Checking Supervisor API configuration..."
SUPERVISOR_API_RESPONSE=$(curl -s -X GET -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" http://supervisor/core/api/config)
bashio::log.info "Supervisor API response: $SUPERVISOR_API_RESPONSE"

wait_for_ha() {
  for i in $(seq 1 10); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
      -H "Content-Type: application/json" \
      "$SUPERVISOR_API/")
    if [ "$STATUS" = "200" ]; then
      bashio::log.info "Home Assistant is available."
      return 0
    fi
    if [ "$STATUS" = "401" ]; then
      bashio::log.error "Unauthorized access to Home Assistant API. Check your SUPERVISOR_TOKEN."
      return 1
    fi
    bashio::log.info "Home Assistant API not available yet. Status: $STATUS"
    bashio::log.info "Waiting for Home Assistant API... ($i/10)"
    sleep 10
  done
  bashio::log.info "Home Assistant API not available after 10 attempts."
  return 1
}

setup_mqtt_integration() {
  bashio::log.info "Configuring Home Assistant MQTT integration to use custom mosquitto.conf..."
  MOSQUITTO_CONF_SRC="/app/mosquitto.conf"
  MOSQUITTO_CONF_DEST="/config/mosquitto.conf"
  if [ -f "$MOSQUITTO_CONF_SRC" ]; then
    cp "$MOSQUITTO_CONF_SRC" "$MOSQUITTO_CONF_DEST"
    bashio::log.info "Copied $MOSQUITTO_CONF_SRC to $MOSQUITTO_CONF_DEST."
  else
    bashio::log.error "Custom mosquitto.conf not found at $MOSQUITTO_CONF_SRC. Skipping MQTT integration config."
  fi
}
setup_mqtt_statestream() {
  bashio::log.info "Setting up MQTT Statestream integration..."
  BASE_TOPIC=$(bashio::config 'mqtt_statestream_base_topic')
  CONFIG_PATH="/config/configuration.yaml"

  if grep -q "^mqtt_statestream:" "$CONFIG_PATH"; then
    bashio::log.info "mqtt_statestream section found in $CONFIG_PATH. Updating base_topic..."
    # If base_topic exists, replace it; otherwise, add it under mqtt_statestream
    if grep -A 5 "^mqtt_statestream:" "$CONFIG_PATH" | grep -q "base_topic:"; then
      sed -i "/^mqtt_statestream:/,/^[^ ]/ s|^  base_topic:.*|  base_topic: $BASE_TOPIC|" "$CONFIG_PATH"
      bashio::log.info "Updated existing base_topic in mqtt_statestream section."
    else
      # Add base_topic under mqtt_statestream
      sed -i "/^mqtt_statestream:/a \\  base_topic: $BASE_TOPIC" "$CONFIG_PATH"
      bashio::log.info "Added base_topic to existing mqtt_statestream section."
    fi
  else
    bashio::log.info "mqtt_statestream section not found. Appending new section to $CONFIG_PATH."
    echo -e "\nmqtt_statestream:\n  base_topic: $BASE_TOPIC\n  publish_attributes: true\n  publish_timestamps: true" >> "$CONFIG_PATH"
  fi
}

setup_service_call_automation() {
  bashio::log.info "Setting up service call automation..."
  AUTOMATION_FILE="/app/automation.json"
  if [ ! -f "$AUTOMATION_FILE" ]; then
    bashio::log.info "Automation file $AUTOMATION_FILE not found. Skipping."
    return
  fi
  # Validate automation.json
  if ! jq empty "$AUTOMATION_FILE" 2>/dev/null; then
    bashio::log.error "automation.json is not valid JSON. Skipping automation setup."
    return
  fi
  AUTOMATIONS=$(cat "$AUTOMATION_FILE")
  echo "Automations file"
  echo "$AUTOMATIONS"
  # Check for existing automation in automations.yaml instead of API
  AUTOMATIONS_YAML="/config/automations.yaml"
  if [ -f "$AUTOMATIONS_YAML" ]; then
    if grep -q 'id: grexx-services' "$AUTOMATIONS_YAML"; then
      bashio::log.info "Service call automation already exists in automations.yaml."
      return
    fi
  else
    bashio::log.warning "automations.yaml not found at $AUTOMATIONS_YAML. Skipping existence check."
  fi

  # Extract the first automation object from the array
  AUTOMATION_OBJ=$(jq '.[0]' "$AUTOMATION_FILE")

  RESULT=$(curl -s -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    "$SUPERVISOR_API/config/automation/config/grexx-service" \
    -d "$AUTOMATION_OBJ")
  bashio::log.info "$RESULT"
  bashio::log.info "Service call automation created."
}

if wait_for_ha; then
  setup_mqtt_statestream
  setup_service_call_automation
else
  bashio::log.info "Could not connect to Home Assistant, exiting."
fi
# --- End Bash logic ---


# Wait for mosquitto to start before continuing
bashio::net.wait_for 1885

# Create discovery config payload for Home Assistant
config=$(bashio::var.json \
    host "$(hostname)" \
    port "^1885" \
    ssl "^false" \
    protocol "3.1.1" \
)

# Send discovery info
if bashio::discovery "Energyboxx Integration" "${config}" > /dev/null; then
    bashio::log.info "Successfully send discovery information to Home Assistant."
else
    bashio::log.error "Discovery message to Home Assistant failed!"
fi

# Create service config payload for other add-ons
config=$(bashio::var.json \
    host "$(hostname)" \
    port "^1885" \
    ssl "^false" \
    protocol "3.1.1" \
)

# Send service info
if bashio::services.publish "Energyboxx Integration" "${config}" > /dev/null 2>&1; then
    bashio::log.info "Successfully send service information to the Supervisor."
else
    bashio::log.error "Service message to Supervisor failed!"
fi

# Keep the container running
tail -f /dev/null
