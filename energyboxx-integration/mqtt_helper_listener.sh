#!/usr/bin/with-contenv bashio

bashio::log.info "MQTT Sensor Listener: Starting..."

# Get configuration
COMMUNITY_TOPIC=$(bashio::config 'community_topic')
ENERGYBOXX_HOST=$(bashio::config 'energyboxx_mqtt_host')
ENERGYBOXX_PORT=$(bashio::config 'energyboxx_mqtt_port')
ENERGYBOXX_USER=$(bashio::config 'energyboxx_mqtt_username')
ENERGYBOXX_PASSWORD=$(bashio::config 'energyboxx_mqtt_password')
SUPERVISOR_API="${SUPERVISOR_API:-http://supervisor/core/api}"
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"

# CA certificate path
CA_CERT="/config/ssl/grexxconnect_ca.crt"

bashio::log.info "========================================="
bashio::log.info "MQTT Sensor Listener Configuration:"
bashio::log.info "  Topic: $COMMUNITY_TOPIC"
bashio::log.info "  Remote Broker: $ENERGYBOXX_HOST:$ENERGYBOXX_PORT"
bashio::log.info "  Username: $ENERGYBOXX_USER"
bashio::log.info "  CA Certificate: $CA_CERT"
bashio::log.info "  API: $SUPERVISOR_API"
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
fi

# Verify CA certificate exists
if [ -f "$CA_CERT" ]; then
  bashio::log.info "✓ CA certificate found"
else
  bashio::log.error "✗ CA certificate not found at $CA_CERT"
fi

bashio::log.info "Connecting directly to remote broker..."
bashio::log.info "Subscribing to: $COMMUNITY_TOPIC"

# Convert topic to sensor entity_id
topic_to_entity_id() {
  local topic="$1"
  local base_topic="$COMMUNITY_TOPIC"

  local topic_prefix=$(echo "$base_topic" | sed 's|/+$||' | sed 's|/#$||')
  local subtopic=$(echo "$topic" | sed "s|^${topic_prefix}/||")
  local entity_name=$(echo "$subtopic" | tr '[:upper:]' '[:lower:]' | tr '/' '_' | tr -cd '[:alnum:]_')

  if [ -z "$entity_name" ]; then
    entity_name="unknown"
  fi

  echo "sensor.community_${entity_name}"
}

# Check if value is numeric (int or float)
is_numeric() {
  local v="$1"
  [[ "$v" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

# JSON-escape string for inclusion in payload
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Update sensor state via REST /api/states. Auto-creates entity in HA registry.
update_sensor() {
  local entity_id="$1"
  local value="$2"
  local topic="$3"

  local key="${entity_id#sensor.}"
  local friendly_name=$(echo "${key#community_}" | tr '_' ' ')

  local escaped_value=$(json_escape "$value")
  local escaped_topic=$(json_escape "$topic")
  local escaped_name=$(json_escape "$friendly_name")

  local attrs="\"friendly_name\": \"${escaped_name}\", \"source_topic\": \"${escaped_topic}\""

  if is_numeric "$value"; then
    attrs="${attrs}, \"state_class\": \"measurement\""
  fi

  local payload="{\"state\": \"${escaped_value}\", \"attributes\": {${attrs}}}"

  RESPONSE=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    "$SUPERVISOR_API/states/${entity_id}" \
    -d "$payload")

  HTTP_CODE=$(echo "$RESPONSE" | grep "HTTP_CODE:" | cut -d: -f2)
  BODY=$(echo "$RESPONSE" | sed '/HTTP_CODE:/d')

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
    bashio::log.info "✓ $entity_id = \"$value\" (HTTP $HTTP_CODE)"
    return 0
  else
    bashio::log.error "✗ Failed to set sensor state (HTTP $HTTP_CODE)"
    bashio::log.error "  Entity: $entity_id"
    bashio::log.error "  Value: $value"
    bashio::log.error "  Response: $BODY"
    return 1
  fi
}

# Main loop
bashio::log.info "Starting mosquitto_sub listener (connecting to remote broker)..."
MESSAGE_COUNT=0

MQTT_CMD="mosquitto_sub -h $ENERGYBOXX_HOST -p $ENERGYBOXX_PORT -u $ENERGYBOXX_USER -P $ENERGYBOXX_PASSWORD"

if [ -f "$CA_CERT" ]; then
  MQTT_CMD="$MQTT_CMD --cafile $CA_CERT"
fi

MQTT_CMD="$MQTT_CMD -t $COMMUNITY_TOPIC -v"

bashio::log.info "Executing: mosquitto_sub -h $ENERGYBOXX_HOST -p $ENERGYBOXX_PORT -u $ENERGYBOXX_USER -P *** --cafile $CA_CERT -t $COMMUNITY_TOPIC -v"

$MQTT_CMD 2>&1 | while read -r line; do
  bashio::log.debug "Received line from mosquitto_sub: $line"
  MESSAGE_COUNT=$((MESSAGE_COUNT + 1))

  if echo "$line" | grep -qi "error\|connection refused\|failed"; then
    bashio::log.error "mosquitto_sub error: $line"
    continue
  fi

  TOPIC=$(echo "$line" | awk '{print $1}')
  MESSAGE=$(echo "$line" | cut -d' ' -f2-)

  bashio::log.info "MQTT #$MESSAGE_COUNT  $TOPIC = $MESSAGE"

  ENTITY_ID=$(topic_to_entity_id "$TOPIC")
  update_sensor "$ENTITY_ID" "$MESSAGE" "$TOPIC"
done

bashio::log.error "MQTT Sensor Listener: mosquitto_sub exited unexpectedly"
