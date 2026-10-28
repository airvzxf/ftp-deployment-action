#!/bin/sh
# scripts/verify-tag.sh — re-verify a release tag against the in-repo
# trusted-signers allow-list, locally.
#
# Mirrors the relevant step of `airvzxf/moagan`'s
# `scripts/gauntlet.sh` (the v0 draft) but is a single-purpose script
# rather than a multi-step gauntlet, because ftp-deployment-action
# has no pre-commit / pre-push hook layer.
#
# Why this script exists
# ----------------------
# The release workflow runs `git verify-tag` on every push of a
# `v*.*.*` tag. That covers the production case. This script
# re-verifies the same allow-list **locally**, so the operator can
# catch a missing or stale allow-list entry *before* pushing the tag
# — and so any future contributor can re-verify a historical tag
# without poking at the runner's `~/.gnupg`.
#
# Like release.yml, it reads the allow-lists from `origin/main`, not
# from the working tree, so a key revoked on main is revoked here
# too, whatever branch or tag is checked out. For a signed tag it runs
# `git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main`
# first and needs network access to `origin`; it cannot run offline.
#
# It deliberately writes **nothing** to the developer's environment:
#
#   * `GNUPGHOME` is a `mktemp -d` (cleaned by trap on exit, INT or
#     TERM) so the PGP keyring import never lands in permanent
#     `~/.gnupg`, and `git verify-tag` never consults it, whatever the
#     tag's format.
#   * Git config is passed only via per-invocation `git -c` overrides
#     (see `vgit` below); there is no temp repo and nothing is ever
#     written to the developer's `.git/config`.
#   * The allow-lists are copied out of `origin/main` into a
#     `mktemp -d` (cleaned by the same trap). The only change to the
#     repository that holds this script is the fetch, which refreshes
#     `refs/remotes/origin/main` (and FETCH_HEAD, and may add objects);
#     it never makes the clone shallow.
#
# Usage
# -----
#   scripts/verify-tag.sh <tag>
#
# Where <tag> is a tag (e.g. `v2.11.0`) that exists as `refs/tags/<tag>`
# in the git repository of the caller's current directory. Run it from
# inside the clone (see the note on the working directory below).
#
# Exit codes
# ----------
#   0  tag is signed by a key in .github/trusted-signers (SSH) or
#      .github/trusted-signers.asc (PGP), or is one of the legacy
#      tags listed in SECURITY.md ("Legacy lightweight tags":
#      v1.0-alpha.1, v1.0-alpha.2, v1.1, v1.2.0, v1.3.0 … v1.3.3) and
#      is lightweight or an unsigned annotated tag (informational: an
#      INFO line, no fetch, no signature check). The list is hard-coded
#      in `is_legacy_unsigned`; it is not read from SECURITY.md.
#   1  tag is not found locally, or it is lightweight / unsigned and
#      not a listed legacy tag (release.yml would reject it), or its
#      signature could not be verified against the origin/main
#      allow-lists (including a PGP-signed tag when gpg is not
#      installed or origin/main has no .asc), or its tag header does
#      not name <tag>, or the tag object cannot be read, or
#      origin/main (and so its allow-list) could not be fetched or has
#      no trusted-signers, or origin/main's trusted-signers.asc could
#      not be imported into the temp keyring (this affects SSH-signed
#      tags too), or a mktemp fails. When `git verify-tag` itself
#      fails, the script exits with that command's status (errexit),
#      which is 1 for a failed verification.
#   2  usage error.
#   130 interrupted (SIGINT), after removing the temp dirs.
#   143 terminated (SIGTERM), after removing the temp dirs.
#
# Dependencies
# ------------
#   * git (always present in the maintainer's environment).
#   * ssh-keygen (vgit pins gpg.ssh.program to it; needed to verify
#     an SSH-signed tag).
#   * mktemp, awk, sed and grep (POSIX tools; awk detects the format,
#     sed reads the tag header).
#   * gpg (used for any signed tag when origin/main has a
#     trusted-signers.asc, to import it into the temp keyring; a
#     PGP-signed tag fails without it, an SSH-signed one does not
#     need it, but if gpg is installed and the import fails, either
#     format fails).

set -eu

# Resolve repo root from the script's own location. Only the fetch and
# the allow-list reads (`git -C "${REPO_ROOT}"`) use it; the tag
# lookups and `git verify-tag` (rev-parse, cat-file, vgit) run in the
# caller's cwd, so the script is NOT cwd-independent: outside a repo it
# reports "tag not found locally", and in another repo it verifies that
# repo's tag against this repo's origin/main allow-lists. `CDPATH=` and
# >/dev/null keep an exported CDPATH from sending cd elsewhere and
# printing (FND-0022).
# shellcheck disable=SC1007
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" >/dev/null && pwd)
# shellcheck disable=SC1007
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." >/dev/null && pwd)

# Remove the temp dirs. The trap names this function rather than
# embedding the paths, so it reads them when it runs and a path with a
# quote in it cannot change the trap command (FND-0024). The trap is
# set before the first mktemp, so a failed second mktemp still removes
# the first dir. INT and TERM clean up and then exit with the usual
# 128+signal status instead of resuming the script.
ALLOWLIST_DIR=
VERIFY_GNUPGHOME=
cleanup() {
  [ -z "${ALLOWLIST_DIR}" ] || rm -rf -- "${ALLOWLIST_DIR}"
  [ -z "${VERIFY_GNUPGHOME}" ] || rm -rf -- "${VERIFY_GNUPGHOME}"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# The allow-lists are read from origin/main (see fetch_allowlists),
# as release.yml does, into this temp dir.
ALLOWLIST_DIR=$(mktemp -d) || exit 1
# Isolated keyring for every `git verify-tag` run: it holds only
# origin/main's trusted-signers.asc (or nothing), never ~/.gnupg.
VERIFY_GNUPGHOME=$(mktemp -d) || exit 1
TRUSTED_SSH="${ALLOWLIST_DIR}/trusted-signers"
TRUSTED_PGP="${ALLOWLIST_DIR}/trusted-signers.asc"

# git with per-invocation `-c` overrides, so the script never touches
# the developer's `.git/config`. A function rather than a command
# string, so a path with spaces or glob characters stays one argument
# (FND-0021). The gpg.program and gpg.ssh.program pins stop a value set
# in the developer's repo .git/config (or global config) from pointing
# verify-tag at a program that fakes a pass; gpg.x509.program=false
# does the same for x509, which is never a valid release format here.
# GNUPGHOME is set on the git command itself, so the isolated keyring
# reaches git without relying on env prefixes on a function call.
# These pins harden the check; they do not protect against someone who
# can write .git/config (a hook could still run during `git fetch`).
vgit() {
  GNUPGHOME="${VERIFY_GNUPGHOME}" \
    git -c gpg.format=ssh -c "gpg.ssh.allowedsignersfile=${TRUSTED_SSH}" \
    -c gpg.program=gpg -c gpg.ssh.program=ssh-keygen \
    -c gpg.x509.program=false "$@"
}

# Fetch origin/main and copy its allow-lists into ALLOWLIST_DIR,
# mirroring release.yml's "Fetch allow-list from origin/main" step:
# the SSH list is required and must be non-empty; the .asc is
# optional (absent on origin/main is acceptable).
fetch_allowlists() {
  if ! git -C "${REPO_ROOT}" fetch --no-tags origin \
      +refs/heads/main:refs/remotes/origin/main; then
    printf 'ERROR: could not fetch origin main; the allow-list on origin/main is what CI uses, so the check cannot run offline\n' >&2
    exit 1
  fi
  # Full ref: a bare `origin/main` would resolve to a local tag or
  # branch of that name before the remote-tracking ref just fetched.
  if ! git -C "${REPO_ROOT}" show "refs/remotes/origin/main:.github/trusted-signers" \
      > "${TRUSTED_SSH}" || [ ! -s "${TRUSTED_SSH}" ]; then
    printf 'ERROR: .github/trusted-signers missing or empty on origin/main\n' >&2
    exit 1
  fi
  if ! git -C "${REPO_ROOT}" show "refs/remotes/origin/main:.github/trusted-signers.asc" \
      > "${TRUSTED_PGP}" 2>/dev/null; then
    rm -f "${TRUSTED_PGP}"
  fi
}

# Detect the tag's signature format. It decides whether verification
# runs at all ('unsigned' and 'lightweight' skip the fetch and
# `git verify-tag`: legacy tags exit 0, others exit 1) and whether
# the PGP keyring is imported; for 'ssh' and 'pgp', `git verify-tag`
# itself picks the backend (see verify_signature).
# Output: 'ssh', 'pgp', 'unsigned' (an annotated tag without a
# signature block) or 'lightweight' (not a tag object). It takes the
# signature to start at the LAST line that is exactly a BEGIN PGP/SSH
# SIGNATURE marker, so text in the message body cannot change the
# result. git matches markers more loosely (by prefix, and it also
# knows PGP MESSAGE / x509 blocks); such tags come out 'unsigned'
# here and fail closed. The object is captured first (POSIX sh has
# no pipefail).
detect_signature() {
  _tag=$1
  if ! git cat-file -t "refs/tags/${_tag}" 2>/dev/null \
      | grep -qx 'tag'; then
    printf 'lightweight\n'
    return 0
  fi
  if ! _obj=$(git cat-file tag "refs/tags/${_tag}"); then
    printf 'ERROR: could not read tag object refs/tags/%s\n' "${_tag}" >&2
    exit 1
  fi
  printf '%s\n' "${_obj}" | awk '
    $0 == "-----BEGIN PGP SIGNATURE-----" { fmt = "pgp" }
    $0 == "-----BEGIN SSH SIGNATURE-----" { fmt = "ssh" }
    END { if (fmt == "") fmt = "unsigned"; print fmt }'
}

# Verify the signature with a single `git verify-tag`, whatever the
# detected format. git picks the backend from the signature block
# itself, so both backends are confined to origin/main's allow-lists:
# the SSH list via gpg.ssh.allowedSignersFile, and the PGP list via a
# temp GNUPGHOME that holds only trusted-signers.asc (imported when it
# exists and gpg is installed; otherwise the keyring stays empty and a
# PGP signature fails). The developer's `~/.gnupg` is never consulted.
# The format-specific checks below only give a clearer error first.
verify_signature() {
  _tag=$1
  _sig=$2
  case ${_sig} in
    ssh)
      if [ ! -s "${TRUSTED_SSH}" ]; then
        printf 'ERROR: origin/main:.github/trusted-signers missing or empty\n' >&2
        return 1
      fi
      ;;
    pgp)
      if [ ! -s "${TRUSTED_PGP}" ]; then
        printf 'ERROR: origin/main:.github/trusted-signers.asc missing or empty\n' >&2
        return 1
      fi
      if ! command -v gpg >/dev/null 2>&1; then
        printf 'ERROR: tag is PGP-signed but gpg is not installed\n' >&2
        return 1
      fi
      ;;
  esac

  # Use GNUPGHOME rather than --homedir so the same call works with
  # gpg 1.x and 2.x. The import runs for SSH-signed tags too, so a
  # corrupt or non-key .asc fails both formats; report it with gpg's
  # stderr and exit 1 rather than gpg's own status (FND-0020).
  if [ -s "${TRUSTED_PGP}" ] && command -v gpg >/dev/null 2>&1; then
    if ! _import_err=$(GNUPGHOME="${VERIFY_GNUPGHOME}" gpg --batch \
        --import "${TRUSTED_PGP}" 2>&1 >/dev/null); then
      printf 'ERROR: could not import origin/main:.github/trusted-signers.asc into the temporary keyring\n' >&2
      printf '%s\n' "${_import_err}" >&2
      exit 1
    fi
  fi
  vgit verify-tag "refs/tags/${_tag}"
}

# The legacy tags that SECURITY.md ("Legacy lightweight tags") lists
# as intentionally unsigned. Listed one by one, not as a range, so a
# new unsigned tag can never match.
is_legacy_unsigned() {
  case $1 in
    v1.0-alpha.1|v1.0-alpha.2|v1.1|v1.2.0|v1.3.0|v1.3.1|v1.3.2|v1.3.3)
      return 0
      ;;
  esac
  return 1
}

# Require the tag object's own `tag <name>` header to equal the ref
# name. `git verify-tag` does not check it, so an old signed tag
# object re-pushed under a new name would otherwise pass. Run only
# after the signature verified, so the name is covered by it. The
# object is captured first (POSIX sh has no pipefail) so a failing
# cat-file cannot turn into a silently empty name.
check_tag_name() {
  _tag=$1
  if ! _obj=$(git cat-file tag "refs/tags/${_tag}"); then
    printf 'ERROR: could not read tag object refs/tags/%s\n' "${_tag}" >&2
    exit 1
  fi
  _name=$(printf '%s\n' "${_obj}" | sed -n '1,/^$/s/^tag //p')
  if [ -z "${_name}" ]; then
    printf 'ERROR: refs/tags/%s has no tag header (not a tag object)\n' \
      "${_tag}" >&2
    exit 1
  fi
  if [ "${_name}" != "${_tag}" ]; then
    printf "ERROR: tag object is named '%s' but is stored as refs/tags/%s\\n" \
      "${_name}" "${_tag}" >&2
    exit 1
  fi
}

usage() {
  printf 'usage: %s <tag>\n' "$0" >&2
  printf '  e.g. %s v2.11.0\n' "$0" >&2
}

main() {
  if [ $# -ne 1 ]; then
    usage
    exit 2
  fi
  tag=$1

  case ${tag} in
    v*) : ;;
    *)
      printf 'ERROR: %s does not look like a release tag (expected vX.Y.Z)\n' \
        "${tag}" >&2
      usage
      exit 2
      ;;
  esac

  # The tag must exist locally. The release pipeline uses
  # `actions/checkout` with `fetch-tags`, so the runner always has
  # the tag; locally we expect the developer to have run
  # `git fetch --tags`.
  if ! git rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null; then
    printf 'ERROR: tag %s not found locally. Run: git fetch --tags\n' \
      "${tag}" >&2
    exit 1
  fi

  sig=$(detect_signature "${tag}")
  printf 'Tag %s signature format: %s\n' "${tag}" "${sig}"

  case ${sig} in
    ssh)
      fetch_allowlists
      verify_signature "${tag}" "${sig}"
      check_tag_name "${tag}"
      printf 'OK: %s is signed by a key in .github/trusted-signers\n' "${tag}"
      ;;
    pgp)
      fetch_allowlists
      verify_signature "${tag}" "${sig}"
      check_tag_name "${tag}"
      printf 'OK: %s is signed by a key in .github/trusted-signers.asc\n' "${tag}"
      ;;
    lightweight|unsigned)
      if [ "${sig}" = lightweight ]; then
        _kind='a lightweight tag'
      else
        _kind='an unsigned annotated tag'
      fi
      # Only the legacy v1.0-alpha.1 … v1.3.3 tags listed in
      # SECURITY.md are intentionally unsigned; they exit 0 so a
      # routine check of v1.3.3 does not alarm a CI that has opted
      # into this script. Any other unsigned tag is an error, as in
      # release.yml.
      if is_legacy_unsigned "${tag}"; then
        printf 'INFO: %s is %s (no signature), a documented legacy tag.\n' \
          "${tag}" "${_kind}"
        printf '  See SECURITY.md, "Legacy lightweight tags".\n'
        exit 0
      fi
      printf 'ERROR: %s is %s (no signature); release.yml would reject it.\n' \
        "${tag}" "${_kind}" >&2
      printf '  Only the legacy tags listed in SECURITY.md "Tag signing policy" may be unsigned.\n' >&2
      exit 1
      ;;
    *)
      printf 'ERROR: unknown signature format for %s\n' "${tag}" >&2
      exit 1
      ;;
  esac
}

main "$@"
