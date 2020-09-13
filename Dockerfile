FROM debian:stable-slim

WORKDIR /app

RUN apt-get -y update && \
    apt-get install -y \
        lftp

COPY init.sh /app/init.sh
COPY LICENSE README.md /app/

RUN ["/bin/chmod", "+x", "/app/init.sh"]

ENTRYPOINT ["/app/init.sh"]
#RUN ["/bin/sh", "/app/init.sh"]
