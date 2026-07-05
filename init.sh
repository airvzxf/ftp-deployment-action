#!/bin/sh -eu
# pipefail is busybox ash (the shell that actually runs in alpine); it
# fails the script on the first command in a pipeline that returns
# non-zero, instead of only the last one. POSIX sh does not define it
# (shellcheck SC3040), but the runtime guarantees it is available.
# shellcheck disable=SC3040
set -o pipefail

# ------------------------------------------------------------------------------
# Helpers.
# ------------------------------------------------------------------------------

# validate_int NAME VALUE
#   Exit 2 with a clear error if VALUE is not a non-negative integer.
validate_int() {
  _vi_name=$1
  _vi_value=$2
  printf '%s' "${_vi_value}" | grep -qE '^[0-9]+$' || {
    printf 'ERROR: %s must be a non-negative integer (got: %s)\n' \
      "${_vi_name}" "${_vi_value}" >&2
    exit 2
  }
}

# validate_path NAME VALUE
#   Exit 2 if VALUE looks unsafe for a local or remote path passed to
#   lftp. The function is a *deny-list*: it rejects a small set of
#   known-dangerous patterns (path-traversal components, leading dash
#   which lftp would misread as an option, control characters, shell
#   metacharacters). Anything else is allowed; if you need a stricter
#   policy, build a `validate_path_strict` that allow-lists only
#   `[A-Za-z0-9._/-]`.
validate_path() {
  _vp_name=$1
  _vp_value=$2
  if printf '%s' "${_vp_value}" | grep -qE '(^|/)\.\.($|/)'; then
    printf 'ERROR: %s contains ".." path traversal: %s\n' \
      "${_vp_name}" "${_vp_value}" >&2
    exit 2
  fi
  case "${_vp_value}" in
    -*)
      printf 'ERROR: %s starts with a dash (would be misread as lftp option): %s\n' \
        "${_vp_name}" "${_vp_value}" >&2
      exit 2
      ;;
  esac
  if printf '%s' "${_vp_value}" | grep -qE '[[:cntrl:]]'; then
    printf 'ERROR: %s contains control characters: %s\n' \
      "${_vp_name}" "${_vp_value}" >&2
    exit 2
  fi
  if printf '%s' "${_vp_value}" | grep -qE '[;|&`]'; then
    printf 'ERROR: %s contains forbidden shell metacharacter: %s\n' \
      "${_vp_name}" "${_vp_value}" >&2
    exit 2
  fi
  if printf '%s' "${_vp_value}" | grep -qF '$'; then
    printf 'ERROR: %s contains dollar (shell substitution): %s\n' \
      "${_vp_name}" "${_vp_value}" >&2
    exit 2
  fi
}

# validate_lftp_settings VALUE
#   Light sanitization of the free-form lftp_settings input (B-16). The
#   documented use case is 1-3 'set' directives chained with ';', so
#   we allow up to 3 ';' characters but reject control characters,
#   backtick, dollar, and the '!' character (lftp's own shell escape,
#   which would otherwise let an attacker run arbitrary commands
#   inside the container even within the 3-';' limit).
validate_lftp_settings() {
  _vls_value=$1
  if printf '%s' "${_vls_value}" | grep -qE '[[:cntrl:]]'; then
    printf 'ERROR: lftp_settings contains control characters\n' >&2
    exit 2
  fi
  if printf '%s' "${_vls_value}" | grep -q '`'; then
    printf 'ERROR: lftp_settings contains backtick (shell substitution)\n' >&2
    exit 2
  fi
  if printf '%s' "${_vls_value}" | grep -qF '$'; then
    printf 'ERROR: lftp_settings contains dollar (shell substitution)\n' >&2
    exit 2
  fi
  if printf '%s' "${_vls_value}" | grep -qF '!'; then
    printf 'ERROR: lftp_settings contains "!" (lftp shell escape)\n' >&2
    exit 2
  fi
  _vls_n=$(printf '%s' "${_vls_value}" | tr -cd ';' | wc -c | tr -d ' ')
  if [ "${_vls_n}" -gt 3 ]; then
    printf 'ERROR: lftp_settings has %s ";" characters (max 3)\n' "${_vls_n}" >&2
    exit 2
  fi
}

# ------------------------------------------------------------------------------
# _deprecated_check
#
# Emit a deprecation / EOL / major-out-of-date notice based on the ref the
# user pinned this action to. Driven by $GITHUB_ACTION_REF (set by the
# runner) and the /app/VERSION file baked at build time by release.yml.
#
# Strategy: hardcoded EOL list. No network call, no latency, no rate
# limit. Update on each major-line cut.
#
#   * @latest                  -> ::warning:: "moving target" (B-18)
#   * @master / @main / empty  -> ::warning:: "development branch"
#   * v1.0-alpha.* | v1.1 |
#     v1.2.0 | v1.3.*          -> ::warning:: "end-of-life" (SECURITY.md)
#   * v1.4* - v1.9*            -> ::notice::  "v2 is available"
#   * anything else            -> silent (current line)
#
# If INPUT_FAIL_ON_DEPRECATED=true AND the ref is in the EOL list, exit 1
# via ::error::. Other warnings (latest, master) are advisory only.
# ------------------------------------------------------------------------------
_deprecated_check() {
  _ref="${GITHUB_ACTION_REF:-}"
  _img_ver=$(cat /app/VERSION 2>/dev/null || echo "unknown")
  _eol_pattern='v1\.0-alpha\.[12]|v1\.1|v1\.2\.0|v1\.3\.[0-9]+'

  case "${_ref}" in
    latest)
      printf '::warning file=action.yml,title=Deprecated usage::' >&2
      printf 'You are using @latest, a moving target. ' >&2
      printf 'Pin to @v2 or @<sha>. (image version: %s)\n' "${_img_ver}" >&2
      ;;
    "")
      # No GITHUB_ACTION_REF means the workflow invoked the action from
      # the same repo (`uses: ./` or local checkout). Not a user-facing
      # warning, but still useful to know the image version.
      ;;
    master|main)
      printf '::warning file=action.yml,title=Branch usage::' >&2
      printf 'You are using @%s, a development branch. ' "${_ref}" >&2
      printf 'Use a tagged release (current image: %s).\n' "${_img_ver}" >&2
      ;;
    v1.0-alpha.1|v1.0-alpha.2|v1.1|v1.2.0|v1.3.0|v1.3.1|v1.3.2|v1.3.3)
      printf '::warning file=action.yml,title=End-of-life version::' >&2
      printf 'Version %s is end-of-life (SECURITY.md: only v1.4+ is supported). ' "${_ref}" >&2
      printf 'Upgrade to v2: https://github.com/airvzxf/ftp-deployment-action/releases\n' >&2
      if [ "${INPUT_FAIL_ON_DEPRECATED:-false}" = "true" ]; then
        printf '::error file=action.yml::fail_on_deprecated is true and ref %s is EOL.\n' "${_ref}" >&2
        exit 1
      fi
      ;;
    v1.4*|v1.5*|v1.6*|v1.7*|v1.8*|v1.9*)
      printf '::notice file=action.yml,title=New major available::' >&2
      printf 'You are on %s. v2 is available (BREAKING: ssl_verify_certificate default is now true). ' "${_ref}" >&2
      printf 'See CHANGELOG.md. (image version: %s)\n' "${_img_ver}" >&2
      ;;
    *)
      # Current line (v2.x, or anything not yet in the EOL list).
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Emit a deprecation / EOL warning based on the ref the user pinned this
# action to. Runs *before* any other echo so the warning is the first
# thing the user sees in the log.
# ------------------------------------------------------------------------------
_deprecated_check

# ------------------------------------------------------------------------------
# Defence-in-depth: ask the runner to mask sensitive values in the log
# even if they ever leak outside the .netrc plumbing. GitHub already
# auto-masks inputs named *password* / *token* / *secret*, but `user`
# and `server` are not in that list. If the user opts in to debug mode
# (INPUT_DEBUG=true) the server, user and password values are echoed
# below; this mask prevents them from showing up in any other
# downstream log line.
# ------------------------------------------------------------------------------
if [ -n "${INPUT_PASSWORD:-}" ]; then
  printf '::add-mask::%s\n' "${INPUT_PASSWORD}"
fi
if [ -n "${INPUT_USER:-}" ]; then
  printf '::add-mask::%s\n' "${INPUT_USER}"
fi
if [ -n "${INPUT_SERVER:-}" ]; then
  printf '::add-mask::%s\n' "${INPUT_SERVER}"
fi

# ------------------------------------------------------------------------------
# Display environment variables.
#
# B-10: By default, only show which inputs were received (no values). Set
# INPUT_DEBUG=true to print resolved values for troubleshooting.
# ------------------------------------------------------------------------------
printf '::group::Inputs received\n'
echo "=== Inputs received ==="
if [ "${INPUT_DEBUG}" = "true" ]; then
  printf '  %-26s %s\n' "server:"                  "${INPUT_SERVER}"
  printf '  %-26s %s\n' "user:"                    "${INPUT_USER}"
  printf '  %-26s %s\n' "password:"                "${INPUT_PASSWORD}"
  printf '  %-26s %s\n' "local_dir:"               "${INPUT_LOCAL_DIR}"
  printf '  %-26s %s\n' "remote_dir:"              "${INPUT_REMOTE_DIR}"
  printf '  %-26s %s\n' "max_retries:"             "${INPUT_MAX_RETRIES}"
  printf '  %-26s %s\n' "delete:"                  "${INPUT_DELETE}"
  printf '  %-26s %s\n' "no_symlinks:"             "${INPUT_NO_SYMLINKS}"
  printf '  %-26s %s\n' "mirror_verbose:"          "${INPUT_MIRROR_VERBOSE}"
  printf '  %-26s %s\n' "ftp_ssl_allow:"           "${INPUT_FTP_SSL_ALLOW}"
  printf '  %-26s %s\n' "ssl_verify_certificate:"  "${INPUT_SSL_VERIFY_CERTIFICATE}"
  printf '  %-26s %s\n' "ssl_check_hostname:"      "${INPUT_SSL_CHECK_HOSTNAME}"
  printf '  %-26s %s\n' "ftp_passive_mode:"        "${INPUT_FTP_PASSIVE_MODE}"
  printf '  %-26s %s\n' "ftp_use_feat:"            "${INPUT_FTP_USE_FEAT}"
  printf '  %-26s %s\n' "ftp_nop_interval:"        "${INPUT_FTP_NOP_INTERVAL}"
  printf '  %-26s %s\n' "net_max_retries:"         "${INPUT_NET_MAX_RETRIES}"
  printf '  %-26s %s\n' "net_persist_retries:"     "${INPUT_NET_PERSIST_RETRIES}"
  printf '  %-26s %s\n' "net_timeout:"             "${INPUT_NET_TIMEOUT}"
  printf '  %-26s %s\n' "dns_max_retries:"         "${INPUT_DNS_MAX_RETRIES}"
  printf '  %-26s %s\n' "dns_fatal_timeout:"       "${INPUT_DNS_FATAL_TIMEOUT}"
  printf '  %-26s %s\n' "lftp_settings:"           "${INPUT_LFTP_SETTINGS}"
  printf '  %-26s %s\n' "debug:"                   "${INPUT_DEBUG}"
else
  for _v in SERVER USER PASSWORD LOCAL_DIR REMOTE_DIR MAX_RETRIES DELETE \
            NO_SYMLINKS MIRROR_VERBOSE FTP_SSL_ALLOW SSL_VERIFY_CERTIFICATE \
            SSL_CHECK_HOSTNAME FTP_PASSIVE_MODE FTP_USE_FEAT FTP_NOP_INTERVAL \
            NET_MAX_RETRIES NET_PERSIST_RETRIES NET_TIMEOUT DNS_MAX_RETRIES \
            DNS_FATAL_TIMEOUT LFTP_SETTINGS DEBUG FAIL_ON_DEPRECATED DRY_RUN; do
    _label=$(printf '%s' "${_v}" | tr '[:upper:]' '[:lower:]')
    eval "_cur=\${INPUT_${_v}}"
    if [ -n "${_cur}" ]; then
      printf '  %-26s (set)\n' "${_label}:"
    else
      printf '  %-26s (using default)\n' "${_label}:"
    fi
  done
fi
echo ""
printf '::endgroup::\n'
echo "=== Current location ==="
pwd
echo ""

# ------------------------------------------------------------------------------
# B-07: Normalize integer inputs to their effective defaults, then validate.
#   In a real GitHub Actions run these are always populated by the
#   action.yml default, but init.sh can also be run outside that
#   mechanism (tests, manual invocation), so we apply the same
#   defaults here before validating. This avoids a false-positive
#   exit 2 on an empty numeric input.
# ------------------------------------------------------------------------------
if [ -z "${INPUT_MAX_RETRIES}" ]; then
  INPUT_MAX_RETRIES="10"
fi
if [ -z "${INPUT_MIRROR_VERBOSE}" ]; then
  INPUT_MIRROR_VERBOSE="1"
fi
if [ -z "${INPUT_FTP_NOP_INTERVAL}" ]; then
  INPUT_FTP_NOP_INTERVAL="2"
fi
if [ -z "${INPUT_NET_MAX_RETRIES}" ]; then
  INPUT_NET_MAX_RETRIES="1"
fi
if [ -z "${INPUT_NET_PERSIST_RETRIES}" ]; then
  INPUT_NET_PERSIST_RETRIES="5"
fi
if [ -z "${INPUT_DNS_MAX_RETRIES}" ]; then
  INPUT_DNS_MAX_RETRIES="8"
fi
validate_int "max_retries"         "${INPUT_MAX_RETRIES}"
validate_int "mirror_verbose"      "${INPUT_MIRROR_VERBOSE}"
validate_int "ftp_nop_interval"    "${INPUT_FTP_NOP_INTERVAL}"
validate_int "net_max_retries"     "${INPUT_NET_MAX_RETRIES}"
validate_int "net_persist_retries" "${INPUT_NET_PERSIST_RETRIES}"
validate_int "dns_max_retries"     "${INPUT_DNS_MAX_RETRIES}"
# B-16: light sanitization of the free-form lftp_settings input.
validate_lftp_settings "${INPUT_LFTP_SETTINGS}"

# ------------------------------------------------------------------------------
# Set the LFTP setting.
# ------------------------------------------------------------------------------
FTP_SETTINGS=""

# ftp:ssl-allow
if [ -n "${INPUT_FTP_SSL_ALLOW}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set ftp:ssl-allow ${INPUT_FTP_SSL_ALLOW};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set ftp:ssl-allow true;"
fi

# ssl:verify-certificate
if [ -n "${INPUT_SSL_VERIFY_CERTIFICATE}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set ssl:verify-certificate ${INPUT_SSL_VERIFY_CERTIFICATE};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set ssl:verify-certificate true;"
fi

# ssl:check-hostname
if [ -n "${INPUT_SSL_CHECK_HOSTNAME}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set ssl:check-hostname ${INPUT_SSL_CHECK_HOSTNAME};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set ssl:check-hostname true;"
fi

# ftp:passive-mode
if [ -n "${INPUT_FTP_PASSIVE_MODE}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set ftp:passive-mode ${INPUT_FTP_PASSIVE_MODE};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set ftp:passive-mode true;"
fi

# ftp:use-feat
if [ -n "${INPUT_FTP_USE_FEAT}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set ftp:use-feat ${INPUT_FTP_USE_FEAT};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set ftp:use-feat false;"
fi

# ftp:nop-interval
if [ -n "${INPUT_FTP_NOP_INTERVAL}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set ftp:nop-interval ${INPUT_FTP_NOP_INTERVAL};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set ftp:nop-interval 2;"
fi

# net:max-retries
if [ -n "${INPUT_NET_MAX_RETRIES}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set net:max-retries ${INPUT_NET_MAX_RETRIES};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set net:max-retries 1;"
fi

# net:persist-retries
if [ -n "${INPUT_NET_PERSIST_RETRIES}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set net:persist-retries ${INPUT_NET_PERSIST_RETRIES};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set net:persist-retries 5;"
fi

# net:timeout
if [ -n "${INPUT_NET_TIMEOUT}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set net:timeout ${INPUT_NET_TIMEOUT};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set net:timeout 15s;"
fi

# dns:max-retries
if [ -n "${INPUT_DNS_MAX_RETRIES}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set dns:max-retries ${INPUT_DNS_MAX_RETRIES};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set dns:max-retries 8;"
fi

# dns:fatal-timeout
if [ -n "${INPUT_DNS_FATAL_TIMEOUT}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS}set dns:fatal-timeout ${INPUT_DNS_FATAL_TIMEOUT};"
else
  FTP_SETTINGS="${FTP_SETTINGS}set dns:fatal-timeout 10s;"
fi

# Any manual settings
if [ -n "${INPUT_LFTP_SETTINGS}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS} ${INPUT_LFTP_SETTINGS};"
fi

# Remove first space in settings variable
if [ -n "${FTP_SETTINGS}" ]; then
  FTP_SETTINGS="${FTP_SETTINGS#"${FTP_SETTINGS%%[![:space:]]*}"}"
fi

# Local path to get the directories
if [ -z "${INPUT_LOCAL_DIR}" ]; then
  INPUT_LOCAL_DIR="./"
else
  INPUT_LOCAL_DIR="${INPUT_LOCAL_DIR%/}/"
fi
# B-04: path traversal and shell-metacharacter guard.
validate_path "local_dir" "${INPUT_LOCAL_DIR}"

# Remote path to put the directories
if [ -z "${INPUT_REMOTE_DIR}" ]; then
  INPUT_REMOTE_DIR="./"
else
  INPUT_REMOTE_DIR="${INPUT_REMOTE_DIR%/}/"
fi
# B-04: path traversal and shell-metacharacter guard.
validate_path "remote_dir" "${INPUT_REMOTE_DIR}"

# Reverse mirror which uploads or updates a directory tree on server
MIRROR_COMMAND="mirror --continue --reverse"

# Mirror verbosity level
if [ -n "${INPUT_MIRROR_VERBOSE}" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --verbose=${INPUT_MIRROR_VERBOSE}"
else
  MIRROR_COMMAND="${MIRROR_COMMAND} --verbose=1"
fi

# Don't create symbolic links
if [ "${INPUT_NO_SYMLINKS}" = "true" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --no-symlinks"
fi

# Delete files not present at the source
if [ "${INPUT_DELETE}" = "true" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --delete"
fi

# Dry run: compute the mirror plan but do not transfer or delete
# anything. lftp's --dry-run makes mirror print every file it
# *would* act on, then quit without writing. Safe to combine with
# --delete: the deletion list is reported but not executed.
if [ "${INPUT_DRY_RUN}" = "true" ]; then
  MIRROR_COMMAND="${MIRROR_COMMAND} --dry-run"
fi

# ------------------------------------------------------------------------------
# Display LFTP settings.
# ------------------------------------------------------------------------------
printf '::group::Resolved configuration\n'
echo "=== Directories ==="
echo "INPUT_LOCAL_DIR: ${INPUT_LOCAL_DIR}"
echo "INPUT_REMOTE_DIR: ${INPUT_REMOTE_DIR}"
echo ""
echo "=== List local directory ==="
echo "${INPUT_LOCAL_DIR}"
ls -lha "${INPUT_LOCAL_DIR}"
echo ""
echo "=== LFTP Settings ==="
echo " FTP_SETTINGS      -> ${FTP_SETTINGS}"
echo " MIRROR_COMMAND    -> ${MIRROR_COMMAND}"
echo " INPUT_LOCAL_DIR   -> ${INPUT_LOCAL_DIR}"
echo " INPUT_REMOTE_DIR  -> ${INPUT_REMOTE_DIR}"
echo " INPUT_MAX_RETRIES -> ${INPUT_MAX_RETRIES}"
echo ""
echo "=== * NOTE * ==="
echo "The upload should be fast depends how many files and what size they have."
echo "If the process take for several minutes or hours, please stop the job and run it again."
printf '::endgroup::\n'

# ------------------------------------------------------------------------------
# B-03: write credentials to a private .netrc and let lftp read it.
#
# Passing the password on the lftp command line leaves it in
# /proc/<pid>/cmdline and in the GH Actions runner log. Writing it to
# ~/.netrc with mode 0600 is the POSIX-blessed way to feed lftp a
# password. The file is removed via an EXIT trap so it does not survive
# a `set -e` abort, a SIGINT, or a normal exit.
#
# Extract just the hostname from the (possibly decorated) server URL,
# because that is the form .netrc's "machine" directive expects.
# ------------------------------------------------------------------------------
: "${HOME:=/home/lftp}"
NETRC="${HOME}/.netrc"
# Extract the hostname (or bracketed IPv6 literal) from the (possibly
# decorated) server URL: strip the scheme and the optional userinfo,
# then either match the [...] bracket pair for IPv6 or strip ":port" /
# "/path" for everything else.
NETRC_HOST=$(printf '%s' "${INPUT_SERVER}" \
  | sed -E 's|^[a-zA-Z]+://||' \
  | sed -E 's|^[^@/]*@||')
case "${NETRC_HOST}" in
  \[*\])
    NETRC_HOST=$(printf '%s' "${NETRC_HOST}" | sed -nE 's|^\[([^]]*)\].*|\1|p')
    ;;
  *)
    NETRC_HOST=$(printf '%s' "${NETRC_HOST}" | sed -E 's|[:/].*||')
    ;;
esac
{
  printf 'machine %s login %s password %s\n' \
    "${NETRC_HOST}" "${INPUT_USER}" "${INPUT_PASSWORD}"
} > "${NETRC}"
chmod 600 "${NETRC}"
trap 'rm -f "${NETRC}"' EXIT

# ------------------------------------------------------------------------------
# Execute the LFTP actions.
#
# B-09: Wrap with a hard global timeout (5h) so a hung lftp cannot run past
# the GH Actions job limit. busybox `timeout` supports -k for SIGKILL after a
# grace period.
#
# B-05: Capture lftp's exit code explicitly. With `set -e` and `&&`, a
# non-zero lftp exit was causing the script to abort via the `set -e`
# short-circuit instead of falling into the "ERROR" banner.
#
# B-08: Exponential backoff with jitter, capped at 30s. The proposal's
# `2 ** (COUNTER - 1)` example is invalid in POSIX sh (no `**` operator);
# we use a small lookup table instead.
# ------------------------------------------------------------------------------
COUNTER=1
SUCCESS=""
PERMANENT_ERROR=""

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
mkdir -p "${HOME}/.lftp-logs"
LOG_FILE="${HOME}/.lftp-logs/run-$(date -u +%Y%m%dT%H%M%SZ).log"

printf '::group::Upload\n'
while true; do
  echo ""
  echo "Try #${COUNTER}"
  echo "-------"

  set +e
  # B-03: no -u USER,PASS — lftp reads credentials from ${NETRC}.
  # B-04: redirect combined stdout+stderr to the timestamped log file
  # so the captured output can be inspected after the fact and, if
  # the user wishes, attached as a workflow artifact.
  timeout -k "${LFTP_KILL_AFTER}" "${LFTP_TIMEOUT}" lftp \
    "${INPUT_SERVER}" \
    -e "${FTP_SETTINGS} ${MIRROR_COMMAND} ${INPUT_LOCAL_DIR} ${INPUT_REMOTE_DIR}; quit;" \
    > "${LOG_FILE}" 2>&1
  LFTP_RC=$?
  set -e

  if [ "${LFTP_RC}" -eq 0 ]; then
    SUCCESS="true"
    break
  fi

  echo "  lftp exited with code ${LFTP_RC}"

  # A6: classify the failure. Some errors are permanent (no point in
  # retrying with the same credentials and same path): bad login,
  # permission denied, missing file. Detect them in the captured log
  # and abort the retry loop early.
  if grep -qiE '(^|[^0-9])(530 |login authentication failed|login incorrect|login failed|not logged in|550 permission denied|550 .*no such file|550 .*not found)' "${LOG_FILE}"; then
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
  case "${COUNTER}" in
    2) DELAY=1 ;;
    3) DELAY=2 ;;
    4) DELAY=4 ;;
    5) DELAY=8 ;;
    6) DELAY=16 ;;
    *) DELAY=30 ;;
  esac
  if [ "${DELAY}" -gt 1 ]; then
    # ±50% jitter: range is [-DELAY/2, +DELAY/2] so DELAY=4 -> ±2s,
    # DELAY=2 -> ±1s, DELAY=8 -> ±4s. The previous formula
    # `(RANDOM % (HALF + 1)) - (HALF / 2)` was off because for small
    # DELAY the integer division collapsed the negative half.
    # shellcheck disable=SC3028  # RANDOM is a busybox ash extension (the shell we actually run in).
    JITTER=$(( RANDOM % (DELAY + 1) - DELAY / 2 ))
    SLEEP_S=$(( DELAY + JITTER ))
  else
    SLEEP_S="${DELAY}"
  fi
  [ "${SLEEP_S}" -lt 1 ] && SLEEP_S=1
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
  echo ""
  echo "=============================="
  echo "=    ERROR: UPLOAD FAILED    ="
  echo "=============================="
  if [ -n "${PERMANENT_ERROR}" ]; then
    echo "Failure type: PERMANENT (no point retrying with the same inputs)."
    echo "Check credentials, the remote_dir path, and the FTP user's"
    echo "permissions; see the log file below for the server's message."
  fi
  if [ -n "${LFTP_RC}" ]; then
    echo "Last lftp exit code: ${LFTP_RC}"
    echo "Common codes:"
    echo "  1   lftp generic error"
    echo "  4    Fatal error (e.g. command-line usage, configuration)"
    echo "  124  timeout reached (max wall-clock ${LFTP_TIMEOUT})"
    echo "  137  process killed (SIGKILL after ${LFTP_KILL_AFTER} grace)"
  fi
  echo "Full lftp output: ${LOG_FILE}"
  exit 1
fi

echo ""
echo "=============================="
if [ "${INPUT_DRY_RUN}" = "true" ]; then
  echo "=  FTP DRY RUN COMPLETED     ="
  echo "=  (no files transferred)    ="
else
  echo "=   FTP UPLOADED FINISHED!   ="
fi
echo "=============================="
