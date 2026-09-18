#!/usr/bin/env bash
# Destroy the session's domain controller.
#
#   scripts/46-ad-down.sh [--dry-run]
#
# terraform destroy in terraform/ad, then remove config/mcp-env/ad.env.
# Run it after scripts/45-ise-down.sh: ISE depends on the DC, and the
# numbers follow that order. Never touches bootstrap, persistent, or the
# CML VM. ADR 0010. Prompts unless ASSUME_YES=1.
set -euo pipefail

# ad_tf_args, AD_ROOT, and AD_ENV come from the up script, whose main is
# guarded, so destroy is given exactly the variables apply was.
# shellcheck source=scripts/24-ad-up.sh
source "$(dirname "${BASH_SOURCE[0]}")/24-ad-up.sh"

destroy_root() {
  ad_tf_args
  run terraform -chdir="${AD_ROOT}" destroy -auto-approve "${AD_TF_ARGS[@]}"
}

main_down() {
  DRY_RUN="$(parse_dry_run_only "$@")"
  require_env ARM_SUBSCRIPTION_ID
  if [[ "${DRY_RUN}" != "1" ]]; then
    require_cmd terraform az
  fi
  confirm "Destroy the domain controller (terraform/ad root only)?" || die "declined"
  destroy_root
  run rm -f -- "${AD_ENV}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    pass "dry run: would destroy the domain controller (terraform/ad root only) and remove ${AD_ENV}."
  else
    pass "domain controller destroyed. Persistent resources, ISE, and the CML VM untouched."
  fi
  summary_and_exit
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main_down "$@"
fi
