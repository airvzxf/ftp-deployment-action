#!/usr/bin/env bats
# tests/unit/verify-tag.bats — tests for scripts/verify-tag.sh.
#
# FND-0018: verify-tag.sh must read the allow-lists from origin/main
# (after fetching it), as release.yml does, not from the working tree.
#
# Every test builds a throwaway fixture under $BATS_TEST_TMPDIR:
#
#   origin.git  bare repo, branch main; the "remote"
#   seed/       clone used to publish allow-list commits to origin
#   work/       full (non-shallow) clone; the script under test is
#               copied to work/scripts/verify-tag.sh because the
#               script resolves REPO_ROOT from its own path
#
# HOME, git system/global config and GNUPGHOME are isolated, so the
# real repo's remotes/tags/config and the user's keys are never used.
#
# Set VERIFY_TAG_SCRIPT to run the tests against another copy of the
# script (e.g. `git show HEAD:scripts/verify-tag.sh > /tmp/x.sh`) to
# check that they fail on the pre-fix code.
#
# Skips: SSH cases need ssh-keygen and a git that can make SSH-signed
# tags (git >= 2.34, OpenSSH >= 8.2); PGP cases need gpg.

SCRIPT_UNDER_TEST_DEFAULT="${BATS_TEST_DIRNAME}/../../scripts/verify-tag.sh"

setup() {
  FIX="${BATS_TEST_TMPDIR}/fix"
  mkdir -p "${FIX}/home"
  export HOME="${FIX}/home"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export GNUPGHOME="${FIX}/gnupg"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  SCRIPT="${VERIFY_TAG_SCRIPT:-${SCRIPT_UNDER_TEST_DEFAULT}}"
}

teardown() {
  if [ -d "${GNUPGHOME:-/nonexistent}" ] && command -v gpgconf >/dev/null 2>&1; then
    gpgconf --kill all >/dev/null 2>&1 || true
  fi
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

need_ssh() {
  command -v ssh-keygen >/dev/null 2>&1 || skip "ssh-keygen not available"
  command -v git >/dev/null 2>&1 || skip "git not available"
}

# new_key NAME -> ${FIX}/NAME{,.pub}
new_key() {
  ssh-keygen -q -t ed25519 -N '' -C "$1" -f "${FIX}/$1"
}

# allow_line NAME -> an allowed_signers line for key NAME
allow_line() {
  printf 'a@example.invalid namespaces="git" %s\n' "$(cat "${FIX}/$1.pub")"
}

# make_fixture: origin.git (main), seed/, work/ (full clone)
make_fixture() {
  git init -q --bare -b main "${FIX}/origin.git"
  git init -q -b main "${FIX}/seed"
  git -C "${FIX}/seed" remote add origin "${FIX}/origin.git"
  mkdir -p "${FIX}/seed/.github" "${FIX}/seed/scripts"
  echo base > "${FIX}/seed/README"
  git -C "${FIX}/seed" add -A
  git -C "${FIX}/seed" commit -q -m "base"
  git -C "${FIX}/seed" commit -q --allow-empty -m "second"
  git -C "${FIX}/seed" push -q origin main
}

# publish_allowlist NAME: origin/main lists only key NAME
publish_allowlist() {
  allow_line "$1" > "${FIX}/seed/.github/trusted-signers"
  git -C "${FIX}/seed" add .github
  git -C "${FIX}/seed" commit -q -m "allow-list: $1 only"
  git -C "${FIX}/seed" push -q origin main
}

# make_work: full clone of origin, with the script under test copied in
make_work() {
  git clone -q "${FIX}/origin.git" "${FIX}/work"
  mkdir -p "${FIX}/work/scripts"
  cp "${SCRIPT}" "${FIX}/work/scripts/verify-tag.sh"
  chmod +x "${FIX}/work/scripts/verify-tag.sh"
}

# ssh_tag TAG KEYNAME: SSH-signed annotated tag in work/. Skips when
# this git/ssh-keygen cannot make SSH-signed tags.
ssh_tag() {
  if ! git -C "${FIX}/work" -c gpg.format=ssh \
        -c user.signingkey="${FIX}/$2" tag -s -m "$1" "$1" 2>"${FIX}/tag.err"; then
    skip "cannot create SSH-signed tags here: $(cat "${FIX}/tag.err")"
  fi
}

verify() {
  cd "${FIX}/work"
  run scripts/verify-tag.sh "$1"
}

# ---------------------------------------------------------------------------
# FND-0018: SSH allow-list comes from origin/main
# ---------------------------------------------------------------------------

@test "FND-0018: tag signed by a key on origin/main verifies even if the working tree dropped that key" {
  need_ssh
  new_key keyA; new_key keyB
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.0.1 keyA
  # Working tree (uncommitted) lists keyB only.
  allow_line keyB > "${FIX}/work/.github/trusted-signers"

  verify v99.0.1
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: v99.0.1 is signed by a key in .github/trusted-signers"* ]]
}

@test "FND-0018: tag signed by a key only in the working tree is rejected" {
  need_ssh
  new_key keyA; new_key keyB
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.0.2 keyB
  allow_line keyB > "${FIX}/work/.github/trusted-signers"

  verify v99.0.2
  [ "$status" -eq 1 ]
  [[ "$output" != *"OK: v99.0.2"* ]]
}

@test "FND-0018: a key revoked on origin/main is rejected although the working tree still lists it" {
  need_ssh
  new_key keyA; new_key keyB
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.0.3 keyA
  # Revoke keyA on main after the clone; the working tree still has it.
  publish_allowlist keyB

  verify v99.0.3
  [ "$status" -eq 1 ]
  [[ "$output" != *"OK: v99.0.3"* ]]
}

# stray_allowlist_commit KEYNAME: in work/, create a commit whose
# .github/trusted-signers lists only key KEYNAME, leave HEAD and the
# branch where they were, and print the new commit id.
stray_allowlist_commit() {
  git -C "${FIX}/work" checkout -q --detach
  { echo "# stray list"; allow_line "$1"; } > "${FIX}/work/.github/trusted-signers"
  git -C "${FIX}/work" commit -q -a -m "stray allow-list: $1"
  git -C "${FIX}/work" rev-parse HEAD > "${FIX}/stray.id"
  git -C "${FIX}/work" checkout -q main
}

# ---------------------------------------------------------------------------
# FND-0086: a stray local ref named origin/main must not supply the lists
# ---------------------------------------------------------------------------

@test "FND-0086: a stray local TAG named origin/main cannot resurrect a key revoked on origin/main" {
  need_ssh
  new_key keyA; new_key keyB
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.0.5 keyA
  stray_allowlist_commit keyA
  git -C "${FIX}/work" tag origin/main "$(cat "${FIX}/stray.id")"
  publish_allowlist keyB   # revoke keyA on origin/main

  verify v99.0.5
  [ "$status" -eq 1 ]
  [[ "$output" != *"OK: v99.0.5"* ]]
  [[ "$output" == *"No principal matched"* || "$output" == *"no signature found"* || "$output" == *"error:"* ]]
  # The stray tag is left alone; only refs/remotes/origin/main moved.
  [ "$(git -C "${FIX}/work" rev-parse refs/tags/origin/main^{commit})" = "$(cat "${FIX}/stray.id")" ]
}

@test "FND-0086: a stray local BRANCH named origin/main cannot resurrect a key revoked on origin/main" {
  need_ssh
  new_key keyA; new_key keyB
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.0.6 keyA
  stray_allowlist_commit keyA
  git -C "${FIX}/work" branch origin/main "$(cat "${FIX}/stray.id")"
  publish_allowlist keyB   # revoke keyA on origin/main

  verify v99.0.6
  [ "$status" -eq 1 ]
  [[ "$output" != *"OK: v99.0.6"* ]]
  [[ "$output" == *"No principal matched"* || "$output" == *"no signature found"* || "$output" == *"error:"* ]]
  [ "$(git -C "${FIX}/work" rev-parse refs/heads/origin/main)" = "$(cat "${FIX}/stray.id")" ]
}

@test "FND-0086: stray local tag and branch named origin/main do not block a key that is on origin/main" {
  need_ssh
  new_key keyA; new_key keyB
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.0.7 keyA
  stray_allowlist_commit keyB
  git -C "${FIX}/work" tag origin/main "$(cat "${FIX}/stray.id")"
  git -C "${FIX}/work" branch origin/main "$(cat "${FIX}/stray.id")"

  verify v99.0.7
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: v99.0.7 is signed by a key in .github/trusted-signers"* ]]
}

@test "FND-0018: unreachable origin fails with the 'could not fetch origin main' message" {
  need_ssh
  new_key keyA
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.0.1 keyA
  git -C "${FIX}/work" remote set-url origin "${FIX}/does-not-exist.git"

  verify v99.0.1
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: could not fetch origin main"* ]]
  [[ "$output" != *"OK: v99.0.1"* ]]
}

@test "FND-0018: running on a full clone never makes it shallow" {
  need_ssh
  new_key keyA
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.0.1 keyA
  [ ! -e "${FIX}/work/.git/shallow" ]

  verify v99.0.1
  [ "$status" -eq 0 ]
  [ ! -e "${FIX}/work/.git/shallow" ]
  [ "$(git -C "${FIX}/work" rev-parse --is-shallow-repository)" = "false" ]
}

@test "FND-0018: trusted-signers missing on origin/main fails with exit 1" {
  need_ssh
  new_key keyA
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.0.1 keyA
  # Delete the allow-list on origin/main (the working tree keeps it).
  git -C "${FIX}/seed" rm -q .github/trusted-signers
  git -C "${FIX}/seed" commit -q -m "drop allow-list"
  git -C "${FIX}/seed" push -q origin main

  verify v99.0.1
  [ "$status" -eq 1 ]
  [[ "$output" == *"trusted-signers missing or empty on origin/main"* ]]
}

@test "FND-0018: the allow-list temp dir is not left behind" {
  need_ssh
  new_key keyA
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.0.1 keyA
  export TMPDIR="${FIX}/tmp"
  mkdir -p "${TMPDIR}"

  verify v99.0.1
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "${TMPDIR}")" ]
}

@test "FND-0018: a lightweight tag exits 0 without needing origin" {
  command -v git >/dev/null 2>&1 || skip "git not available"
  make_fixture
  make_work
  git -C "${FIX}/work" tag v99.0.9
  git -C "${FIX}/work" remote set-url origin "${FIX}/does-not-exist.git"

  verify v99.0.9
  [ "$status" -eq 0 ]
  [[ "$output" == *"lightweight tag"* ]]
  [[ "$output" != *"could not fetch"* ]]
}

@test "verify-tag: no argument is a usage error (exit 2)" {
  command -v git >/dev/null 2>&1 || skip "git not available"
  make_fixture
  make_work
  cd "${FIX}/work"
  run scripts/verify-tag.sh
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# FND-0018: PGP allow-list comes from origin/main (optional: needs gpg)
# ---------------------------------------------------------------------------

# pgp_setup: key in an isolated GNUPGHOME; sets FPR, writes ${FIX}/pgp.asc
pgp_setup() {
  command -v gpg >/dev/null 2>&1 || skip "gpg not available"
  mkdir -p -m700 "${GNUPGHOME}"
  if ! gpg --batch --quiet --passphrase '' \
        --quick-gen-key 'pgp <p@example.invalid>' ed25519 sign never \
        2>"${FIX}/gpg.err"; then
    skip "gpg cannot generate a key here: $(cat "${FIX}/gpg.err")"
  fi
  FPR=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
  gpg --batch --armor --export "${FPR}" > "${FIX}/pgp.asc"
}

pgp_tag() {
  if ! git -C "${FIX}/work" -c gpg.format=openpgp \
        -c user.signingkey="${FPR}" tag -s -m "$1" "$1" 2>"${FIX}/tag.err"; then
    skip "cannot create PGP-signed tags here: $(cat "${FIX}/tag.err")"
  fi
}

@test "FND-0018: PGP tag verifies with the .asc only on origin/main" {
  need_ssh
  pgp_setup
  new_key keyA
  make_fixture
  publish_allowlist keyA
  cp "${FIX}/pgp.asc" "${FIX}/seed/.github/trusted-signers.asc"
  git -C "${FIX}/seed" add .github
  git -C "${FIX}/seed" commit -q -m "add asc"
  git -C "${FIX}/seed" push -q origin main
  make_work
  pgp_tag v99.0.4
  rm -f "${FIX}/work/.github/trusted-signers.asc"

  verify v99.0.4
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: v99.0.4 is signed by a key in .github/trusted-signers.asc"* ]]
}

@test "FND-0018: PGP tag fails when the .asc is absent on origin/main" {
  need_ssh
  pgp_setup
  new_key keyA
  make_fixture
  publish_allowlist keyA
  make_work
  pgp_tag v99.0.4
  # Present in the working tree only.
  cp "${FIX}/pgp.asc" "${FIX}/work/.github/trusted-signers.asc"

  verify v99.0.4
  [ "$status" -eq 1 ]
  [[ "$output" != *"OK: v99.0.4"* ]]
}

# ---------------------------------------------------------------------------
# FND-0087: the signed tag object's own `tag` header must name the ref
# ---------------------------------------------------------------------------

# rename_tag OLD NEW: point refs/tags/NEW at the tag OBJECT of OLD (not
# the commit), as an attacker re-pushing an old signed tag would.
rename_tag() {
  git -C "${FIX}/work" update-ref "refs/tags/$2" \
    "$(git -C "${FIX}/work" rev-parse "refs/tags/$1")"
}

@test "FND-0087: SSH-signed tag object copied to another ref name is rejected" {
  need_ssh
  new_key keyA
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.1.0 keyA
  rename_tag v99.1.0 v99.1.1

  verify v99.1.1
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: tag object is named 'v99.1.0' but is stored as refs/tags/v99.1.1"* ]]
  [[ "$output" != *"OK"* ]]
}

@test "FND-0087: control: SSH-signed tag whose header matches the ref name verifies" {
  need_ssh
  new_key keyA
  make_fixture
  publish_allowlist keyA
  make_work
  ssh_tag v99.1.0 keyA
  rename_tag v99.1.0 v99.1.1

  verify v99.1.0
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: v99.1.0 is signed by a key in .github/trusted-signers"* ]]
  [[ "$output" != *"is named"* ]]
}

@test "FND-0087: PGP-signed tag object copied to another ref name is rejected" {
  need_ssh
  pgp_setup
  new_key keyA
  make_fixture
  publish_allowlist keyA
  cp "${FIX}/pgp.asc" "${FIX}/seed/.github/trusted-signers.asc"
  git -C "${FIX}/seed" add .github
  git -C "${FIX}/seed" commit -q -m "add asc"
  git -C "${FIX}/seed" push -q origin main
  make_work
  pgp_tag v99.1.2
  rename_tag v99.1.2 v99.1.3

  verify v99.1.2
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: v99.1.2 is signed by a key in .github/trusted-signers.asc"* ]]

  verify v99.1.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: tag object is named 'v99.1.2' but is stored as refs/tags/v99.1.3"* ]]
  [[ "$output" != *"OK"* ]]
}
