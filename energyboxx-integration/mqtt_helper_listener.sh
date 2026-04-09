#!/usr/bin/with-contenv bashio

bashio::log.info "MQTT Helper Listener: Starting..."

# Get configuration
COMMUNITY_TOPIC=$(bashio::config 'community_topic')
SUPERVISOR_API="${SUPERVISOR_API:-http://supervisor/core/api}"
SUPERVISOR_TOKEN="${SUPERVISOR_TOKEN}"

# Track created helpers to avoid duplicates
HELPERS_FILE="/data/created_helpers.txt"
mkdir -p /data
touch "$HELPERS_FILE"

bashio::log.info "Listening on topic: $COMMUNITY_TOPIC on local broker (127.0.0.1:1885)"

# Function to convert topic to entity_id
topic_to_entity_id() {
  local topic="$1"
  # Remove base community/ prefix if present
  local entity_name=$(echo "$topic" | sed 's|^community/||')
  # Replace / with _ and remove invalid characters
  entity_name=$(echo "$entity_name" | tr '/' '_' | tr -cd '[:alnum:]_')
  echo "input_text.community_${entity_name}"
}

# Function to create input_text helper
create_helper() {
  local entity_id="$1"
  local topic="$2"

  # Check if already created
  if grep -q "^${entity_id}$" "$HELPERS_FILE"; then
    return 0
  fi

  bashio::log.info "Creating helper: $entity_id for topic: $topic"

  # Extract helper name from entity_id
  local helper_name=$(echo "$entity_id" | sed 's/input_text\.//' | tr '_' ' ')

  # Create input_text helper via HA REST API
  RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    "$SUPERVISOR_API/services/input_text/create" \
    -d "{
      \"name\": \"${helper_name}\",
      \"min\": 0,
      \"max\": 255,
      \"initial\": \"\"
    }")

  if [ $? -eq 0 ]; then
    bashio::log.info "Helper created: $entity_id"
    echo "$entity_id" >> "$HELPERS_FILE"
    return 0
  else
    bashio::log.error "Failed to create helper: $entity_id. Response: $RESPONSE"
    return 1
  fi
}

# Function to update helper value
update_helper() {
  local entity_id="$1"
  local value="$2"

  # Call input_text.set_value service
  RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    "$SUPERVISOR_API/services/input_text/set_value" \
    -d "{
      \"entity_id\": \"${entity_id}\",
      \"value\": \"${value}\"
    }")

  if [ $? -eq 0 ]; then
    bashio::log.debug "Updated helper: $entity_id = $value"
    return 0
  else
    bashio::log.error "Failed to update helper: $entity_id. Response: $RESPONSE"
    return 1
  fi
}

# Main loop: Subscribe to MQTT and process messages
mosquitto_sub -h 127.0.0.1 -p 1885 -t "$COMMUNITY_TOPIC" -v | while read -r line; do
  # Parse topic and message (format: "topic message")
  TOPIC=$(echo "$line" | cut -d' ' -f1)
  MESSAGE=$(echo "$line" | cut -d' ' -f2-)

  bashio::log.info "Received: [$TOPIC] = $MESSAGE"

  # Convert topic to entity_id
  ENTITY_ID=$(topic_to_entity_id "$TOPIC")

  # Create helper if it doesn't exist
  if ! grep -q "^${ENTITY_ID}$" "$HELPERS_FILE"; then
    create_helper "$ENTITY_ID" "$TOPIC"
    sleep 1  # Give HA time to create the entity
  fi

  # Update helper value
  update_helper "$ENTITY_ID" "$MESSAGE"
done

bashio::log.error "MQTT Helper Listener: Stopped unexpectedly"
