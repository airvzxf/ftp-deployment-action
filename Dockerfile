FROM alpine@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6

# B-13: pin the base image by digest (resolved against the alpine:3.24
# tag at the time of v2.3.1). Bump on a controlled cadence via the
# release pipeline; the digest is recorded in the corresponding tag
# message.
#
# Pin apk packages by version (pkg~X.Y.Z), never by Alpine revision (-rN):
# GitHub builds this file on every run and Alpine deletes old revisions.
# ca-certificates is unpinned on purpose: the newest CA bundle is correct.
RUN apk add --no-cache \
      lftp~4.9.3 \
      ca-certificates \
 && addgroup -S lftp \
 && adduser -S lftp -G lftp -h /home/lftp

# VERSION comes from the repo: GitHub builds this file on the runner
# without build args, and entrypoint.sh prints it on the first line.
COPY entrypoint.sh lib.sh VERSION /app/
RUN chmod 0644 /app/VERSION \
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
