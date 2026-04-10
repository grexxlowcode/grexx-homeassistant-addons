#!/usr/bin/with-contenv bashio

bashio::log.info "MQTT Helper Listener: Starting..."

# Get configuration
COMMUNITY_TOPIC=$(bashio::config 'community_topic')
ENERGYBOXX_HOST=$(bashio::config 'energyboxx_mqtt_host')
ENERGYBOXX_PORT=$(bashio::config 'energyboxx_mqtt_port')
ENERGYBOXX_USER=$(bashio::config 'energyboxx_mqtt_username')
ENERGYBOXX_PASSWORD=$(bashio::config 'energyboxx_mqtt_password')
SUPERVISOR_API="${SUPERVISOR_API:-http://supervisor/core/api}"
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"

# Track created helpers to avoid duplicates
HELPERS_FILE="/data/created_helpers.txt"
mkdir -p /data
touch "$HELPERS_FILE"

# CA certificate path
CA_CERT="/config/ssl/grexxconnect_ca.crt"

bashio::log.info "========================================="
bashio::log.info "MQTT Helper Listener Configuration:"
bashio::log.info "  Topic: $COMMUNITY_TOPIC"
bashio::log.info "  Remote Broker: $ENERGYBOXX_HOST:$ENERGYBOXX_PORT"
bashio::log.info "  Username: $ENERGYBOXX_USER"
bashio::log.info "  CA Certificate: $CA_CERT"
bashio::log.info "  API: $SUPERVISOR_API"
bashio::log.info "  Token: ${SUPERVISOR_TOKEN:0:20}..."
bashio::log.info "  Helpers file: $HELPERS_FILE"
bashio::log.info "========================================="

# Test API connectivity
bashio::log.info "Testing Home Assistant API connectivity..."
API_TEST=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
  -H "Content-Type: application/json" \
  "$SUPERVISOR_API/config" 2>&1)

if [ "$API_TEST" = "200" ]; then
  bashio::log.info "✓ API connectivity test successful (HTTP $API_TEST)"
else
  bashio::log.error "✗ API connectivity test failed (HTTP $API_TEST)"
  bashio::log.error "Helper creation will likely fail. Check add-on permissions."
fi

# Verify CA certificate exists
if [ -f "$CA_CERT" ]; then
  bashio::log.info "✓ CA certificate found"
else
  bashio::log.error "✗ CA certificate not found at $CA_CERT"
  bashio::log.error "TLS connection will fail"
fi

bashio::log.info "Connecting directly to remote broker..."
bashio::log.info "Subscribing to: $COMMUNITY_TOPIC"

# Function to convert topic to entity_id
topic_to_entity_id() {
  local topic="$1"
  # Remove base community/ prefix if present
  local entity_name=$(echo "$topic" | sed 's|^community/||')
  # Replace / with _ and remove invalid characters
  entity_name=$(echo "$entity_name" | tr '/' '_' | tr -cd '[:alnum:]_')
  echo "input_text.community_${entity_name}"
}

# Function to create input_text helper in configuration.yaml
create_helper() {
  local entity_id="$1"
  local topic="$2"

  # Check if already created
  if grep -q "^${entity_id}$" "$HELPERS_FILE"; then
    bashio::log.debug "Helper already exists: $entity_id (skipping creation)"
    return 0
  fi

  bashio::log.info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  bashio::log.info "Creating new helper:"
  bashio::log.info "  Entity ID: $entity_id"
  bashio::log.info "  Topic: $topic"

  # Extract helper name and key from entity_id
  local helper_key=$(echo "$entity_id" | sed 's/input_text\.//')
  local helper_name=$(echo "$helper_key" | tr '_' ' ')
  bashio::log.info "  Helper Key: $helper_key"
  bashio::log.info "  Display Name: $helper_name"

  CONFIG_PATH="/config/configuration.yaml"

  # Check if input_text section exists in configuration.yaml
  if ! grep -q "^input_text:" "$CONFIG_PATH"; then
    bashio::log.info "  Adding input_text section to configuration.yaml"
    echo "" >> "$CONFIG_PATH"
    echo "input_text:" >> "$CONFIG_PATH"
  fi

  # Check if this specific helper already exists in config
  if grep -A 3 "^input_text:" "$CONFIG_PATH" | grep -q "^  ${helper_key}:"; then
    bashio::log.warning "  Helper already exists in configuration.yaml"
    echo "$entity_id" >> "$HELPERS_FILE"
    return 0
  fi

  # Add helper to configuration.yaml
  bashio::log.info "  Adding helper to configuration.yaml"
  cat >> "$CONFIG_PATH" <<EOF
  ${helper_key}:
    name: "${helper_name}"
    max: 255
EOF

  # Reload input_text integration
  bashio::log.info "  Reloading input_text integration..."
  RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    "$SUPERVISOR_API/services/input_text/reload")

  HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
  BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    bashio::log.info "✓ Helper created and reloaded successfully (HTTP $HTTP_CODE)"
    echo "$entity_id" >> "$HELPERS_FILE"
    bashio::log.info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
  else
    bashio::log.error "✗ Failed to reload input_text integration (HTTP $HTTP_CODE)"
    bashio::log.error "  Response: $BODY"
    bashio::log.error "  Helper added to config but not loaded yet. Will retry."
    bashio::log.error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 1
  fi
}

# Function to update helper value
update_helper() {
  local entity_id="$1"
  local value="$2"

  # Truncate value if longer than 255 characters
  if [ ${#value} -gt 255 ]; then
    value="${value:0:255}"
    bashio::log.warning "Value truncated to 255 characters"
  fi

  bashio::log.info "Updating helper: $entity_id = \"$value\""

  # Call input_text.set_value service via REST API
  local payload="{\"entity_id\": \"${entity_id}\", \"value\": \"${value}\"}"

  RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    "$SUPERVISOR_API/services/input_text/set_value" \
    -d "$payload")

  HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
  BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    bashio::log.info "✓ Helper updated successfully"
    return 0
  else
    bashio::log.error "✗ Failed to update helper (HTTP $HTTP_CODE)"
    bashio::log.error "  Entity: $entity_id"
    bashio::log.error "  Value: $value"
    bashio::log.error "  Response: $BODY"
    bashio::log.error "  This usually means the helper doesn't exist yet in Home Assistant"
    return 1
  fi
}

# Main loop: Subscribe to MQTT and process messages
bashio::log.info "Starting mosquitto_sub listener (connecting to remote broker)..."
MESSAGE_COUNT=0

# Build mosquitto_sub command with TLS
MQTT_CMD="mosquitto_sub -h $ENERGYBOXX_HOST -p $ENERGYBOXX_PORT -u $ENERGYBOXX_USER -P $ENERGYBOXX_PASSWORD"

# Add TLS options
if [ -f "$CA_CERT" ]; then
  MQTT_CMD="$MQTT_CMD --cafile $CA_CERT"
fi

# Add topic and verbose flag
MQTT_CMD="$MQTT_CMD -t $COMMUNITY_TOPIC -v"

bashio::log.info "Executing: mosquitto_sub -h $ENERGYBOXX_HOST -p $ENERGYBOXX_PORT -u $ENERGYBOXX_USER -P *** --cafile $CA_CERT -t $COMMUNITY_TOPIC -v"

$MQTT_CMD 2>&1 | while read -r line; do
  MESSAGE_COUNT=$((MESSAGE_COUNT + 1))

  # Check for mosquitto errors
  if echo "$line" | grep -qi "error\|connection refused\|failed"; then
    bashio::log.error "mosquitto_sub error: $line"
    continue
  fi

  # Parse topic and message (format: "topic message")
  TOPIC=$(echo "$line" | awk '{print $1}')
  MESSAGE=$(echo "$line" | cut -d' ' -f2-)

  bashio::log.info "╔════════════════════════════════════════╗"
  bashio::log.info "║ MQTT Message #$MESSAGE_COUNT Received"
  bashio::log.info "╠════════════════════════════════════════╣"
  bashio::log.info "║ Topic:   $TOPIC"
  bashio::log.info "║ Message: $MESSAGE"
  bashio::log.info "╚════════════════════════════════════════╝"

  # Convert topic to entity_id
  ENTITY_ID=$(topic_to_entity_id "$TOPIC")
  bashio::log.info "Converted to entity ID: $ENTITY_ID"

  # Create helper if it doesn't exist
  if ! grep -q "^${ENTITY_ID}$" "$HELPERS_FILE"; then
    bashio::log.info "Helper does not exist, creating..."
    create_helper "$ENTITY_ID" "$TOPIC"
    sleep 2  # Give HA time to create the entity
  else
    bashio::log.info "Helper already exists, updating value..."
  fi

  # Update helper value
  update_helper "$ENTITY_ID" "$MESSAGE"

  bashio::log.info "----------------------------------------"
done

bashio::log.error "MQTT Helper Listener: mosquitto_sub exited unexpectedly"
bashio::log.error "This usually means the MQTT broker stopped or the connection was lost"
