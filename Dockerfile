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

# B-03 / B-14: default HOME for the image: pins HOME to the lftp user's
# home for a `docker run` debugging session or a shell in the container
# (running as the lftp user, set further down), whatever the runtime
# would otherwise derive (podman/runc take it from /etc/passwd when it
# is unset). This ENV does not decide where the .netrc goes:
# entrypoint.sh pins NETRC="/home/lftp/.netrc" and exports
# HOME="/home/lftp" itself, unconditionally, before write_netrc (#111),
# because a runner can pass its own HOME (e.g. -e HOME=/github/home),
# which overrides this ENV. Do not treat this ENV as the safeguard for
# the .netrc path; the pin in entrypoint.sh is.
ENV HOME=/home/lftp

# B-14: drop root. From here on, every process in the container runs as
# 'lftp'. /app remains root-owned but is world-readable, which is enough
# for entrypoint.sh to be executed.
# The content of local_dir must be world-readable too (files o+r, dirs
# o+rx): see "Self-hosted runners" in README.md.
USER lftp

ENTRYPOINT ["/app/entrypoint.sh"]
