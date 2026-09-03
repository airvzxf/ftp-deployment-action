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
    printf '  %-26s %s\n' "exclude:"                 "$(_indirection INPUT_EXCLUDE)"
    printf '  %-26s %s\n' "exclude_delete:"          "$(_indirection INPUT_EXCLUDE_DELETE)"
    printf '  %-26s %s\n' "debug:"                   "$(_indirection INPUT_DEBUG)"
    printf '  %-26s %s\n' "upload_log_on_failure:"   "$(_indirection INPUT_UPLOAD_LOG_ON_FAILURE)"
    printf '  %-26s %s\n' "concurrency_lock:"        "$(_indirection INPUT_CONCURRENCY_LOCK)"
    printf '  %-26s %s\n' "concurrency_lock_path:"   "$(_indirection INPUT_CONCURRENCY_LOCK_PATH)"
    printf '  %-26s %s\n' "concurrency_lock_timeout:"  "$(_indirection INPUT_CONCURRENCY_LOCK_TIMEOUT)"
    printf '  %-26s %s\n' "concurrency_lock_poll_interval:"  "$(_indirection INPUT_CONCURRENCY_LOCK_POLL_INTERVAL)"
  else
    for _pid_name in \
      SERVER USER PASSWORD LOCAL_DIR REMOTE_DIR MAX_RETRIES DELETE \
      NO_SYMLINKS MIRROR_VERBOSE FTP_SSL_ALLOW SSL_VERIFY_CERTIFICATE \
      SSL_CHECK_HOSTNAME FTP_PASSIVE_MODE FTP_USE_FEAT FTP_NOP_INTERVAL \
      NET_MAX_RETRIES NET_PERSIST_RETRIES NET_TIMEOUT DNS_MAX_RETRIES \
      DNS_FATAL_TIMEOUT LFTP_SETTINGS EXCLUDE EXCLUDE_DELETE DEBUG \
      FAIL_ON_DEPRECATED DRY_RUN UPLOAD_LOG_ON_FAILURE \
      CONCURRENCY_LOCK CONCURRENCY_LOCK_PATH CONCURRENCY_LOCK_TIMEOUT \
      CONCURRENCY_LOCK_POLL_INTERVAL; do
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
#   per INPUT_*, in a fixed order. Each entry in the positional
#   parameter list is a triple:
#     <lftp-key>  <default-value>  <INPUT_var_name>
#   The default applies when the INPUT is unset or empty. After the
#   11 standard settings, the function injects:
#
#     * `set mirror:exclude <value>;` if INPUT_EXCLUDE is non-empty
#       (files matching these globs are not uploaded and not deleted).
#     * `set mirror:exclude-file <value>;` if INPUT_EXCLUDE_DELETE is
#       non-empty (files matching these globs are protected from
#       `--delete` but are still uploaded).
#     * the free-form lftp_settings input (already validated upstream
#       by `validate_lftp_settings`) is appended verbatim with a
#       trailing semicolon. lftp processes `set` directives in order,
#       so the user can override the above via lftp_settings if
#       needed.
#
#   `set mirror:exclude-file <value>;` is NOT emitted as a plain
#   directive: lftp 4.9.x hides that variable behind the `set -a`
#   toggle (off by default; turns on "show all variables" so the
#   plain `set mirror:exclude-file ...` form is recognised). Toggling
#   `-a` on for the whole chain would also flip the auto-show for
#   every other directive and produce surprising side effects, so we
#   wrap the assignment in `set -a; ... ; set -a;` — on for the one
#   write, off again so the rest of the chain behaves normally. See
#   #131 (closes).
#
#   The "Remove leading space" trick at the end of the function
#   keeps the output clean when the first directive is preceded by
#   one of the extension blocks.
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
  # Pattern-exclusion inputs (exclude / exclude_delete). Only
  # emitted when non-empty so the bit-by-bit diff vs. v2.5.0 with
  # both inputs at default is a no-op.
  _bfs_exclude=$(_indirection "INPUT_EXCLUDE")
  if [ -n "${_bfs_exclude}" ]; then
    _bfs_settings="${_bfs_settings} set mirror:exclude ${_bfs_exclude};"
  fi
  _bfs_exclude_delete=$(_indirection "INPUT_EXCLUDE_DELETE")
  if [ -n "${_bfs_exclude_delete}" ]; then
    # lftp 4.9.x hides `mirror:exclude-file` behind the `set -a`
    # toggle. Toggle it on for this one write, then toggle it off so
    # the rest of the chain behaves normally. See #131.
    _bfs_settings="${_bfs_settings} set -a; set mirror:exclude-file ${_bfs_exclude_delete}; set -a;"
  fi
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
# build_lock_acquire_script
#   DEPRECATED in v2.9.0. Returns empty string unconditionally.
#
#   In v2.8.0 this function emitted the inline `repeat --until-ok
#   quote MKD ...` lftp script fragment that was concatenated into
#   the mirror's lftp `-e` command. In v2.9.0 the lock work moved
#   out of the mirror lftp invocation and into the shell-driven
#   `acquire_lock_with_recovery` helper, so the stale-lock auto-
#   recovery can do its LIST / parse / DELE / RMD sequence without
#   fighting lftp's flow-control primitives (the `repeat --until-ok`
#   retry loop has no clean way to branch into a stale-recovery
#   sub-flow on each MKD failure).
#
#   The function is kept as a no-op so entrypoint.sh (which assigns
#   its output to LOCK_ACQUIRE) does not need to change, and so the
#   unit tests can verify the deprecation cleanly.
#
#   Reads: INPUT_CONCURRENCY_LOCK (ignored; always empty).
# ------------------------------------------------------------------------------
build_lock_acquire_script() {
  return 0
}

# ------------------------------------------------------------------------------
# build_lock_release_script
#   DEPRECATED in v2.9.0. Returns empty string unconditionally.
#
#   In v2.8.0 this emitted `quote RMD <path>; ` to be appended to
#   the mirror's lftp `-e` command. In v2.9.0 the release moved to
#   `release_lock_safely` (best-effort standalone lftp invocation
#   from the EXIT trap), which also DELEs the sentinel file (a
#   sibling of the lock dir) — see acquire_lock_with_recovery.
#
#   Reads: INPUT_CONCURRENCY_LOCK (ignored; always empty).
# ------------------------------------------------------------------------------
build_lock_release_script() {
  return 0
}

# ------------------------------------------------------------------------------
# _lock_sentinel_name TIMESTAMP PID
#   Build the canonical sentinel filename for the lock. Format:
#
#     .lftp-deployment.lock.<TIMESTAMP>.<PID>.info
#
#   where TIMESTAMP is YYYYMMDDTHHMMSSZ (UTC, the format produced
#   by `date -u +%Y%m%dT%H%M%SZ`, sortable as a string) and PID is
#   the runner shell PID. The sentinel lives at the FTP root, as
#   a SIBLING of the lock dir, NOT inside it: that way the release
#   path can do `quote RMD <lock_dir>` without first having to
#   recursively clear its contents (FTP RMD on a non-empty dir
#   returns 550, and there is no portable recursive RMD).
#
#   Pure: no IO, no side effects.
# ------------------------------------------------------------------------------
_lock_sentinel_name() {
  printf '.lftp-deployment.lock.%s.%s.info' "$1" "$2"
}

# ------------------------------------------------------------------------------
# _lock_age_seconds STAMP_NOW STAMP_THEN
#   Return the age in seconds between STAMP_NOW and STAMP_THEN.
#   Both stamps must be YYYYMMDDTHHMMSSZ (the format from
#   `_lock_sentinel_name`). Uses POSIX awk `mktime`, which busybox
#   awk supports.
#
#   Pure: no IO, no side effects. Echoes an integer (possibly
#   negative if STAMP_THEN is in the future, which the caller
#   must check for).
# ------------------------------------------------------------------------------
_lock_age_seconds() {
  _las_now=$1
  _las_then=$2
  awk -v now="${_las_now}" -v then="${_las_then}" '
    BEGIN {
      n_y = substr(now,  1, 4); n_m  = substr(now,  5, 2); n_d  = substr(now,  7, 2)
      n_h = substr(now, 10, 2); n_mn = substr(now, 12, 2); n_s  = substr(now, 14, 2)
      t_y = substr(then,  1, 4); t_m  = substr(then,  5, 2); t_d  = substr(then,  7, 2)
      t_h = substr(then, 10, 2); t_mn = substr(then, 12, 2); t_s  = substr(then, 14, 2)
      n = mktime(n_y " " n_m " " n_d " " n_h " " n_mn " " n_s)
      t = mktime(t_y " " t_m " " t_d " " t_h " " t_mn " " t_s)
      print int(n - t)
    }
  '
}

# ------------------------------------------------------------------------------
# _lock_parse_sentinel_listing LISTING_TEXT
#   Given the captured stdout of `lftp ... -e 'cls -la .; quit;'`,
#   extract the FIRST filename matching the sentinel pattern
#   `.lftp-deployment.lock.<digits>.info`. Echoes the matching
#   filename (e.g. `.lftp-deployment.lock.20260707T080000Z.1234.info`)
#   on stdout, or empty if no sentinel exists.
#
#   Uses grep -E anchored to the line end so unrelated files (the
#   lock dir itself, user files) are ignored. The `head -1` keeps
#   the parser deterministic in the (rare) case where multiple
#   orphan sentinels exist on disk.
#
#   Pure: no IO, no FTP. Echoes the matched filename or "".
# ------------------------------------------------------------------------------
_lock_parse_sentinel_listing() {
  _lpsl_listing=$1
  printf '%s\n' "${_lpsl_listing}" \
    | grep -oE '\.lftp-deployment\.lock\.[0-9]{8}T[0-9]{6}Z\.[0-9]+\.info' \
    | head -1
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
# run_lftp_once SERVER FTP_SETTINGS MIRROR LOCAL REMOTE LOG_FILE TIMEOUT KILL_AFTER LOCK_ACQUIRE LOCK_RELEASE
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
#   LOCK_ACQUIRE is prepended to the mirror command, LOCK_RELEASE is
#   appended right before the final `; quit;`. Both are empty when
#   INPUT_CONCURRENCY_LOCK is not "true", in which case the script
#   is bit-for-bit identical to v2.7.0.
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
  _rlo_lock_acquire=$9
  _rlo_lock_release=${10}
  _rlo_user=${11}  # v2.11.0: optional. When non-empty AND the URL
                   # has no embedded user, we rewrite the URL to
                   # "scheme://user@host:port" so lftp's lookup against
                   # ~/.netrc (B-03) actually triggers. See
                   # tests/integration/scenarios/08-action-driven-upload.sh
                   # and #124 (closes lftp-by-design workaround).

  # v2.11.0: rewrite the URL when it has a scheme but no embedded user.
  # Without this, lftp 4.9.3 falls back to USER anonymous for
  # `ftp://host:port` URLs and never consults ~/.netrc — see #124 and
  # the upstream issue lavv17/lftp#372 (where lavv17 closed the
  # equivalent report as by-design). When the URL already has a user
  # ("scheme://user@host:..."), leave it as-is.
  _rlo_server_eff=${_rlo_server}
  if [ -n "${_rlo_user}" ]; then
    case ${_rlo_server_eff} in
      *://*@*) ;;                                                    # user already present; no-op
      *://*)   _rlo_server_eff="${_rlo_server_eff%%://*}://${_rlo_user}@${_rlo_server_eff#*://}" ;;
      *)       ;;                                                    # no scheme; lftp's open code already covers netrc lookup
    esac
  fi

  # B-03: no -u USER,PASS — lftp reads the password from ${NETRC}.
  # The user embedded in the URL above is what triggers lftp's
  # NetRC::LookupHost call (see commands.cc:1055 in upstream).
  # B-04: redirect combined stdout+stderr to the timestamped log file
  # so the captured output can be inspected after the fact and, if
  # the user wishes, attached as a workflow artifact.
  timeout -k "${_rlo_kill_after}" "${_rlo_timeout}" lftp \
    "${_rlo_server_eff}" \
    -e "${_rlo_settings} ${_rlo_lock_acquire}${_rlo_mirror} ${_rlo_local} ${_rlo_remote}; ${_rlo_lock_release}quit;" \
    > "${_rlo_log}" 2>&1
}

# ------------------------------------------------------------------------------
# acquire_lock_with_recovery SERVER LOCK_PATH TIMEOUT_SECS POLL_SECS
#   Acquire the server-side concurrency lock at LOCK_PATH on SERVER,
#   polling up to TIMEOUT_SECS (with POLL_SECS between attempts).
#   On a successful acquire, write a sentinel file at the FTP root
#   named `.lftp-deployment.lock.<TIMESTAMP>.<PID>.info` and store
#   the sentinel name in the global `ACQUIRED_LOCK_SENTINEL` so
#   `release_lock_safely` (and the EXIT trap) can clean it up.
#
#   Stale-lock recovery: on every MKD failure (550, lock held), the
#   function does a `quote LIST -la .` to look for a sentinel file
#   at the FTP root. If a sentinel exists and its embedded
#   timestamp is older than TIMEOUT_SECS, the function assumes the
#   previous holder died (OOM, SIGKILL, 6h job limit) and takes
#   over: DELE the stale sentinel + RMD the lock dir, then
#   immediately retry MKD (no sleep). If the sentinel is recent or
#   missing, the function sleeps POLL_SECS and tries again.
#
#   Returns 0 on a successful acquire, 1 if the timeout is
#   exhausted. The caller MUST have a writable ${NETRC} at $HOME
#   and MUST have `set -e` disabled around the call to this
#   function (or check the return value explicitly), because
#   intermediate lftp calls may legitimately fail (timeout=0 fast
#   path, transient network errors).
#
#   Reads: nothing. Reads $HOME for netrc discovery.
#   Writes: ACQUIRED_LOCK_SENTINEL global (on success).
# ------------------------------------------------------------------------------
acquire_lock_with_recovery() {
  _alwr_server=$1
  _alwr_path=$2
  _alwr_timeout=$3
  _alwr_poll=$4

  # Compute iteration count. timeout=0 means "no waiting, fail
  # immediately if the lock is held" -> count=1.
  if [ "${_alwr_timeout}" = "0" ]; then
    _alwr_count=1
  else
    _alwr_count=$(( (_alwr_timeout + _alwr_poll - 1) / _alwr_poll ))
  fi

  # Sentinel identity for THIS acquisition. Timestamp is captured
  # once per attempt-set; PID is the runner shell PID.
  _alwr_stamp=$(date -u +%Y%m%dT%H%M%SZ)
  _alwr_pid=$$
  _alwr_sentinel=$(_lock_sentinel_name "${_alwr_stamp}" "${_alwr_pid}")

  # Inline lftp preamble: tighten reconnect intervals so a
  # misconfigured server URL (refused connection, DNS failure) does
  # not stall the action for lftp's default 15s-5min retry window.
  # We use a sibling sentinel-style preamble that the main
  # FTP_SETTINGS does not include (those are tuned for the mirror
  # itself, which the user might WANT to ride out transient
  # issues).
  _alwr_preamble="set net:max-retries 1; set net:reconnect-interval-base 1; set net:reconnect-interval-max 1; set net:timeout 5; set dns:max-retries 1; set dns:fatal-timeout 5;"

  _alwr_attempt=0
  while [ "${_alwr_attempt}" -lt "${_alwr_count}" ]; do
    _alwr_attempt=$((_alwr_attempt + 1))

    # Step 1: try MKD. We use lftp's high-level `mkdir` command
    # rather than the raw `quote MKD` because lftp 4.9.x does not
    # propagate a 5xx reply from a `quote` meta-command into lftp's
    # exit code (the controller just reads the line and moves on),
    # so the script would never see a held lock as a failure and
    # would happily spin forever. `mkdir` is the documented lftp
    # command for the MKD FTP verb and does propagate 5xx replies.
    # `set +e` because MKD on a held lock returns 550, which is
    # the common case (not an error).
    set +e
    timeout 30s lftp "${_alwr_server}" \
      -e "${_alwr_preamble} mkdir ${_alwr_path}; quit;" \
      >/dev/null 2>&1
    _alwr_mkd_rc=$?
    set -e

    if [ "${_alwr_mkd_rc}" -eq 0 ]; then
      # Got the lock. Write the sentinel so the next runner can
      # tell whether we died mid-mirror. The sentinel content is
      # not parsed (we use the FILENAME timestamp); we keep the
      # body for human debugging via FTP `cat`.
      _alwr_sentinel_body=$(mktemp 2>/dev/null) || _alwr_sentinel_body="/tmp/.lftp-lock-body.$$"
      {
        printf 'pid=%s\n' "${_alwr_pid}"
        printf 'started_at=%s\n' "${_alwr_stamp}"
        printf 'host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
      } > "${_alwr_sentinel_body}"
      set +e
      timeout 30s lftp "${_alwr_server}" \
        -e "${_alwr_preamble} put ${_alwr_sentinel_body} -o ${_alwr_sentinel}; quit;" \
        >/dev/null 2>&1
      set -e
      rm -f "${_alwr_sentinel_body}"

      # Publish sentinel name for release_lock_safely.
      ACQUIRED_LOCK_SENTINEL=${_alwr_sentinel}
      return 0
    fi

    # Step 2: MKD failed (550 = held, or connection refused).
    # Probe for a stale sentinel. We list the FTP root and grep
    # for the sentinel pattern; if the timestamp in the filename
    # is older than TIMEOUT_SECS, we take over.
    # Use lftp's high-level `cls` (alias for `ls`) rather than the
    # raw `quote LIST` because vsftpd requires the data connection
    # (PASV/PORT) to be negotiated before answering LIST, and the
    # raw quote does not negotiate PASV — vsftpd replies `425 Use
    # PORT or PASV first` and we get an empty listing. `cls` opens
    # PASV automatically and returns a usable directory listing.
    set +e
    _alwr_listing=$(timeout 10s lftp "${_alwr_server}" \
      -e "${_alwr_preamble} cls -la .; quit;" \
      2>/dev/null)
    set -e

    _alwr_stale_file=$(_lock_parse_sentinel_listing "${_alwr_listing}")
    _alwr_took_over=1
    if [ -n "${_alwr_stale_file}" ]; then
      _alwr_stale_stamp=$(printf '%s' "${_alwr_stale_file}" \
        | sed -nE 's|^\.lftp-deployment\.lock\.([0-9TZ]+)\..*\.info$|\1|p')
      if [ -n "${_alwr_stale_stamp}" ]; then
        _alwr_now=$(date -u +%Y%m%dT%H%M%SZ)
        _alwr_age=$(_lock_age_seconds "${_alwr_now}" "${_alwr_stale_stamp}")
        # `<= timeout` (not `<`) — the timeout represents the maximum
        # age at which we still consider the sentinel recent, so a
        # sentinel whose age is exactly `timeout` is at the boundary
        # and must still be respected. Using `<` here would make
        # the comparison racy when `_alwr_now` and the sentinel's
        # timestamp straddle a second boundary (test #19 catches
        # this: a sentinel stamped at "now" but observed one
        # second later would have age=1 vs timeout=1 and be
        # mis-classified as stale, triggering an unwanted DELE/RMD).
        if [ "${_alwr_age}" -le "${_alwr_timeout}" ]; then
          # Recent — legitimate holder, do not touch it.
          _alwr_took_over=0
        fi
      fi
    fi
    # An empty or missing sentinel also counts as "stale" (the
    # _alwr_took_over=1 default applies). This covers the race
    # where the previous holder died between MKD and PUT.

    if [ "${_alwr_took_over}" -eq 1 ]; then
      # Stale (or empty). Take over: DELE the stale sentinel
      # (best-effort, may not exist), RMD the lock dir, and
      # IMMEDIATELY retry MKD without sleeping. We do not count
      # this retry against the timeout because we've already
      # waited; the next MKD attempt's MKD delay (if any) is the
      # only thing on the critical path.
      set +e
      if [ -n "${_alwr_stale_file}" ]; then
        timeout 10s lftp "${_alwr_server}" \
          -e "${_alwr_preamble} quote DELE ${_alwr_stale_file}; quit;" \
          >/dev/null 2>&1
      fi
      timeout 10s lftp "${_alwr_server}" \
        -e "${_alwr_preamble} quote RMD ${_alwr_path}; quit;" \
        >/dev/null 2>&1
      set -e
      continue
    fi

    # Lock is legitimately held. Wait and retry.
    sleep "${_alwr_poll}"
  done

  return 1
}

# ------------------------------------------------------------------------------
# release_lock_safely SERVER LOCK_PATH [SENTINEL]
#   Best-effort release of the server-side concurrency lock:
#   DELE the sentinel file (if SENTINEL is provided or
#   $ACQUIRED_LOCK_SENTINEL is set), then RMD the lock dir. All
#   failures are silently swallowed because the caller is
#   typically on the way out (EXIT trap); the whole point of
#   release is to fail soft.
#
#   SERVER: lftp server URL (e.g. ftp://host).
#   LOCK_PATH: the lock dir on the FTP server (e.g. .lftp-deployment.lock).
#   SENTINEL: (optional) the sentinel filename to DELE first. Falls
#             back to $ACQUIRED_LOCK_SENTINEL. If neither is set,
#             we skip the DELE (the lock dir alone is still RMDed
#             — covers the case where the previous holder died
#             before writing the sentinel).
#
#   Always returns 0.
# ------------------------------------------------------------------------------
release_lock_safely() {
  _rls_server=$1
  _rls_path=$2
  _rls_sentinel=${3:-${ACQUIRED_LOCK_SENTINEL:-}}

  if [ -z "${_rls_path}" ]; then
    return 0
  fi

  # Same tightened reconnect preamble as acquire_lock_with_recovery:
  # a misconfigured server should not stall the EXIT trap for
  # 15s-5min of reconnect attempts.
  _rls_preamble="set net:max-retries 1; set net:reconnect-interval-base 1; set net:reconnect-interval-max 1; set net:timeout 5; set dns:max-retries 1; set dns:fatal-timeout 5;"

  set +e
  if [ -n "${_rls_sentinel}" ]; then
    timeout 30s lftp "${_rls_server}" \
      -e "${_rls_preamble} quote DELE ${_rls_sentinel}; quote RMD ${_rls_path}; quit;" \
      >/dev/null 2>&1
  else
    timeout 30s lftp "${_rls_server}" \
      -e "${_rls_preamble} quote RMD ${_rls_path}; quit;" \
      >/dev/null 2>&1
  fi
  set -e
  return 0
}

# ------------------------------------------------------------------------------
# run_lftp_lock_release SERVER NETRC_PATH LOCK_PATH [SENTINEL]
#   Backward-compatibility shim. Used by the EXIT trap in
#   entrypoint.sh to release the server-side concurrency lock if
#   the main pipeline was killed before reaching the explicit
#   release_lock_safely call (signal, OOM, hard timeout).
#
#   When the lock is disabled (LOCK_PATH empty) or the netrc file
#   is missing (the EXIT trap may run after the netrc was already
#   removed), this function is a no-op. Otherwise it delegates to
#   release_lock_safely with the optional SENTINEL argument.
#
#   Failures are silently swallowed because at this point the
#   script is already on the way out; we do not want the cleanup
#   itself to print spurious noise. Logs to /dev/null.
# ------------------------------------------------------------------------------
run_lftp_lock_release() {
  _rlr_server=$1
  _rlr_netrc=$2
  _rlr_lock_path=$3
  _rlr_sentinel=${4:-}

  if [ -z "${_rlr_lock_path}" ]; then
    return 0
  fi
  if [ ! -f "${_rlr_netrc}" ]; then
    return 0
  fi

  release_lock_safely "${_rlr_server}" "${_rlr_lock_path}" "${_rlr_sentinel}"
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

# ------------------------------------------------------------------------------
# upload_log_artifact LOG_FILE
#   If INPUT_UPLOAD_LOG_ON_FAILURE=true AND every GitHub-Actions env
#   var required for the artifact upload API is set
#   (GITHUB_API_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID,
#   GITHUB_RUN_ATTEMPT, GITHUB_TOKEN), POST LOG_FILE to the workflow
#   run as an artifact named "ftp-deployment-action-log-<run-attempt>"
#   with a 90-day retention. Otherwise, skip with a notice.
#
#   The function never aborts the parent: any failure (missing env,
#   missing log file, curl error, HTTP 4xx/5xx) is logged as a warning
#   and the function returns 0. The action's own exit code is
#   unaffected.
#
#   The env-var lookup uses `_indirection` (no second `eval` site) so
#   the project-wide "single point of dynamic variable-name lookup"
#   rule is preserved.
#
#   API endpoint:
#     POST ${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/artifacts
#   Body: multipart/form-data with
#     - name            "ftp-deployment-action-log-<attempt>"
#     - retention_days  90 (max allowed by the public API)
#     - artifact_file   <LOG_FILE>  (filename = basename of LOG_FILE,
#                                   content-type text/plain)
#
#   curl's -F flag builds the multipart envelope automatically. The
#   Authorization header carries the token; it is never interpolated
#   into the URL, so the token does not leak into the runner log
#   even if -v were used.
# ------------------------------------------------------------------------------
upload_log_artifact() {
  _ula_log=$1

  # 1. Opt-in switch.
  if [ "$(_indirection INPUT_UPLOAD_LOG_ON_FAILURE)" != "true" ]; then
    return 0
  fi

  # 2. Required GitHub-Actions env vars. Iterate over a known list
  #    of literal names and use _indirection for the lookup; never
  #    introduce a second `eval` site.
  for _ula_var in GITHUB_API_URL GITHUB_REPOSITORY GITHUB_RUN_ID \
                  GITHUB_RUN_ATTEMPT GITHUB_TOKEN; do
    if [ -z "$(_indirection "${_ula_var}")" ]; then
      printf '  skip: not uploading log; %s is not set in the step env.\n' "${_ula_var}" >&2
      printf '  hint: add GITHUB_TOKEN to the step env: ' >&2
      # shellcheck disable=SC2016  # intentional literal ${{ ... }} for the user to copy
      printf 'env: GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}\n' >&2
      return 0
    fi
  done

  # 3. Log file must exist (the lftp loop always creates it, but a
  #    failure before the loop would skip this).
  if [ ! -f "${_ula_log}" ]; then
    printf '  skip: not uploading log; %s does not exist.\n' "${_ula_log}" >&2
    return 0
  fi

  _ula_api_url=$(_indirection GITHUB_API_URL)
  _ula_repo=$(_indirection GITHUB_REPOSITORY)
  _ula_run_id=$(_indirection GITHUB_RUN_ID)
  _ula_attempt=$(_indirection GITHUB_RUN_ATTEMPT)
  _ula_token=$(_indirection GITHUB_TOKEN)

  _ula_name="ftp-deployment-action-log-${_ula_attempt}"
  _ula_url="${_ula_api_url}/repos/${_ula_repo}/actions/runs/${_ula_run_id}/artifacts"
  _ula_filename=$(basename "${_ula_log}")

  printf '  uploading log %s to %s as "%s" (90-day retention) ...\n' \
    "${_ula_log}" "${_ula_url}" "${_ula_name}" >&2

  # 4. The actual upload. set +e / set -e bracketing, same pattern as
  #    run_lftp_once, so a curl non-zero exit does not trip errexit
  #    and abort the script before we can print a warning.
  set +e
  curl -fsSL \
    -X POST \
    -H "Authorization: Bearer ${_ula_token}" \
    -H "Accept: application/vnd.github+json" \
    -F "name=${_ula_name}" \
    -F "retention_days=90" \
    -F "artifact_file=@${_ula_log};filename=${_ula_filename};type=text/plain" \
    "${_ula_url}" >/dev/null
  _ula_rc=$?
  set -e

  if [ "${_ula_rc}" -ne 0 ]; then
    printf '  WARNING: failed to upload log artifact (curl exit %s); ' \
      "${_ula_rc}" >&2
    printf 'continuing to the failure banner.\n' >&2
    return 0
  fi
  printf '  ok: log uploaded as artifact "%s"\n' "${_ula_name}" >&2
}
