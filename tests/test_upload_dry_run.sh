#!/usr/bin/env bash
# Dry-run tests for scripts/10-upload-images.sh with a fake mounted ISO.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/10-upload-images.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
failures=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

# Fake ISO contents and software folder.
mkdir -p "${TMP}/iso/node-definitions" "${TMP}/iso/virl-base-images/alpine-base-3-21-3" "${TMP}/iso/virl-base-images/iosv-159-3-m10" "${TMP}/software"
touch "${TMP}/iso/node-definitions/alpine.yaml" "${TMP}/iso/node-definitions/iosv.yaml"
touch "${TMP}/iso/virl-base-images/alpine-base-3-21-3/alpine.qcow2" "${TMP}/iso/virl-base-images/iosv-159-3-m10/iosv.qcow2"
touch "${TMP}/software/cml2_2.9.0-3_amd64-3.pkg"
printf 'alpine alpine-base-3-21-3\niosv iosv-159-3-m10\n' > "${TMP}/refplat.txt"
printf 'software_package = "cml2_2.9.0-3_amd64-3.pkg"\n' > "${TMP}/cml.tfvars"

common="REFPLAT_DIR=${TMP}/iso CML_SOFTWARE_DIR=${TMP}/software REFPLAT_FILE=${TMP}/refplat.txt CML_TFVARS=${TMP}/cml.tfvars STORAGE_ACCOUNT=stfake"

# shellcheck disable=SC2086
out="$(env ${common} bash "${SCRIPT}" --dry-run 2>&1)"; rc=$?
assert_eq "dry run exits 0" "0" "${rc}"
assert_contains "package copy planned" "+ azcopy copy ${TMP}/software/cml2_2.9.0-3_amd64-3.pkg https://stfake.blob.core.windows.net/cml/cml2_2.9.0-3_amd64-3.pkg" "${out}"
assert_contains "definition copy planned" "+ azcopy copy ${TMP}/iso/node-definitions/alpine.yaml https://stfake.blob.core.windows.net/cml/refplat/node-definitions/alpine.yaml" "${out}"
assert_contains "image copy planned" "+ azcopy copy ${TMP}/iso/virl-base-images/iosv-159-3-m10 https://stfake.blob.core.windows.net/cml/refplat/virl-base-images/ --recursive" "${out}"
assert_contains "azcopy state kept in repo" "AZCOPY_LOG_LOCATION=${REPO_ROOT}/.azcopy" "${out}"

# A missing image is a FAIL and exit 1.
printf 'alpine alpine-base-3-21-3\nnxosv9000 nxosv9300-10-5-3-f\n' > "${TMP}/refplat.txt"
rc=0
# shellcheck disable=SC2086
out="$(env ${common} bash "${SCRIPT}" --dry-run 2>&1)" || rc=$?
assert_eq "missing image exits 1" "1" "${rc}"
assert_contains "missing image reported" "[FAIL]  image nxosv9300-10-5-3-f not on the ISO" "${out}"

if [[ "${failures}" -gt 0 ]]; then echo "test_upload_dry_run: ${failures} failure(s)"; exit 1; fi
echo "test_upload_dry_run: all passed"
