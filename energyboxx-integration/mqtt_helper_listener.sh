#!/usr/bin/with-contenv bashio

bashio::log.info "MQTT Sensor Listener: Starting..."

COMMUNITY_TOPIC=$(bashio::config 'community_topic')
ENERGYBOXX_USER=$(bashio::config 'energyboxx_mqtt_username')
ENERGYBOXX_PASSWORD=$(bashio::config 'energyboxx_mqtt_password')
ENERGYBOXX_HOST="${ENERGYBOXX_HOST:-ess.grexxconnect.com}"
ENERGYBOXX_PORT="${ENERGYBOXX_PORT:-8883}"

SUPERVISOR_API="${SUPERVISOR_API:-http://supervisor/core/api}"
CA_CERT="/config/ssl/grexxconnect_ca.crt"

bashio::log.info "Topic=$COMMUNITY_TOPIC Broker=$ENERGYBOXX_HOST:$ENERGYBOXX_PORT User=$ENERGYBOXX_USER"

topic_to_entity_id() {
  local topic="$1"
  local base_topic="$COMMUNITY_TOPIC"
  local topic_prefix=$(echo "$base_topic" | sed 's|/+$||' | sed 's|/#$||')
  local subtopic=$(echo "$topic" | sed "s|^${topic_prefix}/||")
  local entity_name=$(echo "$subtopic" | tr '[:upper:]' '[:lower:]' | tr '/' '_' | tr -cd '[:alnum:]_')
  if [ -z "$entity_name" ]; then
    entity_name="unknown"
  fi
  echo "sensor.${entity_name}"
}

is_numeric() {
  [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

update_sensor() {
  local entity_id="$1"
  local value="$2"
  local topic="$3"

  local key="${entity_id#sensor.}"
  local friendly_name=$(echo "${key}" | tr '_' ' ')

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
    bashio::log.info "✓ $entity_id = \"$value\""
  else
    bashio::log.error "✗ Failed (HTTP $HTTP_CODE) $entity_id: $BODY"
  fi
}

bashio::log.info "Connecting to $ENERGYBOXX_HOST:$ENERGYBOXX_PORT, subscribing to $COMMUNITY_TOPIC"

mosquitto_sub \
  -h "$ENERGYBOXX_HOST" \
  -p "$ENERGYBOXX_PORT" \
  -u "$ENERGYBOXX_USER" \
  -P "$ENERGYBOXX_PASSWORD" \
  --cafile "$CA_CERT" \
  -t "$COMMUNITY_TOPIC" \
  -v 2>&1 | while read -r line; do
    if echo "$line" | grep -qi "error\|connection refused\|failed"; then
      bashio::log.error "mosquitto_sub: $line"
      continue
    fi

    TOPIC=$(echo "$line" | awk '{print $1}')
    MESSAGE=$(echo "$line" | cut -d' ' -f2-)
    bashio::log.info "MQTT $TOPIC = $MESSAGE"

    ENTITY_ID=$(topic_to_entity_id "$TOPIC")
    update_sensor "$ENTITY_ID" "$MESSAGE" "$TOPIC"
  done

bashio::log.error "mosquitto_sub exited."
