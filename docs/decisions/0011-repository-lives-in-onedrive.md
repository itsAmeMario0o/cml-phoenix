# 0011: The repository stays inside the OneDrive folder

Status: accepted, 2026-09-17

## Context

The working tree sits under `~/Library/CloudStorage/OneDrive-<account>/`,
a folder a sync client uploads. The git database does not: `.git` in the
repository is a symlink to `~/.local-git/cml-azure-lab.git`, outside
OneDrive, so history and refs never sync. What syncs is the working tree,
and the working tree holds every gitignored secret the kit produces:

- `config/mcp-env/`: the CML admin credentials, the ISE admin password and
  RADIUS secret, the lab password, the Cloudflare tunnel token, and the
  generated CML user credentials sheet.
- `keys/cml-lab`, the SSH private key, generated without a passphrase.
- `config/cml.yml`, the rendered cloud-cml config with both CML passwords
  and the license token, and `config/cml.tfvars` with the token.
- The local state of `terraform/bootstrap`, `terraform/ad`, and
  `vendor/cloud-cml`. The last two hold generated passwords: the DC's
  administrator, lab user, and `svc-ise` passwords in the directory root,
  and the CML passwords in the fork's.

`.gitignore` keeps these out of git and does nothing else. Whether the sync
client excludes any of them is not known; nobody has checked its settings.
OneDrive has also caused two recorded failures, both in
`docs/LESSONS-LEARNED.md`: a large ISO replaced by an on-demand placeholder
so that `hdiutil` and `azcopy` read it short, and Terraform provider
binaries left as stale placeholders so that `init` and `validate` hung or
failed with a stale NFS file handle.

The 2026-09-17 architecture review asked for either a move out of OneDrive
or an ADR that accepts staying. This is that ADR.

## Decision

The repository stays where it is. The operator accepted this on
2026-09-17.

## Consequences

- The exposure is bounded by the security of the Microsoft account that
  owns the OneDrive, and by lifetime: the CML VM, the DC, and ISE end with
  the session, so most of what could leak stops working when the session
  does. The exceptions are the two CML passwords in the persistent root's
  outputs, the license token, and the SSH key, which outlive a session.
- The upside is an off-machine copy of the local state files. ADR 0002 said
  to back up the bootstrap state "by keeping the repo folder intact" and
  relied on this sync without saying so. Now it is said.
- If the Microsoft account is compromised, rotate everything: the three
  passwords in the table under "Passwords" in `docs/AD.md` (a new build of
  the directory root does that), `ISE_ADMIN_PASSWORD` and `RADIUS_SECRET`
  in `config/mcp-env/ise.env`, the license token, a fresh `keys/cml-lab`,
  and the two persistent `random_password` resources by the procedure in
  ADR 0004.
- The two OneDrive failure modes stay. Their fixes in the lessons log are
  "Always Keep on This Device" for large downloads and deleting a root's
  `.terraform` cache before `init`.
- ADR 0010's line that the directory root's state is protected "only by
  `.gitignore` and the Mac's disk" was wrong on the day it was written. It
  now points here.

## Options considered

1. Move the folder out of OneDrive. It is only a relocation, and it
   removes both the sync exposure and the placeholder failures. Rejected
   by the operator on 2026-09-17.
2. Stay, and move the secrets into Key Vault. ADR 0004 defers Key Vault
   until a second operator joins, and `CLAUDE.md` keeps it out of scope
   until then. Rejected for now for the same reason.
3. Stay and accept the exposure as bounded above. Chosen.

Exit condition: a second operator, or Key Vault. Either one reopens this
decision, because the bound "one Microsoft account, one Mac" no longer
holds.
