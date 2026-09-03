#!/usr/bin/env bash
# Runs every local check. This is the gate before any commit.
#
#   1. bash -n on every script
#   2. shellcheck on every script (warning severity, external sources)
#   3. Python unittest discovery in tests/
#   4. Every tests/test_*.sh
#
# Exit code is nonzero if anything fails.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
failed=0

echo "== bash -n"
for f in scripts/*.sh scripts/lib/*.sh tests/*.sh; do
  [[ -f "${f}" ]] || continue
  if ! bash -n "${f}"; then
    echo "[FAIL]  syntax: ${f}"; failed=1
  fi
done

echo "== shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  if ! shellcheck --severity=warning --external-sources $(ls scripts/*.sh scripts/lib/*.sh tests/*.sh 2>/dev/null); then
    failed=1
  fi
else
  echo "[WARN]  shellcheck not installed, skipping"
fi

echo "== python unittest"
if ls tests/test_*.py >/dev/null 2>&1; then
  if ! python3 -m unittest discover -s tests -p 'test_*.py'; then
    failed=1
  fi
else
  echo "(no python tests yet)"
fi

echo "== bash tests"
for t in tests/test_*.sh; do
  [[ -f "${t}" ]] || continue
  echo "-- ${t}"
  if ! bash "${t}"; then
    failed=1
  fi
done

if [[ "${failed}" -ne 0 ]]; then
  echo "tests/run.sh: FAILED"
  exit 1
fi
echo "tests/run.sh: all passed"
