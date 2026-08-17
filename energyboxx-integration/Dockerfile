ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache jq mosquitto-clients curl python3 py3-websocket-client

WORKDIR /app

COPY run.sh ./run.sh
COPY mqtt_helper_listener.sh ./mqtt_helper_listener.sh
COPY create_dashboard.py ./create_dashboard.py
COPY dashboard.json ./dashboard.json
COPY ca.crt ./ca.crt

RUN chmod +x ./run.sh ./mqtt_helper_listener.sh ./create_dashboard.py

CMD ["/app/run.sh"]
