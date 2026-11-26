#!/usr/bin/with-contenv bashio
# shellcheck source=notify.sh
source /app/notify.sh

if bashio::config.has_value 'log_level'; then
  bashio::log.level "$(bashio::config 'log_level')"
fi

bashio::log.info "MQTT Sensor Listener: Starting..."

COMMUNITY_TOPIC=$(bashio::config 'community_topic')
FLIP_POWER_RESULT_KW=$(bashio::config 'flip_power_result_kw')
ENERGYBOXX_USER=$(bashio::config 'energyboxx_mqtt_username')
ENERGYBOXX_PASSWORD=$(bashio::config 'energyboxx_mqtt_password')
ENERGYBOXX_HOST="${ENERGYBOXX_HOST:-ess.grexxconnect.com}"
ENERGYBOXX_PORT="${ENERGYBOXX_PORT:-8883}"

SUPERVISOR_API="${SUPERVISOR_API:-http://supervisor/core/api}"
CA_CERT="/config/ssl/grexxconnect_ca.crt"
LAST_ENTITY_FILE="/tmp/last_entity"
RECONNECT_DELAY=30

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

  local unit=""
  local device_class=""
  case "$key" in
    *_kw)
      unit="kW"
      device_class="power"
      ;;
    *_price_eur)
      unit="€/kWh"
      ;;
  esac

  local attrs="\"friendly_name\": \"${escaped_name}\", \"source_topic\": \"${escaped_topic}\""
  if is_numeric "$value"; then
    attrs="${attrs}, \"state_class\": \"measurement\""
    if [ -n "$unit" ]; then
      attrs="${attrs}, \"unit_of_measurement\": \"${unit}\""
    fi
    if [ -n "$device_class" ]; then
      attrs="${attrs}, \"device_class\": \"${device_class}\""
    fi
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
    bashio::log.debug "✓ $entity_id = \"$value\""
    echo "$entity_id" > "$LAST_ENTITY_FILE"
  else
    bashio::log.error "✗ Failed (HTTP $HTTP_CODE) $entity_id: $BODY"
  fi
}

# An HA core restart wipes sensors set via POST /states; reconnecting makes the broker resend retained values.
# ponytail: 60s probe leaves sensors empty up to 90s; subscribe to homeassistant_start over WebSocket if that matters.
watch_core_restart() {
  while sleep 60; do
    [ -s "$LAST_ENTITY_FILE" ] || continue
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
      "$SUPERVISOR_API/states/$(cat "$LAST_ENTITY_FILE")")
    if [ "$code" = "404" ]; then
      bashio::log.info "Home Assistant restarted; reconnecting to restore sensors."
      pkill -x mosquitto_sub
    fi
  done
}
watch_core_restart &

while true; do
  bashio::log.info "Connecting to $ENERGYBOXX_HOST:$ENERGYBOXX_PORT, subscribing to $COMMUNITY_TOPIC"

  mosquitto_sub \
    -h "$ENERGYBOXX_HOST" \
    -p "$ENERGYBOXX_PORT" \
    -u "$ENERGYBOXX_USER" \
    -P "$ENERGYBOXX_PASSWORD" \
    --cafile "$CA_CERT" \
    -t "$COMMUNITY_TOPIC" \
    -v 2>&1 | {
    receiving=false
    while read -r line; do
      if [[ "$line" =~ ^(Error|Connection\ error|Unable\ to\ connect) ]]; then
        bashio::log.error "mosquitto_sub: $line"
        if [[ "$line" =~ [Nn]ot\ authori[sz]ed|[Bb]ad\ user\ name\ or\ password ]]; then
          notify "The Energyboxx broker rejected your username or password. Check them in the add-on's Configuration tab."
        else
          notify "Cannot reach the Energyboxx broker (${line%.}). The add-on retries every ${RECONNECT_DELAY} seconds."
        fi
        continue
      fi

      TOPIC=$(echo "$line" | awk '{print $1}')
      MESSAGE=$(echo "$line" | cut -d' ' -f2-)
      bashio::log.debug "MQTT $TOPIC = $MESSAGE"

      if [ "$receiving" = false ]; then
        receiving=true
        bashio::log.info "Receiving data from the Energyboxx broker."
        dismiss_notification
      fi

      ENTITY_ID=$(topic_to_entity_id "$TOPIC")

      if [ "$FLIP_POWER_RESULT_KW" = "true" ] && [ "$ENTITY_ID" = "sensor.community_power_result_kw" ] && is_numeric "$MESSAGE"; then
        if [[ "$MESSAGE" =~ ^-?0+(\.0+)?$ ]]; then
          :  # leave zero untouched, avoid "-0"
        elif [[ "$MESSAGE" == -* ]]; then
          MESSAGE="${MESSAGE#-}"
        else
          MESSAGE="-$MESSAGE"
        fi
        bashio::log.debug "Flipped community_power_result_kw -> $MESSAGE"
      fi

      update_sensor "$ENTITY_ID" "$MESSAGE" "$TOPIC"
    done
  }

  bashio::log.warning "Disconnected from the Energyboxx broker; reconnecting in ${RECONNECT_DELAY}s."
  sleep "$RECONNECT_DELAY"
done
