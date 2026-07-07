# Security Policy

## Supported versions

Only the latest tagged release receives security fixes. Older tags
(`v1.0-alpha.*`, `v1.1`, `v1.2.0`, `v1.3.x`, `latest`) are kept on a
best-effort basis and may not receive patches.

| Tag        | Supported |
|------------|-----------|
| `latest`   | Yes       |
| `<v1.4+>`  | Yes       |
| `<v1.4`    | No        |

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

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

Report privately by emailing **israel.alberto.rv@gmail.com** with:

- A short description of the issue and its impact.
- A reproducer (workflow YAML, lftp command, or steps).
- The affected version (commit SHA or tag).

You should receive an acknowledgement within 72 hours. If you do not,
please follow up with a second email.

## What to expect

- **Acknowledgement** within 72 hours.
- **Triage** within 7 days: confirm the issue, assign a CVSS estimate
  and decide whether to fix in-tree or in a fork.
- **Fix** for critical/high issues as soon as possible, ideally within
  30 days. Lower-severity issues are bundled with the next regular
  release.
- **Disclosure**: once a fix is published, the original report will be
  credited in the release notes (unless the reporter prefers otherwise).

## Out of scope

- Vulnerabilities in upstream `lftp` — please report them upstream at
  https://lftp.yar.ru/.
- Vulnerabilities in the base `alpine` image — please report to the
  Alpine security team.
- Misconfiguration of the action (e.g. using `delete: true` with the
  wrong `remote_dir`) that does not require a code change.
