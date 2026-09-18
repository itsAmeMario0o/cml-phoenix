#!/usr/bin/env bash
# Verify a running lab: generate a fresh pyATS testbed from CML, then run
# the scenario's easypy jobfile against it (Task 3, ADR 0009).
#
#   scripts/80-verify-lab.sh <scenario> [--dry-run]
#
# Known scenarios and the tracked topology each one verifies:
#   cilium-evpn      labs/cilium-evpn-blank.yaml
#   trustsec-phase1  labs/trustsec-phase1.yaml
#
# Order:
#   1. Confirm verify/.venv exists (see verify/README.md to bootstrap it).
#   2. Confirm verify/<scenario>/jobfile.py exists.
#   3. load_cml_env (scripts/lib/common.sh) sources config/mcp-env/cml.env
#      and exports CML_URL/CML_USERNAME/CML_PASSWORD for gen_testbed.py to
#      read from its own environment (ADR 0004); neither ever appears on
#      this or gen_testbed.py's command line, so a --dry-run plan carries
#      no secret (senior-secops).
#   4. Resolve the scenario's lab title by reading it from the tracked
#      topology in labs/, through scripts/lib/render_lab.py --print-title,
#      so the title used to find the lab on CML can never drift from the
#      YAML (ADR 0006 documents why the tracked file, not this script,
#      owns the title).
#   5. Generate verify/.testbed/<scenario>.yaml from the running lab
#      (verify/lib/gen_testbed.py, Task 2).
#   6. Run the scenario's jobfile with easypy in the pyATS venv, with its
#      archive and runinfo under verify/.archive and verify/.runinfo (both
#      gitignored) rather than ~/.pyats. easypy prints its own report
#      archive path to stdout; this script does not capture or suppress
#      that output.
#
# A verification only checks a lab that is already built. It builds,
# deploys, and tears down nothing.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

VENV_DIR="${REPO_ROOT}/verify/.venv"
ARCHIVE_DIR="${REPO_ROOT}/verify/.archive"
RUNINFO_DIR="${REPO_ROOT}/verify/.runinfo"
RENDER="${REPO_ROOT}/scripts/lib/render_lab.py"
DRY_RUN=0

usage() {
  echo "usage: scripts/80-verify-lab.sh <scenario> [--dry-run]" >&2
  exit 2
}

# lab_yaml_for_scenario: the tracked topology backing a scenario. A new
# scenario adds a case here naming its labs/ file; the lab title itself
# is never hardcoded, only read from that file at runtime (lab_title_for).
lab_yaml_for_scenario() {
  case "$1" in
    cilium-evpn) echo "${REPO_ROOT}/labs/cilium-evpn-blank.yaml" ;;
    trustsec-phase1) echo "${REPO_ROOT}/labs/trustsec-phase1.yaml" ;;
    *) die "unknown scenario '$1'. Known scenarios: cilium-evpn, trustsec-phase1" ;;
  esac
}

# lab_title_for: read the lab title out of the scenario's tracked YAML.
# --pubkey is required by render_lab.py's argparse but is never opened on
# the --print-title early return, so a path that may not exist is fine.
lab_title_for() {
  local yaml="$1" title
  title="$(python3 "${RENDER}" "${yaml}" --pubkey "${REPO_ROOT}/keys/cml-lab.pub" --print-title)"
  [[ -n "${title}" ]] || die "${yaml} has no lab title"
  echo "${title}"
}

require_venv() {
  [[ -d "${VENV_DIR}" ]] || die "verify/.venv missing. Bootstrap: python3 -m venv verify/.venv && verify/.venv/bin/pip install -r verify/requirements.txt"
}

require_jobfile() {
  [[ -f "$1" ]] || die "$1 missing"
}

# gen_testbed: fetch a fresh testbed from the running lab. gen_testbed.py
# itself creates verify/.testbed/ (mode-safe, ADR 0004) if it does not
# already exist, so this script does not create it separately.
gen_testbed() {
  local title="$1" out="$2"
  run python3 "${REPO_ROOT}/verify/lib/gen_testbed.py" "${title}" "${out}"
}

run_jobfile() {
  # PATH needs the venv's bin/ ahead of the system one: easypy's own
  # pre-job EnvironmentDebugPlugin shells out to the bare "pyats" command
  # to check the install, and running "${VENV_DIR}/bin/easypy" by full
  # path does not put its own bin/ on PATH the way "source .../activate"
  # would. Without it the plugin errors "pyats: command not found" and
  # the job aborts before any testcase runs (caught live, Task 7).
  #
  # Without -archive_dir and -runinfo_dir easypy writes under ~/.pyats/,
  # outside the repo, and the archive holds the test AAA password in
  # clear text (verify/trustsec-phase1/verify.py). Both live under
  # verify/, gitignored, created 0700 so only the operator reads them.
  # The option names are the ones the installed easypy registers with
  # argparse: single dash, underscore. ADR 0009.
  run mkdir -p -m 0700 "${ARCHIVE_DIR}" "${RUNINFO_DIR}"
  PATH="${VENV_DIR}/bin:${PATH}" run "${VENV_DIR}/bin/easypy" "$1" \
    -archive_dir "${ARCHIVE_DIR}" -runinfo_dir "${RUNINFO_DIR}"
}

main() {
  local scenario="" arg yaml title jobfile testbed_out
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      -*) usage ;;
      *) [[ -z "${scenario}" ]] || usage; scenario="${arg}" ;;
    esac
  done
  [[ -n "${scenario}" ]] || usage
  require_cmd python3
  require_venv
  load_cml_env
  yaml="$(lab_yaml_for_scenario "${scenario}")"
  [[ -f "${yaml}" ]] || die "${yaml} missing for scenario '${scenario}'"
  jobfile="${REPO_ROOT}/verify/${scenario}/jobfile.py"
  require_jobfile "${jobfile}"
  title="$(lab_title_for "${yaml}")"
  testbed_out="${REPO_ROOT}/verify/.testbed/${scenario}.yaml"
  gen_testbed "${title}" "${testbed_out}"
  run_jobfile "${jobfile}"
  pass "verification run complete for '${scenario}'. See easypy's own output above for the report archive path."
  summary_and_exit
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
