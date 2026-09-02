# Security Policy

## Supported versions

| Track                  | Tag range                                  | Support                                                              |
|------------------------|--------------------------------------------|-----------------------------------------------------------------------|
| Currently maintained   | `v2.x` (latest = `v2.10.0`)                | Active — security and bug fixes published in the next v2.x.y release. |
| Legacy support window  | `v1.4` — `v1.9`                            | Security-only backports on a best-effort basis.                       |
| End-of-life            | `v1.0-alpha.*`, `v1.1`, `v1.2.0`, `v1.3.x`  | No support.                                                           |

Floating refs like `@latest`, `@master`, or `@main` are **not** in
the support matrix — pin to a specific tag (e.g. `@v2.10.0`) or a
full commit SHA so the maintainer can reproduce the exact image
you are running. See the "Pin to a major version" note in the
README for the recommended pattern.

## Tag signing policy

Starting with `v1.5.0`, every release tag is **annotated and
GPG-signed** by the maintainer (key
`82DE44111B30F91F55BCEB1F414687A3CD7E65B9`). The signature is
verified by the release pipeline before the image is published.
Locally, a signed tag can be distinguished from a lightweight
one and checked like this:

```sh
git verify-tag <tag>      # exit 0 + "Good signature" for signed tags
git cat-file -t <tag>     # 'tag' for annotated, 'commit' for lightweight
```

The maintainer's public key can be fetched from
<https://keys.openpgp.net/search?q=82DE44111B30F91F55BCEB1F414687A3CD7E65B9>
or with
`gpg --keyserver keys.openpgp.net --recv-keys 82DE44111B30F91F55BCEB1F414687A3CD7E65B9`
to verify tag signatures locally without trusting the GitHub web
UI.

The 8 legacy tags below are **lightweight pointers** (raw
commits, not annotated tag objects), so they cannot be
GPG-signed in their current form. They pre-date the signing
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
- Confirm the image tag is GPG-signed (`git verify-tag <tag>`
  against the maintainer key listed in the "Tag signing policy"
  section above). The release pipeline refuses to publish an
  image whose tag does not verify, so a signed image is also a
  signed-source-image.
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
