#!/bin/sh
# scripts/backfill-releases.sh — Backfill missing GitHub Releases
# for tags that were tagged locally but never published as a
# GitHub Release on github.com. The release pipeline
# (.github/workflows/release.yml) builds and signs images for
# ghcr.io, but historically did not create the corresponding
# GitHub Release page. This script makes those pages retroactive
# as drafts so a human can review and publish them.
#
# Usage:
#   scripts/backfill-releases.sh [--dry-run]
#
# Idempotent: skips tags that already have a release on github.com.
# Exits non-zero if any create failed.
#
# Notes are extracted from CHANGELOG.md by matching the
# `## [X.Y.Z]` heading and capturing until the next `## [...]`
# heading or the compare-link footer. The script ignores
# `## [Unreleased]` blocks (which would otherwise be confused
# with version sections).
#
# Requires:
#   - gh CLI authenticated (gh auth status).
#   - awk, sed, mktemp (POSIX).

set -eu

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 64 ;;
esac

cd "$(dirname "$0")/.."
ROOT=$(pwd)
CHANGELOG="${ROOT}/CHANGELOG.md"

if [ ! -f "${CHANGELOG}" ]; then
    echo "missing ${CHANGELOG}" >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI not found on PATH" >&2
    exit 1
fi

if [ "${DRY_RUN}" -ne 1 ]; then
    if ! gh auth status >/dev/null 2>&1; then
        echo "gh is not authenticated; run 'gh auth login' first" >&2
        exit 1
    fi
fi

TAGS="v2.1.0 v2.2.0 v2.3.0 v2.3.1 v2.4.0 v2.4.1 v2.5.0 v2.6.0 v2.7.0 v2.8.0"

extract_section() {
    _v="$1"
    awk -v v="${_v}" '
        BEGIN {
            in_section = 0
            v_escaped = v
            gsub(/\./, "\\.", v_escaped)
            heading_re = "^## \\[" v_escaped "\\]( -.*)?$"
            next_heading_re = "^## \\["
            compare_re = "^\\[[0-9]+\\.[0-9]+\\.[0-9]+\\]:"
        }
        $0 ~ heading_re { in_section = 1; next }
        in_section && $0 ~ next_heading_re { exit }
        in_section && $0 ~ compare_re { exit }
        in_section { print }
    ' "${CHANGELOG}" | awk '
        # Collapse runs of blank lines to a single blank line,
        # and trim any trailing blank lines. Both produce a
        # tidy block for a GitHub release body without ever
        # turning awk into an infinite loop on an empty input.
        BEGIN { seen_blank = 0 }
        NF {
            print
            seen_blank = 0
        }
        !NF {
            if (seen_blank) next
            print
            seen_blank = 1
        }
        END {
            # Drop the single trailing blank if any.
            exit seen_blank ? 0 : 0
        }
    ' | awk '
        # Strip a single trailing blank line emitted above.
        { lines[NR] = $0 }
        END {
            last = NR
            while (last > 0 && lines[last] == "") last--
            for (i = 1; i <= last; i++) print lines[i]
        }
    '
}

N_CREATED=0
N_SKIPPED=0
N_FAILED=0
N_GENERATED=0

for tag in ${TAGS}; do
    if gh release view "${tag}" >/dev/null 2>&1; then
        printf 'skip:    %s (release already exists on github.com)\n' "${tag}"
        N_SKIPPED=$((N_SKIPPED + 1))
        continue
    fi

    version="${tag#v}"

    # Resolve the commit SHA the tag points at. `gh release
    # create --target <tag-name>` is rejected by the GitHub
    # API with a 422 ("Release.target_commitish is invalid");
    # the API wants either a branch name or a full SHA. The
    # SHA lets us anchor the release at the tag's actual commit
    # rather than at the tip of `main`, which is what we want.
    # During draft state GitHub shows a placeholder URL like
    # `untagged-<id>`; once published the URL becomes
    # `releases/tag/<tag>`.
    tag_sha=$(git rev-parse "${tag}^{}" 2>/dev/null || git rev-parse "${tag}")
    if [ -z "${tag_sha}" ]; then
        printf 'FAIL:    %s — could not resolve commit SHA\n' "${tag}" >&2
        N_FAILED=$((N_FAILED + 1))
        continue
    fi

    notes=$(extract_section "${version}")
    notes_file=""

    if [ -z "${notes}" ]; then
        printf 'warn:    %s — no CHANGELOG section found for %s; will use --generate-notes\n' "${tag}" "${version}"
        notes_flag="generate"
    else
        notes_file=$(mktemp) || exit 1
        printf '%s\n' "${notes}" > "${notes_file}"
        notes_flag="file"
    fi

    if [ "${DRY_RUN}" -eq 1 ]; then
        if [ "${notes_flag}" = "file" ]; then
            printf 'would:    create draft for %s (target=%s, notes %d bytes from CHANGELOG)\n' "${tag}" "${tag_sha}" "$(wc -c < "${notes_file}")"
            rm -f "${notes_file}"
        else
            printf 'would:    create draft for %s (target=%s, with --generate-notes)\n' "${tag}" "${tag_sha}"
        fi
        continue
    fi

    if [ "${notes_flag}" = "file" ]; then
        if gh release create "${tag}" \
                --draft \
                --target "${tag_sha}" \
                --title "${tag}" \
                --notes-file "${notes_file}"; then
            printf 'created: %s (draft, notes from CHANGELOG)\n' "${tag}"
            N_CREATED=$((N_CREATED + 1))
        else
            printf 'FAIL:    %s\n' "${tag}" >&2
            N_FAILED=$((N_FAILED + 1))
        fi
        rm -f "${notes_file}"
    else
        if gh release create "${tag}" \
                --draft \
                --target "${tag_sha}" \
                --title "${tag}" \
                --generate-notes; then
            printf 'created: %s (draft, auto-generated notes)\n' "${tag}"
            N_GENERATED=$((N_GENERATED + 1))
        else
            printf 'FAIL:    %s\n' "${tag}" >&2
            N_FAILED=$((N_FAILED + 1))
        fi
    fi
done

printf '\nsummary: created=%d (changelog) + %d (auto-notes), skipped=%d, failed=%d\n' \
    "${N_CREATED}" "${N_GENERATED}" "${N_SKIPPED}" "${N_FAILED}"

[ "${N_FAILED}" -eq 0 ] || exit 1
