FROM alpine:3.23.3

# B-14: create an unprivileged user and group for lftp to run as.
# All credentials, cache and .netrc files are written under this user's
# $HOME (/home/lftp), so the user must own it before the USER directive.
RUN apk add --no-cache lftp ca-certificates \
 && addgroup -S lftp \
 && adduser -S lftp -G lftp -h /home/lftp \
 && mkdir -p /home/lftp \
 && chown -R lftp:lftp /home/lftp

WORKDIR /app

COPY init.sh /app/init.sh
COPY LICENSE README.md /app/

RUN ["/bin/chmod", "+x", "/app/init.sh"]

# B-14: drop root. From here on, every process in the container runs as
# 'lftp'. /app remains root-owned but is world-readable, which is enough
# for init.sh to be executed.
USER lftp

ENTRYPOINT ["/app/init.sh"]
