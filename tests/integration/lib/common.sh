#!/bin/sh
# tests/integration/lib/common.sh — shared helpers for integration tests.
#
# Sourced by every scenario (via `. "$(dirname "$0")/../lib/common.sh"`).
# Provides:
#   * Container runtime detection (docker / podman, skip on neither).
#   * FTP server lifecycle helpers (start_ftp_server / stop_ftp_server).
#   * Action invocation helpers (run_action, build_action_env_file).
#   * Assertion helpers (assert_present / assert_absent / assert_action_success).
#   * Fixture / credentials constants.
#
# Conventions enforced by this file:
#   * set -eu at the top of every sourced scenario.
#   * FTP_PASSWORD (and every other credential) go into the env-file,
#     NEVER on the argv / URL. lftp 4.9.3 ignores .netrc when the URL
#     carries user:password@host, so leaking credentials to the URL
#     bypasses the .netrc plumbing the action was designed around.
#   * Container cleanup: every scenario installs `trap stop_ftp_server EXIT`
#     before start_ftp_server, so the FTP container is removed on any
#     exit path (success, assertion failure, signal).
#   * Container name uniqueness: PID + a POSIX-sh random suffix (awk
#     srand), so parallel scenarios cannot collide.
#   * If something fails inside the scenario body, the scenario calls
#     `exit 1` directly. Do NOT use `cmd || { log_fail; }` patterns —
#     when `set -e` is active and `log_fail` returns non-zero, the
#     combination can mask the failure and produce a PASS report.
#   * When `run_action` fails, the captured container log is echoed to
#     stderr (NOT redirected to /dev/null) so the failure is debuggable.

# ------------------------------------------------------------------------------
# Runtime detection. Mirrors tests/smoke.sh: docker first, podman fallback,
# exit 0 (skip) if neither is found. Local-dev ergonomics: a developer
# without docker still sees a clean "skip" instead of a hard failure.
# ------------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
elif command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
else
  printf 'skip: no docker/podman found\n'
  exit 0
fi

# ------------------------------------------------------------------------------
# Image and fixture constants. IMAGE is the ftp-deployment-action image
# under test (CI builds ftp-deployment-action:ci-integration; the
# developer who runs `make integration` locally can set IMAGE=...).
# FTP_SERVER_IMAGE is the RFC-959-compliant FTP server used by every
# scenario: docker.io/fauria/vsftpd (picked in #117 variant C).
# ------------------------------------------------------------------------------
: "${IMAGE:=ftp-deployment-action:local}"
: "${FTP_SERVER_IMAGE:=docker.io/fauria/vsftpd:latest}"

# FTP control + PASV data port range.
#
# The standard FTP control port is 21 (privileged, < 1024). GitHub-
# hosted ubuntu-latest runs the docker daemon as root, so binding to
# 21 there is fine. Local rootless podman/docker setups, however,
# cannot bind to < 1024 without `ip_unprivileged_port_start=0` (which
# requires sudo on most distros). To keep `make integration` runnable
# by anyone who can install docker or podman, we map the HOST side of
# the FTP control connection to 2121 (unprivileged) and the PASV data
# range to 31100-31110. CI uses the same values; the test exercises
# the same FTP protocol surface (PORT 21 vs 2121 is just a number).
#
# The container INSIDE fauria/vsftpd still binds to vsftpd's default
# port 21; pasta/slirp4netns only needs the host-side port to be
# unprivileged.
FTP_CONTROL_PORT=2121
FTP_PASV_MIN_PORT=31100
FTP_PASV_MAX_PORT=31110

# Repository root (great-grandparent of tests/integration/lib/common.sh:
# lib -> integration -> tests -> <repo>). Scenarios use $ROOT to bind-
# mount the fixtures directory into the action container at a stable
# path (/data).
#
# The two-step resolution (first make SCRIPT_DIR absolute, then
# compute ROOT) is required because when this file is sourced via
# `. tests/integration/lib/common.sh` from a relative path (e.g.
# `sh tests/integration/scenarios/05-foo.sh`), the literal
# `cd "$(dirname "$0")/../../../"` would resolve relative to the
# caller's cwd, not relative to the file. The first cd fixes that.
#
# $0 inside a sourced file is the caller's $0, not the file's path.
# So this resolution only works when common.sh is SOURCED (not run
# directly) AND the caller has a meaningful $0. For robustness,
# accept $FTP_INTEGRATION_ROOT as an override (the orchestrator
# sets it before sourcing).
if [ -n "${FTP_INTEGRATION_ROOT:-}" ]; then
  ROOT="${FTP_INTEGRATION_ROOT}"
else
  # shellcheck disable=SC1007
  SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  # shellcheck disable=SC1007
  ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../../.." && pwd)
fi
FIXTURES_DIR="${ROOT}/tests/integration/fixtures/sample-public-html"

# ------------------------------------------------------------------------------
# Per-scenario unique container name. POSIX sh has no $RANDOM, so we
# fall back to awk's srand. PID ($$) alone is not enough because two
# parallel scenarios would race; the random suffix closes that gap.
# ------------------------------------------------------------------------------
rand_suffix() {
  awk 'BEGIN{srand();printf "%d",rand()*100000}'
}

unique_container_name() {
  _ucn_prefix=$1
  _ucn_pid=$$
  _ucn_rand=$(rand_suffix)
  printf '%s-%s-%s' "${_ucn_prefix}" "${_ucn_pid}" "${_ucn_rand}"
}

# ------------------------------------------------------------------------------
# Logging helpers. log_info prints human-readable progress; log_fail
# prints a labelled FAIL line and EXITS 1 (never returns). Scenarios
# must call log_fail on a hard failure and STOP executing (do not use
# log_fail inside an `if ... || { log_fail; }` construct with set -e).
# ------------------------------------------------------------------------------
log_info()  { printf '  [info] %s\n' "$*"; }
log_pass()  { printf '  ok: %s\n' "$*"; }
log_fail()  { printf '  FAIL: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------------------
# wait_for_port HOST PORT TIMEOUT_SECONDS
#   Poll HOST:PORT every 0.5s, up to TIMEOUT_SECONDS. Returns 0 on the
#   first successful TCP connect, 1 if the timeout expires. Used to
#   gate the action invocation on the FTP server actually accepting
#   connections (vsftpd needs ~1s to bootstrap after start).
# ------------------------------------------------------------------------------
wait_for_port() {
  _wfp_host=$1
  _wfp_port=$2
  _wfp_timeout=$3
  _wfp_deadline=$((_wfp_timeout * 2))
  _wfp_i=0
  while [ "${_wfp_i}" -lt "${_wfp_deadline}" ]; do
    if _wfp_busybox_ok=1; then :; fi
    # Use the runtime's built-in port-check; `docker run --rm -i
    # alpine` is reliable and the alpine image is already cached.
    if ${RUNTIME} run --rm --network host alpine:3.23.3 \
        nc -z "${_wfp_host}" "${_wfp_port}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
    _wfp_i=$((_wfp_i + 1))
  done
  return 1
}

# ------------------------------------------------------------------------------
# start_ftp_server FTP_USER FTP_PASS DATA_DIR
#   Boot fauria/vsftpd with the given virtual user / password, bind-
#   mounted DATA_DIR at /home/vsftpd (the directory where virtual
#   user homes live). Stores the container name in the global
#   FTP_CONTAINER_NAME for stop_ftp_server and for diagnostic dumps.
#
#   Ports: $FTP_CONTROL_PORT (host side) -> container 21 (control),
#   $FTP_PASV_MIN_PORT-$FTP_PASV_MAX_PORT (host side) -> same (PASV
#   data). PASV_ADDRESS=127.0.0.1 makes vsftpd advertise localhost
#   for PASV — required because the action runs with --network host
#   and so shares the host's loopback.
#
#   LOCAL_UMASK=022 is set so the FTP server creates dirs/files with
#   world-readable permissions, which lets us `ls` the bind-mounted
#   DATA_DIR from the host to verify uploads (see assert_present /
#   assert_absent). This is realistic for a public FTP server; the
#   fauria/vsftpd default of 077 is more conservative.
#
#   Exits 1 on any failure (port not free, container start fails,
#   port not ready within the timeout).
# ------------------------------------------------------------------------------
start_ftp_server() {
  _sfs_user=$1
  _sfs_pass=$2
  _sfs_data_dir=$3

  # Pre-create the FTP user home inside DATA_DIR so the bind mount
  # has the directory vsftpd will chown to ftp:ftp at startup. The
  # host must be able to write under DATA_DIR (chmod 0777 below).
  mkdir -p "${_sfs_data_dir}/${_sfs_user}"
  chmod -R 0777 "${_sfs_data_dir}"

  _sfs_name=$(unique_container_name "ftpsvr")

  # Start the server detached (-d). The container's stdout is captured
  # for debugging but we do not require it.
  if ! ${RUNTIME} run -d --rm \
      --name "${_sfs_name}" \
      -p "${FTP_CONTROL_PORT}:21" \
      -p "${FTP_PASV_MIN_PORT}-${FTP_PASV_MAX_PORT}:${FTP_PASV_MIN_PORT}-${FTP_PASV_MAX_PORT}" \
      -v "${_sfs_data_dir}:/home/vsftpd" \
      -e "FTP_USER=${_sfs_user}" \
      -e "FTP_PASS=${_sfs_pass}" \
      -e "PASV_ADDRESS=127.0.0.1" \
      -e "PASV_MIN_PORT=${FTP_PASV_MIN_PORT}" \
      -e "PASV_MAX_PORT=${FTP_PASV_MAX_PORT}" \
      -e "PASV_ENABLE=YES" \
      -e "REVERSE_LOOKUP_ENABLE=NO" \
      -e "LOG_STDOUT=true" \
      -e "LOCAL_UMASK=022" \
      -e "FILE_OPEN_MODE=0644" \
      "${FTP_SERVER_IMAGE}" >/dev/null; then
    log_fail "failed to start ftp server container"
  fi

  FTP_CONTAINER_NAME="${_sfs_name}"
  export FTP_CONTAINER_NAME
  FTP_DATA_DIR="${_sfs_data_dir}"
  export FTP_DATA_DIR

  # Wait for vsftpd to accept control connections on
  # $FTP_CONTROL_PORT. Typical startup time is ~1s; allow up to 20s
  # for slow runners.
  if ! wait_for_port 127.0.0.1 "${FTP_CONTROL_PORT}" 20; then
    ${RUNTIME} logs "${FTP_CONTAINER_NAME}" >&2 || true
    log_fail "ftp server did not accept connections on port ${FTP_CONTROL_PORT} within 20s"
  fi

  # vsftpd creates /home/vsftpd/${FTP_USER} and chowns it to ftp:ftp.
  # On rootless container runtimes that maps container uid 14 to a
  # host uid like 100013, the bind-mount directory ends up owned by
  # a uid the host test runner does NOT own, so `ls` from the host
  # fails with EACCES. chmod 0777 inside the container (which runs
  # as root) makes the dir world-readable+executable regardless of
  # the host-side uid mapping. Without this, scenarios can upload
  # but fail their assert_present / assert_absent checks.
  ${RUNTIME} exec "${FTP_CONTAINER_NAME}" \
      chmod 0777 "/home/vsftpd/${_sfs_user}" >/dev/null 2>&1 || true

  log_info "ftp server up (container=${FTP_CONTAINER_NAME}, user=${_sfs_user}, data=${_sfs_data_dir}, port=${FTP_CONTROL_PORT})"
}

# ------------------------------------------------------------------------------
# stop_ftp_server
#   Remove the FTP server container started by start_ftp_server. Safe
#   to call multiple times and on any exit path (designed to be used
#   as the value of `trap ... EXIT`). Idempotent.
# ------------------------------------------------------------------------------
stop_ftp_server() {
  if [ -n "${FTP_CONTAINER_NAME:-}" ]; then
    ${RUNTIME} rm -f "${FTP_CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------------------------
# lftp_run_script SCRIPT_FILE LOG_FILE [TIMEOUT_SECONDS]
#   Run an lftp script from a freshly-pulled alpine:3.23.3 container
#   that has `apk add lftp` installed (alpine base + apk layer).
#
#   lftp 4.9.3 in alpine refuses to combine `-c`/`-f` with a URL
#   argument ("-c, -f, -v, -h conflict with other `open' options and
#   arguments"), so the URL is part of the script itself (the
#   lftp_build_open_script helper prepends an `open` line). The script
#   file is bind-mounted into the container at /tmp/lftp-script.lftp
#   so the container can `cat` it; this avoids putting the password
#   on the docker command line.
#
#   Credentials: lftp 4.9.3 (the version the action image ships) does
#   NOT honor .netrc lookups for `ftp://host:port` URLs — see README
#   "Why variant B" for the rationale. So we pass credentials via the
#   script's `open -u user,pass ...` form. Credentials still never go
#   on the harness command line: they live in the scenario's
#   `FTP_USER`/`FTP_PASSWORD` shell variables and are interpolated
#   into the script string by lftp_build_open_script, which writes
#   the result to a temp file owned by the test runner with mode 0600.
#
#   Arguments:
#     SCRIPT_FILE     Path to a temp file holding the lftp script
#                     (open + commands + quit). Built by
#                     lftp_build_open_script.
#     LOG_FILE        Where combined stdout+stderr is captured. We do NOT
#                     redirect to /dev/null: a failure must surface the
#                     lftp log to stderr.
#     TIMEOUT_SECONDS Outer timeout (default 30).
#
#   Returns lftp's exit code (0 = success, anything else = failure).
# ------------------------------------------------------------------------------
lftp_run_script() {
  _lrs_script=$1
  _lrs_log=$2
  _lrs_timeout=${3:-30}

  set +e
  timeout "${_lrs_timeout}" ${RUNTIME} run --rm \
      --network host \
      --user root \
      -v "${_lrs_script}:/tmp/lftp-script.lftp:ro" \
      -v "${FIXTURES_DIR}:/data:ro" \
      alpine:3.23.3 \
      /bin/sh -c "apk add --no-cache lftp >/dev/null 2>&1 && lftp -c \"\$(cat /tmp/lftp-script.lftp)\"" \
      > "${_lrs_log}" 2>&1
  _lrs_rc=$?
  set -e
  return "${_lrs_rc}"
}

# ------------------------------------------------------------------------------
# lftp_build_open_script SCRIPT_FILE [lftp_command ...]
#   Write a minimal lftp script to SCRIPT_FILE that opens a connection
#   with the per-scenario FTP_USER / FTP_PASSWORD (read from the
#   environment), runs the caller-supplied commands, and quits. The
#   script is consumed by `lftp -c "$(cat ${SCRIPT_FILE})"` (see
#   lftp_run_script). Each caller-supplied command is echoed as a
#   separate line so shell metacharacters in the caller's command stay
#   literal (no eval).
# ------------------------------------------------------------------------------
lftp_build_open_script() {
  _lbs_out=$1
  shift

  : "${FTP_USER:?FTP_USER must be set before calling lftp_build_open_script}"
  : "${FTP_PASSWORD:?FTP_PASSWORD must be set before calling lftp_build_open_script}"
  : "${FTP_CONTROL_PORT:?FTP_CONTROL_PORT must be set before calling lftp_build_open_script}"

  {
    printf '%s\n' "set net:max-retries 1"
    printf '%s\n' "set net:timeout 10s"
    printf '%s\n' "set dns:max-retries 1"
    printf '%s\n' "set dns:fatal-timeout 10s"
    printf '%s\n' "set ftp:ssl-allow false"
    printf '%s\n' "set ftp:passive-mode true"
    # `set` directives are global, but writing them BEFORE `open`
    # makes them obviously orthogonal to the connection's auth
    # negotiation. lftp does not care about the order, but the
    # reader does — see the action's lib.sh build_ftp_settings,
    # which writes the same shape.
    printf '%s\n' "open -u ${FTP_USER},${FTP_PASSWORD} ftp://127.0.0.1:${FTP_CONTROL_PORT}"
    for _lbs_cmd in "$@"; do
      printf '%s\n' "${_lbs_cmd}"
    done
    printf '%s\n' "quit"
  } > "${_lbs_out}"
}

# ------------------------------------------------------------------------------
# build_action_env_file ENV_FILE ACTION_IMAGE LOCAL_DIR REMOTE_DIR [extra_kv ...]
#   Write an env-file for the action container. ALL action inputs go
#   through the env-file (do not mix --env-file and -e; doing so has
#   caused INPUT_* values to be silently swallowed in previous
#   iterations of this harness).
#
#   Writes a stable set of INPUT_* values that every scenario needs:
#     INPUT_SERVER     ftp://127.0.0.1
#     INPUT_USER       $FTP_USER (set by start_ftp_server / scenario)
#     INPUT_PASSWORD   $FTP_PASSWORD (NEVER on argv / URL)
#     INPUT_LOCAL_DIR  $3
#     INPUT_REMOTE_DIR $4
#     INPUT_MAX_RETRIES=1     (we want fast failure in tests)
#     INPUT_NET_TIMEOUT=10s   (cap on a single FTP operation)
#     INPUT_DNS_FATAL_TIMEOUT=10s
#     INPUT_FTP_SSL_ALLOW=false (plain FTP only; FTPS scenarios 03/04 are stubs)
#   plus any caller-supplied KEY=value pairs as-is.
#
#   Returns 0 on success; the caller is responsible for `rm -f` of
#   the env-file. The file path is echoed on stdout so the caller can
#   capture it (avoids shellcheck SC2034 on a temp path).
#
#   The output file is chmod 0600'd before this function returns so
#   INPUT_PASSWORD is not world-readable between the write and the
#   podman/docker invocation (closes #133; the previous mktemp-derived
#   mode was not portable — alpine busybox mktemp -t produces 0644).
#
#   NOTE: as of the variant B fallback (see README "Why variant B"),
#   this helper is no longer the primary driver of scenarios 01/02/05.
#   It is kept for two reasons: (a) the harness asserts the action
#   IMAGE can be invoked with the documented env-file interface
#   without crashing on input parsing (Test 5 in run-integration-tests.sh
#   does a one-shot invocation), and (b) future FTPS scenarios
#   (deferred to #120) will exercise the action directly.
# ------------------------------------------------------------------------------
build_action_env_file() {
  _baef_out=$1
  _baef_image=$2
  _baef_local=$3
  _baef_remote=$4
  shift 4

  : "${FTP_USER:?FTP_USER must be set before calling build_action_env_file}"
  : "${FTP_PASSWORD:?FTP_PASSWORD must be set before calling build_action_env_file}"
  : "${FTP_CONTROL_PORT:?FTP_CONTROL_PORT must be set before calling build_action_env_file}"

  {
    printf '%s\n' "INPUT_SERVER=ftp://127.0.0.1:${FTP_CONTROL_PORT}"
    printf '%s\n' "INPUT_USER=${FTP_USER}"
    printf '%s\n' "INPUT_PASSWORD=${FTP_PASSWORD}"
    printf '%s\n' "INPUT_LOCAL_DIR=${_baef_local}"
    printf '%s\n' "INPUT_REMOTE_DIR=${_baef_remote}"
    printf '%s\n' "INPUT_MAX_RETRIES=1"
    printf '%s\n' "INPUT_NET_TIMEOUT=10s"
    printf '%s\n' "INPUT_DNS_FATAL_TIMEOUT=10s"
    printf '%s\n' "INPUT_FTP_SSL_ALLOW=false"
    for _baef_kv in "$@"; do
      printf '%s\n' "${_baef_kv}"
    done
  } > "${_baef_out}"

  # The env-file carries INPUT_PASSWORD in plain text (the same secret
  # the .netrc file inside the action carries). Lock it down to the
  # runner's umask-derived permissions: without this chmod, the file
  # mode would depend on the host mktemp flavour (0600 on GNU coreutils,
  # 0644 on alpine busybox) and INPUT_PASSWORD would be readable to any
  # other process on the host between the write and the runtime
  # invocation. Closes #133.
  chmod 0600 "${_baef_out}"
}

# ------------------------------------------------------------------------------
# run_action ACTION_IMAGE ENV_FILE TIMEOUT_SECONDS ACTION_LOG
#   Invoke the ftp-deployment-action image in a one-shot container
#   that:
#     * shares the host network namespace (--network host) so it can
#       reach vsftpd at 127.0.0.1 AND connect to the PASV data ports
#       (21100-21110) on the host loopback;
#     * bind-mounts the fixtures directory at /data:ro so
#       INPUT_LOCAL_DIR=/data resolves to a stable, predictable path
#       inside the container regardless of which directory the
#       harness was invoked from;
#     * reads all INPUT_* values from the env-file built by
#       build_action_env_file (no -e flags mixed in).
#
#   Output (combined stdout+stderr from the action container) is
#   captured to ACTION_LOG. We do NOT redirect to /dev/null: a failure
#   must surface the lftp log to stderr so the failure is debuggable
#   from the runner log alone (no need to download an artifact).
#
#   Returns the action container's exit code (0 = success, anything
#   else = failure). The caller decides what to do with the code.
# ------------------------------------------------------------------------------
run_action() {
  _ra_image=$1
  _ra_env=$2
  _ra_timeout=$3
  _ra_log=$4

  set +e
  timeout "${_ra_timeout}" ${RUNTIME} run --rm \
      --network host \
      -v "${FIXTURES_DIR}:/data:ro" \
      --env-file "${_ra_env}" \
      "${_ra_image}" > "${_ra_log}" 2>&1
  _ra_rc=$?
  set -e
  return "${_ra_rc}"
}

# ------------------------------------------------------------------------------
# assert_action_success ACTION_LOG RC
#   Verify the action exited 0 AND emitted the success banner. A
#   non-zero exit OR a missing banner is treated as a hard failure;
#   the captured log is echoed to stderr before the script exits 1.
# ------------------------------------------------------------------------------
assert_action_success() {
  _aas_log=$1
  _aas_rc=$2
  if [ "${_aas_rc}" -ne 0 ]; then
    printf '%s\n' '---- captured action log (exit '"${_aas_rc}"') ----' >&2
    cat "${_aas_log}" >&2
    printf '%s\n' '---- end of action log ----' >&2
    log_fail "action exited with code ${_aas_rc}"
  fi
  if ! grep -q 'FTP UPLOADED FINISHED' "${_aas_log}"; then
    printf '%s\n' '---- captured action log ----' >&2
    cat "${_aas_log}" >&2
    printf '%s\n' '---- end of action log ----' >&2
    log_fail "action exited 0 but did not print the FTP UPLOADED FINISHED banner"
  fi
}

# ------------------------------------------------------------------------------
# assert_present DIR NAME
# assert_absent  DIR NAME
#   Assert the existence (or absence) of NAME inside DIR. NAME is a
#   single path segment (filename or single subdir); use a sequence of
#   calls for paths like site/index.html. Hard failure on mismatch.
# ------------------------------------------------------------------------------
assert_present() {
  _ap_dir=$1
  _ap_name=$2
  if [ ! -e "${_ap_dir}/${_ap_name}" ]; then
    printf '%s\n' '---- listing of '"${_ap_dir}"' ----' >&2
    ls -la "${_ap_dir}" >&2 || true
    printf '%s\n' '---- end listing ----' >&2
    log_fail "expected ${_ap_dir}/${_ap_name} to exist"
  fi
}

assert_absent() {
  _aa_dir=$1
  _aa_name=$2
  if [ -e "${_aa_dir}/${_aa_name}" ]; then
    printf '%s\n' '---- listing of '"${_aa_dir}"' ----' >&2
    ls -la "${_aa_dir}" >&2 || true
    printf '%s\n' '---- end listing ----' >&2
    log_fail "expected ${_aa_dir}/${_aa_name} NOT to exist"
  fi
}

# ------------------------------------------------------------------------------
# scenario_setup SCENARIO_NAME
#   Print a banner so the runner output is grep-able per scenario,
#   allocate the FTP user / password / data dir for this scenario, and
#   install the EXIT trap that guarantees container cleanup.
#
#   FTP user/password are unique per scenario (PID + random) so two
#   parallel runs cannot step on each other on the same FTP server.
# ------------------------------------------------------------------------------
scenario_setup() {
  _ss_name=$1
  printf '\n=== Scenario: %s ===\n' "${_ss_name}"

  # Per-scenario credentials. mktemp gives us a unique data dir on
  # the host; chmod 0777 lets vsftpd (running as root in the
  # container, mapped to host user under rootless) write through it.
  FTP_USER="u$$_$(rand_suffix)"
  FTP_PASSWORD="p$$_$(rand_suffix)"
  FTP_DATA_DIR=$(mktemp -d -t ftpint.XXXXXX) || log_fail "mktemp failed"
  chmod 0777 "${FTP_DATA_DIR}"
  export FTP_USER FTP_PASSWORD FTP_DATA_DIR

  trap stop_ftp_server EXIT
}
