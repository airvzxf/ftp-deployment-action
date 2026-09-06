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
#
#   v2.11.3.1 (post-release F2 audit): the previous implementation
#   piped through `grep -qE '^[0-9]+$'`, which matches per LINE —
#   a value like `"2\n!cmd"` satisfied `^[0-9]+$` on the first line
#   and slipped past validation. Since every validate_int input
#   flows verbatim into the `lftp -e` script body (via
#   build_ftp_settings' `set <key> <value>;` and build_mirror_command's
#   `--verbose=`), a newline would start a new lftp command line and
#   `!` would invoke the lftp shell-escape. Same RCE class as
#   #171 / #172. Use a POSIX case-pattern instead so the entire
#   string is checked, including any embedded newlines.
# ------------------------------------------------------------------------------
validate_int() {
  _vi_name=$1
  _vi_value=$2
  case "${_vi_value}" in
    ''|*[!0-9]*|0[0-9]*)
      printf 'ERROR: %s must be a non-negative integer without leading zeros (got: %s)\n' \
        "${_vi_name}" "${_vi_value}" >&2
      exit 2
      ;;
  esac
}

# ------------------------------------------------------------------------------
# validate_bool NAME VALUE
#   Exit 2 if VALUE is not a recognised boolean. v2.11.3 (#171):
#   the 7 boolean inputs (`ftp_ssl_allow`, `ssl_verify_certificate`,
#   `ssl_check_hostname`, `ftp_passive_mode`, `ftp_use_feat`,
#   plus the two duration inputs handled by validate_duration)
#   flow verbatim into `build_ftp_settings` -> `lftp -e "set <key>
#   <value>;"`. A malicious value containing `;` or `!` would let
#   the workflow author escape into lftp's command parser and
#   execute arbitrary commands as the `lftp` user (RCE — direct
#   read of /home/lftp/.netrc before the cleanup trap fires).
#
#   Accepted values match lftp's own canonical set: true, false,
#   yes, no, on, off, 1, 0, plus the empty string (the action.yml
#   default applies when the input is unset/empty). Any other
#   value exits 2 before lftp is reached.
# ------------------------------------------------------------------------------
validate_bool() {
  _vb_name=$1
  _vb_value=$2
  case "${_vb_value}" in
    true|false|yes|no|on|off|0|1|"") return 0 ;;
    *)
      printf 'ERROR: %s must be a bool (true|false|yes|no|on|off|0|1) (got: %s)\n' \
        "${_vb_name}" "${_vb_value}" >&2
      exit 2
      ;;
  esac
}

# ------------------------------------------------------------------------------
# normalize_bool NAME VALUE
#   Echo the canonical lftp-style "true" or "false" for VALUE, after
#   validating it through `validate_bool`. Used for the GATE inputs
#   (`delete`, `no_symlinks`, `dry_run`, `upload_log_on_failure`,
#   `concurrency_lock`, plus `debug` and `fail_on_deprecated`) which
#   the script compares with a literal `[ ... = "true" ]` to decide
#   whether to append a flag / take a branch.
#
#   Without this, a workflow author who writes `concurrency_lock: yes`
#   or `dry_run: True` is silently off — the gate falls through to the
#   "false" branch because `= "true"` rejects every alias. With this,
#   the aliases map to "true" / "false" the same way lftp's own
#   toggle parser would, and the literal compare keeps working.
#
#   Empty string maps to "false" so the action.yml default applies
#   even when entrypoint.sh is invoked outside GH Actions
#   (smoke tests, manual docker run). Matches the documented
#   default of every gate input that defaults to "false".
#
#   Calls validate_bool NAME VALUE first, so any value outside the
#   canonical lftp set (RCE payload, typo, capitalised variant)
#   exits 2 BEFORE the gate fires.
# ------------------------------------------------------------------------------
normalize_bool() {
  _nb_name=$1
  _nb_value=$2
  validate_bool "${_nb_name}" "${_nb_value}"
  case "${_nb_value}" in
    true|yes|on|1) printf '%s' "true" ;;
    *)             printf '%s' "false" ;;
  esac
}

# ------------------------------------------------------------------------------
# validate_duration NAME VALUE
#   Exit 2 if VALUE is not a recognised lftp duration. v2.11.3
#   (#171): `net_timeout` and `dns_fatal_timeout` flow verbatim
#   into `build_ftp_settings` -> `lftp -e "set <key> <value>;"`.
#
#   Accepted shapes:
#     * empty string — the action.yml default applies
#     * "never"      — lftp's documented sentinel that disables
#                       the timeout (see action.yml::dns_fatal_timeout)
#     * a positive integer optionally followed by one of
#       s|m|h|d|S|M|H|D (seconds, minutes, hours, days; case-
#       insensitive to match lftp's own parser)
#
#   Examples accepted: 15, 15s, 5m, 1h, 2d, 30S, 5M, never
#   Examples rejected: 15; !cmd, 1abc, 1.5, -1, true, 15s!cmd
# ------------------------------------------------------------------------------
validate_duration() {
  _vd_name=$1
  _vd_value=$2
  _vd_invalid=0
  case "${_vd_value}" in
    "")
      return 0
      ;;
    never)
      return 0
      ;;
    *[!0-9smhdSMHD]*)
      _vd_invalid=1
      ;;
  esac

  # The allow-list above is necessary but not sufficient: it also admits
  # unit-only and repeated-unit values such as "s", "mhd", and "5s5m".
  # Strip one optional suffix, then require the remainder to be digits.
  if [ "${_vd_invalid}" -eq 0 ]; then
    case "${_vd_value}" in
      *[smhdSMHD]) _vd_digits=${_vd_value%?} ;;
      *) _vd_digits=${_vd_value} ;;
    esac
    case "${_vd_digits}" in
      ''|*[!0-9]*) _vd_invalid=1 ;;
    esac
  fi

  if [ "${_vd_invalid}" -ne 0 ]; then
    printf 'ERROR: %s must be a duration (digits or digits+[smhd], or "never") (got: %s)\n' \
      "${_vd_name}" "${_vd_value}" >&2
    exit 2
  fi
}

# ------------------------------------------------------------------------------
# validate_glob_pattern NAME VALUE
#   Light validation for inputs that flow into lftp's `mirror -x`
#   / `mirror -X` command line (the regex/glob exclude inputs). v2.11.3
#   (#160): those inputs were being validated by validate_lftp_settings
#   since v2.11.2, which rejects `!`, backtick, `$`, and limits `;` to
#   3. v2.11.3 closed #160 by switching to a lighter validator.
#
#   v2.11.3.1 (post-release F2 audit): the original #160 docstring
#   claimed the value is "a single argv slot to `mirror`, never
#   parsed by a shell". That premise is FALSE — `build_mirror_command`
#   concatenates the value unquoted into MIRROR_COMMAND (lib.sh:546,
#   lib.sh:557), and `run_lftp_once` then concatenates MIRROR_COMMAND
#   into the `lftp -e` script body (lib.sh:919). lftp 4.9.3's `-e`
#   parser treats `;`, `&`, `|` as command separators even when they
#   appear mid-token (verified with `lftp -e '... -x foo;echo X;...'`).
#   Re-introduce the command-separator rejection. `!`, backtick, `$`,
#   `"` remain allowed because they are valid PatternSet / regex
#   metacharacters that lftp's glob / regex parser handles without
#   command-separator semantics.
# ------------------------------------------------------------------------------
validate_glob_pattern() {
  _vgp_name=$1
  _vgp_value=$2
  # Newline check via case (grep [[:cntrl:]] never matches \n).
  # The case pattern below embeds a literal LF; this is portable
  # POSIX and avoids the shellcheck SC3003 (bash-only $'\n')
  # warning that the runtime (busybox ash) does not understand.
  case "${_vgp_value}" in
    *"
"*)
      printf 'ERROR: %s contains newline: %s\n' "${_vgp_name}" "${_vgp_value}" >&2
      exit 2
      ;;
  esac
  if printf '%s' "${_vgp_value}" | grep -qE '[[:cntrl:]]'; then
    printf 'ERROR: %s contains control characters\n' "${_vgp_name}" >&2
    exit 2
  fi
  case "${_vgp_value}" in
    -*)
      printf 'ERROR: %s starts with a dash (would be misread as mirror option)\n' \
        "${_vgp_name}" >&2
      exit 2
      ;;
    *';'*|*'&'*|*'|'*|*'"'*)
      printf 'ERROR: %s contains lftp command separator (; & |) or double-quote: %s\n' \
        "${_vgp_name}" "${_vgp_value}" >&2
      exit 2
      ;;
  esac
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
#
#   v2.11.3 (#172): also reject double-quote and "!". The double-quote
#   breaks lftp's `-e` command parser (the script is a single shell
#   double-quoted argument to lftp; an embedded `"` closes the
#   lftp-internal string delimiter, allowing an attacker to inject
#   further lftp commands). The "!" is lftp's shell-escape (runs an
#   arbitrary command inside the container as the lftp user — direct
#   path to reading /home/lftp/.netrc before the cleanup trap fires).
#   The previous deny-list omitted "!" (a regression from the pre-v2.5.0
#   validator that the v2.11.2 audit surfaced).
# ------------------------------------------------------------------------------
validate_path() {
  _vp_name=$1
  _vp_value=$2
  # v2.11.3 (#172): check for double-quote BEFORE the generic
  # shell-metacharacter branch below, so the error message points
  # at the actual problem. `"` is also a shell metacharacter
  # but its exploit class (lftp `-e` parser injection) is distinct
  # from `;|&``` (shell command chaining).
  case "${_vp_value}" in
    *'"'*)
      printf 'ERROR: %s contains double-quote (breaks lftp command parsing): %s\n' \
        "${_vp_name}" "${_vp_value}" >&2
      exit 2
      ;;
  esac
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
  # v2.11.3.1 (post-release F2 audit): grep's POSIX [[:cntrl:]]
  # never matches \n (grep splits on \n before matching), so an
  # embedded newline bypassed the deny-list. Use a case pattern
  # with an embedded literal LF (POSIX-portable; busybox ash
  # handles this fine and shellcheck flags $'\n' as a bashism).
  case "${_vp_value}" in
    *"
"*)
      printf 'ERROR: %s contains newline: %s\n' "${_vp_name}" "${_vp_value}" >&2
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
  # v2.11.3 (#172): reject "!" (lftp shell escape). The double-quote
  # branch is above (must run before the generic shell-metacharacter
  # branch so the error message is precise).
  case "${_vp_value}" in
    *'!'*)
      printf 'ERROR: %s contains "!" (lftp shell escape): %s\n' \
        "${_vp_name}" "${_vp_value}" >&2
      exit 2
      ;;
  esac
  # v2.11.8 (#174): reject ASCII space. Must come AFTER the `!`
  # check so a combined input like `foo!cat /etc/passwd` surfaces
  # the more-precise "!" lftp-shell-escape error first. server-dir
  # / remote_dir / local_dir values are interpolated into the
  # `lftp -e` script body (see run_lftp_once at lib.sh:~1031) where
  # lftp 4.9.3 tokenises on whitespace; a value like "/my
  # data/site/" splits into `cd /my` + leftover `data/site/`,
  # silently breaking the action. Tests in tests/integration/ all
  # use space-free paths, so this is a strict-improvement error
  # class (loud failure beats silent breakage).
  case "${_vp_value}" in
    *' '*)
      printf 'ERROR: %s contains space (breaks lftp -e token parsing): %s\n' \
        "${_vp_name}" "${_vp_value}" >&2
      exit 2
      ;;
  esac
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
  # v2.11.3.1: newline check before the grep-based ctrl check
  # (grep [[:cntrl:]] does not match \n).
  case "${_vls_value}" in
    *"
"*)
      printf 'ERROR: lftp_settings contains newline\n' >&2
      exit 2
      ;;
  esac
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
    # v2.11.8 (#181): order matches action.yml's `inputs:` block so a
    # side-by-side diff of the dump against the schema is clean. Also
    # adds the two entries the previous printf block was silently
    # missing: `fail_on_deprecated` and `dry_run` (29 entries vs the
    # 31 declared inputs). The DEBUG=false branch already iterated
    # all 31 names correctly.
    printf '  %-26s %s\n' "server:"                  "$(_indirection INPUT_SERVER)"
    printf '  %-26s %s\n' "user:"                    "$(_indirection INPUT_USER)"
    printf '  %-26s %s\n' "password:"                "$(_indirection INPUT_PASSWORD)"
    printf '  %-26s %s\n' "local_dir:"               "$(_indirection INPUT_LOCAL_DIR)"
    printf '  %-26s %s\n' "remote_dir:"              "$(_indirection INPUT_REMOTE_DIR)"
    printf '  %-26s %s\n' "delete:"                  "$(_indirection INPUT_DELETE)"
    printf '  %-26s %s\n' "max_retries:"             "$(_indirection INPUT_MAX_RETRIES)"
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
    printf '  %-26s %s\n' "fail_on_deprecated:"      "$(_indirection INPUT_FAIL_ON_DEPRECATED)"
    printf '  %-26s %s\n' "dry_run:"                 "$(_indirection INPUT_DRY_RUN)"
    printf '  %-26s %s\n' "upload_log_on_failure:"   "$(_indirection INPUT_UPLOAD_LOG_ON_FAILURE)"
    printf '  %-26s %s\n' "concurrency_lock:"        "$(_indirection INPUT_CONCURRENCY_LOCK)"
    printf '  %-26s %s\n' "concurrency_lock_path:"   "$(_indirection INPUT_CONCURRENCY_LOCK_PATH)"
    printf '  %-26s %s\n' "concurrency_lock_timeout:"  "$(_indirection INPUT_CONCURRENCY_LOCK_TIMEOUT)"
    printf '  %-26s %s\n' "concurrency_lock_poll_interval:"  "$(_indirection INPUT_CONCURRENCY_LOCK_POLL_INTERVAL)"
  else
    # v2.11.8 (#181): swap MAX_RETRIES <-> DELETE to match action.yml
    # declaration order. Loop already iterates all 31 names.
    for _pid_name in \
      SERVER USER PASSWORD LOCAL_DIR REMOTE_DIR DELETE MAX_RETRIES \
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
#   The default applies when the INPUT is unset or empty.
#
#   v2.11.2: INPUT_EXCLUDE / INPUT_EXCLUDE_DELETE are NO LONGER
#   emitted here. The pre-fix code emitted `set mirror:exclude` /
#   `set mirror:exclude-file` directives, but neither variable
#   is actually queried by lftp 4.9.3's MirrorJob when the mirror
#   command runs (MirrorJob::AddPattern only consults
#   `mirror:exclude-regex` as a *default* when the user passes
#   `mirror -x`; a bare `set mirror:exclude-file` is a silent
#   no-op). The v2.11.2 fix moves the exclude values onto the
#   mirror command line itself (see build_mirror_command below,
#   which appends `-x <regex>` / `-X <glob>` based on the same
#   inputs). The action's behaviour-preserving contract for the
#   default case (both inputs empty -> no `set` or `-x`/`-X`
#   emitted) is preserved. See #131, #167.
#
#   The function still emits:
#     * the 11 standard `set <lftp-key> <value>;` directives for
#       ftp:* / ssl:* / net:* / dns:*
#     * the free-form lftp_settings input (already validated
#       upstream by `validate_lftp_settings`) is appended verbatim
#       with a trailing semicolon.
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
  # v2.11.2: INPUT_EXCLUDE / INPUT_EXCLUDE_DELETE removed from
  # this function (no-op directives, see comment above). They are
  # now applied via `mirror -x` / `mirror -X` in build_mirror_command.
  # Any manual settings (B-16, already validated).
  _bfs_extra=$(_indirection "INPUT_LFTP_SETTINGS")
  if [ -n "${_bfs_extra}" ]; then
    _bfs_settings="${_bfs_settings} ${_bfs_extra};"
  fi
  # v2.11.8 (#258): the previous code stripped a leading whitespace
  # block here. _bfs_settings always starts with `set ftp:ssl-allow`
  # (the first iteration of the while loop above unconditionally
  # appends `set ... ;`); the leading character is `s`, never
  # whitespace. When _bfs_settings is empty, the [ -n ... ] guard
  # skipped the strip too. So the strip never had anything to
  # remove. tests/unit/parse.bats:119-131 asserts the first
  # character is `s`, which mechanically proves this.
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

  # v2.11.2: INPUT_EXCLUDE / INPUT_EXCLUDE_DELETE. lftp's `mirror`
  # command takes `-x <regex>` to exclude files matching a POSIX
  # regex. The pre-fix code emitted `set mirror:exclude-regex ...`
  # into FTP_SETTINGS, but that variable is only consulted by lftp
  # when `mirror -x` is also given — a `set` alone is a silent
  # no-op in lftp 4.9.3. So the action's INPUT_EXCLUDE /
  # INPUT_EXCLUDE_DELETE inputs have been broken since v2.5.0.
  # The fix moves the exclude values onto the mirror command line
  # itself, which is what actually applies them. See #131, #167.
  #
  # INPUT_EXCLUDE -> `mirror -x <regex>` (POSIX ERE, NOT a shell
  # glob). Users who currently pass `*.bak` etc. will need to
  # convert to `.*\.bak` (documented in CHANGELOG and the
  # action.yml input descriptions below).
  _bmc_exclude=$(_indirection "INPUT_EXCLUDE")
  if [ -n "${_bmc_exclude}" ]; then
    _bmc_command="${_bmc_command} -x ${_bmc_exclude}"
  fi

  # INPUT_EXCLUDE_DELETE -> `mirror -X <glob>` (POSIX glob syntax,
  # lftp's PatternSet::Glob). The action surface keeps the
  # INPUT_EXCLUDE vs INPUT_EXCLUDE_DELETE naming for API stability,
  # but lftp 4.9.3's `-X` flag applies the pattern to BOTH upload
  # and delete operations (same as `-x`) — there is no separate
  # delete-only-exclude variable in lftp 4.9.3.
  _bmc_exclude_delete=$(_indirection "INPUT_EXCLUDE_DELETE")
  if [ -n "${_bmc_exclude_delete}" ]; then
    _bmc_command="${_bmc_command} -X ${_bmc_exclude_delete}"
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
      # POSIX mawk/gawk mktime returns -1 on parse failure (e.g.
      # sentinel file with a syntactically-valid but calendrically-
      # invalid timestamp like month=13). Without this check, the
      # caller would see `int(n - t) = -1` and treat the sentinel
      # as "infinitely old" -> take over the lock on stale data.
      # Exit 1 lets the caller classify the age as "indeterminate"
      # and treat the lock as held (F2 audit, NEW).
      if (n == -1 || t == -1) {
        exit 1
      }
      print int(n - t)
    }
  '
}

# ------------------------------------------------------------------------------
# _lock_parse_sentinel_listing LISTING_TEXT
#   Given the captured stdout of `lftp ... -e 'cls -la .; quit;'`,
#   extract every filename matching the sentinel pattern
#   `.lftp-deployment.lock.<digits>.info`. Echoes one name per
#   line on stdout, sorted ascending by stamp (so the OLDEST
#   sentinel is the first line), or empty if no sentinel exists.
#
#   Uses grep -E anchored to the line end so unrelated files (the
#   lock dir itself, user files) are ignored. F2 audit (#173):
#   the previous `head -1` discarded every orphan past the first
#   and let stale sentinels accumulate on the FTP server. The
#   recovery branch in acquire_lock_with_recovery now iterates
#   every emitted name and DELEs each one.
#
#   Pure: no IO, no FTP. Echoes the matched filenames or "".
# ------------------------------------------------------------------------------
_lock_parse_sentinel_listing() {
  _lpsl_listing=$1
  printf '%s\n' "${_lpsl_listing}" \
    | grep -oE '\.lftp-deployment\.lock\.[0-9]{8}T[0-9]{6}Z\.[0-9]+\.info' \
    | sort
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
#     ftp://host?token=abc             -> host   (v2.11.8, #185)
#     ftp://host#frag                  -> host   (v2.11.8, #185)
#     host                             -> host  (no scheme)
# ------------------------------------------------------------------------------
extract_netrc_host() {
  _enh_value=$1
  _enh_value=$(printf '%s' "${_enh_value}" \
    | sed -E 's|^[a-zA-Z]+://||' \
    | sed -E 's|^[^@/]*@||' \
    | sed -E 's|[?#].*||')
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
#   v2.11.8 (#179): jitter uses POSIX `awk` rather than the
#   busybox-ash `$RANDOM` extension. On a strict POSIX /bin/sh
#   (e.g. dash on Debian), `$RANDOM` is unset and the jitter
#   collapses to zero, defeating the backoff. busybox awk is on
#   the alpine runtime and on every CI test runner; the same
#   pattern is already idiomatic in tests/integration/lib/common.sh
#   for synthetic-port generation.
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
    # _cb_delay+1 makes the divisor odd, which is what produces the
    # perfectly symmetric [-d/2, +d/2] range for every even delay
    # (verified by tests/unit/retry.bats). jitter in [-d/2, +d/2].
    _cb_jitter=$(awk -v n="${_cb_delay}" 'BEGIN { srand(); printf "%d", int(rand() * (n + 1)) - int(n / 2) }')
    _cb_sleep=$(( _cb_delay + _cb_jitter ))
  else
    _cb_sleep="${_cb_delay}"
  fi
  [ "${_cb_sleep}" -lt 1 ] && _cb_sleep=1
  printf '%s' "${_cb_sleep}"
}

# ------------------------------------------------------------------------------
# rewrite_lftp_url SERVER USER
#   Echo SERVER with USER embedded if SERVER has a scheme but no embedded
#   user. v2.11.0 fix for the lftp 4.9.3 .netrc quirk (closes #124):
#   lftp only consults ~/.netrc when the URL carries an explicit user, so
#   a bare `ftp://host:port` falls back to `USER anonymous` and the FTP
#   server rejects with 530. Used by run_lftp_once (the mirror),
#   acquire_lock_with_recovery (the server-side concurrency lock
#   acquire path), and release_lock_safely (the EXIT trap lock release
#   path) so all three lftp invocations share the same URL semantics
#   and cannot drift again. Closes #132.
#
#   SERVER: the lftp URL (e.g. ftp://host:21, ftps://[::1]:990, host:21).
#   USER:   the user to embed. Empty USER is a no-op (URL echoed
#           unchanged — preserves the pre-v2.11.0 "no rewrite" path
#           for callers that pass an empty user).
#
#   Contract:
#     ftp://host:21           + user -> ftp://user@host:21
#     ftp://user@host:21      + user -> ftp://user@host:21    (no-op)
#     ftp://user:pw@host:21   + user -> ftp://user:pw@host:21 (no-op; B-03)
#     host:21                 + user -> host:21                (no scheme)
#     ftp://host:21           + ""   -> ftp://host:21          (no-op)
# ------------------------------------------------------------------------------
rewrite_lftp_url() {
  _rlu_server=$1
  _rlu_user=$2
  if [ -z "${_rlu_user}" ]; then
    printf '%s\n' "${_rlu_server}"
    return 0
  fi
  case "${_rlu_server}" in
    *://*@*) printf '%s\n' "${_rlu_server}" ;;
    *://*)   printf '%s\n' "${_rlu_server%%://*}://${_rlu_user}@${_rlu_server#*://}" ;;
    *)       printf '%s\n' "${_rlu_server}" ;;
  esac
}

# ------------------------------------------------------------------------------
# run_lftp_once SERVER FTP_SETTINGS MIRROR LOCAL REMOTE LOG_FILE TIMEOUT KILL_AFTER USER
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
#   v2.11.8 (#259): removed the LOCK_ACQUIRE / LOCK_RELEASE positional
#   arguments (10, 11). Both have been unconditional no-op shims
#   since v2.9.0 (lock work moved to acquire_lock_with_recovery /
#   release_lock_safely); the empty strings were concatenated into
#   the lftp -e body for years without effect. Threading two
#   permanently-empty positional arguments through a 10-argument
#   function is dead code.
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
  _rlo_user=$9  # v2.11.0: optional. When non-empty AND the URL
                # has no embedded user, we rewrite the URL to
                # "scheme://user@host:port" so lftp's lookup against
                # ~/.netrc (B-03) actually triggers. See
                # tests/integration/scenarios/08-action-driven-upload.sh
                # and #124 (closes lftp-by-design workaround). The
                # rewrite itself lives in rewrite_lftp_url (shared
                # with acquire_lock_with_recovery / release_lock_safely
                # to close the asymmetry tracked in #132).

  # v2.11.0: rewrite the URL when it has a scheme but no embedded user.
  # Without this, lftp 4.9.3 falls back to USER anonymous for
  # `ftp://host:port` URLs and never consults ~/.netrc — see #124 and
  # the upstream issue lavv17/lftp#372 (where lavv17 closed the
  # equivalent report as by-design). When the URL already has a user
  # ("scheme://user@host:..."), leave it as-is. The rewrite is
  # delegated to rewrite_lftp_url so all three lftp invocations share
  # the same URL semantics (#132).
  _rlo_server_eff=$(rewrite_lftp_url "${_rlo_server}" "${_rlo_user}")

  # B-03: no -u USER,PASS — lftp reads the password from ${NETRC}.
  # The user embedded in the URL above is what triggers lftp's
  # NetRC::LookupHost call (see commands.cc:1055 in upstream).
  # B-04: redirect combined stdout+stderr to the timestamped log file
  # so the captured output can be inspected after the fact and, if
  # the user wishes, attached as a workflow artifact.
  #
  # v2.11.9 (#193): use >> (append) instead of > (truncate). The
  # caller (entrypoint.sh's retry loop) computes LOG_FILE once
  # before the loop and passes it in unchanged on every retry; with
  # >, each retry erased the previous attempt's output and the
  # post-mortem log only contained the LAST attempt's stderr (or
  # nothing if all attempts failed mid-startup). With >>, the file
  # grows by retry and the upload_log_artifact path picks up the
  # full history. The log is timestamped once per run (entrypoint.sh
  # uses `date -u +%Y%m%dT%H%M%SZ` in the basename) so retries
  # within one run do NOT collide on the filename; the only
  # consumer of the file (upload_log_artifact) uploads the whole
  # thing, so the appended history is the desired shape.
  timeout -k "${_rlo_kill_after}" "${_rlo_timeout}" lftp \
    "${_rlo_server_eff}" \
    -e "${_rlo_settings} ${_rlo_mirror} ${_rlo_local} ${_rlo_remote}; quit;" \
    >> "${_rlo_log}" 2>&1
}

# ------------------------------------------------------------------------------
# acquire_lock_with_recovery SERVER LOCK_PATH TIMEOUT_SECS POLL_SECS USER
#   Acquire the server-side concurrency lock at LOCK_PATH on SERVER,
#   polling up to TIMEOUT_SECS (with POLL_SECS between attempts).
#   On a successful acquire, write a sentinel file at the FTP root
#   named `.lftp-deployment.lock.<TIMESTAMP>.<PID>.info` and store
#   the sentinel name in the global `ACQUIRED_LOCK_SENTINEL` so
#   `release_lock_safely` (and the EXIT trap) can clean it up.
#
#   Stale-lock recovery: on every MKD failure (550, lock held), the
#   function does a `cls -la .` (lftp's high-level ls) to look for
#   sentinel files at the FTP root. If the OLDEST sentinel exists
#   and its embedded timestamp is older than TIMEOUT_SECS, the
#   function assumes the previous holder died (OOM, SIGKILL, 6h job
#   limit) and takes over: it runs ONE lftp invocation that lists
#   the directory AND DELEs every parsed sentinel AND RMDs the
#   lock dir, then immediately retries MKD (no sleep). If the
#   sentinel is recent or missing, the function sleeps POLL_SECS
#   and tries again.
#
#   F2 audit hardening (closes #173, #176, #178, #184, #251, #268):
#     * #173 — every parsed sentinel is DELE'd in one lftp
#       invocation, so orphan sentinels no longer accumulate.
#     * #176 — the LIST+DELE+RMD runs in a single TCP control
#       session, so a concurrent holder's PUT-in-progress is
#       preserved across our recovery.
#     * #178 + #184 — the mktemp fallback for the sentinel body
#       uses /dev/urandom entropy and chmod 0600.
#     * #251 — when TIMEOUT_SECS=0 (fail-fast mode) the function
#       returns 1 immediately after a MKD fail; no LIST, no DELE,
#       no RMD, so a healthy holder's lock dir is never vandalised.
#     * #268 — a transient LIST failure (TCP reset, FTP 421, 10s
#       timeout) is detected via the captured exit code and
#       treated as "lock held, back off"; we never DELE/RMD on
#       an empty listing we cannot distinguish from a failure.
#
#   Returns 0 on a successful acquire, 1 if the timeout is
#   exhausted or the lock is held and timeout=0. The caller MUST
#   have a writable ${NETRC} at $HOME and MUST have `set -e`
#   disabled around the call to this function (or check the
#   return value explicitly), because intermediate lftp calls may
#   legitimately fail (timeout=0 fast path, transient network
#   errors).
#
#   USER: optional. When non-empty AND the URL has no embedded user,
#   it is embedded into the URL via rewrite_lftp_url so lftp's
#   .netrc lookup fires (same v2.11.0 fix as run_lftp_once, closes
#   #132). When USER is empty or the URL already carries a user,
#   the URL is passed to lftp unchanged.
#
#   Reads: nothing. Reads $HOME for netrc discovery.
#   Writes: ACQUIRED_LOCK_SENTINEL global (on success).
# ------------------------------------------------------------------------------
acquire_lock_with_recovery() {
  _alwr_server=$1
  _alwr_path=$2
  _alwr_timeout=$3
  _alwr_poll=$4
  _alwr_user=$5

  # v2.11.x (#132): rewrite the URL when it has a scheme but no
  # embedded user. Without this, lftp 4.9.3 falls back to USER
  # anonymous against a bare `ftp://host:port` INPUT_SERVER, the FTP
  # server rejects with 530, and this loop spins until TIMEOUT. The
  # rewrite is the same one run_lftp_once applies to the mirror
  # path, delegated to the shared rewrite_lftp_url helper so the
  # two cannot drift again.
  _alwr_server_eff=$(rewrite_lftp_url "${_alwr_server}" "${_alwr_user}")

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
    timeout 30s lftp "${_alwr_server_eff}" \
      -e "${_alwr_preamble} mkdir ${_alwr_path}; quit;" \
      >/dev/null 2>&1
    _alwr_mkd_rc=$?
    set -e

    if [ "${_alwr_mkd_rc}" -eq 0 ]; then
      # Got the lock. Write the sentinel so the next runner can
      # tell whether we died mid-mirror. The sentinel content is
      # not parsed (we use the FILENAME timestamp); we keep the
      # body for human debugging via FTP `cat`.
      # F2 audit (#178 + #184): mktemp's success path is fine
      # (busybox gives a random name and mode 0600). Only the
      # fallback needs hardening: PID-predictable name +
      # umask-inherited mode. Mix in entropy from /dev/urandom
      # and chmod 0600 unconditionally so the body file never
      # lands at 0644 on the fallback branch.
      _alwr_sentinel_body=$(mktemp 2>/dev/null) \
        || _alwr_sentinel_body="/tmp/.lftp-lock-body.$$-$(date +%s)-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
      chmod 600 "${_alwr_sentinel_body}" 2>/dev/null || true
      {
        printf 'pid=%s\n' "${_alwr_pid}"
        printf 'started_at=%s\n' "${_alwr_stamp}"
        printf 'host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
      } > "${_alwr_sentinel_body}"
      set +e
      timeout 30s lftp "${_alwr_server_eff}" \
        -e "${_alwr_preamble} put ${_alwr_sentinel_body} -o ${_alwr_sentinel}; quit;" \
        >/dev/null 2>&1
      _alwr_put_rc=$?
      set -e
      rm -f "${_alwr_sentinel_body}"
      # v2.11.2: surface a PUT failure. Pre-fix, the exit code was
      # discarded — a MKD success + PUT failure returned 0 with
      # ACQUIRED_LOCK_SENTINEL set but no file on the FTP server.
      # The next runner then took over the lock while the original
      # was mid-mirror; both then mirrored concurrently, defeating
      # the serialization concurrency_lock exists to provide. Treat
      # the PUT failure the same as a MKD failure (continue to
      # stale-recovery / retry); this can re-enter the loop and
      # either win the MKD against the lock-holder's stale sentinel
      # or back off and wait.
      #
      # v2.11.8 (#254): MKD succeeded (this process owns the lock
      # dir) but the sentinel PUT failed — ACQUIRED_LOCK_SENTINEL is
      # never set, so release_lock_safely's post-#188 no-sentinel
      # guard will short-circuit, leaving the dir behind. RMD
      # best-effort before retrying so the next iteration either wins
      # MKD against a clean tree or hands off to stale-recovery.
      # Mirrors the recovery branch's set +e / set -e / >/dev/null
      # swallow semantics (transient RMD failures are not actionable).
      if [ "${_alwr_put_rc}" -ne 0 ]; then
        set +e
        timeout 10s lftp "${_alwr_server_eff}" \
          -e "${_alwr_preamble} quote RMD ${_alwr_path}; quit;" \
          >/dev/null 2>&1
        set -e
        continue
      fi

      # Publish sentinel name for release_lock_safely.
      ACQUIRED_LOCK_SENTINEL=${_alwr_sentinel}
      return 0
    fi

    # Step 2: MKD failed (550 = held, or connection refused).
    # F2 audit (#251): when timeout=0 the caller has explicitly
    # opted out of lock-orchestration ("fail immediately when
    # held"). Skip the stale-recovery path entirely: any
    # recovery attempt would race a healthy holder's sentinel /
    # lock dir, defeating the serialization concurrency_lock
    # exists to provide. Return 1 so the caller surfaces a
    # clean "lock held" error to the workflow.
    if [ "${_alwr_timeout}" = "0" ]; then
      return 1
    fi

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
    _alwr_listing=$(timeout 10s lftp "${_alwr_server_eff}" \
      -e "${_alwr_preamble} cls -la .; quit;" \
      2>/dev/null)
    _alwr_listing_rc=$?
    set -e
    # F2 audit (#268): a transient LIST failure (TCP reset, FTP
    # 421, 10s timeout, refused connection) cannot be
    # distinguished from "no sentinel" without the exit code;
    # respect the lock and back off instead of triggering an
    # unwanted DELE/RMD against a live holder's lock dir.
    if [ "${_alwr_listing_rc}" -ne 0 ]; then
      sleep "${_alwr_poll}"
      continue
    fi

    _alwr_stale_files=$(_lock_parse_sentinel_listing "${_alwr_listing}") || _alwr_stale_files=""
    _alwr_took_over=1
    if [ -n "${_alwr_stale_files}" ]; then
      # F2 audit (#173): _lock_parse_sentinel_listing now returns
      # EVERY parsed sentinel (one per line, sorted ascending by
      # stamp). For the staleness check we consult the OLDEST
      # sentinel — if even the oldest is recent, the holder is
      # healthy and we must respect the lock. The recovery branch
      # below DELEs every parsed name.
      _alwr_oldest=$(printf '%s\n' "${_alwr_stale_files}" | head -n 1)
      # The parser restricts the input to the documented sentinel
      # pattern, so sed's regex matches on every line — `|| _stamp=""`
      # is purely defensive against a future parser loosening.
      _alwr_stale_stamp=$(printf '%s' "${_alwr_oldest}" \
        | sed -nE 's|^\.lftp-deployment\.lock\.([0-9TZ]+)\..*\.info$|\1|p') \
        || _alwr_stale_stamp=""
      if [ -n "${_alwr_stale_stamp}" ]; then
        _alwr_now=$(date -u +%Y%m%dT%H%M%SZ)
        # F2 audit NEW: mktime parse failure (e.g., corrupted
        # sentinel with non-numeric components) returns -1 and
        # would otherwise be propagated as a garbage age. Capture
        # the exit code and treat a parse failure as "lock held,
        # back off" — the same semantic as a recent sentinel —
        # so a malformed sentinel never triggers takeover.
        set +e
        _alwr_age=$(_lock_age_seconds "${_alwr_now}" "${_alwr_stale_stamp}")
        _alwr_age_rc=$?
        set -e
        if [ "${_alwr_age_rc}" -ne 0 ]; then
          _alwr_took_over=0
        elif [ "${_alwr_age}" -le "${_alwr_timeout}" ]; then
          # `<= timeout` (not `<`) — the timeout represents the maximum
          # age at which we still consider the sentinel recent, so a
          # sentinel whose age is exactly `timeout` is at the boundary
          # and must still be respected. Using `<` here would make
          # the comparison racy when `_alwr_now` and the sentinel's
          # timestamp straddle a second boundary (test #19 catches
          # this: a sentinel stamped at "now" but observed one
          # second later would have age=1 vs timeout=1 and be
          # mis-classified as stale, triggering an unwanted DELE/RMD).
          _alwr_took_over=0
        fi
      fi
    fi
    # An empty or missing sentinel also counts as "stale" (the
    # _alwr_took_over=1 default applies). This covers the race
    # where the previous holder died between MKD and PUT.

    if [ "${_alwr_took_over}" -eq 1 ]; then
      # F2 audit (#173 + #176): take over with ONE lftp script
      # that lists the directory and DELEs every parsed sentinel
      # in the same control connection. The single-invocation
      # shape makes the snapshot atomic against the FTP server's
      # view: any sentinel PUT that arrives between our `cls` and
      # our first `quote DELE` survives the loop, which is the
      # desired behaviour — that sentinel belongs to a live
      # concurrent runner and we must not touch it. RMD fires
      # unconditionally when we have decided to takeover (covers
      # the PUT-failed-previous-holder case where the lock dir
      # exists but no sentinel does).
      _alwr_recover_script="${_alwr_preamble} cls -la .;"
      if [ -n "${_alwr_stale_files}" ]; then
        while IFS= read -r _alwr_name; do
          [ -z "${_alwr_name}" ] && continue
          _alwr_recover_script="${_alwr_recover_script} quote DELE ${_alwr_name};"
        done <<EOF
${_alwr_stale_files}
EOF
      fi
      _alwr_recover_script="${_alwr_recover_script} quote RMD ${_alwr_path}; quit;"
      set +e
      timeout 10s lftp "${_alwr_server_eff}" \
        -e "${_alwr_recover_script}" \
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
# release_lock_safely SERVER LOCK_PATH [SENTINEL] [USER]
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
#             the function is a no-op — we never acquired the lock
#             in this run, and issuing `quote RMD <lock_path>` would
#             race any concurrent holder's lock dir. The
#             stale-holder-cleanup semantics the v2.5.0 docstring
#             described ("RMD the lock dir even without a sentinel,
#             covers the case where the previous holder died before
#             writing the sentinel") were always speculative — the
#             only call site is the one-shot EXIT trap, which only
#             fires for the current process. v2.11.3 (#188) removes
#             the unsafe RMD.
#   USER: (optional, v2.11.x / #132) — when non-empty AND SERVER has
#         a scheme but no embedded user, USER is embedded into the
#         URL via rewrite_lftp_url so lftp's .netrc lookup fires.
#         Same v2.11.0 fix as acquire_lock_with_recovery, so the
#         EXIT trap's release path does not silently fail against
#         a bare-host `ftp://host:port` INPUT_SERVER.
#
#   Always returns 0.
# ------------------------------------------------------------------------------
release_lock_safely() {
  _rls_server=$1
  _rls_path=$2
  _rls_sentinel=${3:-${ACQUIRED_LOCK_SENTINEL:-}}
  _rls_user=${4:-}

  if [ -z "${_rls_path}" ]; then
    return 0
  fi

  # v2.11.3 (#188): if no sentinel is available (neither the explicit
  # arg nor $ACQUIRED_LOCK_SENTINEL is set), this process never
  # acquired the lock — the EXIT trap fired BEFORE acquire_lock_with_recovery
  # set ACQUIRED_LOCK_SENTINEL, or during its polling loop. Issuing
  # `quote RMD <lock_path>` in this state races a parallel runner
  # that legitimately holds the lock: the trap would remove the
  # live holder's lock dir, defeating the serialization
  # concurrency_lock exists to provide. The trap's job is to release
  # what THIS process acquired, not to clean up any lock it sees.
  # The previous behaviour (always RMD when no sentinel) was a
  # residual side-effect of the pre-v2.9.0 inline-lftp layout that
  # kept leaking into subsequent versions; #188 surfaced it via the
  # audit (the v2.11.2 issue body described the mechanism imprecisely
  # — the actual harm is `quote RMD`, not sentinel DELE).
  if [ -z "${_rls_sentinel}" ] && [ -z "${ACQUIRED_LOCK_SENTINEL:-}" ]; then
    return 0
  fi

  # v2.11.x (#132): same URL rewrite as acquire_lock_with_recovery
  # so the EXIT trap's release lftp call can authenticate against
  # a bare-host INPUT_SERVER.
  _rls_server_eff=$(rewrite_lftp_url "${_rls_server}" "${_rls_user}")

  # Same tightened reconnect preamble as acquire_lock_with_recovery:
  # a misconfigured server should not stall the EXIT trap for
  # 15s-5min of reconnect attempts.
  _rls_preamble="set net:max-retries 1; set net:reconnect-interval-base 1; set net:reconnect-interval-max 1; set net:timeout 5; set dns:max-retries 1; set dns:fatal-timeout 5;"

  set +e
  if [ -n "${_rls_sentinel}" ]; then
    timeout 30s lftp "${_rls_server_eff}" \
      -e "${_rls_preamble} quote DELE ${_rls_sentinel}; quote RMD ${_rls_path}; quit;" \
      >/dev/null 2>&1
  else
    timeout 30s lftp "${_rls_server_eff}" \
      -e "${_rls_preamble} quote RMD ${_rls_path}; quit;" \
      >/dev/null 2>&1
  fi
  set -e
  return 0
}

# ------------------------------------------------------------------------------
# run_lftp_lock_release SERVER NETRC_PATH LOCK_PATH [SENTINEL] [USER]
#   Backward-compatibility shim. Used by the EXIT trap in
#   entrypoint.sh to release the server-side concurrency lock if
#   the main pipeline was killed before reaching the explicit
#   release_lock_safely call (signal, OOM, hard timeout).
#
#   When the lock is disabled (LOCK_PATH empty) or the netrc file
#   is missing (the EXIT trap may run after the netrc was already
#   removed), this function is a no-op. Otherwise it delegates to
#   release_lock_safely with the optional SENTINEL and USER
#   arguments.
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
  _rlr_user=${5:-}

  if [ -z "${_rlr_lock_path}" ]; then
    return 0
  fi
  if [ ! -f "${_rlr_netrc}" ]; then
    return 0
  fi

  release_lock_safely "${_rlr_server}" "${_rlr_lock_path}" "${_rlr_sentinel}" "${_rlr_user}"
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
