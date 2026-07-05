FROM alpine@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659

# B-13: pin the base image by digest (resolved against the alpine:3.23.3
# tag at the time of v2.0.1). Bump on a controlled cadence via the
# release pipeline; the digest is recorded in the corresponding tag
# message.
#
# Pin the package versions too (resolves hadolint DL3018).
# lftp=4.9.2-r9 and ca-certificates=20260611-r0 are the current
# versions in alpine 3.23.3; bump them together with the base image.
RUN apk add --no-cache \
      lftp=4.9.2-r9 \
      ca-certificates=20260611-r0 \
 && addgroup -S lftp \
 && adduser -S lftp -G lftp -h /home/lftp \
 && mkdir -p /home/lftp \
 && chown -R lftp:lftp /home/lftp

WORKDIR /app

COPY init.sh /app/init.sh
COPY LICENSE README.md /app/

RUN ["/bin/chmod", "+x", "/app/init.sh"]

# B-03 / B-14: the script writes the .netrc file at $HOME/.netrc, so
# HOME must point at the lftp user's writable home. Without this ENV
# HOME is inherited as /root from the base image; USER lftp is set
# further down and at that point the lftp user has no write access to
# /root, which would make the .netrc write fail.
ENV HOME=/home/lftp

# B-14: drop root. From here on, every process in the container runs as
# 'lftp'. /app remains root-owned but is world-readable, which is enough
# for init.sh to be executed.
USER lftp

ENTRYPOINT ["/app/init.sh"]
