#!/usr/bin/env bash
# Tests for scripts/lib/common.sh. Runs on macOS bash 3.2.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

# Each case runs in a subshell so counters and exit codes stay isolated.

out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; pass a; warn b; miss c; summary_and_exit" 2>&1 || true)"
assert_eq "summary counts" "summary: 1 OK, 1 WARN, 1 FAIL" "$(echo "${out}" | tail -1)"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; pass a; summary_and_exit" >/dev/null 2>&1 || rc=$?
assert_eq "exit 0 with no FAIL" "0" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; miss a; summary_and_exit" >/dev/null 2>&1 || rc=$?
assert_eq "exit 1 with a FAIL" "1" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_cmd bash definitely-not-a-command-xyz" >/dev/null 2>&1 || rc=$?
assert_eq "require_cmd fails on missing tool" "1" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_env NOT_SET_VAR_XYZ" >/dev/null 2>&1 || rc=$?
assert_eq "require_env fails on unset var" "1" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; ASSUME_YES=1 confirm 'go?'" >/dev/null 2>&1 || rc=$?
assert_eq "confirm honours ASSUME_YES" "0" "${rc}"

rc=0; echo "n" | bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; confirm 'go?'" >/dev/null 2>&1 || rc=$?
assert_eq "confirm returns 1 on n" "1" "${rc}"

out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; echo \"\${REPO_ROOT}\"")"
assert_eq "REPO_ROOT resolves" "${REPO_ROOT}" "${out}"

# tf_out: stub terraform stands in for the real binary so we can exercise
# the empty-state and present/absent-output cases without touching state.
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

cat > "${TMP}/terraform" <<'EOF'
#!/usr/bin/env bash
echo '{}'
EOF
chmod +x "${TMP}/terraform"

out=""; rc=0
out="$(PATH="${TMP}:${PATH}" bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; tf_out persistent x" 2>/dev/null)" || rc=$?
assert_eq "tf_out empty state fails silently" "rc=1 out=" "rc=${rc} out=${out}"

cat > "${TMP}/terraform" <<'EOF'
#!/usr/bin/env bash
echo '{"x":{"sensitive":false,"type":"string","value":"hello"}}'
EOF
chmod +x "${TMP}/terraform"

out=""; rc=0
out="$(PATH="${TMP}:${PATH}" bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; tf_out persistent x")" || rc=$?
assert_eq "tf_out present output" "rc=0 out=hello" "rc=${rc} out=${out}"

rc=0
PATH="${TMP}:${PATH}" bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; tf_out persistent missing" >/dev/null 2>&1 || rc=$?
assert_eq "tf_out missing output exit code" "1" "${rc}"

rm -rf "${TMP}"
trap - EXIT

# cml_ssh keeps host keys in keys/known_hosts, not ~/.ssh/known_hosts, so a
# rebuilt VM's new key is accepted once the up script forgets the old one.
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin"
printf '#!/bin/sh\nprintf "%%s " "$@"\n' > "${TMP}/bin/ssh"
chmod +x "${TMP}/bin/ssh"
out="$(PATH="${TMP}/bin:${PATH}" bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; cml_ip() { echo 203.0.113.9; }; cml_ssh hostname" 2>&1)"
assert_eq "cml_ssh uses the repo known_hosts" "yes" "$(grep -q -- "-o UserKnownHostsFile=${REPO_ROOT}/keys/known_hosts" <<<"${out}" && echo yes || echo no)"
assert_eq "cml_ssh accepts new keys only" "yes" "$(grep -q -- "-o StrictHostKeyChecking=accept-new" <<<"${out}" && echo yes || echo no)"
assert_eq "cml_ssh targets sysadmin on 1122" "yes" "$(grep -q -- "-p 1122 .*sysadmin@203.0.113.9 hostname" <<<"${out}" && echo yes || echo no)"

# run: DRY_RUN gates real execution vs echoing the plan.
out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; DRY_RUN=1; run echo hi")"
assert_eq "run echoes the plan under DRY_RUN=1" "+ echo hi" "${out}"
out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; DRY_RUN=0; run echo hi")"
assert_eq "run executes for real under DRY_RUN=0" "hi" "${out}"

# out_or_placeholder: DRY_RUN=1 falls back to <NAME> instead of dying.
out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; tf_out() { return 1; }; DRY_RUN=1; out_or_placeholder resource_group_name")"
assert_eq "out_or_placeholder falls back under DRY_RUN=1" "<resource_group_name>" "${out}"
rc=0
bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; tf_out() { return 1; }; DRY_RUN=0; out_or_placeholder resource_group_name" >/dev/null 2>&1 || rc=$?
assert_eq "out_or_placeholder dies under DRY_RUN=0" "1" "${rc}"

# parse_dry_run_only: the shared parser for the single-flag scripts. A typo
# must die, not fall through and run for real (the bug it was added to fix).
out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; parse_dry_run_only --dry-run")"
assert_eq "parse_dry_run_only accepts --dry-run" "1" "${out}"
out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; parse_dry_run_only")"
assert_eq "parse_dry_run_only defaults to 0" "0" "${out}"
rc=0
bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; parse_dry_run_only --bogus" >/dev/null 2>&1 || rc=$?
assert_eq "parse_dry_run_only dies on an unrecognized flag" "1" "${rc}"

# azcopy_env_init: logs and job plans stay inside the repo, never $HOME.
out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; azcopy_env_init; echo \"\${AZCOPY_LOG_LOCATION}\"")"
assert_eq "azcopy_env_init stays inside the repo" "${REPO_ROOT}/.azcopy" "${out}"

# load_cml_env: cml.env is mandatory; labs.env is optional unless
# --require-labs. Every key is exported for a python3/curl child to read.
TMP2="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
printf 'CML_URL=https://example\nCML_USERNAME=admin\nCML_PASSWORD=secret\n' > "${TMP2}/cml.env"
out="$(CML_ENV_FILE="${TMP2}/cml.env" LAB_ENV_FILE="${TMP2}/no-labs.env" bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; load_cml_env; echo \"\${CML_URL}\"")"
assert_eq "load_cml_env exports CML_URL from cml.env" "https://example" "${out}"
rc=0
CML_ENV_FILE="${TMP2}/cml.env" LAB_ENV_FILE="${TMP2}/no-labs.env" bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; load_cml_env --require-labs" >/dev/null 2>&1 || rc=$?
assert_eq "load_cml_env --require-labs dies without labs.env" "1" "${rc}"
rc=0
CML_ENV_FILE="${TMP2}/missing.env" bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; load_cml_env" >/dev/null 2>&1 || rc=$?
assert_eq "load_cml_env dies without cml.env" "1" "${rc}"
rm -rf "${TMP2}"

finish "test_common"
