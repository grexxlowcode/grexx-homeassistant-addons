ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache python3 py3-websocket-client py3-paho-mqtt

WORKDIR /app

COPY gateway.py ca.crt ./

CMD ["/usr/bin/with-contenv", "python3", "/app/gateway.py"]
