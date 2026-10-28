#!/usr/bin/env bats
# tests/unit/validate.bats — unit tests for the validator functions
# in lib.sh: validate_int, validate_path, validate_lftp_settings.
#
# bats is bash + tap. Each `@test` block is a function that returns
# non-zero on failure. The shared setup() sources lib.sh in a clean
# environment (no INPUT_* set, set -u off) so the validators can be
# called with explicit arguments.

setup() {
  # Source the library under test. We disable set -u in this shell
  # so unset INPUT_* don't trigger errexit. The lib.sh functions
  # themselves use set -u-safe patterns (e.g. ${VAR-}).
  set +u
  # LIB_SRC overrides the lib.sh under test (used to prove the FND-0015
  # tests fail without the fix).
  LIB="${LIB_SRC:-${BATS_TEST_DIRNAME}/../../lib.sh}"
  # shellcheck disable=SC1090
  . "${LIB}"
}

# ----------------------------------------------------------------------------
# validate_int
# ----------------------------------------------------------------------------

@test "validate_int accepts a positive integer" {
  run validate_int "max_retries" "10"
  [ "$status" -eq 0 ]
}

@test "validate_int accepts 0 (the retry-forever sentinel)" {
  run validate_int "max_retries" "0"
  [ "$status" -eq 0 ]
}

@test "validate_int rejects 00 (leading zeros would break retry-forever sentinel)" {
  run validate_int "max_retries" "00"
  [ "$status" -eq 2 ]
  [[ "$output" == *"without leading zeros"* ]]
}

@test "validate_int rejects 007 (leading zeros on positive integer)" {
  run validate_int "max_retries" "007"
  [ "$status" -eq 2 ]
}

@test "validate_int rejects 08 / 09 (would be parsed as invalid octal in \$((...)))" {
  run validate_int "concurrency_lock_poll_interval" "08"
  [ "$status" -eq 2 ]
  run validate_int "concurrency_lock_poll_interval" "09"
  [ "$status" -eq 2 ]
}

@test "validate_int rejects a non-numeric value with exit 2" {
  run validate_int "max_retries" "abc"
  [ "$status" -eq 2 ]
  [[ "$output" == *"max_retries must be a non-negative integer"* ]]
}

@test "validate_int rejects an empty string with exit 2" {
  run validate_int "max_retries" ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"max_retries must be a non-negative integer"* ]]
}

@test "validate_int rejects a value with letters" {
  run validate_int "max_retries" "10s"
  [ "$status" -eq 2 ]
}

@test "validate_int rejects a negative integer with exit 2" {
  run validate_int "max_retries" "-1"
  [ "$status" -eq 2 ]
}

@test "validate_int rejects a float with exit 2" {
  run validate_int "max_retries" "1.5"
  [ "$status" -eq 2 ]
}

# ----------------------------------------------------------------------------
# validate_path
# ----------------------------------------------------------------------------

@test "validate_path accepts a simple relative path" {
  run validate_path "local_dir" "./public_html/"
  [ "$status" -eq 0 ]
}

@test "validate_path accepts a simple absolute path" {
  run validate_path "remote_dir" "/www/user/home/"
  [ "$status" -eq 0 ]
}

@test "validate_path accepts './'" {
  run validate_path "local_dir" "./"
  [ "$status" -eq 0 ]
}

@test "validate_path rejects a '..' path-traversal component" {
  run validate_path "local_dir" "../../etc/"
  [ "$status" -eq 2 ]
  [[ "$output" == *"local_dir contains \"..\" path traversal"* ]]
}

@test "validate_path rejects a '..' in the middle of the path" {
  run validate_path "remote_dir" "/foo/../bar/"
  [ "$status" -eq 2 ]
}

@test "validate_path rejects a leading dash (would be misread as lftp option)" {
  run validate_path "local_dir" "-rf"
  [ "$status" -eq 2 ]
  [[ "$output" == *"starts with a dash"* ]]
}

@test "validate_path rejects control characters" {
  # Use a tab (0x09) as the control character. Newlines would
  # be split into separate lines by grep, and grep's [:cntrl:]
  # would not match the newline between them.
  run validate_path "local_dir" $'foo\tbar'
  [ "$status" -eq 2 ]
  [[ "$output" == *"control characters"* ]]
}

@test "validate_path rejects the ';' shell metacharacter" {
  run validate_path "local_dir" "foo;rm -rf /"
  [ "$status" -eq 2 ]
  [[ "$output" == *"forbidden shell metacharacter"* ]]
}

@test "validate_path rejects the '&' shell metacharacter" {
  run validate_path "local_dir" "foo&bar"
  [ "$status" -eq 2 ]
}

@test "validate_path rejects the '|' shell metacharacter" {
  run validate_path "local_dir" "foo|bar"
  [ "$status" -eq 2 ]
}

@test "validate_path rejects the backtick shell substitution" {
  run validate_path "local_dir" 'foo`whoami`'
  [ "$status" -eq 2 ]
}

@test "validate_path rejects the dollar shell substitution" {
  run validate_path "local_dir" 'foo$HOME'
  [ "$status" -eq 2 ]
  [[ "$output" == *"dollar"* ]]
}

@test "validate_path rejects '!' (lftp shell escape — v2.11.3 #172)" {
  run validate_path "local_dir" 'foo!cat /home/lftp/.netrc'
  [ "$status" -eq 2 ]
  [[ "$output" == *"\"!\""* ]]
}

@test "validate_path rejects double-quote (lftp command parsing — v2.11.3 #172)" {
  run validate_path "remote_dir" 'foo"; cls; quit;'
  [ "$status" -eq 2 ]
  [[ "$output" == *"double-quote"* ]]
}

@test "validate_path rejects ASCII space (lftp -e token parsing — v2.11.8 #174)" {
  # server-dir / remote_dir values are interpolated into the
  # `lftp -e` script body where lftp 4.9.3 tokenises on whitespace.
  # /my data/site/ would split into `cd /my` + leftover `data/site/`.
  run validate_path "remote_dir" "/my data/site/"
  [ "$status" -eq 2 ]
  [[ "$output" == *"space"* ]]
}

@test "validate_path rejects a leading space (v2.11.8 #174)" {
  run validate_path "remote_dir" " /leading"
  [ "$status" -eq 2 ]
  [[ "$output" == *"space"* ]]
}

@test "validate_path rejects a trailing space (v2.11.8 #174)" {
  run validate_path "remote_dir" "trailing "
  [ "$status" -eq 2 ]
  [[ "$output" == *"space"* ]]
}

@test "validate_path accepts valid FTP / FTPS URL-shaped inputs (v2.11.8 #190)" {
  # New use case for validate_path: INPUT_SERVER. Valid FTP / FTPS
  # URL shapes (bare host, with port, bracketed IPv6) must all pass.
  run validate_path "server" "ftp://example.com"
  [ "$status" -eq 0 ]
  run validate_path "server" "ftp://example.com:21"
  [ "$status" -eq 0 ]
  run validate_path "server" "ftps://[::1]:990"
  [ "$status" -eq 0 ]
  run validate_path "server" "example.com"
  [ "$status" -eq 0 ]
}

@test "validate_path rejects shell metacharacters in INPUT_SERVER (v2.11.8 #190)" {
  run validate_path "server" 'ftp://example.com"; cls; quit;'
  [ "$status" -eq 2 ]
  [[ "$output" == *"double-quote"* ]]
  run validate_path "server" 'ftp://h;rm -rf /'
  [ "$status" -eq 2 ]
  [[ "$output" == *"forbidden shell metacharacter"* ]]
}

# F2 audit v2.11.10 (#295): bracket-balance guard for IPv6 URLs.
# Pre-fix, validate_path let `ftp://[::1` through and
# extract_netrc_host returned empty (the IPv6 sed requires a
# closing `]`). write_netrc then emitted `machine  login user
# password` — invalid .netrc syntax — and the user got a
# confusing "530 Login authentication failed" instead of a
# precise URL-shape error. Post-fix: validate_path rejects
# any value whose `[` and `]` counts don't match.
@test "validate_path rejects unbalanced IPv6 brackets — missing close (issue #295)" {
  run validate_path "server" 'ftp://[::1'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unbalanced IPv6 brackets"* ]]
  # The error message embeds the counts so the user can see
  # which side is unbalanced (1 "[" vs 0 "]").
  [[ "$output" == *"1"* ]]
  [[ "$output" == *"0"* ]]
}

@test "validate_path rejects unbalanced IPv6 brackets — extra close (issue #295)" {
  run validate_path "server" 'ftp://::1]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unbalanced IPv6 brackets"* ]]
  # Counts: 0 "[" vs 1 "]". The `0` substring matches both the
  # count field and the literal `0]` in the message body; the
  # `1` substring matches the count. We assert the count
  # direction by requiring `0 "["` and `1 "]"` next to each other.
  [[ "$output" == *"0 \"[\""* ]]
  [[ "$output" == *"1 \"]\""* ]]
}

@test "validate_path rejects unbalanced IPv6 brackets — mismatched pairs (issue #295)" {
  # Two `[` and one `]`: the most common "I tried to write two
  # brackets" typo. Counts must balance.
  run validate_path "server" 'ftp://[[::1]'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unbalanced IPv6 brackets"* ]]
}

@test "validate_path accepts balanced IPv6 brackets — documented form (issue #295)" {
  # The documented IPv6 form passes (balanced brackets) and
  # does NOT trip the new guard.
  run validate_path "server" 'ftps://[::1]:990'
  [ "$status" -eq 0 ]
  run validate_path "server" 'ftps://[::1]'
  [ "$status" -eq 0 ]
  run validate_path "server" 'ftp://[2001:db8::1]:21'
  [ "$status" -eq 0 ]
}

@test "validate_path accepts values with no brackets unchanged (issue #295)" {
  # The guard must be invisible for the common case where no
  # bracket appears at all — count is (0, 0) and the comparison
  # is equal. Regression guard against an over-broad rule that
  # would block every server value.
  run validate_path "server" 'ftp://example.com'
  [ "$status" -eq 0 ]
  run validate_path "server" 'ftp://example.com:21'
  [ "$status" -eq 0 ]
  run validate_path "local_dir" '/var/www/site/'
  [ "$status" -eq 0 ]
  run validate_path "remote_dir" '/www/user/home/'
  [ "$status" -eq 0 ]
}

# v2.11.12 (F2 audit): same exploit class as #295 but for
# BALANCED-but-empty brackets. The v2.11.10 balance check only
# counts `[` vs `]`. Empty brackets `[]` slipped through and
# produced silent .netrc corruption downstream. Shell-meta /
# control-char / space checks already catch the rest of the
# bracket-content threats; this guard closes the empty-content
# gap specifically.
@test "validate_path rejects empty IPv6 brackets (F2 audit v2.11.12)" {
  # `ftp://[]:21` — empty brackets, balanced (1 [ / 1 ]).
  # Pre-fix validate_path returned 0; extract_netrc_host then
  # echoed empty; write_netrc emitted `machine  login user
  # password` (invalid .netrc).
  run validate_path "server" 'ftp://[]:21'
  [ "$status" -eq 2 ]
  [[ "$output" == *"empty IPv6 brackets"* ]]
  # The empty-bracket shape in a path component is also rejected
  # (same exploit class via mirror command injection).
  run validate_path "remote_dir" '/foo/[]/bar/'
  [ "$status" -eq 2 ]
  [[ "$output" == *"empty IPv6 brackets"* ]]
}

@test "validate_path accepts RFC 6874 zone-id form (F2 audit v2.11.12)" {
  # `fe80::1%eth0` is a valid IPv6 zone-id. URL-encoded the `%`
  # becomes `%25`, but the bracket content the user supplies may
  # be either shape. The IPv6 charset includes `%` for the
  # unescaped form; the validator accepts both (the chars pass
  # the shell-meta / control-char / space checks above; the
  # bracket-content guard only rejects EMPTY brackets).
  run validate_path "server" 'ftps://[fe80::1%25eth0]:990'
  [ "$status" -eq 0 ]
  run validate_path "server" 'ftps://[fe80::1%eth0]:990'
  [ "$status" -eq 0 ]
  run validate_path "server" 'ftps://[::1]:990'
  [ "$status" -eq 0 ]
}

@test "validate_path accepts bracketed non-empty content (F2 audit v2.11.12)" {
  # Regression guard — non-empty brackets pass even if the
  # content is not strictly IPv6-shaped. The other validators
  # (control-char, shell-meta, space) handle the malicious
  # shapes; the bracket-content guard only adds the
  # empty-content check.
  run validate_path "server" 'ftp://[xyz]:21'
  [ "$status" -eq 0 ]
}

@test "validate_path accepts pure-IPv4 dotted form with brackets not used (F2 audit v2.11.12)" {
  # Regression guard — brackets only fire when they appear; bare
  # IPv4 / host:port / path forms still pass.
  run validate_path "server" 'ftp://192.0.2.1:21'
  [ "$status" -eq 0 ]
  run validate_path "server" 'ftp://example.com/some/path'
  [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------------------
# FND-0015: _canon_path and validate_local_dir_outside_home. local_dir must not
# be, contain or lie inside the action's home (it holds the .netrc, and the
# reverse mirror uploads dot-files). HOME_DIR is an argument; PWD is set per
# test (bats runs each test in its own process, so the export does not leak).
# ----------------------------------------------------------------------------

_fnd15_reject() {
  # $1 = local_dir value, $2 = home dir
  run validate_local_dir_outside_home "local_dir" "$1" "$2"
  if [ "${status}" -ne 2 ]; then
    echo "case='$1' home='$2' PWD='${PWD}': expected status 2, got ${status}"; echo "${output}"
    return 1
  fi
  case "${output}" in
    "ERROR: local_dir "*) ;;
    *) echo "case='$1' home='$2': ERROR does not name local_dir"; echo "${output}"; return 1 ;;
  esac
  case "${output}" in
    *"holds the FTP credentials"*) ;;
    *) echo "case='$1' home='$2': message lacks the credentials hint"; echo "${output}"; return 1 ;;
  esac
}

_fnd15_accept() {
  run validate_local_dir_outside_home "local_dir" "$1" "$2"
  if [ "${status}" -ne 0 ]; then
    echo "case='$1' home='$2' PWD='${PWD}': expected status 0, got ${status}"; echo "${output}"
    return 1
  fi
  if [ -n "${output}" ]; then
    echo "case='$1' home='$2': expected no output"; echo "${output}"
    return 1
  fi
}

@test "validate_local_dir_outside_home: FND-0015: rejects every spelling of the literal /home/lftp, its contents, and its ancestors" {
  export PWD=/github/workspace
  for v in /home/lftp /home/lftp/ //home//lftp// /home/lftp/sub /home/lftp/.lftp-logs \
           /home/./lftp /home/lftp/./sub/ / // /home /home/ /home/.; do
    _fnd15_reject "${v}" /home/lftp || return 1
  done
}

@test "validate_local_dir_outside_home: FND-0015: rejects the same forms against a temporary home dir" {
  export PWD=/github/workspace
  h="${BATS_TEST_TMPDIR}/home/lftp"
  for v in "${h}" "${h}/" "${h}/sub" "${h}/.lftp-logs" "${BATS_TEST_TMPDIR}/home" \
           "${BATS_TEST_TMPDIR}/home/./lftp" "${BATS_TEST_TMPDIR}//home//lftp//" "${BATS_TEST_TMPDIR}" /; do
    _fnd15_reject "${v}" "${h}" || return 1
  done
}

@test "validate_local_dir_outside_home: FND-0015: the ERROR carries the value, the resolved path and the home dir" {
  export PWD=/github/workspace
  run validate_local_dir_outside_home "local_dir" "//home//lftp//x/" "/home/lftp"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"local_dir '//home//lftp//x/' (resolved to /home/lftp/x)"* ]]
  [[ "${output}" == *"home directory /home/lftp,"* ]]
}

@test "validate_local_dir_outside_home: FND-0015: a relative value is resolved against PWD inside the home dir" {
  export PWD=/home/lftp
  for v in ./ . sub sub/ ./sub/ ; do
    _fnd15_reject "${v}" /home/lftp || return 1
  done
  export PWD=/home/lftp/work
  _fnd15_reject ./ /home/lftp || return 1
  _fnd15_reject public/ /home/lftp || return 1
  export PWD="${BATS_TEST_TMPDIR}/home/lftp/work"
  _fnd15_reject ./ "${BATS_TEST_TMPDIR}/home/lftp" || return 1
}

@test "validate_local_dir_outside_home: FND-0015: './' is rejected when PWD is / (it would mirror the whole filesystem)" {
  export PWD=/
  for v in ./ . ; do
    _fnd15_reject "${v}" /home/lftp || return 1
  done
  # A subdir of / that is not the home dir or an ancestor of it is fine.
  _fnd15_accept public/ /home/lftp || return 1
}

@test "validate_local_dir_outside_home: FND-0015: relative value with PWD=/home (an ancestor) is rejected, a sibling subdir is accepted" {
  export PWD=/home
  _fnd15_reject ./ /home/lftp || return 1
  _fnd15_reject lftp /home/lftp || return 1
  _fnd15_accept other/ /home/lftp || return 1
}

@test "validate_local_dir_outside_home: FND-0015: accepts workspace and sibling paths silently (PWD=/github/workspace)" {
  export PWD=/github/workspace
  for v in ./ public/ dist/site/ /github/workspace /github/workspace/public/ /home/lftpx \
           /home/lftp-site /home/lftpx/sub /home/lftp.d /data/ /var/www/; do
    _fnd15_accept "${v}" /home/lftp || return 1
  done
}

@test "validate_local_dir_outside_home: FND-0015: accepts the same siblings against a temporary home dir, PWD outside it" {
  export PWD="${BATS_TEST_TMPDIR}/ws"
  h="${BATS_TEST_TMPDIR}/home/lftp"
  for v in ./ public/ "${h}x" "${h}-site/" "${BATS_TEST_TMPDIR}/home/other" "${BATS_TEST_TMPDIR}/homelftp"; do
    _fnd15_accept "${v}" "${h}" || return 1
  done
}

@test "validate_local_dir_outside_home: FND-0015: a degenerate HOME_DIR (empty, relative, '/', './', '//') fails closed with exit 2" {
  export PWD=/github/workspace
  for h in "" "home/lftp" "." "./" "/" "//" "/./"; do
    run validate_local_dir_outside_home "local_dir" "/github/workspace/public/" "${h}"
    if [ "${status}" -ne 2 ]; then
      echo "home='${h}': expected status 2, got ${status}"; echo "${output}"
      return 1
    fi
    case "${output}" in
      "ERROR: internal: cannot check local_dir, home directory argument is empty, relative or \"/\""*) ;;
      *) echo "home='${h}': unexpected message"; echo "${output}"; return 1 ;;
    esac
  done
}

@test "validate_local_dir_outside_home: FND-0015: a missing HOME_DIR argument also fails closed" {
  run validate_local_dir_outside_home "local_dir" "/data/"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"internal: cannot check local_dir"* ]]
}

# FND-0015 round 2/3: the raw-value checks (backslash, leading "~", leading
# lowercase "file:") run BEFORE the HOME_DIR check and before _canon_path, so
# they fire even with a degenerate HOME_DIR. run_lftp_once double-quotes
# local_dir (round 3), where "\" is lftp's escape character; lftp 4.9.3 also
# expands a leading ~ and reads file: as a local URL after parsing, so the
# canonical form of the raw string is not the path lftp opens. Reject helper
# with a reason fragment.
_fnd15_reject_why() {
  # $1 = value, $2 = fragment the ERROR must contain, $3 = home dir (default /home/lftp)
  run validate_local_dir_outside_home "local_dir" "$1" "${3-/home/lftp}"
  if [ "${status}" -ne 2 ]; then
    echo "case='$1' PWD='${PWD}': expected status 2, got ${status}"; echo "${output}"
    return 1
  fi
  case "${output}" in
    "ERROR: local_dir "*) ;;
    *) echo "case='$1': ERROR does not start with 'ERROR: local_dir '"; echo "${output}"; return 1 ;;
  esac
  case "${output}" in
    *"$2"*) ;;
    *) echo "case='$1': ERROR lacks reason '$2'"; echo "${output}"; return 1 ;;
  esac
}

@test "validate_local_dir_outside_home: FND-0015 r3: any backslash is rejected with the backslash reason" {
  export PWD=/github/workspace
  q="'"
  bs='\'
  for v in "/home/${bs}${q}lftp${bs}${q}/" "${bs}~/" "/home/l${bs}ftp/" "${bs}/" "/home/lftp${bs}/" \
           "${bs}/home/lftp/" "/home/lftp/${bs}" "a${bs}${bs}b/" "${bs}"; do
    _fnd15_reject_why "${v}" "contains a backslash" || return 1
  done
}

@test "validate_local_dir_outside_home: FND-0015 r3: the backslash ERROR carries the raw value and names the escape character" {
  export PWD=/github/workspace
  run validate_local_dir_outside_home "local_dir" '/home/l\ftp/' "/home/lftp"
  [ "${status}" -eq 2 ]
  [[ "${output}" == 'ERROR: local_dir contains a backslash: /home/l\ftp/;'* ]]
  [[ "${output}" == *"escape character"* ]]
}

@test "validate_local_dir_outside_home: FND-0015 r2: a leading ~ is rejected with the tilde reason" {
  export PWD=/github/workspace
  for v in '~' '~/' '~lftp/' '~root/' '~x/' '~/sub/' '~+/'; do
    _fnd15_reject_why "${v}" 'starts with "~"' || return 1
  done
  run validate_local_dir_outside_home "local_dir" '~/' "/home/lftp"
  [[ "${output}" == *"expands a leading ~"* ]] || { echo "${output}"; return 1; }
  [[ "${output}" == *"holds the FTP credentials"* ]] || { echo "${output}"; return 1; }
}

@test "validate_local_dir_outside_home: FND-0015 r2: a leading lowercase file: is rejected with the file: reason" {
  export PWD=/github/workspace
  for v in 'file:/home/lftp/' 'file:///home/lftp/' 'file://localhost/home/lftp/' 'file:/' 'file:~/' \
           'file:./' 'file:' 'file:.' 'file:home/lftp/' 'file:/data/'; do
    _fnd15_reject_why "${v}" 'starts with "file:"' || return 1
  done
  run validate_local_dir_outside_home "local_dir" 'file:/home/lftp/' "/home/lftp"
  [[ "${output}" == *"local file URL"* ]] || { echo "${output}"; return 1; }
}

@test "validate_local_dir_outside_home: FND-0015 r2: /home/lftp/~/ (mid-path ~) is rejected by the home check, not the tilde check" {
  export PWD=/github/workspace
  _fnd15_reject_why '/home/lftp/~/' "is or contains the action's home directory" || return 1
  [[ "${output}" != *'starts with "~"'* ]]
}

@test "validate_local_dir_outside_home: FND-0015 r2: harmless lookalikes are accepted silently (PWD outside the home)" {
  export PWD=/github/workspace
  for v in 'a/~/b/' 'FILE:x/' 'FILE:/home/lftp/' 'File:/home/lftp/' \
           '/hom?/lftp/' '/home/lft*/' '/home/l[f]tp/' 'a:b/' 'ftp:x/'; do
    _fnd15_accept "${v}" /home/lftp || return 1
  done
}

@test "validate_local_dir_outside_home: FND-0015 r2: File:/home/lftp/ resolves under PWD (lftp treats it as relative)" {
  export PWD=/github/workspace
  # Accepted: the home check sees /github/workspace/File:/home/lftp, outside the home.
  _fnd15_accept 'File:/home/lftp/' /home/lftp || return 1
  # The same spelling IS rejected when PWD is the home, proving it is resolved against PWD.
  export PWD=/home/lftp
  _fnd15_reject 'File:/home/lftp/' /home/lftp || return 1
}

@test "validate_local_dir_outside_home: FND-0015 r2: order, the raw-value checks run before the HOME_DIR check (degenerate HOME_DIR still gets the specific ERROR)" {
  export PWD=/github/workspace
  for h in "" "rel" "/"; do
    _fnd15_reject_why '/home/l\ftp/' "contains a backslash" "${h}" || return 1
    [[ "${output}" != *"internal: cannot check"* ]] || { echo "h='${h}': internal error shown"; echo "${output}"; return 1; }
    _fnd15_reject_why '~/' 'starts with "~"' "${h}" || return 1
    [[ "${output}" != *"internal: cannot check"* ]] || { echo "h='${h}': internal error shown"; echo "${output}"; return 1; }
    _fnd15_reject_why 'file:/home/lftp/' 'starts with "file:"' "${h}" || return 1
    [[ "${output}" != *"internal: cannot check"* ]] || { echo "h='${h}': internal error shown"; echo "${output}"; return 1; }
  done
  # A clean value with the same degenerate HOME_DIR still reaches the internal error.
  run validate_local_dir_outside_home "local_dir" "/data/" ""
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"internal: cannot check local_dir"* ]]
}

@test "_canon_path: FND-0015: collapses repeated slashes" {
  run _canon_path "//home///lftp//sub"
  [ "${status}" -eq 0 ]
  [ "${output}" = "/home/lftp/sub" ]
}

@test "_canon_path: FND-0015: drops '.' components, including consecutive and trailing ones" {
  run _canon_path "/home/./lftp/././sub/."
  [ "${output}" = "/home/lftp/sub" ]
  run _canon_path "/./home"
  [ "${output}" = "/home" ]
  run _canon_path "/home/."
  [ "${output}" = "/home" ]
}

@test "_canon_path: FND-0015: strips the trailing slash but '/' stays '/'" {
  run _canon_path "/home/lftp/"
  [ "${output}" = "/home/lftp" ]
  run _canon_path "/"
  [ "${output}" = "/" ]
  run _canon_path "//"
  [ "${output}" = "/" ]
  run _canon_path "/."
  [ "${output}" = "/" ]
}

@test "_canon_path: FND-0015: keeps names that merely contain dots or start with them" {
  run _canon_path "/a/.hidden/b.c/..x/"
  [ "${output}" = "/a/.hidden/b.c/..x" ]
}

@test "_canon_path: FND-0015: resolves a relative value against PWD" {
  export PWD=/github/workspace
  run _canon_path "public/"
  [ "${output}" = "/github/workspace/public" ]
  run _canon_path "./"
  [ "${output}" = "/github/workspace" ]
  run _canon_path "."
  [ "${output}" = "/github/workspace" ]
  run _canon_path "./a/./b"
  [ "${output}" = "/github/workspace/a/b" ]
  export PWD=/
  run _canon_path "./"
  [ "${output}" = "/" ]
  run _canon_path "x"
  [ "${output}" = "/x" ]
}

# ----------------------------------------------------------------------------
# validate_bool — v2.11.3 (#171)
# ----------------------------------------------------------------------------

@test "validate_bool accepts the documented canonical set" {
  for v in true false yes no on off 0 1 ""; do
    run validate_bool "ftp_ssl_allow" "$v"
    [ "$status" -eq 0 ]
  done
}

@test "validate_bool rejects a malicious payload containing '!' (RCE via lftp -e)" {
  run validate_bool "ftp_ssl_allow" 'true; !cat /home/lftp/.netrc'
  [ "$status" -eq 2 ]
  [[ "$output" == *"ftp_ssl_allow must be a bool"* ]]
}

@test "validate_bool rejects a value with a leading semicolon" {
  run validate_bool "ssl_check_hostname" '; !uname'
  [ "$status" -eq 2 ]
}

@test "validate_bool rejects a capitalised value" {
  run validate_bool "ssl_verify_certificate" "True"
  [ "$status" -eq 2 ]
}

@test "validate_bool rejects a numeric string with a suffix" {
  run validate_bool "ftp_use_feat" "1s"
  [ "$status" -eq 2 ]
}

# ----------------------------------------------------------------------------
# normalize_bool — v2.11.7 (#252)
# ----------------------------------------------------------------------------

@test "normalize_bool canonicalises truthy aliases to 'true'" {
  for v in true yes on 1; do
    run normalize_bool "concurrency_lock" "$v"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
  done
}

@test "normalize_bool canonicalises falsy aliases to 'false'" {
  for v in false no off 0 ""; do
    run normalize_bool "delete" "$v"
    [ "$status" -eq 0 ]
    [ "$output" = "false" ]
  done
}

@test "normalize_bool rejects a capitalised value (validate_bool layer)" {
  run normalize_bool "dry_run" "True"
  [ "$status" -eq 2 ]
}

@test "normalize_bool rejects an RCE payload" {
  run normalize_bool "concurrency_lock" 'true; !cat /home/lftp/.netrc'
  [ "$status" -eq 2 ]
}

# ----------------------------------------------------------------------------
# validate_duration — v2.11.3 (#171)
# ----------------------------------------------------------------------------

@test "validate_duration accepts the empty string (default applies)" {
  run validate_duration "net_timeout" ""
  [ "$status" -eq 0 ]
}

@test "validate_duration accepts 'never' (lftp's documented disable sentinel)" {
  run validate_duration "dns_fatal_timeout" "never"
  [ "$status" -eq 0 ]
}

@test "validate_duration accepts digits with s/m/h/d (case-insensitive)" {
  for v in 15 15s 5m 1h 2d 30S 5M 1H 1D; do
    run validate_duration "net_timeout" "$v"
    [ "$status" -eq 0 ]
  done
}

@test "validate_duration rejects unit-only and repeated-unit values" {
  for v in s mhd 5s5m dd 15ss; do
    run validate_duration "net_timeout" "$v"
    [ "$status" -eq 2 ]
    [[ "$output" == *"net_timeout must be a duration"* ]]
  done
}

@test "validate_duration rejects a malicious payload containing '; !'" {
  run validate_duration "net_timeout" '15s; !cat /home/lftp/.netrc'
  [ "$status" -eq 2 ]
  [[ "$output" == *"net_timeout must be a duration"* ]]
}

@test "validate_duration rejects a float" {
  run validate_duration "dns_fatal_timeout" "1.5"
  [ "$status" -eq 2 ]
}

@test "validate_duration rejects leading zeros (F2 audit v2.11.12)" {
  # Symmetric with validate_int's v2.11.7 #253 fix. `00` is a
  # typo for `0` and breaks the same retry-forever sentinel
  # contract. The F2 audit subagent confirmed `00` / `01s`
  # currently pass validate_duration.
  run validate_duration "net_timeout" "00"
  [ "$status" -eq 2 ]
  [[ "$output" == *"leading zeros"* ]]
  run validate_duration "dns_fatal_timeout" "01s"
  [ "$status" -eq 2 ]
  [[ "$output" == *"leading zeros"* ]]
  # Single zero stays accepted — it's the retry-forever sentinel
  # and the documented disable form.
  run validate_duration "net_timeout" "0"
  [ "$status" -eq 0 ]
  # Bare digit followed by a unit stays accepted.
  run validate_duration "net_timeout" "0s"
  [ "$status" -eq 0 ]
  run validate_duration "net_timeout" "5m"
  [ "$status" -eq 0 ]
}

@test "validate_duration rejects a value with embedded text" {
  run validate_duration "net_timeout" "1abc"
  [ "$status" -eq 2 ]
}

@test "validate_duration rejects a negative value" {
  run validate_duration "net_timeout" "-1"
  [ "$status" -eq 2 ]
}

# ----------------------------------------------------------------------------
# validate_glob_pattern — v2.11.3 (#160)
# ----------------------------------------------------------------------------

@test "validate_glob_pattern accepts a simple glob" {
  run validate_glob_pattern "exclude" "*.bak"
  [ "$status" -eq 0 ]
}

@test "validate_glob_pattern accepts a regex with '!' (the over-rejection v2.11.3 fixes)" {
  run validate_glob_pattern "exclude" '!important.txt'
  [ "$status" -eq 0 ]
}

@test "validate_glob_pattern accepts a glob with backtick, dollar, !" {
  # v2.11.3.1 (post-release F2 audit): the v2.11.3 fix accepted `;`
  # and `"` on the premise that the value is "a single argv slot
  # to mirror, never parsed by a shell". That premise was wrong:
  # build_mirror_command concatenates the value unquoted into the
  # `lftp -e` script body, and lftp 4.9.3's parser treats `;`, `&`,
  # `|`, and `"` as command separators / string delimiters even
  # mid-token. So `;`, `&`, `|`, `"` are now rejected (alongside
  # leading-dash and control chars); backtick, dollar, and `!`
  # remain accepted as legitimate PatternSet / regex
  # metacharacters.
  run validate_glob_pattern "exclude" 'foo$bar`baz!qux'
  [ "$status" -eq 0 ]
}

@test "validate_glob_pattern rejects semicolon (lftp -e command separator)" {
  run validate_glob_pattern "exclude" 'foo;echo X;quit'
  [ "$status" -eq 2 ]
  [[ "$output" == *"lftp command separator"* ]]
}

@test "validate_glob_pattern rejects ampersand and pipe" {
  run validate_glob_pattern "exclude" 'foo&bar'
  [ "$status" -eq 2 ]
  run validate_glob_pattern "exclude" 'foo|bar'
  [ "$status" -eq 2 ]
}

@test "validate_glob_pattern rejects double-quote (lftp string delimiter)" {
  run validate_glob_pattern "exclude" '"X"'
  [ "$status" -eq 2 ]
}

@test "validate_glob_pattern accepts an empty string" {
  run validate_glob_pattern "exclude" ""
  [ "$status" -eq 0 ]
}

@test "validate_glob_pattern rejects newline" {
  # v2.11.3.1: grep's POSIX [:cntrl:] never matches \n (grep
  # splits on \n before matching), so the v2.11.3 implementation
  # was incomplete. Add an explicit newline check via case.
  run validate_glob_pattern "exclude" 'foo
bar'
  [ "$status" -eq 2 ]
}

@test "validate_glob_pattern rejects a leading dash (would be misread as mirror option)" {
  run validate_glob_pattern "exclude" "-rf"
  [ "$status" -eq 2 ]
  [[ "$output" == *"starts with a dash"* ]]
}

# ----------------------------------------------------------------------------
# validate_lftp_settings
# ----------------------------------------------------------------------------

@test "validate_lftp_settings accepts the empty string" {
  run validate_lftp_settings ""
  [ "$status" -eq 0 ]
}

@test "validate_lftp_settings accepts 1 ';' chained directive" {
  run validate_lftp_settings "set cache:cache-empty-listings true;"
  [ "$status" -eq 0 ]
}

@test "validate_lftp_settings accepts 3 ';' chained directives (documented max)" {
  run validate_lftp_settings "set a:1; set b:2; set c:3;"
  [ "$status" -eq 0 ]
}

@test "validate_lftp_settings rejects 4 ';' chained directives" {
  run validate_lftp_settings "set a:1; set b:2; set c:3; set d:4;"
  [ "$status" -eq 2 ]
  [[ "$output" == *"\";\" characters (max 3)"* ]]
}

@test "validate_lftp_settings rejects control characters" {
  # Use a tab; see the note in validate_path's control-character
  # test for why newlines would not be caught.
  run validate_lftp_settings $'set foo:bar\t'
  [ "$status" -eq 2 ]
  [[ "$output" == *"control characters"* ]]
}

@test "validate_lftp_settings rejects backtick" {
  run validate_lftp_settings "set foo:\`uname\`"
  [ "$status" -eq 2 ]
  [[ "$output" == *"backtick"* ]]
}

@test "validate_lftp_settings rejects dollar" {
  run validate_lftp_settings "set foo:\$HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"dollar"* ]]
}

@test "validate_lftp_settings rejects '!' (lftp shell escape)" {
  run validate_lftp_settings "set x:y; !uname; set a:b"
  [ "$status" -eq 2 ]
  [[ "$output" == *"\"!\""* ]]
}

@test "validate_lftp_settings accepts double-quote (documented set-directive string delimiter — F2 audit finding #172 reviewed in v2.11.8)" {
  # F2 audit (#172) claimed validate_lftp_settings should reject
  # `"` because the value flows into the `lftp -e` body. Validated
  # against the documented use case in action.yml:85: the example
  # `set http:user-agent "firefox";` is a 3-`;`-chained string with
  # embedded double-quotes, and tests/smoke.sh:286 pins it as a
  # documented happy path. The closing of #172 therefore means
  # ensuring the validator rejects `"` only where it is dangerous
  # (paths in validate_path; mirror -X values in
  # validate_glob_pattern), not in validate_lftp_settings where
  # `"` is the documented string-delimiter for lftp's
  # `set <key> "value";` directive. v2.11.8 close-doc.
  run validate_lftp_settings 'set cache:cache-empty-listings true; set cmd:status-interval 1s; set http:user-agent "firefox";'
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------------------
# validate_required / validate_credential — FND-0008 / FND-0014
# ------------------------------------------------------------------------------
@test "validate_required rejects an empty value with exit 2 naming the input" {
  for n in server user password; do
    run validate_required "$n" ""
    [ "$status" -eq 2 ]
    [ "$output" = "ERROR: $n must not be empty" ]
  done
}

@test "validate_required accepts a non-empty value" {
  run validate_required "user" "u"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validate_credential accepts @ : / % and other printable characters" {
  for v in 'deploy@example.com' 'a:b' 'a/b' '100%' 'p#ss?w0rd![]{}' 'pässwörd'; do
    run validate_credential "user" "$v"
    [ "$status" -eq 0 ]
  done
}

@test "validate_credential rejects whitespace and control characters without echoing the value" {
  tab=$(printf '\t')
  cr=$(printf '\r')
  esc=$(printf '\033')
  del=$(printf '\177')
  nl='Secret
default'
  for v in "Secret pw" "Secret${tab}pw" "Secret${cr}pw" "$nl" "Secret${esc}pw" "Secret${del}pw" " "; do
    run validate_credential "password" "$v"
    [ "$status" -eq 2 ]
    [ "$output" = "ERROR: password must not contain whitespace or control characters (.netrc cannot hold them)" ]
    [[ "$output" != *Secret* ]]
  done
}

# ------------------------------------------------------------------------------
# tls_max_version — #361
# ------------------------------------------------------------------------------
@test "validate_tls_max_version accepts 1.2 and 1.3" {
  for v in 1.2 1.3; do
    run validate_tls_max_version "$v"
    [ "$status" -eq 0 ]
  done
}

@test "validate_tls_max_version rejects other versions, spellings and payloads with exit 2" {
  for v in "" 1.1 1.0 1.4 TLSv1.2 "1.2 " "1.2; !id" 'TLSv1.3$(id)'; do
    run validate_tls_max_version "$v"
    [ "$status" -eq 2 ]
    [[ "$output" == *"tls_max_version must be"* ]]
  done
}

@test "apply_tls_max_version 1.2 points OPENSSL_CONF at the TLS 1.2 config" {
  unset OPENSSL_CONF
  apply_tls_max_version "1.2"
  [ "${OPENSSL_CONF}" = "/app/openssl-tls12.cnf" ]
}

@test "apply_tls_max_version 1.3 leaves OpenSSL on its defaults" {
  OPENSSL_CONF=/app/openssl-tls12.cnf
  export OPENSSL_CONF
  apply_tls_max_version "1.3"
  [ -z "${OPENSSL_CONF+set}" ]
}

# FND-0072: the cap only works if OpenSSL can follow the whole chain
# openssl_conf -> [X] ssl_conf -> [Y] system_default -> [Z] MaxProtocol.
# _tls12_cnf_get FILE SECTION KEY prints the value of KEY in SECTION and
# fails (exit 3: no such section, exit 4: no such key) otherwise. Lines
# before the first header belong to section "default", as in OpenSSL.
# Rules: "#" starts a comment, CR (CRLF files, which OpenSSL accepts)
# counts as whitespace, whitespace around "=" and inside "[ ]" is
# ignored, a later duplicate key wins. OpenSSL's real parser (conf_def.c)
# also strips quotes, honours "\" escapes, expands $var and accepts
# "section::key"; this file uses none of that, so the simple parser keeps
# the same meaning for it. It also does not check that OpenSSL would
# accept the file at all (a line without `=`, an unclosed `[`, `\`
# continuation, `.include`); integration scenario 30 is the end-to-end
# guard. TLS12_CNF overrides the file under test (used to prove the test
# fails on a broken chain).
_tls12_cnf_get() {
  awk -v want_sec="$2" -v want_key="$3" '
    BEGIN { sec = "default"; seen = (want_sec == "default"); found = 0 }
    {
      sub(/#.*/, "")
      sub(/^[ \t\r]+/, ""); sub(/[ \t\r]+$/, "")
    }
    $0 == "" { next }
    /^\[/ {
      s = $0
      sub(/^\[[ \t]*/, "", s); sub(/[ \t]*\].*$/, "", s)
      sec = s
      if (sec == want_sec) seen = 1
      next
    }
    sec == want_sec {
      i = index($0, "=")
      if (i == 0) next
      k = substr($0, 1, i - 1); v = substr($0, i + 1)
      sub(/[ \t]+$/, "", k); sub(/^[ \t]+/, "", v)
      if (k == want_key) { val = v; found = 1 }
    }
    END {
      if (!seen) { print "tls12.cnf: no section [" want_sec "]" > "/dev/stderr"; exit 3 }
      if (!found) { print "tls12.cnf: no key " want_key " in [" want_sec "]" > "/dev/stderr"; exit 4 }
      print val
    }
  ' "$1"
}

@test "openssl-tls12.cnf caps the protocol at TLS 1.2" {
  _cnf="${TLS12_CNF:-${BATS_TEST_DIRNAME}/../../openssl-tls12.cnf}"
  [ -f "${_cnf}" ]
  # Follow the names instead of hard-coding them: a renamed but
  # consistent chain passes, a broken link fails.
  _init="$(_tls12_cnf_get "${_cnf}" default openssl_conf)"
  [ -n "${_init}" ]
  _ssl="$(_tls12_cnf_get "${_cnf}" "${_init}" ssl_conf)"
  [ -n "${_ssl}" ]
  _sys="$(_tls12_cnf_get "${_cnf}" "${_ssl}" system_default)"
  [ -n "${_sys}" ]
  _max="$(_tls12_cnf_get "${_cnf}" "${_sys}" MaxProtocol)"
  [ "${_max}" = "TLSv1.2" ]
}

# ----------------------------------------------------------------------------
# #195 / FND-0006: the server userinfo guard in entrypoint.sh. The guard runs
# before add_masks, so the test runs a scratch copy of entrypoint.sh (the
# /app/ and /home/lftp paths rewritten into BATS_TEST_TMPDIR, the same way as
# the FND-0043 harness in lock.bats) against a lib.sh copy whose add_masks
# prints a marker and exits 0. The marker means "got past the guard".
# ----------------------------------------------------------------------------

_run_entrypoint_server_guard() {
  local root="${BATS_TEST_DIRNAME}/../.."
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "${app}" "${BATS_TEST_TMPDIR}/home/lftp"
  cp "${root}/lib.sh" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  cat >> "${app}/lib.sh" <<'STUB'

add_masks() { printf 'PAST_SERVER_GUARD\n'; exit 0; }
STUB
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${BATS_TEST_TMPDIR}/home/lftp#g" \
    "${root}/entrypoint.sh" > "${app}/entrypoint.sh"
  # bash, not sh: entrypoint.sh needs `set -o pipefail` (dash lacks it).
  HOME="${BATS_TEST_TMPDIR}/home" INPUT_SERVER="$1" INPUT_USER="ftptest" INPUT_PASSWORD="pw" \
    run bash -eu "${app}/entrypoint.sh"
}

@test "entrypoint: #195/FND-0006: user:pass@ without a scheme is rejected with exit 2, secret not echoed" {
  for v in 'deploy:s3cretPW@ftp.example.com' 'deploy:s3cretPW@ftp.example.com:21' 'deploy:s3c@retPW@ftp.example.com' 'deploy:@ftp.example.com' 'deploy:s3cretPW@ftp.example.com/x://y'; do
    _run_entrypoint_server_guard "$v"
    echo "server=${v} status=${status}"; echo "${output}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"ERROR: server must not contain URL userinfo with embedded password (user:pass@host); use the user/password inputs instead."* ]]
    [[ "${output}" != *"PAST_SERVER_GUARD"* ]]
    [[ "${output}" != *"s3c"* ]]
    [[ "${output}" != *"retPW"* ]]
  done
}

@test "entrypoint: #195: ftp://user:pass@host is still rejected with exit 2" {
  _run_entrypoint_server_guard 'ftp://deploy:s3cretPW@ftp.example.com:21'
  echo "status=${status}"; echo "${output}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"ERROR: server must not contain URL userinfo with embedded password"* ]]
  [[ "${output}" != *"s3cretPW"* ]]
}

@test "entrypoint: #195/FND-0006: hosts, ports, IPv6 literals and a bare user@ get past the guard" {
  for v in 'ftp://user@host:21' 'ftp://user@host' 'user@host:21' 'user@host' 'host:21' \
           '[2001:db8::1]:21' 'ftp://[2001:db8::1]:21' 'ftps://[2001:db8::1]:990' \
           'ftps://host' 'user@[2001:db8::1]:21'; do
    _run_entrypoint_server_guard "$v"
    echo "server=${v} status=${status}"; echo "${output}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PAST_SERVER_GUARD"* ]]
    [[ "${output}" != *"embedded password"* ]]
  done
}

# ----------------------------------------------------------------------------
# FND-0013: a rejected gate boolean must end entrypoint.sh with exit 2 however
# it is invoked. The exit inside `X=$(normalize_bool ...)` ends only the
# subshell; before the fix the script stopped only if errexit was on. The
# shebang's -eu does not apply to `bash ./entrypoint.sh`, so the plain-bash
# case (no -e/-u) is the one that failed on HEAD. The marker printed by the
# add_masks stub (the first command after the bool block and the userinfo
# guard) shows whether the script carried on past the gate.
# ENTRYPOINT_SRC overrides the script under test (used to prove the tests
# fail on the pre-fix entrypoint.sh). dash is not covered: entrypoint.sh has
# `set -o pipefail`, which dash rejects with exit 2 before the gate is reached.
# ----------------------------------------------------------------------------

_bool_gate_case() {
  local flags="$1" name="$2" val="$3" out
  local root="${BATS_TEST_DIRNAME}/../.."
  local src="${ENTRYPOINT_SRC:-${root}/entrypoint.sh}"
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "${app}" "${BATS_TEST_TMPDIR}/home/lftp"
  cp "${root}/lib.sh" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  printf '\nadd_masks() { printf "PAST_BOOL_GATE\\n"; exit 0; }\n' >> "${app}/lib.sh"
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${BATS_TEST_TMPDIR}/home/lftp#g" \
    "${src}" > "${app}/entrypoint.sh"
  if [ -n "${flags}" ]; then
    out=$(env HOME="${BATS_TEST_TMPDIR}/home" INPUT_SERVER="ftp.example.com" INPUT_USER="ftptest" \
      INPUT_PASSWORD="pw" "${name}=${val}" bash "${flags}" "${app}/entrypoint.sh" 2>&1) && status=0 || status=$?
  else
    out=$(env HOME="${BATS_TEST_TMPDIR}/home" INPUT_SERVER="ftp.example.com" INPUT_USER="ftptest" \
      INPUT_PASSWORD="pw" "${name}=${val}" bash "${app}/entrypoint.sh" 2>&1) && status=0 || status=$?
  fi
  output="${out}"
}

@test "entrypoint: FND-0013: bad gate booleans exit 2 under plain bash (no -e/-u), nothing runs after the gate" {
  for c in 'concurrency_lock=True' 'dry_run=TRUE' 'delete=Yes' 'no_symlinks=2' 'debug=on;id'; do
    name="INPUT_$(printf '%s' "${c%%=*}" | tr 'a-z' 'A-Z')"
    _bool_gate_case "" "${name}" "${c#*=}"
    echo "case=${c} status=${status}"; echo "${output}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"ERROR: ${c%%=*} must be a bool"* ]]
    [[ "${output}" != *"PAST_BOOL_GATE"* ]]
  done
}

@test "entrypoint: FND-0013: bad gate booleans exit 2 under bash -eu, nothing runs after the gate" {
  for c in 'concurrency_lock=True' 'dry_run=TRUE' 'delete=Yes' 'no_symlinks=2' 'debug=on;id'; do
    name="INPUT_$(printf '%s' "${c%%=*}" | tr 'a-z' 'A-Z')"
    _bool_gate_case "-eu" "${name}" "${c#*=}"
    echo "case=${c} status=${status}"; echo "${output}"
    [ "${status}" -eq 2 ]
    [[ "${output}" == *"ERROR: ${c%%=*} must be a bool"* ]]
    [[ "${output}" != *"PAST_BOOL_GATE"* ]]
  done
}

@test "entrypoint: FND-0013: valid aliases (debug=yes, concurrency_lock=on) pass the gate under plain bash and bash -eu" {
  for flags in "" "-eu"; do
    _bool_gate_case "${flags}" INPUT_DEBUG yes
    echo "flags='${flags}' status=${status}"; echo "${output}"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PAST_BOOL_GATE"* ]]
    [[ "${output}" != *"must be a bool"* ]]
    _bool_gate_case "${flags}" INPUT_CONCURRENCY_LOCK on
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"PAST_BOOL_GATE"* ]]
  done
}

# ----------------------------------------------------------------------------
# FND-0015: entrypoint-level checks of the local_dir home guard. The scratch
# entrypoint has /home/lftp rewritten to BATS_TEST_TMPDIR/home/lftp, so the
# guard is called with that path as HOME_DIR (the production call passes the
# literal /home/lftp). The script runs with cwd BATS_TEST_TMPDIR/ws (outside
# the rewritten home). Mode "reject" runs the real write_netrc, so a leaked
# netrc would show up as a file; mode "accept" stubs write_netrc with a marker
# and exit 0, which shows the script got past the gate. ENTRYPOINT_SRC and
# LIB_SRC override the scripts under test (used to prove the tests fail on a
# tree without the FND-0015 change).
# ----------------------------------------------------------------------------

_local_dir_gate_case() {
  local mode="$1" val="$2"
  local root="${BATS_TEST_DIRNAME}/../.."
  local src="${ENTRYPOINT_SRC:-${root}/entrypoint.sh}"
  local lib="${LIB_SRC:-${root}/lib.sh}"
  local app="${BATS_TEST_TMPDIR}/app"
  local out
  rm -rf "${BATS_TEST_TMPDIR}/home"
  mkdir -p "${app}" "${BATS_TEST_TMPDIR}/home/lftp" "${BATS_TEST_TMPDIR}/ws"
  cp "${lib}" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  if [ "${mode}" = "accept" ]; then
    printf '\nwrite_netrc() { printf "PAST_LOCAL_DIR_GATE\\n"; exit 0; }\n' >> "${app}/lib.sh"
  fi
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${BATS_TEST_TMPDIR}/home/lftp#g" \
    "${src}" > "${app}/entrypoint.sh"
  # Failing lftp and no-op sleep stubs, so a regression (guard missing) ends fast instead of
  # trying to reach a server.
  mkdir -p "${BATS_TEST_TMPDIR}/fakebin"
  printf '#!/bin/sh\nexit 1\n' > "${BATS_TEST_TMPDIR}/fakebin/lftp"
  printf '#!/bin/sh\nexit 0\n' > "${BATS_TEST_TMPDIR}/fakebin/sleep"
  chmod +x "${BATS_TEST_TMPDIR}/fakebin/lftp" "${BATS_TEST_TMPDIR}/fakebin/sleep"
  out=$(cd "${BATS_TEST_TMPDIR}/ws" && env PATH="${BATS_TEST_TMPDIR}/fakebin:${PATH}" HOME="${BATS_TEST_TMPDIR}/home" INPUT_SERVER="ftp.example.com" \
    INPUT_USER="ftptest" INPUT_PASSWORD="pw" INPUT_REMOTE_DIR="./" INPUT_LOCAL_DIR="${val}" INPUT_MAX_RETRIES=1 \
    bash "${app}/entrypoint.sh" 2>&1) && status=0 || status=$?
  output="${out}"
}

@test "entrypoint: FND-0015: a local_dir that is, contains or lies inside the home exits 2 with the ERROR, before the .netrc is written" {
  h="${BATS_TEST_TMPDIR}/home/lftp"
  for v in "${h}" "${h}/" "${h}/sub" "${h}/.lftp-logs" "${BATS_TEST_TMPDIR}/home" /; do
    _local_dir_gate_case reject "${v}"
    echo "local_dir=${v} status=${status}"; echo "${output}"
    [ "${status}" -eq 2 ] || return 1
    [[ "${output}" == *"ERROR: local_dir '"* ]] || return 1
    [[ "${output}" == *"holds the FTP credentials"* ]] || return 1
    [ ! -e "${h}/.netrc" ] || { echo "netrc was written for local_dir=${v}"; return 1; }
  done
}

@test "entrypoint: FND-0015: an accepted local_dir (workspace-relative, sibling of the home) gets past the gate to write_netrc" {
  h="${BATS_TEST_TMPDIR}/home/lftp"
  for v in ./ public/ "${h}x" "${h}-site/" "${BATS_TEST_TMPDIR}/site/" /data/; do
    _local_dir_gate_case accept "${v}"
    echo "local_dir=${v} status=${status}"; echo "${output}"
    [ "${status}" -eq 0 ] || return 1
    [[ "${output}" == *"PAST_LOCAL_DIR_GATE"* ]] || return 1
    [[ "${output}" != *"holds the FTP credentials"* ]] || return 1
  done
}

@test "entrypoint: FND-0015: validate_path still runs first, a '..' value gets its own ERROR, not the home-dir one" {
  h="${BATS_TEST_TMPDIR}/home/lftp"
  for v in "${h}/../lftp" "${h}/.." ../x ../../etc/; do
    _local_dir_gate_case reject "${v}"
    echo "local_dir=${v} status=${status}"; echo "${output}"
    [ "${status}" -eq 2 ] || return 1
    [[ "${output}" == *"local_dir contains \"..\" path traversal"* ]] || return 1
    [[ "${output}" != *"holds the FTP credentials"* ]] || return 1
    [ ! -e "${h}/.netrc" ] || return 1
  done
}

@test "entrypoint: FND-0015: the home-dir check also runs before the netrc when the rejected value is the default './' and cwd is the home" {
  h="${BATS_TEST_TMPDIR}/home/lftp"
  local root="${BATS_TEST_DIRNAME}/../.."
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "${app}" "${h}"
  cp "${LIB_SRC:-${root}/lib.sh}" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${h}#g" "${ENTRYPOINT_SRC:-${root}/entrypoint.sh}" > "${app}/entrypoint.sh"
  mkdir -p "${BATS_TEST_TMPDIR}/fakebin"
  printf '#!/bin/sh\nexit 1\n' > "${BATS_TEST_TMPDIR}/fakebin/lftp"
  printf '#!/bin/sh\nexit 0\n' > "${BATS_TEST_TMPDIR}/fakebin/sleep"
  chmod +x "${BATS_TEST_TMPDIR}/fakebin/lftp" "${BATS_TEST_TMPDIR}/fakebin/sleep"
  run bash -c 'cd "$1" && PATH="$4:$PATH" HOME="$2" INPUT_SERVER=ftp.example.com INPUT_USER=ftptest INPUT_PASSWORD=pw INPUT_LOCAL_DIR=./ INPUT_REMOTE_DIR=./ bash "$3" 2>&1' _ "${h}" "${BATS_TEST_TMPDIR}/home" "${app}/entrypoint.sh" "${BATS_TEST_TMPDIR}/fakebin"
  echo "status=${status}"; echo "${output}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"ERROR: local_dir './' (resolved to ${h})"* ]]
  [ ! -e "${h}/.netrc" ]
}

# FND-0015 round 2, entrypoint level. The new classes exit 2 before the .netrc
# is written; the older validate_path rejections still fire first (their own
# ERROR, not the new ones).
@test "entrypoint: FND-0015 r3: a backslash, leading-~ or file: local_dir exits 2 with its own ERROR, before the .netrc is written" {
  h="${BATS_TEST_TMPDIR}/home/lftp"
  for entry in '/home/l\ftp/|contains a backslash' '\/|contains a backslash' \
               '~/|starts with "~"' '~|starts with "~"' \
               'file:/home/lftp/|starts with "file:"' 'file:///home/lftp/|starts with "file:"'; do
    v="${entry%%|*}"
    frag="${entry#*|}"
    _local_dir_gate_case reject "${v}"
    echo "local_dir=${v} status=${status}"; echo "${output}"
    [ "${status}" -eq 2 ] || return 1
    [[ "${output}" == *"ERROR: local_dir ${frag}"* ]] || { echo "missing '${frag}'"; return 1; }
    [[ "${output}" != *"Choose a directory under the workspace"* ]] || return 1
    [ ! -e "${h}/.netrc" ] || { echo "netrc was written for local_dir=${v}"; return 1; }
  done
}

@test "entrypoint: FND-0015 r2: harmless lookalikes (a/~/b/, FILE:x/, File:/home/lftp/) still get past the gate" {
  for v in 'a/~/b/' 'FILE:x/' 'File:/home/lftp/'; do
    _local_dir_gate_case accept "${v}"
    echo "local_dir=${v} status=${status}"; echo "${output}"
    [ "${status}" -eq 0 ] || return 1
    [[ "${output}" == *"PAST_LOCAL_DIR_GATE"* ]] || return 1
  done
}

@test "entrypoint: FND-0015 r2: validate_path rejections (double quote, dollar HOME forms, leading dash) still fire first with their own ERROR" {
  h="${BATS_TEST_TMPDIR}/home/lftp"
  for entry in '/home/"lftp"/|contains double-quote' '"/"|contains double-quote' \
               '$HOME/|contains dollar' '${HOME}/|contains dollar' \
               '-/|starts with a dash' '-rf|starts with a dash'; do
    v="${entry%%|*}"
    frag="${entry#*|}"
    _local_dir_gate_case reject "${v}"
    echo "local_dir=${v} status=${status}"; echo "${output}"
    [ "${status}" -eq 2 ] || return 1
    [[ "${output}" == *"ERROR: local_dir ${frag}"* ]] || { echo "missing '${frag}'"; return 1; }
    [[ "${output}" != *"single quote"* ]] || return 1
    [[ "${output}" != *"holds the FTP credentials"* ]] || return 1
    [ ! -e "${h}/.netrc" ] || return 1
  done
}

# ----------------------------------------------------------------------------
# FND-0015 round 3: run_lftp_once passes local_dir inside lftp double quotes,
# so the gate only needs the backslash, leading "~" and leading "file:" rules.
# These tests capture the -e script with a fake `timeout` (the real lftp is
# never started) and call the real run_lftp_once from lib.sh. Stubs use an
# explicit bash shebang (/bin/sh is dash on CI).
# ----------------------------------------------------------------------------

# _fnd15_lftp_script LOCAL REMOTE : sets ${script} to the lftp -e argument.
_fnd15_lftp_script() {
  local fb="${BATS_TEST_TMPDIR}/fb15"
  mkdir -p "${fb}"
  printf '#!/bin/bash\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s/argv"\nexit 0\n' "${BATS_TEST_TMPDIR}" > "${fb}/timeout"
  chmod +x "${fb}/timeout"
  rm -f "${BATS_TEST_TMPDIR}/argv"
  PATH="${fb}:${PATH}" run_lftp_once "ftp://h" "set a b;" "mirror -R --verbose" "$1" "$2" \
    "${BATS_TEST_TMPDIR}/lftp.log" 5s 1s "" >/dev/null 2>&1 || {
    echo "run_lftp_once failed for local_dir='$1'"; return 1
  }
  script=$(grep -A1 -Fx -e '-e' "${BATS_TEST_TMPDIR}/argv" | tail -n 1)
  [ -n "${script}" ] || { echo "no -e argument captured"; cat "${BATS_TEST_TMPDIR}/argv"; return 1; }
}

@test "run_lftp_once: FND-0015 r3: local_dir is double-quoted in the -e script, remote_dir is not (exact string)" {
  _fnd15_lftp_script "site/" "./rem" || return 1
  want='set a b; mirror -R --verbose "site/" ./rem; quit;'
  [ "${script}" = "${want}" ] || { echo "got:  ${script}"; echo "want: ${want}"; return 1; }
  _fnd15_lftp_script "/github/workspace/" "./" || return 1
  want='set a b; mirror -R --verbose "/github/workspace/" ./; quit;'
  [ "${script}" = "${want}" ] || { echo "got:  ${script}"; echo "want: ${want}"; return 1; }
  _fnd15_lftp_script "./" "./" || return 1
  want='set a b; mirror -R --verbose "./" ./; quit;'
  [ "${script}" = "${want}" ] || { echo "got:  ${script}"; echo "want: ${want}"; return 1; }
}

@test "run_lftp_once: FND-0015 r3: '>' and '<' forms stay inside the quotes, never loose in the script" {
  for v in '/home/lftp>x/' '/home/>x/' 'a>b/' 'a<b/'; do
    _fnd15_lftp_script "${v}" "./" || return 1
    want="set a b; mirror -R --verbose \"${v}\" ./; quit;"
    [ "${script}" = "${want}" ] || { echo "v=${v}"; echo "got:  ${script}"; echo "want: ${want}"; return 1; }
  done
}

@test "run_lftp_once: FND-0015 r3: single quotes and '#' are carried verbatim inside the double quotes" {
  for v in "it's/" "/home/'lftp'/" "''/" '#x/' '/home/lftp#x/'; do
    _fnd15_lftp_script "${v}" "./" || return 1
    case "${script}" in
      *" \"${v}\" ./; quit;") ;;
      *) echo "v=${v}"; echo "got: ${script}"; return 1 ;;
    esac
  done
}

@test "run_lftp_once: FND-0015 r3: remote_dir stays unquoted (scope is local_dir only)" {
  _fnd15_lftp_script "site/" "remote dir" || return 1
  [ "${script}" = 'set a b; mirror -R --verbose "site/" remote dir; quit;' ] || { echo "${script}"; return 1; }
}

@test "validate_local_dir_outside_home: FND-0015 r3: forms that are literal inside the quotes are accepted" {
  export PWD=/github/workspace
  for v in "it's/" "/home/'lftp'/" "''/" "'/" 'a>b/' 'a<b/' '#x/' '/home/lftp#x/' \
           '/home/lftp>x/' '/home/>x/'; do
    _fnd15_accept "${v}" /home/lftp || return 1
  done
}

@test "validate_local_dir_outside_home: FND-0015 r3: relative and /github/workspace paths are accepted" {
  export PWD=/github/workspace
  for v in site/ ./ /github/workspace/ /github/workspace/site/; do
    _fnd15_accept "${v}" /home/lftp || return 1
  done
}

@test "validate_local_dir_outside_home: FND-0015 r3: raw backslash forms exit 2 with the backslash ERROR naming local_dir" {
  export PWD=/github/workspace
  bs='\'
  for v in '/home/l\ftp/' '\/' '\' 'a\"b' '\~/' 'fi\le:/x/' "/home/lftp/${bs}"; do
    run validate_local_dir_outside_home "local_dir" "${v}" /home/lftp
    if [ "${status}" -ne 2 ]; then echo "v=${v} status=${status}"; echo "${output}"; return 1; fi
    case "${output}" in
      "ERROR: local_dir contains a backslash: ${v};"*) ;;
      *) echo "v=${v}: wrong ERROR"; echo "${output}"; return 1 ;;
    esac
  done
}

@test "validate_local_dir_outside_home: FND-0015 r3: still rejected, leading ~ / file: rules and the home check" {
  export PWD=/github/workspace
  for v in '~' '~/' '~lftp/' 'file:/home/lftp/' 'file:///home/lftp/' 'file:/' 'file:~/'; do
    run validate_local_dir_outside_home "local_dir" "${v}" /home/lftp
    if [ "${status}" -ne 2 ]; then echo "v=${v} status=${status}"; echo "${output}"; return 1; fi
    case "${output}" in
      "ERROR: local_dir starts with \"~\": ${v};"* | "ERROR: local_dir starts with \"file:\": ${v};"*) ;;
      *) echo "v=${v}: wrong ERROR"; echo "${output}"; return 1 ;;
    esac
  done
  for v in /home/lftp/ /; do
    _fnd15_reject "${v}" /home/lftp || return 1
  done
}

@test "entrypoint: FND-0015 r3: backslash forms exit 2 before the .netrc is written (validate_path fires first for a double quote)" {
  h="${BATS_TEST_TMPDIR}/home/lftp"
  for entry in '/home/l\ftp/|contains a backslash' '\/|contains a backslash' '\~/|contains a backslash' \
               'fi\le:/x/|contains a backslash' 'a\"b|contains double-quote'; do
    v="${entry%%|*}"
    frag="${entry#*|}"
    _local_dir_gate_case reject "${v}"
    echo "local_dir=${v} status=${status}"; echo "${output}"
    [ "${status}" -eq 2 ] || return 1
    [[ "${output}" == *"ERROR: local_dir ${frag}"* ]] || { echo "missing '${frag}'"; return 1; }
    [ ! -e "${h}/.netrc" ] || { echo "netrc was written for local_dir=${v}"; return 1; }
  done
}

@test "entrypoint: FND-0015 r3: a trailing backslash is normalized to '\\/' and still exits 2 with the backslash ERROR" {
  _local_dir_gate_case reject 'site\'
  echo "status=${status}"; echo "${output}"
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"ERROR: local_dir contains a backslash"* ]]
}

@test "entrypoint: FND-0015 r3: a>b/ and the other literal-in-quotes forms get past the gate" {
  for v in 'a>b/' 'a<b/' "it's/" '#x/' "/home/'lftp'/" '/home/lftp>x/'; do
    _local_dir_gate_case accept "${v}"
    echo "local_dir=${v} status=${status}"; echo "${output}"
    [ "${status}" -eq 0 ] || return 1
    [[ "${output}" == *"PAST_LOCAL_DIR_GATE"* ]] || return 1
  done
}

# ----------------------------------------------------------------------------
# FND-0099: validate_glob_pattern rejects an exclude item that contains a
# backslash or a single quote. build_mirror_command appends each item unquoted
# to the lftp -e script; lftp reads `\` as an escape and `'` as a quote, so the
# paths after the -X items could become part of the glob. Items are trimmed
# before the check, so the ERROR names the trimmed item. `<` and `#` are
# harmless in lftp 4.9.3 and are pinned as accepted. `>` is rejected too
# (FND-0100, decided; see the FND-0100 tests below).
# LIB_SRC / ENTRYPOINT_SRC override the scripts under test (used to prove the
# tests fail on HEAD).
# ----------------------------------------------------------------------------

# _fnd99_expect_reject VALUE KIND ITEM: runs the validator in the current shell
# context via `run`, checks exit 2 and the exact ERROR line for ITEM.
_fnd99_expect_reject() {
  local value="$1" kind="$2" item="$3" want
  case "${kind}" in
    backslash) want="ERROR: exclude item contains a backslash (lftp escape character): ${item}" ;;
    quote)     want="ERROR: exclude item contains a single quote (lftp quote character): ${item}" ;;
  esac
  run validate_glob_pattern "exclude" "${value}"
  if [ "${status}" -ne 2 ] || [ "${output}" != "${want}" ]; then
    printf 'CASE value=[%s] status=%s\n  want=[%s]\n  got =[%s]\n' "${value}" "${status}" "${want}" "${output}"
    return 1
  fi
}

@test "validate_glob_pattern: FND-0099: an exclude item with a backslash exits 2 with the ERROR naming the item" {
  bs='\'
  _fnd99_expect_reject "a${bs}" backslash "a${bs}" || return 1
  _fnd99_expect_reject "${bs}" backslash "${bs}" || return 1
  _fnd99_expect_reject "a${bs}b" backslash "a${bs}b" || return 1
  _fnd99_expect_reject "*.lo${bs}g" backslash "*.lo${bs}g" || return 1
  _fnd99_expect_reject "!important${bs}.txt" backslash "!important${bs}.txt" || return 1
}

@test "validate_glob_pattern: FND-0099: a backslash in any list position or after trimming is still rejected (the ERROR shows the trimmed item)" {
  bs='\'
  _fnd99_expect_reject "x,a${bs} ,y" backslash "a${bs}" || return 1
  _fnd99_expect_reject " a${bs} " backslash "a${bs}" || return 1
  _fnd99_expect_reject "ok.txt,b${bs}c" backslash "b${bs}c" || return 1
}

@test "validate_glob_pattern: FND-0099: an exclude item with a single quote exits 2 with the ERROR naming the item" {
  q="'"
  _fnd99_expect_reject "a${q}" quote "a${q}" || return 1
  _fnd99_expect_reject "${q}*.log" quote "${q}*.log" || return 1
  _fnd99_expect_reject "it${q}s.txt" quote "it${q}s.txt" || return 1
}

@test "validate_glob_pattern: FND-0099: an even number of single quotes across items is still rejected (first offending item named)" {
  q="'"
  _fnd99_expect_reject "a${q},b${q}" quote "a${q}" || return 1
  _fnd99_expect_reject "ok,a${q},b${q}" quote "a${q}" || return 1
}

@test "validate_glob_pattern: FND-0099: ordinary glob excludes still pass with status 0 and no output" {
  for v in '*.log' '.git/' 'node_modules/' 'dir/*.tmp' '*.log,.git/,node_modules/,dir/*.tmp' \
           '*.map, *.bak, node_modules/' '!important.txt' 'a<x' '#a'; do
    run validate_glob_pattern "exclude" "${v}"
    if [ "${status}" -ne 0 ] || [ -n "${output}" ]; then
      printf 'CASE value=[%s] status=%s output=[%s]\n' "${v}" "${status}" "${output}"
      return 1
    fi
  done
}

# _fnd99_entry_case EXCLUDE REMOTE_DIR MODE: runs the scratch entrypoint (same
# rewrite as _local_dir_gate_case) with INPUT_EXCLUDE and INPUT_REMOTE_DIR set.
# Mode "reject" runs the real write_netrc; a failing lftp stub logs every call
# to lftp.calls. Mode "accept" stubs write_netrc with a marker and exit 0.
_fnd99_entry_case() {
  local excl="$1" rdir="$2" mode="$3"
  local root="${BATS_TEST_DIRNAME}/../.."
  local src="${ENTRYPOINT_SRC:-${root}/entrypoint.sh}"
  local lib="${LIB_SRC:-${root}/lib.sh}"
  local app="${BATS_TEST_TMPDIR}/app" fb="${BATS_TEST_TMPDIR}/fakebin" out
  rm -rf "${BATS_TEST_TMPDIR}/home" "${fb}" "${BATS_TEST_TMPDIR}/lftp.calls"
  mkdir -p "${app}" "${BATS_TEST_TMPDIR}/home/lftp" "${BATS_TEST_TMPDIR}/ws" "${fb}"
  cp "${lib}" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  if [ "${mode}" = "accept" ]; then
    printf '\nwrite_netrc() { printf "PAST_EXCLUDE_GATE\\n"; exit 0; }\n' >> "${app}/lib.sh"
  fi
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${BATS_TEST_TMPDIR}/home/lftp#g" \
    "${src}" > "${app}/entrypoint.sh"
  printf '#!/bin/sh\necho called >> "%s/lftp.calls"\nexit 1\n' "${BATS_TEST_TMPDIR}" > "${fb}/lftp"
  printf '#!/bin/sh\nexit 0\n' > "${fb}/sleep"
  chmod +x "${fb}/lftp" "${fb}/sleep"
  out=$(cd "${BATS_TEST_TMPDIR}/ws" && env PATH="${fb}:${PATH}" HOME="${BATS_TEST_TMPDIR}/home" \
    INPUT_SERVER="ftp.example.com" INPUT_USER="ftptest" INPUT_PASSWORD="pw" \
    INPUT_REMOTE_DIR="${rdir}" INPUT_LOCAL_DIR="./" INPUT_EXCLUDE="${excl}" INPUT_MAX_RETRIES=1 \
    bash "${app}/entrypoint.sh" 2>&1) && status=0 || status=$?
  output="${out}"
}

@test "entrypoint: FND-0099: exclude with a backslash or single quote and remote_dir=/home/lftp/ exits 2 before the .netrc is written and before any lftp call" {
  bs='\'
  q="'"
  h="${BATS_TEST_TMPDIR}/home/lftp"
  for entry in "a${bs}|backslash" "a${q}|quote" "x,a${bs} ,y|backslash" "a${q},b${q}|quote"; do
    v="${entry%|*}"
    kind="${entry##*|}"
    _fnd99_entry_case "${v}" "/home/lftp/" reject
    printf 'CASE exclude=[%s] status=%s\n%s\n' "${v}" "${status}" "${output}"
    [ "${status}" -eq 2 ] || return 1
    case "${kind}" in
      backslash) [[ "${output}" == *"ERROR: exclude item contains a backslash (lftp escape character): "* ]] || return 1 ;;
      quote)     [[ "${output}" == *"ERROR: exclude item contains a single quote (lftp quote character): "* ]] || return 1 ;;
    esac
    [ ! -e "${h}/.netrc" ] || { echo "netrc was written for exclude=${v}"; return 1; }
    [ ! -e "${BATS_TEST_TMPDIR}/lftp.calls" ] || { echo "lftp was called for exclude=${v}"; return 1; }
  done
}

@test "entrypoint: FND-0099: a normal exclude gets past validation to write_netrc" {
  for v in '*.log' '*.log,.git/,node_modules/,dir/*.tmp' '!important.txt'; do
    _fnd99_entry_case "${v}" "/home/lftp/" accept
    printf 'CASE exclude=[%s] status=%s\n%s\n' "${v}" "${status}" "${output}"
    [ "${status}" -eq 0 ] || return 1
    [[ "${output}" == *"PAST_EXCLUDE_GATE"* ]] || return 1
    [[ "${output}" != *"ERROR: exclude"* ]] || return 1
  done
}

# ----------------------------------------------------------------------------
# FND-0100: lftp reads `>` as an output redirection even mid-token.
#  - validate_glob_pattern rejects `>` in an exclude item.
#  - validate_path takes an optional 3rd argument "unquoted" (remote_dir and
#    concurrency_lock_path, which are pasted unquoted into the lftp -e script);
#    with it, `>`, `'` and `\` are rejected. Without it (server, local_dir) they
#    still pass, so the flag scopes the check.
# LIB_SRC / ENTRYPOINT_SRC override the scripts under test (used to prove the
# tests fail on a tree with only the FND-0099 change).
# ----------------------------------------------------------------------------

# _fnd100_expect_glob_gt VALUE ITEM: exit 2 and the exact `>` ERROR for ITEM.
_fnd100_expect_glob_gt() {
  local value="$1" item="$2" want
  want="ERROR: exclude item contains a greater-than sign (lftp output redirection): ${item}"
  run validate_glob_pattern "exclude" "${value}"
  if [ "${status}" -ne 2 ] || [ "${output}" != "${want}" ]; then
    printf 'CASE value=[%s] status=%s\n  want=[%s]\n  got =[%s]\n' "${value}" "${status}" "${want}" "${output}"
    return 1
  fi
}

@test "validate_glob_pattern: FND-0100: an exclude item with a greater-than sign exits 2 with the ERROR naming the item" {
  _fnd100_expect_glob_gt 'a>x' 'a>x' || return 1
  _fnd100_expect_glob_gt 'a>' 'a>' || return 1
  _fnd100_expect_glob_gt '>x' '>x' || return 1
  _fnd100_expect_glob_gt '*.log>/tmp/o' '*.log>/tmp/o' || return 1
}

@test "validate_glob_pattern: FND-0100: a greater-than sign in a later or padded list item names the trimmed item" {
  _fnd100_expect_glob_gt 'ok,a>x' 'a>x' || return 1
  _fnd100_expect_glob_gt ' a>x , ok' 'a>x' || return 1
  _fnd100_expect_glob_gt 'a>,!cat${IFS}/home/lftp/.netrc' 'a>' || return 1
}

# _fnd100_expect_path_reject NAME VALUE KIND: validate_path with "unquoted"
# exits 2 with the exact ERROR for KIND (gt | quote | backslash).
_fnd100_expect_path_reject() {
  local name="$1" value="$2" kind="$3" want
  case "${kind}" in
    gt)        want="ERROR: ${name} contains greater-than (lftp output redirection): ${value}" ;;
    quote)     want="ERROR: ${name} contains single-quote (lftp quote character): ${value}" ;;
    backslash) want="ERROR: ${name} contains backslash (lftp escape character): ${value}" ;;
  esac
  run validate_path "${name}" "${value}" "unquoted"
  if [ "${status}" -ne 2 ] || [ "${output}" != "${want}" ]; then
    printf 'CASE name=%s value=[%s] status=%s\n  want=[%s]\n  got =[%s]\n' "${name}" "${value}" "${status}" "${want}" "${output}"
    return 1
  fi
}

@test "validate_path: FND-0100: with \"unquoted\", remote_dir and concurrency_lock_path values with >, ' or a backslash exit 2 with the new ERROR" {
  q="'"
  bs='\'
  for n in remote_dir concurrency_lock_path; do
    _fnd100_expect_path_reject "${n}" 'a>x' gt || return 1
    _fnd100_expect_path_reject "${n}" "x${q}" quote || return 1
    _fnd100_expect_path_reject "${n}" "${q}/home/lftp/" quote || return 1
    _fnd100_expect_path_reject "${n}" "a${bs}b" backslash || return 1
    _fnd100_expect_path_reject "${n}" "a${bs}" backslash || return 1
  done
}

@test "validate_path: FND-0100: with \"unquoted\", ordinary paths and < or # still pass with status 0 and no output" {
  for v in 'a<b' 'a#b' '/www/site/' '.lftp-deployment.lock' ./ /; do
    run validate_path "remote_dir" "${v}" "unquoted"
    if [ "${status}" -ne 0 ] || [ -n "${output}" ]; then
      printf 'CASE value=[%s] status=%s output=[%s]\n' "${v}" "${status}" "${output}"
      return 1
    fi
  done
}

@test "validate_path: FND-0100: WITHOUT the flag, the same >, ' and backslash values still pass (server and local_dir are unchanged)" {
  q="'"
  bs='\'
  for n in server local_dir remote_dir; do
    for v in 'a>x' "x${q}" "${q}/home/lftp/" "a${bs}b" "a${bs}"; do
      run validate_path "${n}" "${v}"
      if [ "${status}" -ne 0 ] || [ -n "${output}" ]; then
        printf 'CASE name=%s value=[%s] status=%s output=[%s]\n' "${n}" "${v}" "${status}" "${output}"
        return 1
      fi
    done
  done
}

@test "validate_path: FND-0100: a third argument other than \"unquoted\" does not enable the check" {
  run validate_path "remote_dir" 'a>x' "quoted"
  [ "${status}" -eq 0 ] || return 1
  [ -z "${output}" ] || return 1
}

@test "validate_path: FND-0100: \"unquoted\" does not change the earlier checks (a '..' value keeps its own ERROR)" {
  run validate_path "remote_dir" '../x>' "unquoted"
  [ "${status}" -eq 2 ] || return 1
  [[ "${output}" == *'remote_dir contains ".." path traversal'* ]] || return 1
}

# _fnd100_entry_case MODE [VAR=value ...]: like _fnd99_entry_case, but the
# caller supplies the INPUT_* variables. Defaults: remote_dir /www/site/,
# local_dir ./, exclude empty. Mode "reject" runs the real write_netrc; the
# failing lftp stub logs every call to lftp.calls. Mode "accept" stubs
# write_netrc with a marker and exits 0.
_fnd100_entry_case() {
  local mode="$1"
  shift
  local root="${BATS_TEST_DIRNAME}/../.."
  local src="${ENTRYPOINT_SRC:-${root}/entrypoint.sh}"
  local lib="${LIB_SRC:-${root}/lib.sh}"
  local app="${BATS_TEST_TMPDIR}/app" fb="${BATS_TEST_TMPDIR}/fakebin" out
  rm -rf "${BATS_TEST_TMPDIR}/home" "${fb}" "${BATS_TEST_TMPDIR}/lftp.calls"
  mkdir -p "${app}" "${BATS_TEST_TMPDIR}/home/lftp" "${BATS_TEST_TMPDIR}/ws" "${fb}"
  cp "${lib}" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  if [ "${mode}" = "accept" ]; then
    printf '\nwrite_netrc() { printf "PAST_FND100_GATE\\n"; exit 0; }\n' >> "${app}/lib.sh"
  fi
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${BATS_TEST_TMPDIR}/home/lftp#g" \
    "${src}" > "${app}/entrypoint.sh"
  printf '#!/bin/sh\necho called >> "%s/lftp.calls"\nexit 1\n' "${BATS_TEST_TMPDIR}" > "${fb}/lftp"
  printf '#!/bin/sh\nexit 0\n' > "${fb}/sleep"
  chmod +x "${fb}/lftp" "${fb}/sleep"
  out=$(cd "${BATS_TEST_TMPDIR}/ws" && env PATH="${fb}:${PATH}" HOME="${BATS_TEST_TMPDIR}/home" \
    INPUT_SERVER="ftp.example.com" INPUT_USER="ftptest" INPUT_PASSWORD="pw" \
    INPUT_REMOTE_DIR="/www/site/" INPUT_LOCAL_DIR="./" INPUT_EXCLUDE="" INPUT_MAX_RETRIES=1 \
    "$@" timeout 20 bash "${app}/entrypoint.sh" 2>&1) && status=0 || status=$?
  output="${out}"
}

# _fnd100_assert_rejected WANT_FRAGMENT: status 2, the fragment in the output
# (fixed-string match), no .netrc written, lftp never called.
_fnd100_assert_rejected() {
  local frag="$1"
  printf 'status=%s\n%s\n' "${status}" "${output}"
  [ "${status}" -eq 2 ] || return 1
  [[ "${output}" == *"${frag}"* ]] || return 1
  [ ! -e "${BATS_TEST_TMPDIR}/home/lftp/.netrc" ] || { echo "netrc was written"; return 1; }
  [ ! -e "${BATS_TEST_TMPDIR}/lftp.calls" ] || { echo "lftp was called"; return 1; }
}

@test "entrypoint: FND-0100: exclude 'a>,!cat\${IFS}/home/lftp/.netrc' exits 2 before the .netrc is written and before any lftp call" {
  _fnd100_entry_case reject 'INPUT_EXCLUDE=a>,!cat${IFS}/home/lftp/.netrc'
  _fnd100_assert_rejected "ERROR: exclude item contains a greater-than sign (lftp output redirection): a>" || return 1
}

@test "entrypoint: FND-0100: exclude 'a>x' with local_dir=put and remote_dir=/home/lftp/.netrc exits 2 before any lftp call" {
  _fnd100_entry_case reject 'INPUT_EXCLUDE=a>x' 'INPUT_LOCAL_DIR=put' 'INPUT_REMOTE_DIR=/home/lftp/.netrc'
  _fnd100_assert_rejected "ERROR: exclude item contains a greater-than sign (lftp output redirection): a>x" || return 1
}

@test "entrypoint: FND-0100: remote_dir with > or a single quote exits 2 before any lftp call" {
  _fnd100_entry_case reject 'INPUT_REMOTE_DIR=a>x'
  _fnd100_assert_rejected "ERROR: remote_dir contains greater-than (lftp output redirection): a>x/" || return 1
  q="'"
  _fnd100_entry_case reject "INPUT_REMOTE_DIR=x${q}"
  _fnd100_assert_rejected "ERROR: remote_dir contains single-quote (lftp quote character): x${q}/" || return 1
}

@test "entrypoint: FND-0100: concurrency_lock_path with > or a single quote exits 2 before any lftp call" {
  _fnd100_entry_case reject 'INPUT_CONCURRENCY_LOCK=true' 'INPUT_CONCURRENCY_LOCK_PATH=lk>x'
  _fnd100_assert_rejected "ERROR: concurrency_lock_path contains greater-than (lftp output redirection): lk>x" || return 1
  q="'"
  _fnd100_entry_case reject 'INPUT_CONCURRENCY_LOCK=true' "INPUT_CONCURRENCY_LOCK_PATH=lk${q}"
  _fnd100_assert_rejected "ERROR: concurrency_lock_path contains single-quote (lftp quote character): lk${q}" || return 1
}

@test "entrypoint: FND-0100: a concurrency_lock_path with > is not validated when concurrency_lock is off" {
  _fnd100_entry_case accept 'INPUT_CONCURRENCY_LOCK=false' 'INPUT_CONCURRENCY_LOCK_PATH=lk>x'
  printf 'status=%s\n%s\n' "${status}" "${output}"
  [ "${status}" -eq 0 ] || return 1
  [[ "${output}" == *"PAST_FND100_GATE"* ]] || return 1
}

@test "entrypoint: FND-0100: a normal remote_dir and lock path get past validation to write_netrc" {
  _fnd100_entry_case accept
  printf 'status=%s\n%s\n' "${status}" "${output}"
  [ "${status}" -eq 0 ] || return 1
  [[ "${output}" == *"PAST_FND100_GATE"* ]] || return 1
  _fnd100_entry_case accept 'INPUT_CONCURRENCY_LOCK=true' 'INPUT_CONCURRENCY_LOCK_PATH=.lftp-deployment.lock' 'INPUT_REMOTE_DIR=/'
  printf 'status=%s\n%s\n' "${status}" "${output}"
  [ "${status}" -eq 0 ] || return 1
  [[ "${output}" == *"PAST_FND100_GATE"* ]] || return 1
  [[ "${output}" != *"ERROR:"* ]] || return 1
}

# ------------------------------------------------------------------------------
# FND-0009..0012 (doc reconciliation): behaviours that the rewritten action.yml
# descriptions state and that no other test pinned.
# ------------------------------------------------------------------------------

@test "validate_lftp_settings: FND-0010: the limit counts ';' characters - 4 directives without a trailing ';' pass, '&&' and '||' are not counted" {
  run validate_lftp_settings "set a:1; set b:2; set c:3; set d:4"
  [ "$status" -eq 0 ]
  run validate_lftp_settings "set a:1 && set b:2 && set c:3 && set d:4 || set e:5"
  [ "$status" -eq 0 ]
}

# _lock_gate_case NAME=VALUE...: run a scratch entrypoint.sh up to the end of
# the concurrency-lock validation block. build_ftp_settings (the first command
# after the block) prints a marker to stderr and kills the script.
_lock_gate_case() {
  local root="${BATS_TEST_DIRNAME}/../.."
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "${app}" "${BATS_TEST_TMPDIR}/home/lftp"
  cp "${root}/lib.sh" "${app}/lib.sh"
  printf '0.0.0-test\n' > "${app}/VERSION"
  printf '\nbuild_ftp_settings() { printf "PAST_LOCK_BLOCK\\n" >&2; kill -TERM $$; }\n' >> "${app}/lib.sh"
  sed -e "s#/app/#${app}/#g" -e "s#/home/lftp#${BATS_TEST_TMPDIR}/home/lftp#g" \
    "${root}/entrypoint.sh" > "${app}/entrypoint.sh"
  local out
  out=$(env HOME="${BATS_TEST_TMPDIR}/home" INPUT_SERVER="ftp.example.com" INPUT_USER="ftptest" \
    INPUT_PASSWORD="pw" "$@" bash "${app}/entrypoint.sh" 2>&1) && status=0 || status=$?
  output="${out}"
}

@test "entrypoint: FND-0011: poll interval 0 and 05 exit 2 with the lock on; empty falls back to 5 and passes" {
  _lock_gate_case INPUT_CONCURRENCY_LOCK=true INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=0
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"concurrency_lock_poll_interval must be > 0"* ]]
  _lock_gate_case INPUT_CONCURRENCY_LOCK=true INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=05
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"without leading zeros"* ]]
  _lock_gate_case INPUT_CONCURRENCY_LOCK=true INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=
  [[ "${output}" == *"PAST_LOCK_BLOCK"* ]]
  [[ "${output}" != *"ERROR:"* ]]
}

@test "entrypoint: FND-0011: poll interval and timeout are validated only when concurrency_lock is true; timeout 0 is allowed, 00 is not" {
  _lock_gate_case INPUT_CONCURRENCY_LOCK=false INPUT_CONCURRENCY_LOCK_POLL_INTERVAL=0 INPUT_CONCURRENCY_LOCK_TIMEOUT=00
  [[ "${output}" == *"PAST_LOCK_BLOCK"* ]]
  [[ "${output}" != *"ERROR:"* ]]
  _lock_gate_case INPUT_CONCURRENCY_LOCK=true INPUT_CONCURRENCY_LOCK_TIMEOUT=0
  [[ "${output}" == *"PAST_LOCK_BLOCK"* ]]
  [[ "${output}" != *"ERROR:"* ]]
  _lock_gate_case INPUT_CONCURRENCY_LOCK=true INPUT_CONCURRENCY_LOCK_TIMEOUT=00
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"concurrency_lock_timeout must be a non-negative integer without leading zeros"* ]]
}
