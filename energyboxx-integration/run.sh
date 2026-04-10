#!/usr/bin/with-contenv bashio

bashio::log.info "Starting Energyboxx MQTT Bridge Add-on..."

# Get config values
ENERGYBOXX_HOST=$(bashio::config 'energyboxx_mqtt_host')
ENERGYBOXX_PORT=$(bashio::config 'energyboxx_mqtt_port')
ENERGYBOXX_USER=$(bashio::config 'energyboxx_mqtt_username')
ENERGYBOXX_PASSWORD=$(bashio::config 'energyboxx_mqtt_password')
COMMUNITY_TOPIC=$(bashio::config 'community_topic')
USE_MQTT_SENSORS=$(bashio::config 'use_mqtt_sensors')

# Resolve broker IP using system DNS (not Tailscale DNS)
BROKER_IP=$(getent hosts "$ENERGYBOXX_HOST" | awk '{ print $1 }')
if [ -z "$BROKER_IP" ]; then
  bashio::log.error "Could not resolve broker IP for $ENERGYBOXX_HOST. Bridge may fail."
else
  bashio::log.info "Overriding /etc/hosts: $ENERGYBOXX_HOST -> $BROKER_IP"
  echo "$BROKER_IP $ENERGYBOXX_HOST" >> /etc/hosts
fi

# Get Tailscale enabled flag from config
TAILSCALE_ENABLED=$(bashio::config 'tailscale_enabled')

if bashio::var.true "$TAILSCALE_ENABLED"; then
  # Start tailscaled daemon in the background
  bashio::log.info "Starting tailscaled daemon..."
  tailscaled --state=/config/tailscale.state --socket=/run/tailscale/tailscaled.sock &
  sleep 3

  # Get Tailscale authkey from config
  TAILSCALE_AUTHKEY=$(bashio::config 'tailscale_authkey')

  if [ -n "$TAILSCALE_AUTHKEY" ]; then
    bashio::log.info "Running tailscale up with provided authkey..."
    tailscale --socket=/run/tailscale/tailscaled.sock up --login-server=https://headscale.grexx.io --authkey="$TAILSCALE_AUTHKEY" --reset
    if [ $? -eq 0 ]; then
      bashio::log.info "Tailscale started successfully."
    else
      bashio::log.error "Tailscale failed to start."
    fi
  else
    bashio::log.info "No Tailscale authkey provided; skipping Tailscale setup."
  fi
  # verify broker ip resolution
  RESOLVED_IP=$(getent hosts "$ENERGYBOXX_HOST" | awk '{ print $1 }')
  bashio::log.info "Resolved $ENERGYBOXX_HOST to $RESOLVED_IP with tailscale active"
else
  bashio::log.info "Tailscale is disabled by configuration; skipping Tailscale setup."
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
  sed -i "s|HOST_REPLACE_TOKEN|$ENERGYBOXX_HOST|g" "$MOSQUITTO_CONF_DEST"
  sed -i "s|USERNAME_REPLACE_TOKEN|$ENERGYBOXX_USER|g" "$MOSQUITTO_CONF_DEST"
  sed -i "s|PASSWORD_REPLACE_TOKEN|$ENERGYBOXX_PASSWORD|g" "$MOSQUITTO_CONF_DEST"
  sed -i "s|CLIENT_ID_REPLACE_TOKEN|energyboxx-addon-$(hostname)-$ENERGYBOXX_USER|g" "$MOSQUITTO_CONF_DEST"
  sed -i "s|COMMUNITY_TOPIC_REPLACE_TOKEN|$COMMUNITY_TOPIC|g" "$MOSQUITTO_CONF_DEST"

  bashio::log.info "Mosquitto configuration:"
  bashio::log.info "  Remote broker: $ENERGYBOXX_HOST:$ENERGYBOXX_PORT"
  bashio::log.info "  Username: $ENERGYBOXX_USER"
  bashio::log.info "  Community topic: $COMMUNITY_TOPIC"
  bashio::log.info "  Client ID: energyboxx-addon-$(hostname)-$ENERGYBOXX_USER"
else
  bashio::log.error "mosquitto.conf not found at $MOSQUITTO_CONF_SRC."
fi

# Copy CA certificate for TLS verification
bashio::log.info "Copying CA certificate for TLS verification..."
mkdir -p /config/ssl
cp /app/ca.crt /config/ssl/grexxconnect_ca.crt
bashio::log.info "CA certificate installed to /config/ssl/grexxconnect_ca.crt"


# Start mosquitto with the updated config
bashio::log.info "Starting mosquitto bridge..."
bashio::log.info "Bridge will subscribe to: $COMMUNITY_TOPIC from $ENERGYBOXX_HOST"
mosquitto -c /etc/mosquitto/mosquitto.conf &
MOSQUITTO_PID=$!
bashio::log.info "Mosquitto started with PID: $MOSQUITTO_PID"
sleep 5

# Check if mosquitto is still running
if ps -p $MOSQUITTO_PID > /dev/null; then
  bashio::log.info "✓ Mosquitto is running"
else
  bashio::log.error "✗ Mosquitto failed to start or crashed immediately"
  bashio::log.error "Check mosquitto logs above for connection errors"
fi

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

setup_mqtt_sensors() {
  bashio::log.info "Setting up MQTT sensor integration for community topics..."
  CONFIG_PATH="/config/configuration.yaml"

  # Extract base topic without wildcard for sensor configuration
  BASE_TOPIC=$(echo "$COMMUNITY_TOPIC" | sed 's/#$//' | sed 's|/$||')

  # Check if mqtt sensor section exists
  if grep -q "^mqtt:" "$CONFIG_PATH"; then
    bashio::log.info "MQTT section found in configuration.yaml"

    # Check if sensor subsection exists under mqtt
    if grep -A 10 "^mqtt:" "$CONFIG_PATH" | grep -q "^  sensor:"; then
      bashio::log.info "MQTT sensor section already exists"
    else
      # Add sensor section under mqtt
      bashio::log.info "Adding sensor section under mqtt"
      sed -i "/^mqtt:/a \\  sensor:" "$CONFIG_PATH"
    fi
  else
    # Add entire mqtt section with sensor
    bashio::log.info "Adding mqtt and sensor section to configuration.yaml"
    cat >> "$CONFIG_PATH" <<EOF

mqtt:
  sensor:
    - name: "Community Topics Auto-Discovery"
      state_topic: "${BASE_TOPIC}status"
      value_template: "{{ value }}"
EOF
  fi

  bashio::log.info "MQTT sensor integration configured. Sensors will auto-discover from community topics."
  bashio::log.info "Note: Individual sensors need to be defined manually or via MQTT discovery protocol."
}

setup_helper_listener() {
  bashio::log.info "Starting MQTT helper listener for community topics..."

  # Start background process to listen to MQTT and create helpers
  /app/mqtt_helper_listener.sh &
  LISTENER_PID=$!
  bashio::log.info "MQTT helper listener started with PID: $LISTENER_PID"
}

if wait_for_ha; then
  bashio::log.info "Home Assistant API is ready."
else
  bashio::log.error "Could not connect to Home Assistant. Community topic processing may fail."
fi


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

# Process community topics based on feature flag
bashio::log.info "========================================="
bashio::log.info "Community Topic Processing Configuration:"
bashio::log.info "  Mode: $([ "$USE_MQTT_SENSORS" = "true" ] && echo "MQTT Sensors" || echo "Input Text Helpers (default)")"
bashio::log.info "  Topic pattern: $COMMUNITY_TOPIC"
bashio::log.info "========================================="

if bashio::var.true "$USE_MQTT_SENSORS"; then
  setup_mqtt_sensors
else
  setup_helper_listener
fi

# Keep the container running
tail -f /dev/null
