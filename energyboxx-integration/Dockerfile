ARG BUILD_FROM
FROM $BUILD_FROM

# Install required packages
RUN \
    apk add --no-cache \
        python3 \
        py3-pip \
        jq \
        mosquitto \
        mosquitto-clients \
        py3-flask

# Copy data for add-on
COPY run.sh /
COPY setup_mqtt.py /
COPY automation.yaml /

RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
