ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache jq mosquitto tailscale iptables ip6tables iproute2

WORKDIR /app

COPY run.sh ./run.sh
COPY automation.json ./automation.json
COPY statestream-config.yaml ./statestream-config.yaml
COPY mosquitto.conf ./mosquitto.conf

RUN chmod +x ./run.sh

CMD ["/app/run.sh"]
