FROM alpine:latest

RUN apk add --no-cache lftp

WORKDIR /app
WORKDIR /public_html

COPY init.sh /app/init.sh
COPY LICENSE README.md /app/

ENTRYPOINT ["/app/init.sh"]
