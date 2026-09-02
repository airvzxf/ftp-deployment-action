#!/bin/sh
# tests/integration/scenarios/03-ftps-explicit-upload.sh
#
# Scenario 03 (variant C): FTPS explicit upload — STUB.
#
# FTPS explicit (AUTH TLS upgrade on the FTP control channel) is the
# first half of the SSL/TLS support in ftp-deployment-action. Wiring
# it through this integration harness requires:
#
#   * A server with a self-signed TLS certificate (openssl req ...).
#   * Mounting the certificate into fauria/vsftpd.
#   * Pointing the action at ftps://host:21 with
#     INPUT_FTP_SSL_ALLOW=true / INPUT_SSL_VERIFY_CERTIFICATE=false.
#   * Asserting that lftp negotiates AUTH TLS (visible in the log).
#
# That is real work and lives behind #120 (FTPS integration). For
# #117 we leave this scenario as a documented skip so the harness's
# 5-scenario count is honest: scenario 03 exists, it just does not
# run yet.
#
# Acceptance criteria for #117 are about the harness FRAMEWORK (boot
# vsftpd, run scenarios standalone, idempotent, CI <= 5 min). The
# scenario count is 5 because there are five slots; three of them
# run today (01, 02, 05), two are placeholders (03, 04).

set -eu

printf '%s\n' "  skip: scenario 03 (FTPS explicit upload) deferred to #120 (FTPS integration)"
exit 0
