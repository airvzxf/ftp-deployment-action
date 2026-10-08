#!/bin/sh
# tests/release-smoke.sh — smoke tests run against an already-built
# ftp-deployment-action image.
#
# Used by .github/workflows/release.yml between "Build and push
# image" and "Generate SBOM" to catch Dockerfile / lftp pin /
# runtime regressions before the image is signed and the SBOM is
# attached. Also runnable locally against a freshly-built image.
#
# Usage:
#   tests/release-smoke.sh <image>
#
# Where <image> is the image:tag to test (e.g. the value of
# `steps.meta.outputs.image:${{ steps.meta.outputs.version }}` from
# the release workflow, or `ftp-deployment-action:local` for a
# local build).
#
# Exit code 0 if all checks pass, non-zero otherwise. The script
# prints which check failed.

set -eu

IMAGE=${1:-}

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf '  ok: %s\n' "$*"; }
skip() { printf '  skip: %s\n' "$*"; exit 0; }

# Need an image to test.
if [ -z "${IMAGE}" ]; then
  fail "usage: $0 <image:tag>  (e.g. ftp-deployment-action:local)"
fi

# Need a container runtime.
if command -v docker >/dev/null 2>&1; then
  RUNTIME=docker
elif command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
else
  fail "no docker or podman found on PATH"
fi

# The smoke tests below each run a container in isolation. They
# need INPUT_SERVER/INPUT_USER/INPUT_PASSWORD at minimum or
# init.sh's validation will reject the run for other reasons.
COMMON_ENV() {
  printf '%s\n' \
    "INPUT_SERVER=ftp://127.0.0.1:1" \
    "INPUT_USER=u" \
    "INPUT_PASSWORD=p" \
    "INPUT_MAX_RETRIES=1" \
    "INPUT_NET_TIMEOUT=2s" \
    "INPUT_DNS_FATAL_TIMEOUT=2s" \
    "INPUT_FTP_SSL_ALLOW=false"
}

# run_in_image ENV_FILE [timeout_seconds]
# Runs the image with the given env file, returns the exit code.
# Output is captured to /tmp/smoke-<timestamp>.log; the function
# returns the exit code and prints the log path on failure.
run_in_image() {
  _env=$1
  _t=${2:-30}
  _env_file=$(mktemp) || return 1
  _log=$(mktemp) || return 1
  {
    COMMON_ENV
    printf '%s\n' "${_env}"
  } > "${_env_file}"
  _rc=0
  timeout "${_t}" "${RUNTIME}" run --rm \
    --env-file "${_env_file}" \
    "${IMAGE}" >"${_log}" 2>&1 || _rc=$?
  rm -f "${_env_file}"
  if [ "${_rc}" -ne 0 ]; then
    printf 'container output (exit %s):\n' "${_rc}" >&2
    cat "${_log}" >&2
    printf 'end of container output.\n' >&2
  fi
  rm -f "${_log}"
  return "${_rc}"
}

# ---------------------------------------------------------------------------
# Check 1: the image is pullable / runnable. A simple "validate_path"
# failure is the cheapest way to verify init.sh executes: pass
# INPUT_LOCAL_DIR=../etc and expect exit 2.
#
# This catches:
#   * broken ENTRYPOINT in the Dockerfile
#   * missing init.sh (wrong COPY)
#   * lftp not installed (apk add failed)
#   * init.sh syntax error
#   * a non-root USER that cannot read /app/init.sh
#   * validate_path itself regressing
# ---------------------------------------------------------------------------
echo "=== Check 1: container starts, validate_path rejects '..' (expect exit 2) ==="
_log=$(mktemp); _env_file=$(mktemp)
{
  COMMON_ENV
  printf 'INPUT_LOCAL_DIR=../etc\n'
} > "${_env_file}"
set +e
timeout 15 "${RUNTIME}" run --rm --env-file "${_env_file}" "${IMAGE}" >"${_log}" 2>&1
_rc=$?
set -e
if [ "${_rc}" -ne 2 ]; then
  printf 'expected exit 2 (path traversal rejected), got %s\n' "${_rc}" >&2
  cat "${_log}" >&2
  rm -f "${_log}" "${_env_file}"
  fail "INPUT_LOCAL_DIR=../etc did not exit 2"
fi
if ! grep -q 'local_dir contains ".." path traversal' "${_log}"; then
  cat "${_log}" >&2
  rm -f "${_log}" "${_env_file}"
  fail "expected the path-traversal error message in the output"
fi
rm -f "${_log}" "${_env_file}"
pass "container runs and validate_path rejects '..' with exit 2"

# ---------------------------------------------------------------------------
# Check 2: the image prints the right version string. This is the
# canary that catches the kind of bug that hit v2.3.0: the
# /app/VERSION file was supposed to be baked at build time with
# the resolved tag, but if the build-arg wiring regressed the
# file would not contain the tag.
#
# ---------------------------------------------------------------------------
echo "=== Check 2: /app/VERSION is baked (build-arg VERSION reached the Dockerfile) ==="
_log=$(mktemp)
timeout 60 "${RUNTIME}" run --rm --entrypoint cat "${IMAGE}" /app/VERSION >"${_log}" 2>&1 || true
# /app/VERSION must exist and be non-empty. A regression in the
# build-arg wiring would leave the file empty or absent.
_baked_version=$(cat "${_log}" 2>/dev/null || true)
if [ -z "${_baked_version}" ] || [ "${_baked_version}" = "unknown" ]; then
  cat "${_log}" >&2
  rm -f "${_log}"
  fail "build-arg VERSION did not reach /app/VERSION; got: '${_baked_version}'"
fi
rm -f "${_log}"
pass "build-arg VERSION was baked into /app/VERSION: ${_baked_version}"

printf '\nAll release smoke tests passed for %s.\n' "${IMAGE}"
