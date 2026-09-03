# 0004: Secrets from random_password and a gitignored tfvars file

Status: accepted, 2026-09-02

## Context

Three secrets exist: the CML admin password, the sysadmin password, and
the Smart License token. cloud-cml supports Vault, Conjur, or a dummy
manager that takes raw values from its config file. This is a one-person
lab; the cost of a secret store is real and the benefit is small.

## Decision

- The two passwords are `random_password` resources in the persistent root,
  16 characters, no specials, so they match cloud-cml's dummy manager and
  need no YAML escaping. They live in blob state and are read back with
  `terraform output -raw`.
- The license token lives only in `config/cml.tfvars`, gitignored.
- `scripts/20-up.sh` renders both into `config/cml.yml`, gitignored, mode
  600, with a Python step. Terraform never sees this repo's files.
- cml-mcp credentials are written to `config/mcp-env/cml.env`, in a
  self-ignoring directory, and read by `scripts/mcp-cml.sh`.
- gitleaks runs in pre-commit with custom rules for the token and for
  Azure storage keys.

## Consequences

- The blob state container holds the passwords. It is private, Azure AD
  authenticated, versioned, and soft deleted. Acceptable for a lab.
- Rotating a password means tainting the resource and rebuilding the CML
  VM, since cloud-cml sets it at install time.
- A stranded token is the main risk; `scripts/40-down.sh` refuses to
  destroy while the license is registered.

## Options considered

1. **Azure Key Vault.** Rejected for now: more resources, RBAC, and a
   provider dependency for three values. Revisit if a second person joins.
2. **HashiCorp Vault or Conjur via cloud-cml.** Rejected: nothing to run it on.
3. **random_password plus gitignored tfvars.** Chosen.
