#!/usr/bin/with-contenv bashio

bashio::log.info "Starting Energyboxx MQTT Add-on..."

ENERGYBOXX_HOST="ess.grexxconnect.com"
ENERGYBOXX_PORT=8883

ENERGYBOXX_USER=$(bashio::config 'energyboxx_mqtt_username')
ENERGYBOXX_PASSWORD=$(bashio::config 'energyboxx_mqtt_password')
COMMUNITY_TOPIC=$(bashio::config 'community_topic')

if [ -z "$ENERGYBOXX_USER" ] || [ -z "$ENERGYBOXX_PASSWORD" ]; then
  bashio::log.error "energyboxx_mqtt_username and energyboxx_mqtt_password are required."
  exit 1
fi

bashio::log.info "Installing CA certificate..."
mkdir -p /config/ssl
cp /app/ca.crt /config/ssl/grexxconnect_ca.crt

SUPERVISOR_API="${SUPERVISOR_API:-http://supervisor/core/api}"
if [ -z "$SUPERVISOR_TOKEN" ]; then
  bashio::log.error "SUPERVISOR_TOKEN missing. Cannot call HA API."
  exit 1
fi

# Wait for Home Assistant API
for i in $(seq 1 10); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    "$SUPERVISOR_API/")
  if [ "$STATUS" = "200" ]; then
    bashio::log.info "Home Assistant API ready."
    break
  fi
  bashio::log.info "Waiting for HA API ($i/10), status=$STATUS"
  sleep 10
done

export ENERGYBOXX_HOST ENERGYBOXX_PORT
exec /app/mqtt_helper_listener.sh
