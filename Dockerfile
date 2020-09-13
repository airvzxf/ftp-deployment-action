FROM alpine:latest

RUN apk add --no-cache lftp

WORKDIR /app
WORKDIR /public_html

COPY init.sh /app/init.sh
COPY LICENSE README.md /app/

RUN ["/bin/chmod", "+x", "/app/init.sh"]

ENTRYPOINT ["/app/init.sh"]
