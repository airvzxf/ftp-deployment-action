#!/bin/sh
# lib.sh — pure functions and IO helpers for ftp-deployment-action.
#
# This file is sourced by entrypoint.sh. It is NOT executable on its
# own; it has no `main` and no ENTRYPOINT role. The split between
# lib.sh and entrypoint.sh is the only architectural change vs. the
# pre-v2.5.0 single-file layout; the behaviour of the action is
# preserved bit-by-bit.
#
# Conventions:
#   * POSIX sh (busybox ash is the runtime target). No `local`.
#   * Function-private variables are prefixed with the function name
#     (e.g. `_bfs_key` inside `build_ftp_settings`).
#   * Functions either succeed silently, `exit N` on a hard error,
#     or echo a value to stdout. They do not mutate global state
#     outside the documented surface.
#   * The single point of dynamic variable-name lookup is
#     `_indirection`. Do not duplicate the `eval` pattern elsewhere.
#
# shellcheck shell=sh
# shellcheck disable=SC2039  # busybox ash extensions (RANDOM) are documented at the call site.

# ------------------------------------------------------------------------------
# _indirection VAR_NAME
#   Echo the value of the variable named VAR_NAME, or empty string if
#   unset. This is the SINGLE place in the codebase where dynamic
#   variable-name lookup happens, because POSIX sh has no ${!var}
#   indirection and busybox ash (the runtime) is the strict target.
#   Every caller that needs to look up INPUT_<X> from a runtime-
#   computed name goes through this helper. Do not duplicate the
#   `eval` pattern elsewhere.
#
#   The `${VAR-}` form (with the dash) is safe under `set -u` and
#   resolves to empty when VAR is unset.
# ------------------------------------------------------------------------------
_indirection() {
  # shellcheck disable=SC2154  # var is referenced indirectly via $1
  eval "printf '%s' \"\${${1}-}\""
}

# ------------------------------------------------------------------------------
# validate_int NAME VALUE
#   Exit 2 with a clear error if VALUE is not a non-negative integer.
# ------------------------------------------------------------------------------
validate_int() {
  _vi_name=$1
  _vi_value=$2
  printf '%s' "${_vi_value}" | grep -qE '^[0-9]+$' || {
    printf 'ERROR: %s must be a non-negative integer (got: %s)\n' \
      "${_vi_name}" "${_vi_value}" >&2
    exit 2
  }
}

# ------------------------------------------------------------------------------
# validate_path NAME VALUE
#   Exit 2 if VALUE looks unsafe for a local or remote path passed to
#   lftp. The function is a *deny-list*: it rejects a small set of
#   known-dangerous patterns (path-traversal components, leading dash
#   which lftp would misread as an option, control characters, shell
#   metacharacters). Anything else is allowed; if you need a stricter
#   policy, build a `validate_path_strict` that allow-lists only
#   `[A-Za-z0-9._/-]`.
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# validate_lftp_settings VALUE
#   Light sanitization of the free-form lftp_settings input (B-16). The
#   documented use case is 1-3 'set' directives chained with ';', so
#   we allow up to 3 ';' characters but reject control characters,
#   backtick, dollar, and the '!' character (lftp's own shell escape,
#   which would otherwise let an attacker run arbitrary commands
#   inside the container even within the 3-';' limit).
# ------------------------------------------------------------------------------
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
# emit_deprecation_warning REF IMAGE_VERSION FAIL_ON_DEPRECATED
#
# Emit a deprecation / EOL / major-out-of-date notice based on the ref
# the user pinned this action to. Driven by $GITHUB_ACTION_REF (set
# by the runner) and the /app/VERSION file baked at build time by
# release.yml.
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
# If FAIL_ON_DEPRECATED=true AND the ref is in the EOL list, exit 1
# via ::error::. Other warnings (latest, master) are advisory only.
# ------------------------------------------------------------------------------
emit_deprecation_warning() {
  _edw_ref=$1
  _edw_img_ver=$2
  _edw_fail_on=$3

  case "${_edw_ref}" in
    latest)
      printf '::warning file=action.yml,title=Deprecated usage::' >&2
      printf 'You are using @latest, a moving target. ' >&2
      printf 'Pin to @v2 or @<sha>. (image version: %s)\n' "${_edw_img_ver}" >&2
      ;;
    "")
      # No GITHUB_ACTION_REF means the workflow invoked the action from
      # the same repo (`uses: ./` or local checkout). Not a user-facing
      # warning, but still useful to know the image version.
      ;;
    master|main)
      printf '::warning file=action.yml,title=Branch usage::' >&2
      printf 'You are using @%s, a development branch. ' "${_edw_ref}" >&2
      printf 'Use a tagged release (current image: %s).\n' "${_edw_img_ver}" >&2
      ;;
    v1.0-alpha.1|v1.0-alpha.2|v1.1|v1.2.0|v1.3.0|v1.3.1|v1.3.2|v1.3.3)
      printf '::warning file=action.yml,title=End-of-life version::' >&2
      printf 'Version %s is end-of-life (SECURITY.md: only v1.4+ is supported). ' "${_edw_ref}" >&2
      printf 'Upgrade to v2: https://github.com/airvzxf/ftp-deployment-action/releases\n' >&2
      if [ "${_edw_fail_on}" = "true" ]; then
        printf '::error file=action.yml::fail_on_deprecated is true and ref %s is EOL.\n' "${_edw_ref}" >&2
        exit 1
      fi
      ;;
    v1.4*|v1.5*|v1.6*|v1.7*|v1.8*|v1.9*)
      printf '::notice file=action.yml,title=New major available::' >&2
      printf 'You are on %s. v2 is available (BREAKING: ssl_verify_certificate default is now true). ' "${_edw_ref}" >&2
      printf 'See CHANGELOG.md. (image version: %s)\n' "${_edw_img_ver}" >&2
      ;;
    *)
      # Current line (v2.x, or anything not yet in the EOL list).
      ;;
  esac
}

# ------------------------------------------------------------------------------
# add_masks
#   Defence-in-depth: ask the runner to mask sensitive values in the
#   log even if they ever leak outside the .netrc plumbing. GitHub
#   already auto-masks inputs named *password* / *token* / *secret*,
#   but `user` and `server` are not in that list. The init.sh script
#   emits `::add-mask::` for the three values; the function reads
#   them via _indirection so we don't repeat the eval pattern.
#
#   Reads: INPUT_PASSWORD, INPUT_USER, INPUT_SERVER.
# ------------------------------------------------------------------------------
add_masks() {
  if [ -n "$(_indirection INPUT_PASSWORD)" ]; then
    printf '::add-mask::%s\n' "$(_indirection INPUT_PASSWORD)"
  fi
  if [ -n "$(_indirection INPUT_USER)" ]; then
    printf '::add-mask::%s\n' "$(_indirection INPUT_USER)"
  fi
  if [ -n "$(_indirection INPUT_SERVER)" ]; then
    printf '::add-mask::%s\n' "$(_indirection INPUT_SERVER)"
  fi
}

# ------------------------------------------------------------------------------
# print_inputs_dump DEBUG
#   Print the "Inputs received" group. When DEBUG=true, prints the
#   resolved value of every INPUT_* in order. When DEBUG=false (or
#   empty), prints only "(set)" / "(using default)" per input.
#
#   The list of input names is explicit and matches action.yml; the
#   contract test (tests/contract.sh) verifies that this list matches
#   both the declared inputs and the static INPUT_* references. The
#   explicit list replaces the previous `eval "_cur=\${INPUT_${_v}-}"`
#   pattern: there is no longer a single point of dynamic-name lookup
#   outside `_indirection`.
# ------------------------------------------------------------------------------
print_inputs_dump() {
  _pid_debug=$1
  printf '::group::Inputs received\n'
  echo "=== Inputs received ==="
  if [ "${_pid_debug}" = "true" ]; then
    printf '  %-26s %s\n' "server:"                  "$(_indirection INPUT_SERVER)"
    printf '  %-26s %s\n' "user:"                    "$(_indirection INPUT_USER)"
    printf '  %-26s %s\n' "password:"                "$(_indirection INPUT_PASSWORD)"
    printf '  %-26s %s\n' "local_dir:"               "$(_indirection INPUT_LOCAL_DIR)"
    printf '  %-26s %s\n' "remote_dir:"              "$(_indirection INPUT_REMOTE_DIR)"
    printf '  %-26s %s\n' "max_retries:"             "$(_indirection INPUT_MAX_RETRIES)"
    printf '  %-26s %s\n' "delete:"                  "$(_indirection INPUT_DELETE)"
    printf '  %-26s %s\n' "no_symlinks:"             "$(_indirection INPUT_NO_SYMLINKS)"
    printf '  %-26s %s\n' "mirror_verbose:"          "$(_indirection INPUT_MIRROR_VERBOSE)"
    printf '  %-26s %s\n' "ftp_ssl_allow:"           "$(_indirection INPUT_FTP_SSL_ALLOW)"
    printf '  %-26s %s\n' "ssl_verify_certificate:"  "$(_indirection INPUT_SSL_VERIFY_CERTIFICATE)"
    printf '  %-26s %s\n' "ssl_check_hostname:"      "$(_indirection INPUT_SSL_CHECK_HOSTNAME)"
    printf '  %-26s %s\n' "ftp_passive_mode:"        "$(_indirection INPUT_FTP_PASSIVE_MODE)"
    printf '  %-26s %s\n' "ftp_use_feat:"            "$(_indirection INPUT_FTP_USE_FEAT)"
    printf '  %-26s %s\n' "ftp_nop_interval:"        "$(_indirection INPUT_FTP_NOP_INTERVAL)"
    printf '  %-26s %s\n' "net_max_retries:"         "$(_indirection INPUT_NET_MAX_RETRIES)"
    printf '  %-26s %s\n' "net_persist_retries:"     "$(_indirection INPUT_NET_PERSIST_RETRIES)"
    printf '  %-26s %s\n' "net_timeout:"             "$(_indirection INPUT_NET_TIMEOUT)"
    printf '  %-26s %s\n' "dns_max_retries:"         "$(_indirection INPUT_DNS_MAX_RETRIES)"
    printf '  %-26s %s\n' "dns_fatal_timeout:"       "$(_indirection INPUT_DNS_FATAL_TIMEOUT)"
    printf '  %-26s %s\n' "lftp_settings:"           "$(_indirection INPUT_LFTP_SETTINGS)"
    printf '  %-26s %s\n' "debug:"                   "$(_indirection INPUT_DEBUG)"
  else
    for _pid_name in \
      SERVER USER PASSWORD LOCAL_DIR REMOTE_DIR MAX_RETRIES DELETE \
      NO_SYMLINKS MIRROR_VERBOSE FTP_SSL_ALLOW SSL_VERIFY_CERTIFICATE \
      SSL_CHECK_HOSTNAME FTP_PASSIVE_MODE FTP_USE_FEAT FTP_NOP_INTERVAL \
      NET_MAX_RETRIES NET_PERSIST_RETRIES NET_TIMEOUT DNS_MAX_RETRIES \
      DNS_FATAL_TIMEOUT LFTP_SETTINGS DEBUG FAIL_ON_DEPRECATED DRY_RUN; do
      _pid_label=$(printf '%s' "${_pid_name}" | tr '[:upper:]' '[:lower:]')
      _pid_cur=$(_indirection "INPUT_${_pid_name}")
      if [ -n "${_pid_cur}" ]; then
        printf '  %-26s (set)\n' "${_pid_label}:"
      else
        printf '  %-26s (using default)\n' "${_pid_label}:"
      fi
    done
  fi
  echo ""
  printf '::endgroup::\n'
  echo "=== Current location ==="
  pwd
  echo ""
}

# ------------------------------------------------------------------------------
# build_ftp_settings
#   Echo the concatenated "set <key> <value>;" string, one directive
#   per INPUT_*, in a fixed order. Each entry is a triple:
#     <lftp-key>  <default-value>  <INPUT_var_name>
#   The default applies when the INPUT is unset or empty. The
#   free-form lftp_settings input (already validated upstream by
#   `validate_lftp_settings`) is appended verbatim with a trailing
#   semicolon.
#
#   This replaces 12 near-identical if/else branches. The behaviour
#   is bit-by-bit equivalent: same keys, same defaults, same order,
#   same trailing-semicolon semantics. The "Remove first space in
#   settings variable" trick is preserved so the output still has no
#   leading space when the first entry is followed by the lftp_settings
#   extension (B-16 free-form path).
# ------------------------------------------------------------------------------
build_ftp_settings() {
  _bfs_settings=""
  set -- \
    "ftp:ssl-allow"          "true"   "INPUT_FTP_SSL_ALLOW" \
    "ssl:verify-certificate" "true"   "INPUT_SSL_VERIFY_CERTIFICATE" \
    "ssl:check-hostname"     "true"   "INPUT_SSL_CHECK_HOSTNAME" \
    "ftp:passive-mode"       "true"   "INPUT_FTP_PASSIVE_MODE" \
    "ftp:use-feat"           "false"  "INPUT_FTP_USE_FEAT" \
    "ftp:nop-interval"       "2"      "INPUT_FTP_NOP_INTERVAL" \
    "net:max-retries"        "1"      "INPUT_NET_MAX_RETRIES" \
    "net:persist-retries"    "5"      "INPUT_NET_PERSIST_RETRIES" \
    "net:timeout"            "15s"    "INPUT_NET_TIMEOUT" \
    "dns:max-retries"        "8"      "INPUT_DNS_MAX_RETRIES" \
    "dns:fatal-timeout"      "10s"    "INPUT_DNS_FATAL_TIMEOUT"
  while [ $# -gt 0 ]; do
    _bfs_key=$1
    _bfs_default=$2
    _bfs_input=$3
    shift 3
    _bfs_val=$(_indirection "${_bfs_input}")
    if [ -z "${_bfs_val}" ]; then
      _bfs_val="${_bfs_default}"
    fi
    _bfs_settings="${_bfs_settings}set ${_bfs_key} ${_bfs_val};"
  done
  # Any manual settings (B-16, already validated).
  _bfs_extra=$(_indirection "INPUT_LFTP_SETTINGS")
  if [ -n "${_bfs_extra}" ]; then
    _bfs_settings="${_bfs_settings} ${_bfs_extra};"
  fi
  # Remove leading space if the first directive is followed by a
  # space (e.g. when lftp_settings is non-empty).
  if [ -n "${_bfs_settings}" ]; then
    _bfs_settings="${_bfs_settings#"${_bfs_settings%%[![:space:]]*}"}"
  fi
  printf '%s' "${_bfs_settings}"
}

# ------------------------------------------------------------------------------
# build_mirror_command
#   Echo the assembled `mirror --continue --reverse ...` command line
#   fragment, including the optional --no-symlinks, --delete, and
#   --dry-run flags. The fragment does NOT include local/remote
#   directories; those are appended by the caller when building the
#   final lftp `-e` script.
#
#   Behaviour-preserving vs. the inline block in pre-v2.5.0 init.sh:
#   same order, same flags, same default --verbose=1 when the input
#   is empty.
# ------------------------------------------------------------------------------
build_mirror_command() {
  _bmc_command="mirror --continue --reverse"

  # Mirror verbosity level.
  _bmc_verbose=$(_indirection "INPUT_MIRROR_VERBOSE")
  if [ -n "${_bmc_verbose}" ]; then
    _bmc_command="${_bmc_command} --verbose=${_bmc_verbose}"
  else
    _bmc_command="${_bmc_command} --verbose=1"
  fi

  # Don't create symbolic links.
  if [ "$(_indirection INPUT_NO_SYMLINKS)" = "true" ]; then
    _bmc_command="${_bmc_command} --no-symlinks"
  fi

  # Delete files not present at the source.
  if [ "$(_indirection INPUT_DELETE)" = "true" ]; then
    _bmc_command="${_bmc_command} --delete"
  fi

  # Dry run: compute the mirror plan but do not transfer or delete
  # anything. lftp's --dry-run makes mirror print every file it
  # *would* act on, then quit without writing. Safe to combine with
  # --delete: the deletion list is reported but not executed.
  if [ "$(_indirection INPUT_DRY_RUN)" = "true" ]; then
    _bmc_command="${_bmc_command} --dry-run"
  fi

  printf '%s' "${_bmc_command}"
}

# ------------------------------------------------------------------------------
# normalize_dir VALUE
#   Echo VALUE with a trailing slash appended, unless VALUE is empty
#   in which case echo "./".
#
#   This preserves the exact pre-v2.5.0 behaviour:
#     normalize_dir ""        -> "./"
#     normalize_dir "/www/x"  -> "/www/x/"
#     normalize_dir "/www/x/" -> "/www/x/"   (idempotent)
#
#   Validation is NOT done here. The caller must call
#   `validate_path` on the result separately, in the main shell
#   context (not inside a `$(...)` substitution) so that
#   `validate_path`'s `exit 2` actually aborts the parent script.
#   busybox ash does NOT propagate a subshell's `exit` through a
#   `$(...)` substitution; the assignment itself succeeds and the
#   parent script continues.
# ------------------------------------------------------------------------------
normalize_dir() {
  _nd_value=$1
  if [ -z "${_nd_value}" ]; then
    _nd_value="./"
  else
    _nd_value="${_nd_value%/}/"
  fi
  printf '%s' "${_nd_value}"
}

# ------------------------------------------------------------------------------
# extract_netrc_host SERVER_URL
#   Echo just the hostname (or bracketed IPv6 literal) from a possibly
#   decorated server URL. This is the form .netrc's "machine"
#   directive expects.
#
#   Supported forms:
#     ftp://host                       -> host
#     ftp://user:pw@host               -> host
#     ftp://host:21                    -> host
#     ftp://user:pw@host:21            -> host
#     ftps://[::1]:990                 -> ::1
#     ftps://[::1]                     -> ::1
#     host                             -> host  (no scheme)
# ------------------------------------------------------------------------------
extract_netrc_host() {
  _enh_value=$1
  _enh_value=$(printf '%s' "${_enh_value}" \
    | sed -E 's|^[a-zA-Z]+://||' \
    | sed -E 's|^[^@/]*@||')
  # IPv6 host literals arrive wrapped in [ ]. The host literal may
  # be followed by :port and/or /path (e.g. "[::1]:990" or
  # "[::1]/x"). Match the bracket form on the leading character so
  # we correctly handle both "[::1]" and "[::1]:990".
  case "${_enh_value}" in
    \[*)
      _enh_value=$(printf '%s' "${_enh_value}" | sed -nE 's|^\[([^]]*)\].*|\1|p')
      ;;
    *)
      _enh_value=$(printf '%s' "${_enh_value}" | sed -E 's|[:/].*||')
      ;;
  esac
  printf '%s' "${_enh_value}"
}

# ------------------------------------------------------------------------------
# write_netrc NETRC_PATH HOST USER PASSWORD
#   Write a .netrc file at NETRC_PATH with mode 0600, then install an
#   EXIT trap that removes it on any exit path. This is the B-03
#   fix: the password never appears on the lftp command line (and
#   therefore not in /proc/<pid>/cmdline or in the GH Actions runner
#   log).
#
#   The trap is installed in the parent shell context, so it covers
#   the entire run from this point onward.
# ------------------------------------------------------------------------------
write_netrc() {
  _wn_path=$1
  _wn_host=$2
  _wn_user=$3
  _wn_password=$4
  {
    printf 'machine %s login %s password %s\n' \
      "${_wn_host}" "${_wn_user}" "${_wn_password}"
  } > "${_wn_path}"
  chmod 600 "${_wn_path}"
  trap 'rm -f "${_wn_path}"' EXIT
}

# ------------------------------------------------------------------------------
# classify_permanent_error LOG_FILE
#   Exit 0 if the captured lftp output at LOG_FILE contains a
#   permanent error (530 login, 550 permission, 550 no-such-file),
#   exit 1 otherwise. The function is read-only; it does not modify
#   the log file.
# ------------------------------------------------------------------------------
classify_permanent_error() {
  _cpe_log=$1
  grep -qiE '(^|[^0-9])(530 |login authentication failed|login incorrect|login failed|not logged in|550 permission denied|550 .*no such file|550 .*not found)' "${_cpe_log}"
}

# ------------------------------------------------------------------------------
# compute_backoff_seconds COUNTER
#   Echo the number of seconds to sleep before the next retry, given
#   the current attempt COUNTER (1-based). The schedule is:
#     counter=1: 1
#     counter=2: 1
#     counter=3: 2
#     counter=4: 4
#     counter=5: 8
#     counter=6: 16
#     counter>=7: 30 (capped)
#   With ±50% jitter for counter>=2 (so the actual sleep is in
#   [delay - delay/2, delay + delay/2], floor at 1).
#
#   The RANDOM expansion is busybox ash (the runtime we actually
#   use); POSIX sh does not define it, hence the SC3028 disable.
# ------------------------------------------------------------------------------
compute_backoff_seconds() {
  _cb_counter=$1
  case "${_cb_counter}" in
    1) _cb_delay=1 ;;
    2) _cb_delay=1 ;;
    3) _cb_delay=2 ;;
    4) _cb_delay=4 ;;
    5) _cb_delay=8 ;;
    6) _cb_delay=16 ;;
    *) _cb_delay=30 ;;
  esac
  if [ "${_cb_delay}" -gt 1 ]; then
    # shellcheck disable=SC3028  # RANDOM is a busybox ash extension (the shell we actually run in).
    _cb_jitter=$(( RANDOM % (_cb_delay + 1) - _cb_delay / 2 ))
    _cb_sleep=$(( _cb_delay + _cb_jitter ))
  else
    _cb_sleep="${_cb_delay}"
  fi
  [ "${_cb_sleep}" -lt 1 ] && _cb_sleep=1
  printf '%s' "${_cb_sleep}"
}

# ------------------------------------------------------------------------------
# run_lftp_once SERVER FTP_SETTINGS MIRROR LOCAL REMOTE LOG_FILE TIMEOUT KILL_AFTER
#   Run a single lftp invocation with the given parameters, capturing
#   combined stdout+stderr to LOG_FILE. The function returns lftp's
#   exit code via the function-return convention. The caller is
#   responsible for the retry loop, the timeout wrapper, and the
#   backoff between attempts.
#
#   This is the B-09 + B-05 plumbing: a hard global timeout around
#   lftp, and an explicit exit-code capture so the caller's
#   `set -e` does not short-circuit the failure banner.
#
#   IMPORTANT: this function does NOT re-enable `set -e` before
#   returning. If it did, a non-zero lftp exit would cause the
#   `return` itself to trigger errexit and abort the script. The
#   caller is expected to bracket the call with `set +e` / `set -e`
#   and capture the exit code into a variable, exactly as the
#   inline code did in pre-v2.5.0 init.sh.
# ------------------------------------------------------------------------------
run_lftp_once() {
  _rlo_server=$1
  _rlo_settings=$2
  _rlo_mirror=$3
  _rlo_local=$4
  _rlo_remote=$5
  _rlo_log=$6
  _rlo_timeout=$7
  _rlo_kill_after=$8

  # B-03: no -u USER,PASS — lftp reads credentials from ${NETRC}.
  # B-04: redirect combined stdout+stderr to the timestamped log file
  # so the captured output can be inspected after the fact and, if
  # the user wishes, attached as a workflow artifact.
  timeout -k "${_rlo_kill_after}" "${_rlo_timeout}" lftp \
    "${_rlo_server}" \
    -e "${_rlo_settings} ${_rlo_mirror} ${_rlo_local} ${_rlo_remote}; quit;" \
    > "${_rlo_log}" 2>&1
}

# ------------------------------------------------------------------------------
# print_resolved_config
#   Print the "Resolved configuration" group: directories, listing of
#   the local directory, and the computed FTP_SETTINGS / MIRROR_COMMAND
#   values. Reads the resolved state from the documented INPUT_*
#   variables (after they have been normalized by entrypoint.sh).
# ------------------------------------------------------------------------------
print_resolved_config() {
  printf '::group::Resolved configuration\n'
  echo "=== Directories ==="
  echo "INPUT_LOCAL_DIR: $(_indirection INPUT_LOCAL_DIR)"
  echo "INPUT_REMOTE_DIR: $(_indirection INPUT_REMOTE_DIR)"
  echo ""
  echo "=== List local directory ==="
  _prc_local=$(_indirection INPUT_LOCAL_DIR)
  echo "${_prc_local}"
  ls -lha "${_prc_local}"
  echo ""
  echo "=== LFTP Settings ==="
  echo " FTP_SETTINGS      -> $(_indirection FTP_SETTINGS)"
  echo " MIRROR_COMMAND    -> $(_indirection MIRROR_COMMAND)"
  echo " INPUT_LOCAL_DIR   -> $(_indirection INPUT_LOCAL_DIR)"
  echo " INPUT_REMOTE_DIR  -> $(_indirection INPUT_REMOTE_DIR)"
  echo " INPUT_MAX_RETRIES -> $(_indirection INPUT_MAX_RETRIES)"
  echo ""
  echo "=== * NOTE * ==="
  echo "The upload should be fast depends how many files and what size they have."
  echo "If the process take for several minutes or hours, please stop the job and run it again."
  printf '::endgroup::\n'
}

# ------------------------------------------------------------------------------
# print_failure_banner LFTP_RC PERMANENT_ERROR LOG_FILE TIMEOUT KILL_AFTER
#   Print the "ERROR: UPLOAD FAILED" banner, mention whether the
#   failure was classified as permanent, list common lftp exit codes
#   for debugging, and exit 1. The function does not return.
# ------------------------------------------------------------------------------
print_failure_banner() {
  _pfb_rc=$1
  _pfb_permanent=$2
  _pfb_log=$3
  _pfb_timeout=$4
  _pfb_kill_after=$5

  echo ""
  echo "=============================="
  echo "=    ERROR: UPLOAD FAILED    ="
  echo "=============================="
  if [ -n "${_pfb_permanent}" ]; then
    echo "Failure type: PERMANENT (no point retrying with the same inputs)."
    echo "Check credentials, the remote_dir path, and the FTP user's"
    echo "permissions; see the log file below for the server's message."
  fi
  if [ -n "${_pfb_rc}" ]; then
    echo "Last lftp exit code: ${_pfb_rc}"
    echo "Common codes:"
    echo "  1   lftp generic error"
    echo "  4    Fatal error (e.g. command-line usage, configuration)"
    echo "  124  timeout reached (max wall-clock ${_pfb_timeout})"
    echo "  137  process killed (SIGKILL after ${_pfb_kill_after} grace)"
  fi
  echo "Full lftp output: ${_pfb_log}"
  exit 1
}

# ------------------------------------------------------------------------------
# print_success_banner DRY_RUN
#   Print either the standard "FTP UPLOADED FINISHED!" banner or the
#   "FTP DRY RUN COMPLETED" variant.
# ------------------------------------------------------------------------------
print_success_banner() {
  _psb_dry_run=$1
  echo ""
  echo "=============================="
  if [ "${_psb_dry_run}" = "true" ]; then
    echo "=  FTP DRY RUN COMPLETED     ="
    echo "=  (no files transferred)    ="
  else
    echo "=   FTP UPLOADED FINISHED!   ="
  fi
  echo "=============================="
}
