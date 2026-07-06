FROM alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b

# B-13: pin the base image by digest (resolved against the alpine:3.24
# tag at the time of v2.3.1). Bump on a controlled cadence via the
# release pipeline; the digest is recorded in the corresponding tag
# message.
#
# Pin the package versions too (resolves hadolint DL3018).
# lftp=4.9.3-r0 and ca-certificates=20260611-r0 are the current
# versions in alpine 3.24; bump them together with the base image.
RUN apk add --no-cache \
      lftp=4.9.3-r0 \
      ca-certificates=20260611-r0 \
 && addgroup -S lftp \
 && adduser -S lftp -G lftp -h /home/lftp \
 && mkdir -p /home/lftp \
 && chown -R lftp:lftp /home/lftp

WORKDIR /app

COPY init.sh /app/init.sh
COPY LICENSE README.md /app/

# Bake the image version into /app/VERSION so the deprecation warning
# in init.sh can print the actual version even on local builds.
# `release.yml` passes --build-arg VERSION=<tag>; local `docker build`
# gets the default "dev".
ARG VERSION=dev
RUN echo "$VERSION" > /app/VERSION

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
