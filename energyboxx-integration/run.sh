#!/usr/bin/with-contenv bashio

LOGFILE="/var/log/energyboxx-addon.log"

# Ensure log file exists and is writable
mkdir -p /var/log
: > "$LOGFILE"
chmod 666 "$LOGFILE"

# Redirect all output to both stdout and log file
exec > >(tee -a "$LOGFILE") 2>&1

# Get config values
ENERGYBOXX_HOST=$(bashio::config 'energyboxx_mqtt_host')
ENERGYBOXX_PORT=$(bashio::config 'energyboxx_mqtt_port')
ENERGYBOXX_USER=$(bashio::config 'energyboxx_mqtt_username')
ENERGYBOXX_PASSWORD=$(bashio::config 'energyboxx_mqtt_password')

# Create mosquitto bridge configuration
mkdir -p /etc/mosquitto/conf.d
cat > /etc/mosquitto/conf.d/bridge.conf << EOF
# Energyboxx MQTT Bridge
connection energyboxx-bridge
address ${ENERGYBOXX_HOST}:${ENERGYBOXX_PORT}
remote_username ${ENERGYBOXX_USER}
remote_password ${ENERGYBOXX_PASSWORD}
topic # both 0 energyboxx/ energyboxx/
bridge_attempt_unsubscribe false
EOF

# Start mosquitto with the bridge config
mosquitto -c /etc/mosquitto/mosquitto.conf &
sleep 5

# Start config server in the background
python3 /config_server.py &

# Setup MQTT statestream and automation
bashio::log.info "Setting up MQTT statestream and automation..."
python3 /setup_mqtt.py

# Keep the container running
tail -f /dev/null
