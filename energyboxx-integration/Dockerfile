ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache jq mosquitto mosquitto-clients tailscale iptables ip6tables iproute2

WORKDIR /app

COPY run.sh ./run.sh
COPY automation.json ./automation.json
COPY statestream-config.yaml ./statestream-config.yaml
COPY mosquitto.conf ./mosquitto.conf
COPY mqtt_helper_listener.sh ./mqtt_helper_listener.sh
COPY ca.crt ./ca.crt

RUN chmod +x ./run.sh ./mqtt_helper_listener.sh

CMD ["/app/run.sh"]
