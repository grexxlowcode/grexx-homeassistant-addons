ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache jq mosquitto-clients curl

WORKDIR /app

COPY run.sh ./run.sh
COPY mqtt_helper_listener.sh ./mqtt_helper_listener.sh
COPY ca.crt ./ca.crt

RUN chmod +x ./run.sh ./mqtt_helper_listener.sh

CMD ["/app/run.sh"]
