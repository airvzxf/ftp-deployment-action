#!/bin/sh
# tests/integration/scenarios/04-ftps-implicit-upload.sh
#
# Scenario 04 (variant C): FTPS implicit upload — STUB.
#
# FTPS implicit (TLS from byte 0 on a dedicated port, typically 990)
# is the other half of the SSL/TLS support. Wiring it through this
# harness requires:
#
#   * vsftpd with a self-signed certificate AND listen on 990.
#   * Pointing the action at ftps://host:990 with
#     INPUT_FTP_SSL_ALLOW=true.
#   * Asserting that lftp negotiates TLS without an AUTH upgrade.
#
# Like scenario 03, this is real work and lives behind #120. For
# #117 we leave this as a documented skip.

set -eu

printf '%s\n' "  skip: scenario 04 (FTPS implicit upload) deferred to #120 (FTPS integration)"
exit 0
