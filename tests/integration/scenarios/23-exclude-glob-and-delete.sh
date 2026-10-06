#!/bin/sh
# 23-exclude-glob-and-delete.sh — frozen acceptance scenario.
#
# Business rule: `exclude` takes a comma-separated list of shell globs.
# Matching files are neither uploaded nor deleted, at any depth. With
# delete: true, server-only files that match `exclude` survive, and
# server-only files that do not match are removed.
#
# Local tree:  index.html  local.bak  assets/app.js  assets/app.js.map
#              sub/deep.bak
# Server tree before:  keep.log  stale.html
# Inputs: delete=true, exclude="*.bak, *.map , *.log"
#
# Expected on the server after the run:
#   present: index.html, assets/app.js, keep.log
#   absent:  local.bak, assets/app.js.map, sub/deep.bak, stale.html
set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "23-exclude-glob-and-delete"
start_ftp_server "${FTP_USER}" "${FTP_PASSWORD}" "${FTP_DATA_DIR}"

_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env file failed"
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"
_src=$(mktemp -d -t actsrc.XXXXXX) || log_fail "mktemp src dir failed"
trap 'rm -f "${_env:-}" "${_log:-}"; rm -rf "${_src:-}"; stop_ftp_server' EXIT

mkdir -p "${_src}/assets" "${_src}/sub"
printf 'index\n' > "${_src}/index.html"
printf 'bak\n'   > "${_src}/local.bak"
printf 'js\n'    > "${_src}/assets/app.js"
printf 'map\n'   > "${_src}/assets/app.js.map"
printf 'deep\n'  > "${_src}/sub/deep.bak"
chmod -R a+rX "${_src}"

_ftp_home="${FTP_DATA_DIR}/${FTP_USER}"
printf 'server-only log\n'  > "${_ftp_home}/keep.log"
printf 'server-only page\n' > "${_ftp_home}/stale.html"
chmod 0666 "${_ftp_home}/keep.log" "${_ftp_home}/stale.html"

build_action_env_file "${_env}" "${IMAGE}" /data / \
  "INPUT_DELETE=true" \
  "INPUT_EXCLUDE=*.bak, *.map , *.log"
set +e
timeout 60 ${RUNTIME} run --rm --network host \
    -v "${_src}:/data:ro" --env-file "${_env}" \
    "${IMAGE}" > "${_log}" 2>&1
_rc=$?
set -e
assert_action_success "${_log}" "${_rc}"

assert_present "${_ftp_home}" "index.html"
assert_present "${_ftp_home}" "assets/app.js"
assert_present "${_ftp_home}" "keep.log"
assert_absent  "${_ftp_home}" "local.bak"
assert_absent  "${_ftp_home}" "assets/app.js.map"
assert_absent  "${_ftp_home}" "sub/deep.bak"
assert_absent  "${_ftp_home}" "stale.html"

log_pass "scenario 23 passed: exclude globs filter upload and protect server-only files from delete"
exit 0
