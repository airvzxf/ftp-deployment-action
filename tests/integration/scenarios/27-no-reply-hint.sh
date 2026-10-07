#!/bin/sh
# 27-no-reply-hint.sh — a server that never answers gets a hint, not
# only lftp's bare "max-retries exceeded" (#342).
#
# Business rule: when the server never replies (firewall drop, wrong
# host), the user must be told to check the address, port and firewall.
#
# The "server" is a socket that listens but never accepts: the kernel
# completes the TCP handshake and nobody ever sends the FTP greeting,
# so every lftp attempt ends in a timeout, as behind a firewall that
# drops packets, but without depending on the runner's routing.
#
# Expected:   exit 1, the no-reply hint, no PERMANENT classification.
set -eu

# shellcheck disable=SC1007
COMMON=$(CDPATH= cd -- "$(dirname -- "$0")/../lib" && pwd)
# shellcheck source=tests/integration/lib/common.sh
. "${COMMON}/common.sh"

scenario_setup "27-no-reply-hint"
command -v python3 >/dev/null 2>&1 || log_fail "python3 is required for the silent listener"

_env=$(mktemp -t actenv.XXXXXX) || log_fail "mktemp env file failed"
_log=$(mktemp -t actlog.XXXXXX) || log_fail "mktemp log file failed"
_port_file=$(mktemp -t port.XXXXXX) || log_fail "mktemp port file failed"
_listener_pid=""
trap 'rm -f "${_env:-}" "${_log:-}" "${_port_file:-}"; [ -n "${_listener_pid}" ] && kill "${_listener_pid}" 2>/dev/null; :' EXIT

python3 -c '
import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(64)
with open(sys.argv[1], "w") as f:
    f.write(str(s.getsockname()[1]))
time.sleep(300)
' "${_port_file}" &
_listener_pid=$!

_i=0
while [ ! -s "${_port_file}" ]; do
  _i=$((_i + 1))
  [ "${_i}" -le 50 ] || log_fail "silent listener did not start"
  sleep 0.1
done
_port=$(cat "${_port_file}")
log_info "silent listener on 127.0.0.1:${_port}"

build_action_env_file "${_env}" "${IMAGE}" /data site \
  "INPUT_SERVER=ftp://127.0.0.1:${_port}" "INPUT_NET_TIMEOUT=2s"
# run_action re-enables `set -e` before returning, so capture the code
# with `||` instead of reading $? after it.
_rc=0
run_action "${IMAGE}" "${_env}" 120 "${_log}" || _rc=$?

show_log() { sed 's/^/    | /' "${_log}" >&2; }

if [ "${_rc}" -ne 1 ]; then
  show_log; log_fail "expected exit 1 against a silent server, got ${_rc}"
fi
if ! grep -q "lftp got no reply from the server" "${_log}"; then
  show_log; log_fail "the no-reply hint is missing"
fi
if grep -q "PERMANENT" "${_log}"; then
  show_log; log_fail "a silent server was classified as PERMANENT"
fi

log_pass "scenario 27 passed: a silent server gets the no-reply hint"
exit 0
