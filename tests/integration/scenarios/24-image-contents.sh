#!/bin/sh
# 24-image-contents.sh — frozen acceptance scenario (no FTP server).
#
# Business rule: the action image carries only what the action uses.
#
# Expected:   lftp 4.9.x present, curl absent, runs as the non-root
#             user "lftp", /app contains only entrypoint.sh, lib.sh and
#             VERSION.
set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

printf '\n=== Scenario: %s ===\n' "24-image-contents"

# shellcheck disable=SC2016  # the -c body is expanded by the container shell
_out=$(${RUNTIME} run --rm --entrypoint sh "${IMAGE}" -c '
  printf "lftp=%s\n" "$(lftp --version 2>/dev/null | head -1)"
  printf "curl=%s\n" "$(command -v curl || echo absent)"
  printf "user=%s\n" "$(id -un)"
  printf "app=%s\n"  "$(ls /app | sort | tr "\n" " ")"
') || log_fail "could not run ${IMAGE}"
printf '%s\n' "${_out}" | sed 's/^/    /'

printf '%s\n' "${_out}" | grep -q '^lftp=.*Version 4\.9\.' || log_fail "lftp 4.9.x not found in the image"
printf '%s\n' "${_out}" | grep -q '^curl=absent$'          || log_fail "curl is still installed in the image"
printf '%s\n' "${_out}" | grep -q '^user=lftp$'            || log_fail "image does not run as user lftp"
printf '%s\n' "${_out}" | grep -q '^app=VERSION entrypoint.sh lib.sh $' || log_fail "/app has unexpected content"

log_pass "scenario 24 passed: image contents are minimal"
exit 0
