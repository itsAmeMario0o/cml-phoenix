#!/usr/bin/env bash
# Export every lab to YAML and copy the folder to blob storage.
#
#   scripts/30-export-labs.sh [--dry-run]
#
# 1. Refuse if the CML API does not answer (nothing to export safely)
# 2. On the host: cml-remote.sh export-labs /data/exports/<UTC timestamp>
# 3. scp that folder to exports/<timestamp>/ in the repo (gitignored)
# 4. Compare the file count with a fresh cml-remote.sh list-labs
# 5. azcopy the local copy to the exports container, same folder name
#
# The blob copy is the durable one. The host copy dies with the VM, the
# local copy is a convenience for diffing. Reimport is by hand or via
# cml-mcp create_full_lab_topology, on purpose (spec section 3).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

LOCAL_EXPORTS="${REPO_ROOT}/exports"
DRY_RUN=0

export_on_host() {
  local stamp="$1"
  run cml_remote export-labs "/data/exports/${stamp}"
}

pull_local_copy() {
  local ip="$1" stamp="$2"
  mkdir -p "${LOCAL_EXPORTS}"
  run cml_scp -q -r "sysadmin@${ip}:/data/exports/${stamp}" "${LOCAL_EXPORTS}/${stamp}"
}

# verify_export_count STAMP: one YAML per lab the controller lists, read
# again on its own. An export that came up short once looked like
# "exported 0 labs" and 40-down.sh destroyed the VM on the strength of it
# (architecture review, 2026-09-17); this is the independent check.
verify_export_count() {
  local stamp="$1" listed exported
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ compare exports/${stamp} file count with cml_remote list-labs"
    return 0
  fi
  listed="$(cml_remote list-labs | wc -l | tr -d ' ')" || die "cannot list labs to verify the export"
  exported="$(find "${LOCAL_EXPORTS}/${stamp}" -name '*.yaml' | wc -l | tr -d ' ')"
  [[ "${listed}" == "${exported}" ]] || die "exported ${exported} files but the controller lists ${listed} labs. Nothing is safe to destroy."
  pass "export holds ${exported} labs, matching the controller"
}

push_to_blob() {
  local stamp="$1" sa
  sa="$(tf_out persistent storage_account_name)" || die "persistent output storage_account_name unavailable, export not uploaded"
  azcopy_env_init
  run azcopy copy "${LOCAL_EXPORTS}/${stamp}" "https://${sa}.blob.core.windows.net/exports/" --recursive
}

main() {
  local ip stamp
  DRY_RUN="$(parse_dry_run_only "$@")"
  require_cmd terraform ssh scp azcopy curl jq
  ip="$(cml_ip)" || die "persistent output public_ip_address unavailable; is the persistent root applied?"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ "${DRY_RUN}" != "1" ]] && ! cml_api_ready; then
    die "CML API at https://${ip} is not ready. Nothing exported."
  fi
  export_on_host "${stamp}"
  pull_local_copy "${ip}" "${stamp}"
  verify_export_count "${stamp}"
  push_to_blob "${stamp}"
  pass "exports in ${LOCAL_EXPORTS}/${stamp} and blob container exports/${stamp}"
  summary_and_exit
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
