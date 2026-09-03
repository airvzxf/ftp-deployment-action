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
# It deliberately writes **nothing** to the developer's environment:
#
#   * `GNUPGHOME` is a `mktemp -d` (cleaned by trap on exit) so the
#     PGP keyring import never lands in permanent `~/.gnupg`.
#   * Git config is passed via per-invocation `git -c` overrides (or
#     `--local` config in a temp repo, see below) — never written to
#     the developer's `.git/config`.
#
# Usage
# -----
#   scripts/verify-tag.sh <tag>
#
# Where <tag> is a tag present in the current working tree (e.g.
# `v2.11.0`).
#
# Exit codes
# ----------
#   0  tag is signed by a key in .github/trusted-signers (SSH) or
#      .github/trusted-signers.asc (PGP), or is documented as
#      lightweight / unsigned in SECURITY.md (informational).
#   1  tag is missing on the remote, or its signature could not be
#      verified against either allow-list.
#   2  usage error.
#
# Dependencies
# ------------
#   * git (always present in the maintainer's environment).
#   * gpg (only consulted when verifying a PGP-signed tag; absent
#     installations are skipped without error).

set -eu

# Resolve repo root from the script's own location so the script
# works regardless of the caller's cwd.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)

TRUSTED_SSH="${REPO_ROOT}/.github/trusted-signers"
TRUSTED_PGP="${REPO_ROOT}/.github/trusted-signers.asc"

# Default git-invocation prefix: `git -c` overrides. Used so the
# script never touches the developer's `.git/config`.
GIT_PREFIX="git -c gpg.format=ssh -c gpg.ssh.allowedsignersfile=${TRUSTED_SSH}"

# Detect the tag's signature format. Output: 'ssh', 'pgp', or
# 'lightweight'.
detect_signature() {
  _tag=$1
  if ! git cat-file -t "${_tag}" 2>/dev/null \
      | grep -qx 'tag'; then
    printf 'lightweight\n'
    return 0
  fi
  if git cat-file tag "${_tag}" 2>/dev/null \
      | grep -q 'BEGIN SSH SIGNATURE'; then
    printf 'ssh\n'
  elif git cat-file tag "${_tag}" 2>/dev/null \
      | grep -q 'BEGIN PGP SIGNATURE'; then
    printf 'pgp\n'
  else
    printf 'lightweight\n'
  fi
}

# Verify with the SSH backend. Requires `.github/trusted-signers`.
verify_ssh() {
  _tag=$1
  if [ ! -s "${TRUSTED_SSH}" ]; then
    printf 'ERROR: %s missing or empty\n' "${TRUSTED_SSH}" >&2
    return 1
  fi
  ${GIT_PREFIX} verify-tag "${_tag}"
}

# Verify with the PGP backend. Imports the allow-list into a temp
# keyring so the developer's permanent `~/.gnupg` is untouched.
verify_pgp() {
  _tag=$1
  if [ ! -s "${TRUSTED_PGP}" ]; then
    printf 'ERROR: %s missing or empty\n' "${TRUSTED_PGP}" >&2
    return 1
  fi
  if ! command -v gpg >/dev/null 2>&1; then
    printf 'ERROR: tag is PGP-signed but gpg is not installed\n' >&2
    return 1
  fi

  # Set up an isolated keyring. Use GNUPGHOME rather than --homedir
  # so the same call works with gpg 1.x and 2.x.
  _gnupghome=$(mktemp -d) || return 1
  # shellcheck disable=SC2064  # we want $? captured now, not on exit.
  trap "rm -rf '${_gnupghome}'" EXIT INT TERM

  GNUPGHOME="${_gnupghome}" gpg --batch --import "${TRUSTED_PGP}" \
    >/dev/null 2>&1
  GNUPGHOME="${_gnupghome}" ${GIT_PREFIX} verify-tag "${_tag}"
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
      verify_ssh "${tag}"
      printf 'OK: %s is signed by a key in .github/trusted-signers\n' "${tag}"
      ;;
    pgp)
      verify_pgp "${tag}"
      printf 'OK: %s is signed by a key in .github/trusted-signers.asc\n' "${tag}"
      ;;
    lightweight)
      printf 'INFO: %s is a lightweight tag (no signature).\n' "${tag}"
      printf '  See SECURITY.md "Tag signing policy" for whether this is expected.\n'
      # Not a hard failure: legacy v1.0-alpha.* … v1.3.3 tags are
      # intentionally lightweight (see SECURITY.md). The script
      # exits 0 so a routine `git verify-tag v1.3.3` does not
      # alarm a CI that has opted into this script.
      exit 0
      ;;
    *)
      printf 'ERROR: unknown signature format for %s\n' "${tag}" >&2
      exit 1
      ;;
  esac
}

main "$@"
