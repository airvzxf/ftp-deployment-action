#!/bin/sh -e

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
# Display environment variables.
#
# B-10: By default, only show which inputs were received (no values). Set
# INPUT_DEBUG=true to print resolved values for troubleshooting.
# ------------------------------------------------------------------------------
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
            DNS_FATAL_TIMEOUT LFTP_SETTINGS DEBUG; do
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

# ------------------------------------------------------------------------------
# Display LFTP settings.
# ------------------------------------------------------------------------------
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

# B-09: hard cap on the total wall-clock time of one lftp invocation.
LFTP_TIMEOUT="5h"
LFTP_KILL_AFTER="30s"

while true; do
  echo ""
  echo "Try #${COUNTER}"
  echo "-------"

  set +e
  # B-03: no -u USER,PASS — lftp reads credentials from ${NETRC}.
  timeout -k "${LFTP_KILL_AFTER}" "${LFTP_TIMEOUT}" lftp \
    "${INPUT_SERVER}" \
    -e "${FTP_SETTINGS} ${MIRROR_COMMAND} ${INPUT_LOCAL_DIR} ${INPUT_REMOTE_DIR}; quit;"
  LFTP_RC=$?
  set -e

  if [ "${LFTP_RC}" -eq 0 ]; then
    SUCCESS="true"
    break
  fi

  echo "  lftp exited with code ${LFTP_RC}"

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

# ------------------------------------------------------------------------------
# Display the status of the LFTP actions.
# ------------------------------------------------------------------------------
if [ -z "${SUCCESS}" ]; then
  echo ""
  echo "=============================="
  echo "=    ERROR: UPLOAD FAILED    ="
  echo "=============================="
  if [ -n "${LFTP_RC}" ]; then
    echo "Last lftp exit code: ${LFTP_RC}"
    echo "Common codes:"
    echo "  1   lftp generic error"
    echo "  4    Fatal error (e.g. command-line usage, configuration)"
    echo "  124  timeout reached (max wall-clock ${LFTP_TIMEOUT})"
    echo "  137  process killed (SIGKILL after ${LFTP_KILL_AFTER} grace)"
  fi
  exit 1
fi

echo ""
echo "=============================="
echo "=   FTP UPLOADED FINISHED!   ="
echo "=============================="
