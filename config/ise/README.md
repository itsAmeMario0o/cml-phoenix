# config/ise

`template.json` is a tracked, tagged copy of Cisco's ISE Azure solution
template. It was built to deploy ISE with `az deployment group create`.

## Tentative-obsolete, 2026-09-13

That automated deploy path is retired. ISE terminally fails Azure OS
provisioning through `az deployment group create`, so ISE is now deployed by
hand through the portal instead. See the ADR 0008 amendment
(`docs/decisions/0008-ise-by-azure-solution-template.md`) and the walkthrough
(`docs/ISE-MARKETPLACE-DEPLOY.md`).

`template.json` is kept, not deleted, because roadmap item 19 (ISEEE
ephemeral ISE) may revive an automated deploy from a captured image and reuse
a tracked template. It is not used by the current deploy method. Do not treat
it as the way ISE is deployed today.
