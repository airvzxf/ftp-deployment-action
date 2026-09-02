#!/bin/sh -eu
# entrypoint.sh — orchestrator for ftp-deployment-action.
#
# This file is the entrypoint of the Docker image. It does the
# following, in order:
#
#   1. Source lib.sh (pure functions and IO helpers).
#   2. Apply effective defaults to every INPUT_* (B-07 / smoke-test
#      safety: works with `set -u` and with direct `docker run`).
#   3. Emit a deprecation / EOL warning based on $GITHUB_ACTION_REF
#      and the baked-in /app/VERSION.
#   4. Mask sensitive inputs in the runner log (::add-mask::).
#   5. Print the "Inputs received" group.
#   6. Validate integer and free-form inputs (exit 2 on failure).
#   7. Build the FTP_SETTINGS and MIRROR_COMMAND strings.
#   8. Normalize local_dir / remote_dir (trailing slash + path
#      traversal guard).
#   9. Print the "Resolved configuration" group.
#  10. Write credentials to ~/.netrc with mode 0600 and install the
#      EXIT trap that removes the file.
#  11. Retry loop with exponential backoff + jitter, capturing
#      lftp's combined stdout+stderr to a timestamped log file.
#  12. Expose the log file path via $GITHUB_OUTPUT.
#  13. Print the success or failure banner.
#
# The split between this file and lib.sh is the only architectural
# change vs. the pre-v2.5.0 single-file layout; the behaviour is
# preserved bit-by-bit.
#
# pipefail is busybox ash (the shell that actually runs in alpine);
# it fails the script on the first command in a pipeline that
# returns non-zero, instead of only the last one. POSIX sh does not
# define it (shellcheck SC3040), but the runtime guarantees it is
# available.
# shellcheck disable=SC3040
set -o pipefail

# shellcheck source=lib.sh
. /app/lib.sh

# ------------------------------------------------------------------------------
# B-07 / smoke-test: normalize all input vars to their effective
# defaults. In a real GitHub Actions run these are always populated
# by the action.yml default, but entrypoint.sh can also be run
# outside that mechanism (tests, manual invocation, the release
# smoke test against a freshly-built image), so we apply the same
# defaults here. This block is FIRST in the user-input handling so
# that every later reference is safe under `set -u`.
#
# Use POSIX parameter expansion (`:="${VAR:=default}"`) instead of
# `if [ -z "${VAR}" ] then VAR=default; fi` so this block is safe
# under `set -u` even when the var is unset.
# ------------------------------------------------------------------------------
: "${INPUT_SERVER:=}"
: "${INPUT_USER:=}"
: "${INPUT_PASSWORD:=}"
: "${INPUT_LOCAL_DIR:=}"
: "${INPUT_REMOTE_DIR:=}"
: "${INPUT_DELETE:=}"
: "${INPUT_NO_SYMLINKS:=}"
: "${INPUT_MAX_RETRIES:=10}"
: "${INPUT_MIRROR_VERBOSE:=1}"
: "${INPUT_FTP_SSL_ALLOW:=}"
: "${INPUT_SSL_VERIFY_CERTIFICATE:=}"
: "${INPUT_SSL_CHECK_HOSTNAME:=}"
: "${INPUT_FTP_PASSIVE_MODE:=}"
: "${INPUT_FTP_USE_FEAT:=}"
: "${INPUT_FTP_NOP_INTERVAL:=2}"
: "${INPUT_NET_MAX_RETRIES:=1}"
: "${INPUT_NET_PERSIST_RETRIES:=5}"
: "${INPUT_NET_TIMEOUT:=}"
: "${INPUT_DNS_MAX_RETRIES:=8}"
: "${INPUT_DNS_FATAL_TIMEOUT:=}"
: "${INPUT_LFTP_SETTINGS:=}"
: "${INPUT_EXCLUDE:=}"
: "${INPUT_EXCLUDE_DELETE:=}"
: "${INPUT_DEBUG:=}"
: "${INPUT_FAIL_ON_DEPRECATED:=}"
: "${INPUT_DRY_RUN:=}"
: "${INPUT_UPLOAD_LOG_ON_FAILURE:=}"
: "${INPUT_CONCURRENCY_LOCK:=false}"
: "${INPUT_CONCURRENCY_LOCK_PATH:=.lftp-deployment.lock}"
: "${INPUT_CONCURRENCY_LOCK_TIMEOUT:=300}"
: "${INPUT_CONCURRENCY_LOCK_POLL_INTERVAL:=5}"

# ------------------------------------------------------------------------------
# Emit deprecation / EOL warning based on the ref the user pinned
# this action to. Runs *before* any other echo so the warning is the
# first thing the user sees in the log.
# ------------------------------------------------------------------------------
emit_deprecation_warning \
  "${GITHUB_ACTION_REF:-}" \
  "$(cat /app/VERSION 2>/dev/null || echo "unknown")" \
  "${INPUT_FAIL_ON_DEPRECATED}"

# ------------------------------------------------------------------------------
# Defence-in-depth: ask the runner to mask sensitive values in the
# log even if they ever leak outside the .netrc plumbing.
# ------------------------------------------------------------------------------
add_masks

# ------------------------------------------------------------------------------
# B-10: By default, only show which inputs were received (no values).
# Set INPUT_DEBUG=true to print resolved values for troubleshooting.
# ------------------------------------------------------------------------------
print_inputs_dump "${INPUT_DEBUG}"

# ------------------------------------------------------------------------------
# B-07: validate the integer inputs and the free-form lftp_settings.
# The defaulting itself is performed by the parameter-expansion
# block above; here we only enforce shape.
# ------------------------------------------------------------------------------
validate_int "max_retries"         "${INPUT_MAX_RETRIES}"
validate_int "mirror_verbose"      "${INPUT_MIRROR_VERBOSE}"
validate_int "ftp_nop_interval"    "${INPUT_FTP_NOP_INTERVAL}"
validate_int "net_max_retries"     "${INPUT_NET_MAX_RETRIES}"
validate_int "net_persist_retries" "${INPUT_NET_PERSIST_RETRIES}"
validate_int "dns_max_retries"     "${INPUT_DNS_MAX_RETRIES}"
# B-16: light sanitization of the free-form lftp_settings input.
validate_lftp_settings "${INPUT_LFTP_SETTINGS}"
# Pattern-exclusion inputs go into the lftp `-e` script the same
# way `lftp_settings` does, so they share the same sanitization.
validate_lftp_settings "${INPUT_EXCLUDE}"
validate_lftp_settings "${INPUT_EXCLUDE_DELETE}"
# Concurrency lock: validate path and integers only when enabled,
# to keep the validation surface tight for the common case
# (concurrency_lock=false). validate_int already rejects negatives
# and non-numeric values; the only extra check we need is
# poll_interval > 0 (0 would be a division-by-zero in the count
# computation).
if [ "${INPUT_CONCURRENCY_LOCK}" = "true" ]; then
  validate_path "concurrency_lock_path" "${INPUT_CONCURRENCY_LOCK_PATH}"
  validate_int "concurrency_lock_timeout" "${INPUT_CONCURRENCY_LOCK_TIMEOUT}"
  validate_int "concurrency_lock_poll_interval" "${INPUT_CONCURRENCY_LOCK_POLL_INTERVAL}"
  if [ "${INPUT_CONCURRENCY_LOCK_POLL_INTERVAL}" = "0" ]; then
    printf 'ERROR: concurrency_lock_poll_interval must be > 0 (got: %s)\n' \
      "${INPUT_CONCURRENCY_LOCK_POLL_INTERVAL}" >&2
    exit 2
  fi
fi

# ------------------------------------------------------------------------------
# Build the lftp command fragments.
#
# The order matters: normalize_dir must run before validate_path so
# the trailing-slash normalization is reflected in the validation
# message, and validate_path must run in the main shell context
# (not inside `$(...)`) so its `exit 2` actually aborts the script.
# See the docstring on normalize_dir for the busybox ash quirk
# that drives this ordering.
# ------------------------------------------------------------------------------
FTP_SETTINGS=$(build_ftp_settings)
INPUT_LOCAL_DIR=$(normalize_dir "${INPUT_LOCAL_DIR}")
INPUT_REMOTE_DIR=$(normalize_dir "${INPUT_REMOTE_DIR}")
# B-04: path traversal and shell-metacharacter guard. Run AFTER
# normalize_dir, in the main shell context, so a failure aborts.
validate_path "local_dir"  "${INPUT_LOCAL_DIR}"
validate_path "remote_dir" "${INPUT_REMOTE_DIR}"
MIRROR_COMMAND=$(build_mirror_command)
# v2.8.0: server-side concurrency lock fragments. Both functions
# are no-ops as of v2.9.0 — the lock work moved out of the lftp
# -e fragment to shell-driven helpers (acquire_lock_with_recovery
# and release_lock_safely) so the stale-lock auto-recovery can
# LIST/parse/DELE/RMD without fighting lftp's flow-control. The
# assignments are kept for backward compat with anyone sourcing
# lib.sh; their values are always empty.
LOCK_ACQUIRE=$(build_lock_acquire_script)
LOCK_RELEASE=$(build_lock_release_script)

# ------------------------------------------------------------------------------
# Display the resolved configuration.
# ------------------------------------------------------------------------------
print_resolved_config

# ------------------------------------------------------------------------------
# B-03: write credentials to a private .netrc and let lftp read it.
#
# Passing the password on the lftp command line leaves it in
# /proc/<pid>/cmdline and in the GH Actions runner log. Writing it
# to ~/.netrc with mode 0600 is the POSIX-blessed way to feed lftp a
# password. The file is removed via an EXIT trap so it does not
# survive a `set -e` abort, a SIGINT, or a normal exit.
#
# v2.11.0: pin NETRC and HOME to the path the Dockerfile guarantees to be
# writable for the `lftp` user. Self-hosted runners that forward
# HOME=/github/home (or any other host path) into the container would
# otherwise make the fallback `: "${HOME:=/home/lftp}"` a no-op, and the
# `lftp` user could not create /github/home/.netrc. This closes #111.
# See tests/integration/scenarios/07-self-hosted-home.sh for the
# regression test that pinned this fix.
# ------------------------------------------------------------------------------
NETRC="/home/lftp/.netrc"
export HOME="/home/lftp"
NETRC_HOST=$(extract_netrc_host "${INPUT_SERVER}")
write_netrc "${NETRC}" "${NETRC_HOST}" "${INPUT_USER}" "${INPUT_PASSWORD}"

# v2.8.0: extend the EXIT trap installed by write_netrc above to
# also release the server-side concurrency lock (best-effort).
# Order matters: the lock release must run BEFORE the .netrc is
# removed, because the release invokes lftp which needs the .netrc
# to authenticate. run_lftp_lock_release is a no-op when the lock
# is disabled, so installing the extended trap unconditionally is
# safe and keeps the no-lock code path bit-for-bit identical to
# v2.7.0.
#
# v2.9.0: pass the sentinel name (if any was acquired during this
# run) so the trap can also DELE the sentinel file. We use the
# empty string as the default — run_lftp_lock_release falls back
# to $ACQUIRED_LOCK_SENTINEL, which is set by acquire_lock_with_recovery.
trap 'run_lftp_lock_release "${INPUT_SERVER}" "${NETRC}" "${INPUT_CONCURRENCY_LOCK_PATH}" "${ACQUIRED_LOCK_SENTINEL:-}"; rm -f "${NETRC}"' EXIT

# ------------------------------------------------------------------------------
# v2.9.0: acquire the server-side concurrency lock BEFORE the
# mirror loop. The lock is held for the entire deployment
# (including the retry sequence) and released by the EXIT trap
# installed above. If the lock cannot be acquired within
# INPUT_CONCURRENCY_LOCK_TIMEOUT seconds (and the existing holder
# is not detected as stale), print a clear error and exit 1 so
# the workflow fails fast.
#
# Stale-lock auto-recovery (v2.9.0): if the existing holder's
# sentinel is older than INPUT_CONCURRENCY_LOCK_TIMEOUT seconds,
# acquire_lock_with_recovery takes over by DELEing the stale
# sentinel and RMDing the lock dir, then retrying MKD. This
# closes the residual risk from v2.8.0 documented in the README
# ("if the holder dies before RMD, subsequent runs will wait
# until `concurrency_lock_timeout` and then fail with exit 1").
# ------------------------------------------------------------------------------
if [ "${INPUT_CONCURRENCY_LOCK}" = "true" ]; then
  printf '::group::Concurrency lock acquire\n'
  if ! acquire_lock_with_recovery \
       "${INPUT_SERVER}" \
       "${INPUT_CONCURRENCY_LOCK_PATH}" \
       "${INPUT_CONCURRENCY_LOCK_TIMEOUT}" \
       "${INPUT_CONCURRENCY_LOCK_POLL_INTERVAL}"; then
    printf '::endgroup::\n'
    printf 'ERROR: could not acquire concurrency lock at %s within %s seconds\n' \
      "${INPUT_CONCURRENCY_LOCK_PATH}" "${INPUT_CONCURRENCY_LOCK_TIMEOUT}" >&2
    printf 'ERROR: another deployment is currently in progress, or the previous holder crashed mid-mirror.\n' >&2
    printf 'ERROR: see README "Concurrency / deployment lock" for manual recovery instructions.\n' >&2
    exit 1
  fi
  printf 'Acquired concurrency lock (sentinel=%s).\n' "${ACQUIRED_LOCK_SENTINEL}"
  printf '::endgroup::\n'
fi

# ------------------------------------------------------------------------------
# Execute the LFTP actions.
#
# B-09: Wrap with a hard global timeout (5h) so a hung lftp cannot
# run past the GH Actions job limit. busybox `timeout` supports -k
# for SIGKILL after a grace period.
#
# B-05: Capture lftp's exit code explicitly. With `set -e` and `&&`,
# a non-zero lftp exit was causing the script to abort via the
# `set -e` short-circuit instead of falling into the "ERROR" banner.
#
# B-08: Exponential backoff with jitter, capped at 30s. The
# proposal's `2 ** (COUNTER - 1)` example is invalid in POSIX sh
# (no `**` operator); we use a small lookup table instead.
# ------------------------------------------------------------------------------
COUNTER=1
SUCCESS=""
PERMANENT_ERROR=""
LFTP_RC=""

# B-09: hard cap on the total wall-clock time of one lftp invocation.
LFTP_TIMEOUT="5h"
LFTP_KILL_AFTER="30s"

# B-04: capture every lftp invocation's combined stdout+stderr to a
# timestamped log file under ~/.lftp-logs/. The path is exported via
# the GITHUB_OUTPUT file so a downstream step can upload it as a
# workflow artifact (or just download it from the runner). The
# directory is created here rather than at the top of the script
# so test runs that exit before the loop (validate_int / deprecated
# ref) do not leave an empty .lftp-logs directory behind.
mkdir -p "/home/lftp/.lftp-logs"
LOG_FILE="/home/lftp/.lftp-logs/run-$(date -u +%Y%m%dT%H%M%SZ).log"

printf '::group::Upload\n'
while true; do
  echo ""
  echo "Try #${COUNTER}"
  echo "-------"

  set +e
  run_lftp_once \
    "${INPUT_SERVER}" \
    "${FTP_SETTINGS}" \
    "${MIRROR_COMMAND}" \
    "${INPUT_LOCAL_DIR}" \
    "${INPUT_REMOTE_DIR}" \
    "${LOG_FILE}" \
    "${LFTP_TIMEOUT}" \
    "${LFTP_KILL_AFTER}" \
    "${LOCK_ACQUIRE}" \
    "${LOCK_RELEASE}"
  LFTP_RC=$?
  set -e

  if [ "${LFTP_RC}" -eq 0 ]; then
    SUCCESS="true"
    break
  fi

  echo "  lftp exited with code ${LFTP_RC}"

  # A6: classify the failure. Some errors are permanent (no point in
  # retrying with the same credentials and same path): bad login,
  # permission denied, missing file. Detect them in the captured
  # log and abort the retry loop early.
  if classify_permanent_error "${LOG_FILE}"; then
    PERMANENT_ERROR="true"
    echo "  Detected permanent error in lftp output; aborting retries."
    break
  fi

  COUNTER=$((COUNTER + 1))
  # B-02: `max_retries=0` is the documented sentinel for "retry forever"
  # (the only exit paths are then: lftp success, the global 5h timeout,
  # or `fail_on_deprecated` in PR-B). Anything else just compares the
  # counter as before.
  # B-06: quote to satisfy shellcheck SC2086 and `set -u` semantics.
  if [ "${INPUT_MAX_RETRIES}" != "0" ] && \
     [ "${COUNTER}" -gt "${INPUT_MAX_RETRIES}" ]; then
    break
  fi

  # B-08: exponential backoff with jitter, capped at 30s.
  SLEEP_S=$(compute_backoff_seconds "${COUNTER}")
  echo "  Backing off ${SLEEP_S}s before retry..."
  sleep "${SLEEP_S}"
done
printf '::endgroup::\n'

# B-04: expose the log file path as an action output so a follow-up
# step can attach it as a workflow artifact. Only do this if the
# runner set GITHUB_OUTPUT (i.e. the user invoked us with `id:` in
# their step and declared `log_file` in the step's outputs).
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'log_file=%s\n' "${LOG_FILE}" >> "${GITHUB_OUTPUT}"
fi

# ------------------------------------------------------------------------------
# Display the status of the LFTP actions.
# ------------------------------------------------------------------------------
if [ -z "${SUCCESS}" ]; then
  # v2.7.0: try to upload the captured lftp log to the current
  # workflow run as a workflow artifact. The function is fail-soft:
  # if GITHUB_TOKEN is missing or the upload request fails, it logs
  # a warning / notice and returns 0, so the failure banner below
  # still runs.
  upload_log_artifact "${LOG_FILE}"
  print_failure_banner "${LFTP_RC}" "${PERMANENT_ERROR}" \
    "${LOG_FILE}" "${LFTP_TIMEOUT}" "${LFTP_KILL_AFTER}"
fi

print_success_banner "${INPUT_DRY_RUN}"
