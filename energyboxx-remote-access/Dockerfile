ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache frp nginx jq curl

WORKDIR /app
COPY run.sh notify.sh nginx.conf ./
RUN chmod +x ./run.sh

CMD ["/app/run.sh"]
