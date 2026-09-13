#!/usr/bin/env bash
# Runs every local check. This is the gate before any commit.
#
#   1. bash -n on every script (including the extensionless az/terraform
#      stubs, which a plain *.sh glob would miss)
#   2. shellcheck on the same set (warning severity, external sources)
#   3. python3 -m py_compile on scripts/lib/*.py and every verify/*.py,
#      the only syntax check the pyATS-only verification scripts get
#      (they import pyats/genie, so unittest cannot import them)
#   4. Python unittest discovery in tests/
#   5. Every tests/test_*.sh
#
# Exit code is nonzero if anything fails.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
failed=0

bash_files=(scripts/*.sh scripts/lib/*.sh tests/*.sh tests/lib/*.sh tests/stubs/az tests/stubs/terraform)

echo "== bash -n"
for f in "${bash_files[@]}"; do
  [[ -f "${f}" ]] || continue
  if ! bash -n "${f}"; then
    echo "[FAIL]  syntax: ${f}"; failed=1
  fi
done

echo "== shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  existing=()
  for f in "${bash_files[@]}"; do
    [[ -f "${f}" ]] && existing+=("${f}")
  done
  if [[ "${#existing[@]}" -gt 0 ]] && ! shellcheck --severity=warning --external-sources "${existing[@]}"; then
    failed=1
  fi
else
  echo "[WARN]  shellcheck not installed, skipping"
fi

echo "== python syntax (py_compile)"
# verify/*/verify.py and jobfile.py import pyats and genie, so they are
# never imported by the stdlib-only unittest discovery below; this is
# the only check that catches a syntax error in them before a live run.
py_files=()
while IFS= read -r f; do
  py_files+=("${f}")
done < <(find scripts/lib verify -name '*.py' -not -path '*/.venv/*' -not -path '*/__pycache__/*' 2>/dev/null)
if [[ "${#py_files[@]}" -gt 0 ]]; then
  if ! python3 -m py_compile "${py_files[@]}"; then
    echo "[FAIL]  py_compile"; failed=1
  fi
else
  echo "(no python files found)"
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
