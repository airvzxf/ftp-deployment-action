# ftp-deployment-action — agent instructions

> Project-level rules for any automated agent (Kimi, Copilot, a
> future maintainer's scripts, etc.) that touches this repo. The
> shape mirrors `airvzxf/moagan`'s `AGENTS.md` for consistency
> across the maintainer's repos; the rules below are specific to
> this project.

## Project

`ftp-deployment-action` is a GitHub Action that copies files via
FTP/FTPS using `lftp`. Single Docker image, no compiled
binaries. Default branch is `main`. The release pipeline
(`.github/workflows/release.yml`) builds the image, pushes it
to ghcr.io (always) plus Docker Hub and ECR Public (when the
right secrets are set), signs it with cosign keyless, attaches
a CycloneDX SBOM attestation, and creates the GitHub Release
page from the `CHANGELOG.md` section for the new version.

| Field | Value |
|---|---|
| Repo | https://github.com/airvzxf/ftp-deployment-action |
| Type | Docker action (`runs.using: docker`) |
| Stack | POSIX sh (busybox ash) + Alpine 3.24 + lftp 4.9.3 + curl 8.22.0 |
| License | AGPL-3.0 (re-licensed from GPL-3.0 in v2.2.0) |
| Image base | `alpine@sha256:28bd5…` (digest pinned in `Dockerfile`) |
| Default branch | `main` |
| Registries | ghcr.io (primary), docker.io (optional), public.ecr.aws (optional) |
| Image signing | cosign keyless via OIDC (Sigstore Fulcio) |
| SBOM | CycloneDX JSON via `anchore/sbom-action`, attached as in-toto attestation |
| Tag signing | PGP (v1.5.0 – v2.10.0, v2.11.7 – v2.11.8) and SSH (v2.11.0 – v2.11.6, v2.11.9+) — see "Tag signature guard" |

## Stack

- POSIX `sh` (busybox ash on the runtime side; the source has to
  be `/bin/sh`-clean because the action's container is alpine).
- `lftp` 4.9.3 pinned by `apk add lftp=4.9.3-r0` in the
  `Dockerfile`. Bumping `lftp` is a routine change but has
  historically been risky (mirror semantics occasionally shift
  between minor versions); review any lftp bump carefully.
- `curl` 8.22.0 pinned by `apk add curl=8.22.0-r0`. Same caveat
  as lftp.
- No other runtime dependencies. No Python, no Node, no `sudo`.

## Coding conventions

- All code, comments, and documentation in **English**. The
  only Spanish interaction is with the user.
- POSIX-portable: prefer `[ ]` over `[[ ]]`, avoid bashisms
  (`local` is fine because busybox ash supports it; `[[ ]]` is
  not).
- No secret literals in code, CLI flags, or committed config
  files. Passwords reach `lftp` through a `.netrc` written by
  `lib.sh` and zeroed on exit (see `lib.sh::acquire_lock_with_recovery`).
- Idiomatic POSIX: prefer pipelines, parameter expansion, and
  here-docs over nested subshells.

## Validation tiers

| Tier | Cost | Where | What |
|---|---|---|---|
| T0 | <30 s | pre-PR (local `make lint`) | shellcheck + actionlint + hadolint |
| T1 | 1–2 min | pre-PR (local `make test`) | contract + bats unit + smoke |
| T2 | 3–5 min | CI | contract + unit + smoke + integration + CI lint |
| T3 | 5–30 min | tag push | `.github/workflows/release.yml` (5 jobs) |

There is no pre-commit / pre-push hook layer today. CI is the
audit. Branch protection rules live under the `protect-main`
ruleset on GitHub.

## Commit policy

- GPG-signed commits are mandatory.
- Conventional commits: `feat`, `fix`, `refactor`, `docs`,
  `test`, `chore`, `ci`, `build`, `perf`.
- One logical change per commit.
- No `git commit --amend`. No `git push --force`. No
  `--no-gpg-sign`.

## ⚠️ Red / failed workflows: do NOT merge, repair until green

A tag is irreversible. Once `release.yml` has published a
release, a workflow bug found afterwards can only be fixed with
another release. So the workflow that a change touches must be
proven green *while the change is still revertible* — on the
branch BEFORE any merge, on the trunk AFTER the merge, and on
the release branch BEFORE the tag.

```
   ┌─→ push ─→ dispatch ─→ CI red? ─yes─→ read logs ─┐
   │                                                │
   └────── no ──── proceed to next step ─────────────┤
                                                    │
                                  fix locally ←─────┘
                                  commit + sign
                                  push
```

1. Work on a local branch. Implement, commit (GPG-signed), push.
2. Dispatch the affected workflow against the branch:
   `gh workflow run <workflow>.yml --ref <branch>`.
3. Watch it: `gh run watch <run-id>` / `gh run view <run-id> --log-failed`.
4. **If any required job is red**: read the failure log
   (`gh run view <run-id> --log-failed` → narrow to the failed step),
   reproduce locally if possible, fix the cause, commit, push, then
   **go back to step 2**. Do NOT proceed until every required job
   is green. Do NOT dismiss a red job as flake without evidence
   from the log.
5. Only when the branch CI is fully green: open the PR and merge.
6. The trunk now runs CI on the merged commit. **If the trunk CI
   comes back red**: read the trunk run's logs, fix locally on a
   follow-up commit, push, and loop back to step 2. Do NOT open
   a release PR until the trunk is green.
7. Only when the trunk is green: open the release PR (CHANGELOG
   + `VERSION` bump). Run CI on the release branch.
8. **If the release branch CI is red**: same repair loop. Do NOT
   tag until the release branch is fully green.
9. Only when the release branch is green: merge the release PR.
10. Only after the release PR is merged: tag the **merge commit
    on the trunk**, NOT the branch tip. The squash-merge
    rewrites the SHA, so the branch-tip tag points at a commit
    that exists on no branch. Re-tag in two steps:
    `git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z`,
    then `git tag -s vX.Y.Z <merge-commit-sha>` and
    `git push origin vX.Y.Z`. Verify with
    `git rev-parse vX.Y.Z^{commit}` — it MUST match
    `git rev-parse main`. The `verify-tag-reachability` job in
    `release.yml` runs this check mechanically.

## Tag the trunk merge commit, NOT the branch tip

The `verify-tag-reachability` job in `release.yml` is the
structural check; this is the procedural recipe. Both must
hold.

① **Fetch and align local `main` to remote.** Covers the local
   drift that the squash merge creates.

   ```bash
   git fetch origin main
   git checkout main
   git reset --hard origin/main
   ```

② **Confirm the release bump is at HEAD and `VERSION` matches
   the planned tag.**

   ```bash
   git log --oneline -1   # expect: <sha> chore(release): vX.Y.Z — ...
   cat VERSION            # expect: X.Y.Z
   ```

③ **Tag with `-s` (GPG-signed) or `-s` with the SSH key
   (`-u` for GPG, no flag for SSH), pointing at the merge
   SHA.** The signing format determines which entry in the
   in-repo allow-list (`SECURITY.md` table) the workflow will
   consult.

   ```bash
   # PGP (legacy):
   git tag -s vX.Y.Z -u 414687A3CD7E65B9 "$(git rev-parse HEAD)"
   # SSH (current, used since v2.11.0):
   git tag -s vX.Y.Z "$(git rev-parse HEAD)"
   git push origin vX.Y.Z
   ```

   **Never** tag a local-only commit before it reaches `main`,
   and **never** tag a branch tip that will be squashed.

④ **Verify the tag's commit equals `origin/main`'s HEAD.** This
   is the invariant the workflow guard checks.

   ```bash
   [ "$(git rev-parse vX.Y.Z^{commit})" \
       = "$(git rev-parse origin/main)" ] \
       || { echo "ORPHAN TAG — abort, re-tag after step ①"; exit 1; }
   ```

⑤ **Verify the tag object SHA on the remote matches the local
   one** (catches a partial push / network race).

   ```bash
   [ "$(git rev-parse vX.Y.Z)" \
       = "$(git ls-remote origin refs/tags/vX.Y.Z | awk '{print $1}')" ] \
       || { echo "TAG PUSH MISMATCH — abort"; exit 1; }
   ```

⑥ **Watch the `release.yml` run.** The
   `Verify · tag is reachable from main` job passes if ④
   holds; `Verify · tag is signed by a trusted signer` passes
   if `git verify-tag vX.Y.Z` succeeds against the allow-list
   fetched from `origin/main` (SSH backend via
   `.github/trusted-signers`, PGP backend via
   `.github/trusted-signers.asc` — used by v2.10.0 and earlier
   tags). Both jobs run in parallel and `Build · release image`
   runs only after both pass; the build is pinned to the
   immutable tag commit SHA so a tag force-push mid-run
   cannot redirect it. `Publish · GitHub Release` creates
   the release page from the `CHANGELOG.md` section for this
   version.

**If you discover you orphaned a tag** (e.g. you tagged before
the squash, or ④ fails):

```bash
git tag -d vX.Y.Z                          # delete local
git push origin :refs/tags/vX.Y.Z          # delete remote
git fetch origin main                      # re-sync to trunk
git checkout main && git reset --hard origin/main
git tag -s vX.Y.Z "$(git rev-parse origin/main)"
git push origin vX.Y.Z
```

The orphan release page stays published even after the remote
tag is deleted — GitHub Releases are independent of git refs.
Mark it as pre-release or delete the release page manually
after re-publishing at the correct SHA so consumers do not
pull the orphan image by accident.

## Tag signature guard

The `verify-tag-signature` job in `release.yml` runs
`git verify-tag` on the pushed tag and rejects the build if
the signature is not produced by a key in
`.github/trusted-signers` (SSH backend) or
`.github/trusted-signers.asc` (PGP backend). The allow-list is
**fetched from `origin/main`** (NOT the tagged tree) so revoking
a key on main takes effect on the next release — reading it
from the tagged tree would make revocation structurally
impossible because the trust anchor would be the same object
being verified.

- **`.github/trusted-signers`** — SSH backend. Each line is
  `<principal> <key-type> <key-body>`. Used by `git config
  gpg.ssh.allowedsignersfile` so `git verify-tag` can check
  SSH-signed tags. **Matching is by key body, not by
  principal** — git resolves the principal via
  `ssh-keygen -Y find-principals` and accepts the signature
  if any principal in this file owns the key that produced
  it. Treat every line as an unconditional grant. Current
  entry: `israel.alberto.rv@gmail.com` (ED25519, fingerprint
  `SHA256:POu2Sr8ILb1IM05Vh1cGU3xivjx05QjWoWYhdLc6YHA`).
- **`.github/trusted-signers.asc`** — PGP backend. The
  maintainer's RSA primary key (long ID `414687A3CD7E65B9`,
  full fingerprint
  `82DE44111B30F91F55BCEB1F414687A3CD7E65B9`) in ASCII-armored
  form. Imported into the runner's keyring **only when the tag
  being verified is PGP-signed** (`v1.5.0`–`v2.10.0` and
  `v2.11.7`–`v2.11.8`). The `.asc` is **not** optional today:
  the maintainer alternates between the two backends and both
  keys are load-bearing for at least one shipped release. Do
  not remove the file until the most recent PGP-signed tag is
  at least one minor version old (see "Removing a signer"
  below).

`git verify-tag` auto-detects which backend the tag used, so
both formats are supported without conditional logic in the
workflow.

Local verification of any tag in the clone:

```sh
scripts/verify-tag.sh v2.11.0   # SSH path
scripts/verify-tag.sh v2.10.0   # PGP path
scripts/verify-tag.sh v1.3.3    # lightweight, exits 0 with INFO
```

The script writes nothing to the developer's `~/.gnupg` or
`.git/config` — the PGP keyring is a `mktemp -d` cleaned by
trap on exit, and git config is passed via `git -c` overrides.

**Adding a new trusted signer** requires a PR that:

1. Appends one entry to `.github/trusted-signers` (and, **if
   the new signer uses PGP**, appends a
   `-----BEGIN PGP PUBLIC KEY BLOCK-----` to
   `.github/trusted-signers.asc`; if all signers are SSH-only
   the `.asc` file may be deleted).
2. Documents the signer's key fingerprint and identity in
   `.github/CONTRIBUTING.md` (or `SECURITY.md` if no
   `CONTRIBUTING.md` exists) so the audit log captures who
   holds the signing key.
3. Is reviewed by a co-maintainer when one exists. Today the
   repo is single-maintainer; treat this procedural step as
   the load-bearing control while that remains true.

**Removing a signer** must wait until the most recent tag
signed by that key is at least one minor version old, so a
compromise of the removed key cannot rewrite a release that's
in production. The `scripts/verify-tag.sh` script re-verifies
the tag against the current allow-list, so a removed signer
surfaces immediately for the operator who removes it.

## No-go list

- No secret literals in code, CLI flags, or committed config
  files. Passwords reach `lftp` through a `.netrc` written by
  `lib.sh` and zeroed on exit.
- No `sudo` inside the action image. The action runs as a
  non-root user (`lftp`); adding `sudo` is a security
  regression.
- No `set -e` masking (B-05 in the original audit). A failed
  command after `&&` must propagate; use `||` for fallback
  semantics and trap the `.netrc` cleanup.
- No `unzip` / `tar -xzf` of untrusted archives without
  validation. The image is built from a digest-pinned base;
  any new layer should be pinned by digest too.
- No floating refs (`@latest`, `@master`, `@main`) in user
  examples. Pin to a specific tag or SHA so the maintainer
  can reproduce the exact image.

## Out of scope (not in this repo)

- No `lefthook` setup. CI is the audit.
- No AUR / pacman packaging. ftp-deployment-action is a
  Docker image, not a binary; AUR is a moagan concern.
- No `release-please` / `release-drafter` automation. The
  release body is extracted from `CHANGELOG.md` by an inline
  awk step in `release.yml`; introducing a third-party tool
  for this would be over-engineering.
