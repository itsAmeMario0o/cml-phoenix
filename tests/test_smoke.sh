#!/usr/bin/env bash
# The smoke test needs a live host. Here we only prove it fails cleanly when
# there is no state, and that it never crashes past the first check.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/90-smoke-test.sh"
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

rc=0; out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" TF_STUB_FAIL=1 bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "no state exits 1" "1" "${rc}"
assert_contains "explains" "persistent output public_ip_address" "${out}"
assert_contains "summary printed" "summary:" "${out}"

# The transit bridge (ADR 0003) needs a live controller, so its SSH checks
# cannot run here. Assert the checks exist in the source instead.
src="$(cat "${SCRIPT}")"
assert_contains "check_transit_bridge defined" "check_transit_bridge() {" "${src}"
assert_contains "check_transit_bridge called from main" "  check_transit_bridge" "${src}"
assert_contains "checks bridge1 address exactly" "10.100.0.1/24" "${src}"
assert_contains "checks ip_forward" "net.ipv4.ip_forward" "${src}"

finish "test_smoke"
