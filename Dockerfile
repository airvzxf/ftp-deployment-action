FROM alpine@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# B-13: pin the base image by digest. Bump via the release pipeline.
#
# Pin package versions by version prefix (pkg~X.Y.Z), not by Alpine -rN
# revision; or not pinned at all (ca-certificates follows the alpine
# index). The '-rN' alpine revisions retire out of band; pinning by
# prefix keeps the build reproducible without forcing a release for
# every revision bump.
RUN apk add --no-cache \
      lftp~4.9.3 \
      ca-certificates \
 && addgroup -S lftp \
 && adduser -S lftp -G lftp -h /home/lftp

COPY entrypoint.sh lib.sh /app/

# Bake the image version into /app/VERSION so the deprecation warning
# in entrypoint.sh can print the actual version even on local builds.
# `release.yml` passes --build-arg VERSION=<tag>; local `docker build`
# gets the default "dev".
ARG VERSION=dev
RUN printf '%s\n' "$VERSION" > /app/VERSION \
 && chmod 0644 /app/VERSION \
 && chmod 0755 /app/entrypoint.sh

# B-03 / B-14: the script writes the .netrc file at $HOME/.netrc, so
# HOME must point at the lftp user's writable home. Without this ENV
# HOME is inherited as /root from the base image; USER lftp is set
# further down and at that point the lftp user has no write access to
# /root, which would make the .netrc write fail.
ENV HOME=/home/lftp

# B-14: drop root. From here on, every process in the container runs as
# 'lftp'. /app remains root-owned but is world-readable, which is enough
# for entrypoint.sh to be executed.
USER lftp

ENTRYPOINT ["/app/entrypoint.sh"]
