#!/usr/bin/env bash
# Dry-run tests for the fork's 05-persist.sh. The script runs on Ubuntu as
# root; here DRY_RUN=1 prints the commands it would run and the PRETEND_*
# variables stand in for disk and filesystem probes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/vendor/cloud-cml/modules/deploy/data/05-persist.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
failures=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "[OK]    ${label}"
  else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1))
  fi
}
assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "[FAIL]  ${label}: unexpected '${needle}'"; failures=$((failures + 1))
  else
    echo "[OK]    ${label}"
  fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

common_env="DRY_RUN=1 LOG_DIR=${TMP} DATA_MNT=${TMP}/data IMAGES_DIR=${TMP}/images REFPLAT_JSON=${TMP}/refplat FSTAB=${TMP}/fstab WAIT_SECS=1"
echo '{"definitions":["alpine"],"images":["alpine-base-3-21-3"]}' > "${TMP}/refplat"
touch "${TMP}/fstab"

# 1. First boot: blank disk, no images yet. Must format, mount, bind, and
#    leave the refplat image list alone so cml.sh copies the images.
# shellcheck disable=SC2086
out="$(env ${common_env} PRETEND_FS= PRETEND_IMAGE_FILES=0 bash "${SCRIPT}" pre 2>&1)"
assert_contains "first boot formats" "+ mkfs.ext4 -L cmldata" "${out}"
assert_contains "first boot partitions" "+ parted -s" "${out}"
assert_contains "first boot binds images" "+ mount --bind ${TMP}/data/images ${TMP}/images" "${out}"
assert_contains "first boot fstab data line" "LABEL=cmldata ${TMP}/data ext4" "${out}"
assert_contains "first boot fstab bind line" "${TMP}/data/images ${TMP}/images none bind" "${out}"
assert_not_contains "first boot keeps image list" "images = []" "${out}"

# 2. Rebuild: formatted disk with images. Must not format, must bind, and
#    must empty the image list so cml.sh skips the copy.
# shellcheck disable=SC2086
out="$(env ${common_env} PRETEND_FS=ext4 PRETEND_IMAGE_FILES=12 bash "${SCRIPT}" pre 2>&1)"
assert_not_contains "rebuild does not format" "mkfs.ext4" "${out}"
assert_contains "rebuild binds images" "+ mount --bind" "${out}"
assert_contains "rebuild skips image copy" "images = []" "${out}"
assert_contains "rebuild reports reuse" "reusing 12 image files" "${out}"

# 3. Post phase fails loudly when the bind mount is gone.
rc=0
# shellcheck disable=SC2086
env ${common_env} PRETEND_BOUND=0 bash "${SCRIPT}" post >/dev/null 2>&1 || rc=$?
assert_eq "post fails without bind mount" "1" "${rc}"

# 4. Post phase passes when bound.
# shellcheck disable=SC2086
out="$(env ${common_env} PRETEND_BOUND=1 PRETEND_IMAGE_FILES=12 bash "${SCRIPT}" post 2>&1)"; rc=$?
assert_contains "post confirms bind" "bind mount active" "${out}"

# 5. Unknown phase is an error.
rc=0
# shellcheck disable=SC2086
env ${common_env} bash "${SCRIPT}" bogus >/dev/null 2>&1 || rc=$?
assert_eq "unknown phase exits 2" "2" "${rc}"

# 6. The script is shellcheck clean (it is outside the pre-commit scope).
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "${SCRIPT}"; then echo "[OK]    shellcheck"; else
    echo "[FAIL]  shellcheck"; failures=$((failures + 1)); fi
fi

if [[ "${failures}" -gt 0 ]]; then echo "test_persist: ${failures} failure(s)"; exit 1; fi
echo "test_persist: all passed"
