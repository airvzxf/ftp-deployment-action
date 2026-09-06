# Security Policy

## Supported versions

| Track                  | Tag range                                  | Support                                                              |
|------------------------|--------------------------------------------|-----------------------------------------------------------------------|
| Currently maintained   | `v2.x` (latest = `v2.11.11`)               | Active — security and bug fixes published in the next v2.x.y release. |
| Legacy support window  | `v1.4` — `v1.9`                            | Security-only backports on a best-effort basis.                       |
| End-of-life            | `v1.0-alpha.*`, `v1.1`, `v1.2.0`, `v1.3.x`  | No support.                                                           |

Floating refs like `@latest`, `@master`, `@main`, and `@v2` are
**not** in the support matrix — pin to a specific tag (e.g.
`@v2.11.9`) or a full commit SHA so the maintainer can reproduce
the exact image you are running. The `@v2` floating major alias
is stale (it still points at the v2.0.x-era image and the
release pipeline does not move it), so following it silently
skips every fix between v2.1.0 and the present. See the
"Pin to a specific tag" note in the README for the recommended
pattern.

## Tag signing policy

Release tags are signed in one of two formats, depending on the
tag's age. The release pipeline's `verify-tag-signature` job
runs `git verify-tag` against an in-repo allow-list and refuses
to publish an image whose tag does not verify.

| Tag range | Format | Allow-list entry | Maintainer key |
|---|---|---|---|
| `v1.0-alpha.1` … `v1.3.3` | Lightweight (unsigned) | n/a — EOL | n/a |
| `v1.5.0` … `v2.10.0` | PGP (RSA) | `.github/trusted-signers.asc` | `82DE44111B30F91F55BCEB1F414687A3CD7E65B9` (long ID `414687A3CD7E65B9`) |
| `v2.11.0` … `v2.11.6` | SSH (ED25519) | `.github/trusted-signers` | `SHA256:POu2Sr8ILb1IM05Vh1cGU3xivjx05QjWoWYhdLc6YHA` (principal `israel.alberto.rv@gmail.com`) |
| `v2.11.7` … `v2.11.8` | PGP (RSA) | `.github/trusted-signers.asc` | `82DE44111B30F91F55BCEB1F414687A3CD7E65B9` (long ID `414687A3CD7E65B9`) |
| `v2.11.9` (and later, see the per-release notes) | SSH (ED25519) | `.github/trusted-signers` | `SHA256:POu2Sr8ILb1IM05Vh1cGU3xivjx05QjWoWYhdLc6YHA` (principal `israel.alberto.rv@gmail.com`) |

The maintainer alternates between the two backends; both
allow-lists are committed to the repo and both keys are
load-bearing for at least one shipped release. To check
which backend a specific tag uses, run
`scripts/verify-tag.sh <tag>` (it auto-detects and prints
the key fingerprint). `git verify-tag` itself auto-detects
the backend; the workflow's `verify-tag-signature` job
imports the PGP keyring only when the tag is PGP-signed and
the SSH allow-list only when the tag is SSH-signed. The
`.asc` file is **not** optional — it is required to verify
`v1.5.0`–`v2.10.0` and `v2.11.7`–`v2.11.8`. Do not remove
it until the most recent PGP-signed tag is at least one
minor version old (see AGENTS.md §"Tag signature guard" →
"Removing a signer").

The maintainer's PGP public key can be fetched from
<https://keys.openpgp.net/search?q=82DE44111B30F91F55BCEB1F414687A3CD7E65B9>
or with
`gpg --keyserver keys.openpgp.net --recv-keys 82DE44111B30F91F55BCEB1F414687A3CD7E65B9`
to verify PGP-signed tags (`v1.5.0`–`v2.10.0` and
`v2.11.7`–`v2.11.8`) locally. The SSH key is the maintainer's
standard GitHub authentication key (fingerprint on the user's
GitHub settings page).

**Verify any tag locally** with the in-repo script (handles all
three formats; safe to run, writes nothing to your `~/.gnupg` or
`.git/config`):

```sh
scripts/verify-tag.sh v2.11.9   # SSH path
scripts/verify-tag.sh v2.11.8   # PGP path
scripts/verify-tag.sh v2.10.0   # PGP path
scripts/verify-tag.sh v1.3.3    # lightweight, exits 0 with INFO
```

Or by hand (the script is a thin wrapper around these calls):

```sh
git verify-tag <tag>      # exit 0 + "Good signature" for signed tags
git cat-file -t <tag>     # 'tag' for annotated, 'commit' for lightweight
```

### Legacy lightweight tags (v1.0-alpha.1 … v1.3.3)

The 8 legacy tags below are **lightweight pointers** (raw
commits, not annotated tag objects), so they cannot be
signed in their current form. They pre-date the signing
policy that was introduced when the release pipeline landed
alongside `v1.5.0`:

| Tag            | Created | Reason kept unsigned          |
|----------------|---------|-------------------------------|
| `v1.0-alpha.1` | 2020    | Pre-dating the signing policy |
| `v1.0-alpha.2` | 2020    | Pre-dating the signing policy |
| `v1.1`         | 2020    | Pre-dating the signing policy |
| `v1.2.0`       | 2020    | Pre-dating the signing policy |
| `v1.3.0`       | 2023    | Pre-dating the signing policy |
| `v1.3.1`       | 2023    | Pre-dating the signing policy |
| `v1.3.2`       | 2026    | Pre-dating the signing policy |
| `v1.3.3`       | 2026    | Pre-dating the signing policy |

**Re-signing these tags is intentionally not done.** Re-creating
them as annotated objects would change their commit SHA and
break every workflow that pins to a legacy ref
(e.g. `uses: airvzxf/ftp-deployment-action@v1.3.3`). The
historical SHA is the contract with existing users; altering
it would be a breaking change worse than the missing
signature.

Users on legacy refs are already covered by the EOL notice in
the "Supported versions" table above and by the deprecation
warning emitted by the action itself at runtime. Users who
need to verify a legacy tag's integrity can pin to a specific
commit SHA instead of the tag name.

## Self-hosted runners

Self-hosted runners copy environment variables from the host into
the container by default. The most consequential one is `HOME`:
the runner process's `HOME` (typically `/github/home` on the
GitHub Actions Runner service, or `/home/runner` on a bare-metal
runner) is forwarded as `HOME=/github/home` (or similar) inside
the container, which historically caused the
`can't create /<HOME>/.netrc: Permission denied` failure
reported in #111.

Since **v2.11.0** the action pins `HOME=/home/lftp` and
`NETRC=/home/lftp/.netrc` unconditionally inside `entrypoint.sh`,
so self-hosted runners no longer trigger that bug. The password
still comes from the `.netrc` file the action writes, which is
mode `0600`, owned by the in-container `lftp` user, and removed
by an `EXIT` trap — so it does not appear in `/proc/<pid>/cmdline`,
in the runner log, or in any subsequent container filesystem
state.

A self-hosted runner operator who needs to verify that the
password never reaches the host can:

- Pin `HOME` on the step explicitly (`env: HOME: /home/lftp`).
  This is the documented escape hatch for users on older versions
  and is now redundant but still valid.
- Confirm the image tag is signed (`scripts/verify-tag.sh <tag>`,
  or `git verify-tag <tag>` against the maintainer key listed in
  the "Tag signing policy" section above). The release pipeline
  refuses to publish an image whose tag does not verify, so a
  signed image is also a signed-source-image.
- Run the integration suite locally against a real FTP server
  with `make integration` — see `tests/integration/README.md`.
  The suite boots `fauria/vsftpd` in a sibling container and runs
  every scenario end-to-end against it; CI runs the same suite
  on every PR.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Report privately by emailing **israel.alberto.rv@gmail.com** with:

- A short description of the issue and its impact.
- A reproducer (workflow YAML, lftp command, or steps).
- The affected version (commit SHA or tag).

You should receive an acknowledgement within 72 hours. If you do not,
please follow up with a second email.

If private vulnerability reporting has been enabled under
*Settings → Code security and analysis → Private vulnerability
reporting*, you can also file a report through the GitHub
Security Advisories tab on this repository. Either channel
reaches the same maintainer inbox; the email above remains
authoritative even if the tab is currently disabled.

## What to expect

- **Acknowledgement** within 72 hours.
- **Triage** within 7 days: confirm the issue, assign a CVSS estimate
  and decide whether to fix in-tree or in a fork.
- **Fix** for critical/high issues as soon as possible, ideally within
  30 days. Lower-severity issues are bundled with the next regular
  release. Confirmed vulnerabilities are published as a GitHub
  Security Advisory, which can carry CVE and CWE IDs assigned by
  GitHub on request; the advisory references the in-the-clear fix
  commit so the public record is complete.
- **Disclosure**: once a fix is published, the original report will be
  credited in the release notes (unless the reporter prefers otherwise).
  *Public* issues that report a vulnerability directly will be closed
  without triage, with a link back to this policy, to avoid disclosing
  the flaw to anyone watching the repo before a fix is available.

## Out of scope

- Vulnerabilities in upstream `lftp` — please report them upstream at
  https://lftp.yar.ru/.
- Vulnerabilities in the base `alpine` image — please report to the
  Alpine security team.
- Misconfiguration of the action (e.g. using `delete: true` with the
  wrong `remote_dir`) that does not require a code change.
