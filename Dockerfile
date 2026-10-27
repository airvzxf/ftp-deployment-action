FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

# B-13: pin the base image by tag and digest (alpine:<X.Y.Z>@sha256:...).
# The tag shows the Alpine version; the digest fixes the content.
# Dependabot (.github/dependabot.yml, group dockerfile-base) bumps both,
# together with the two test Dockerfiles (tests/acceptance/static.sh
# S13).
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
# COPY keeps each file's mode from the build context, so set every mode
# here: USER lftp (below) must be able to read lib.sh, which
# entrypoint.sh sources, even if the context was made under umask 077.
COPY entrypoint.sh lib.sh openssl-tls12.cnf VERSION /app/
RUN chmod 0644 /app/VERSION /app/openssl-tls12.cnf /app/lib.sh \
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
# The content of local_dir must be world-readable too (files o+r, dirs
# o+rx): see "Self-hosted runners" in README.md.
USER lftp

ENTRYPOINT ["/app/entrypoint.sh"]
