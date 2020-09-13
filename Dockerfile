FROM alpine:latest

RUN apk add --no-cache lftp

WORKDIR /app

COPY init.sh /app/init.sh
COPY LICENSE README.md /app/

RUN ["/bin/chmod", "+x", "/app/init.sh"]

ENTRYPOINT ["/app/init.sh"]
