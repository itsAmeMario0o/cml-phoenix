#!/usr/bin/env bash
# Runs scripts/70-users.sh end to end against tests/fake_cml_api.py:
# class rows, dry run, real run, idempotent rerun, and the failure paths.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/70-users.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
PORT=18007
failures=0

python3 "${REPO_ROOT}/tests/fake_cml_api.py" "${PORT}" &
API_PID=$!
trap 'kill "${API_PID}" 2>/dev/null || true; rm -rf "${TMP}"' EXIT
sleep 1

printf 'CML_URL=http://127.0.0.1:%s\nCML_USERNAME=admin\nCML_PASSWORD=secret\nCML_VERIFY_SSL=false\n' "${PORT}" > "${TMP}/cml.env"
export CML_ENV_FILE="${TMP}/cml.env" USERS_CSV="${TMP}/users.csv" USERS_CREDENTIALS="${TMP}/creds.csv"
# LAB_ENV_FILE points at a path that does not exist, so the wrapper does
# not read the operator's real labs.env and the test controls its own env.
export LAB_ENV_FILE="${TMP}/labs.env"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}

out="$(bash "${SCRIPT}" class netsec 3 cisco.com)"
assert_eq "class prints a header and three rows" "4" "$(echo "${out}" | wc -l | tr -d ' ')"
assert_contains "class row shape" "netsec02@cisco.com,Netsec 02,user" "${out}"
echo "${out}" > "${TMP}/users.csv"
echo "jdoe@example.com,Jane Doe,admin" >> "${TMP}/users.csv"

out="$(bash "${SCRIPT}" --dry-run 2>&1)"
assert_contains "dry run plans the group" "would create group lab-users" "${out}"
assert_contains "dry run plans a user" "would create netsec01@cisco.com (user)" "${out}"
assert_contains "dry run plans the admin" "would create jdoe@example.com (admin)" "${out}"
assert_contains "dry run plans the lab grant" "would grant lab-users lab_exec on 3 lab(s)" "${out}"
assert_contains "dry run lists policy emails" "Access policy emails: jdoe@example.com, netsec01@cisco.com" "${out}"
assert_eq "dry run writes no credentials" "no" "$([[ -f "${TMP}/creds.csv" ]] && echo yes || echo no)"

out="$(bash "${SCRIPT}" 2>&1)"
assert_contains "real run creates the group" "created group lab-users" "${out}"
assert_contains "real run creates users" "created netsec03@cisco.com (user)" "${out}"
assert_contains "real run grants labs" "lab-users: 3 member(s), lab_exec on 3 lab(s)" "${out}"
assert_contains "real run reports the sheet" "4 password(s) written to ${TMP}/creds.csv" "${out}"
assert_eq "credentials file is private" "600" "$(stat -f %Lp "${TMP}/creds.csv" 2>/dev/null || stat -c %a "${TMP}/creds.csv")"
assert_eq "credentials has four users" "5" "$(wc -l < "${TMP}/creds.csv" | tr -d ' ')"
if grep -qE "^[^,]+@[^,]+,.*,[A-Za-z0-9]{16}$" <<<"$(tail -1 "${TMP}/creds.csv")"; then echo "[OK]    password column is 16 alphanumerics"; else
  echo "[FAIL]  password column shape"; failures=$((failures + 1)); fi
if grep -qE "[A-Za-z0-9]{16}" <<<"${out}"; then echo "[FAIL]  a password leaked into stdout"; failures=$((failures + 1)); else
  echo "[OK]    no password on stdout"; fi

cp "${TMP}/creds.csv" "${TMP}/creds.csv.keep"
out="$(bash "${SCRIPT}" 2>&1)"
assert_contains "rerun leaves users alone" "netsec01@cisco.com exists, left alone" "${out}"
assert_contains "rerun keeps the sheet" "no new users; credentials file untouched" "${out}"
assert_eq "sheet unchanged after rerun" "same" "$(cmp -s "${TMP}/creds.csv" "${TMP}/creds.csv.keep" && echo same || echo changed)"

# shared password: LAB_USER_PASSWORD gives every new user the same one
printf 'email,fullname,role\nsuser@example.com,Shared User,user\n' > "${TMP}/shared.csv"
out="$(LAB_USER_PASSWORD=labpass1 USERS_CSV="${TMP}/shared.csv" USERS_CREDENTIALS="${TMP}/shared-creds.csv" bash "${SCRIPT}" 2>&1)"
assert_contains "shared run creates the user" "created suser@example.com (user)" "${out}"
assert_eq "shared password in the sheet" "suser@example.com,Shared User,user,labpass1" "$(tail -1 "${TMP}/shared-creds.csv")"
if grep -qF "labpass1" <<<"${out}"; then echo "[FAIL]  shared password leaked to stdout"; failures=$((failures + 1)); else
  echo "[OK]    shared password stays out of stdout"; fi
rc=0; out="$(LAB_USER_PASSWORD=short USERS_CSV="${TMP}/shared.csv" USERS_CREDENTIALS="${TMP}/x.csv" bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "short shared password exits 1" "1" "${rc}"
assert_contains "short shared password message" "at least 8 characters" "${out}"

rc=0; out="$(USERS_CSV="${TMP}/missing.csv" bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "missing csv exits 1" "1" "${rc}"
assert_contains "missing csv names the example" "config/users.csv.example" "${out}"

printf 'email,fullname,role\nnotanemail,B,user\n' > "${TMP}/bad.csv"
rc=0; out="$(bash "${SCRIPT}" --csv "${TMP}/bad.csv" 2>&1)" || rc=$?
assert_eq "bad csv exits 1" "1" "${rc}"
assert_contains "bad csv names the line" "line 2: 'notanemail' is not an email" "${out}"

rc=0; bash "${SCRIPT}" --bogus >/dev/null 2>&1 || rc=$?
assert_eq "bad flag exits 2" "2" "${rc}"

if [[ "${failures}" -gt 0 ]]; then echo "test_users_script: ${failures} failure(s)"; exit 1; fi
echo "test_users_script: all passed"
