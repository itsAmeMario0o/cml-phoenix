# config/ise

This directory held `template.json`, a tracked, tagged copy of Cisco's ISE
Azure solution template, used to deploy ISE with `az deployment group
create`. That automated path is retired: ISE terminally fails Azure OS
provisioning through it, so ISE is deployed by hand through the portal
instead. See the ADR 0008 amendment
(`docs/decisions/0008-ise-by-azure-solution-template.md`) and the walkthrough
(`docs/ISE-MARKETPLACE-DEPLOY.md`).

`template.json` and its renderer, `scripts/lib/ise_params.py`, were deleted
on 2026-09-13 rather than kept alongside the retired path; both are still in
git history if roadmap item 19 (ISEEE ephemeral ISE) ever revives an
automated deploy from a captured image and needs a tracked template again.
