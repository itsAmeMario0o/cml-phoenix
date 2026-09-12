# TrustSec Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up an external, disposable ISE on the Azure apps subnet that CML switches reach for RADIUS with per-device identity and a working Change of Authorization return path, proving the ADR 0003 routed path.

**Architecture:** The persistent root already provides the Azure half of the routed path (UDR, IP forwarding, NSG). This plan adds a no-NAT host transit bridge, a C8000v lab edge, a disposable `terraform/ise` root that deploys ISE from the Azure Marketplace, bring-up and teardown scripts, and a minimal ISE policy applied as code. The full TrustSec fabric and SGT policy are Phase 2.

**Tech Stack:** Terraform (azurerm ~> 4.0), Bash (3.2-compatible on the Mac), Python (stdlib only, unittest), the cloud-cml fork under `vendor/`, ISE REST (ERS/OpenAPI).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-12-trustsec-phase1-routed-ise-design.md`. ADR 0003 (routed path), ADR 0004 (secrets).
- No secret in a tracked file. ISE admin password is a `random_password`; state is gitignored.
- Never `0.0.0.0/0` in an allowed-subnet list.
- Terraform: every variable has a description and type; every resource carries `local.common_tags`; no magic strings.
- Bash: `set -euo pipefail`, quote every variable, functions under 40 lines, `main "$@"` at the bottom, `[OK]`/`[WARN]`/`[FAIL]` output.
- Python: stdlib only, type hints on every signature, `unittest`.
- No em-dashes in prose. Comments explain why and cite the ADR.
- `tests/run.sh` and `pre-commit run --all-files` pass before any commit.
- Stop-and-ask gates (do not proceed on inference): anything under `vendor/`, any `terraform apply`, installing a tool. The plan marks these HUMAN-GATED.
- Transit addressing (from ADR 0003): host bridge `br-transit` at `10.100.0.1/24`; C8000v lab edge at `10.100.0.2` routing `10.100.0.0/16`; ISE on the apps subnet at `10.20.2.20`.

---

### Task 1: Confirm the ISE Azure Marketplace offer and add a preflight check

Resolves the spec's open questions on the ISE image and size. Everything downstream consumes the values this task records.

**Files:**
- Modify: `scripts/00-preflight.sh` (add an ISE-terms check function)
- Modify: `tests/test_preflight.sh` (assert the new check)
- Create: `config/ise.tfvars.example` (records the confirmed image coordinates and size as tracked example values)

**Interfaces:**
- Produces: the confirmed Marketplace coordinates as example tfvars keys `ise_image_publisher`, `ise_image_offer`, `ise_image_sku`, `ise_image_version`, `ise_vm_size`, consumed by Task 3.

- [ ] **Step 1: Research the offer (read-only, record findings)**

Run, and record the newest ISE offer and its plan:

```bash
az vm image list --all --publisher cisco --query "[?contains(offer,'ise') || contains(offer,'identity')].{publisher:publisher,offer:offer,sku:sku,version:version}" -o table
```

Cross-check the supported VM size against Cisco's "Install ISE on Azure" guidance. Record the exact publisher, offer, sku, version, plan name, and the smallest supported size that fits the Edsv6 or Dsv-family quota.

- [ ] **Step 2: Write `config/ise.tfvars.example` with the confirmed values**

```hcl
# Copy to config/ise.tfvars (gitignored) and fill in. Confirmed against the
# Azure Marketplace on 2026-09-12 (Task 1 of the TrustSec Phase 1 plan).
ise_image_publisher = "cisco"
ise_image_offer     = "<offer from step 1>"
ise_image_sku       = "<sku from step 1>"
ise_image_version   = "<version, or 'latest'>"
# Smallest supported ISE size that fits quota. See the plan's Task 1.
ise_vm_size         = "<size from step 1>"
# ISE private IP on the apps subnet.
ise_private_ip      = "10.20.2.20"
```

- [ ] **Step 3: Add the preflight check function**

In `scripts/00-preflight.sh`, add after the quota checks:

```bash
check_ise_marketplace() {
  local pub off sku
  pub="$(grep -E '^ise_image_publisher' config/ise.tfvars 2>/dev/null | cut -d'"' -f2)"
  off="$(grep -E '^ise_image_offer' config/ise.tfvars 2>/dev/null | cut -d'"' -f2)"
  sku="$(grep -E '^ise_image_sku' config/ise.tfvars 2>/dev/null | cut -d'"' -f2)"
  if [[ -z "${pub}" || -z "${off}" || -z "${sku}" ]]; then
    warn "config/ise.tfvars not filled; ISE build will fail. See config/ise.tfvars.example"
    return
  fi
  # Terms must be accepted once per subscription before a Marketplace deploy.
  if az vm image terms show --publisher "${pub}" --offer "${off}" --plan "${sku}" \
       --query accepted -o tsv 2>/dev/null | grep -qi true; then
    pass "ISE Marketplace terms accepted for ${off}"
  else
    miss "ISE Marketplace terms not accepted. Run: az vm image terms accept --publisher ${pub} --offer ${off} --plan ${sku}"
  fi
}
```

Call it from the preflight main sequence alongside the other cloud checks.

- [ ] **Step 4: Assert it in the preflight test**

In `tests/test_preflight.sh`, with the `az` stub, add a case: when `ise.tfvars` is absent the check emits a `[WARN]` and preflight still passes; the stub `az vm image terms show` returns `true` so a filled `ise.tfvars` yields `[OK]`. Follow the existing stub pattern in `tests/stubs/az`.

- [ ] **Step 5: Run the gate and commit**

```bash
tests/run.sh && pre-commit run --files scripts/00-preflight.sh tests/test_preflight.sh config/ise.tfvars.example
git add scripts/00-preflight.sh tests/test_preflight.sh config/ise.tfvars.example
git commit -m "feat: confirm ISE Marketplace offer and preflight its terms"
```

- [ ] **Step 6 (HUMAN-GATED): Accept the Marketplace terms**

The operator runs the `az vm image terms accept` line the preflight prints. Terms acceptance is a subscription change, so it is not automated.

---

### Task 2: The host transit bridge customize script (fork, HUMAN-GATED)

**Files:**
- Create: `vendor/cloud-cml/modules/deploy/data/06-transit-bridge.sh` (fork customize script)
- Modify: the fork's cloud-init customize list to run it (exact file identified during implementation)
- Modify: `scripts/90-smoke-test.sh` (assert the bridge and forwarding)
- Modify: `tests/test_smoke.sh` (assert the new smoke check parses)

**Interfaces:**
- Produces: a Linux bridge `br-transit` at `10.100.0.1/24` on the CML host, `net.ipv4.ip_forward=1`, and no masquerade for `10.100.0.0/16`. Consumed by Task 6 (the external connector maps to it) and Task 7 (verification).

- [ ] **Step 1: Write the customize script**

```bash
#!/bin/bash
# 06-transit-bridge.sh: routed lab connectivity, no NAT (ADR 0003).
# Creates br-transit for lab nodes and makes the host a layer 3 hop so
# ISE on the apps subnet sees each switch at its own address. Runs on
# every rebuild because the VM is disposable.
set -euo pipefail
BR="br-transit"
if ! ip link show "${BR}" >/dev/null 2>&1; then
  ip link add name "${BR}" type bridge
  ip addr add 10.100.0.1/24 dev "${BR}"
  ip link set "${BR}" up
fi
# Route, do not translate: ISE must see per-device source addresses.
sysctl -w net.ipv4.ip_forward=1
sed -i 's/^#\?net.ipv4.ip_forward.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || \
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
# Ensure nothing masquerades the transit range on the way out.
if command -v nft >/dev/null 2>&1; then
  nft list ruleset 2>/dev/null | grep -q '10.100.0.0/16.*masquerade' && \
    echo "WARN: a masquerade rule covers the transit range; CoA per-device identity will break"
fi
echo "06-transit-bridge: ${BR} up at 10.100.0.1/24, ip_forward on"
```

- [ ] **Step 2 (HUMAN-GATED): Wire it into the fork and bump the submodule**

Editing anything under `vendor/` is a stop-and-ask. The operator approves adding the script to the fork's customize sequence, commits it on branch `azure-lab`, pushes, and bumps the submodule pointer. Cite ADR 0003 in the fork commit.

- [ ] **Step 3: Add the smoke-test assertions**

In `scripts/90-smoke-test.sh`, after the `/data` checks, add over SSH to the host:

```bash
if cml_ssh "ip -br addr show br-transit 2>/dev/null | grep -q 10.100.0.1"; then
  pass "br-transit up at 10.100.0.1"
else
  miss "br-transit missing; the fork customize script did not run"
fi
if [[ "$(cml_ssh 'cat /proc/sys/net/ipv4/ip_forward')" == "1" ]]; then
  pass "ip_forward on"
else
  miss "ip_forward off; the routed path will not work"
fi
```

- [ ] **Step 4: Extend `tests/test_smoke.sh`**

The smoke test's no-state path already exits early; add a case asserting the two new lines are present in the script and that it still exits cleanly with no controller. Follow the existing structure in `tests/test_smoke.sh`.

- [ ] **Step 5: Run the gate and commit the repo-side changes**

```bash
tests/run.sh && pre-commit run --files scripts/90-smoke-test.sh tests/test_smoke.sh
git add scripts/90-smoke-test.sh tests/test_smoke.sh
git commit -m "test: smoke-check the transit bridge and ip_forward"
```

---

### Task 3: The disposable `terraform/ise` root

**Files:**
- Create: `terraform/ise/main.tf`, `terraform/ise/variables.tf`, `terraform/ise/outputs.tf`, `terraform/ise/providers.tf`, `terraform/ise/backend.tf`
- Modify: `scripts/00-preflight.sh` (fmt/validate the new root)

**Interfaces:**
- Consumes: `ise_image_*`, `ise_vm_size`, `ise_private_ip` from `config/ise.tfvars` (Task 1); the persistent root's `apps_subnet_id` output.
- Produces: outputs `ise_private_ip` and `ise_admin_password` (sensitive), consumed by Tasks 4 and 5.

- [ ] **Step 1: Write `variables.tf`**

```hcl
variable "ise_image_publisher" {
  description = "Azure Marketplace publisher for ISE (ADR 0003). From config/ise.tfvars."
  type        = string
}
variable "ise_image_offer" {
  description = "Marketplace offer for ISE."
  type        = string
}
variable "ise_image_sku" {
  description = "Marketplace SKU and plan name for ISE."
  type        = string
}
variable "ise_image_version" {
  description = "Marketplace image version, or 'latest'."
  type        = string
  default     = "latest"
}
variable "ise_vm_size" {
  description = "Smallest ISE-supported Azure VM size that fits quota."
  type        = string
}
variable "ise_private_ip" {
  description = "Static private IP for ISE on the apps subnet."
  type        = string
  default     = "10.20.2.20"
}
```

- [ ] **Step 2: Write `main.tf`**

Read the persistent apps subnet by data source, create a NIC with the static private IP, and a Linux VM from the Marketplace image with the required `plan` block and a `random_password` admin secret. Every resource carries `local.common_tags`. (Full resource bodies written during implementation against the Task 1 values; the disposable pattern mirrors `vendor/cloud-cml` and the CML VM.)

- [ ] **Step 3: Write `outputs.tf`**

```hcl
output "ise_private_ip" {
  description = "ISE private IP on the apps subnet."
  value       = var.ise_private_ip
}
output "ise_admin_password" {
  description = "ISE admin password. Read with terraform output -raw."
  value       = random_password.ise_admin.result
  sensitive   = true
}
```

- [ ] **Step 4: fmt, validate, and add to preflight**

```bash
terraform -chdir=terraform/ise init -backend=false && terraform -chdir=terraform/ise validate && terraform -chdir=terraform/ise fmt -check
```

Add `terraform/ise` fmt and validate to `scripts/00-preflight.sh` alongside the other three roots.

- [ ] **Step 5: Run the gate and commit**

```bash
tests/run.sh && pre-commit run --all-files
git add terraform/ise scripts/00-preflight.sh
git commit -m "feat: disposable terraform/ise root for a Marketplace ISE VM"
```

---

### Task 4: ISE bring-up and teardown scripts

**Files:**
- Create: `scripts/25-ise-up.sh`, `scripts/45-ise-down.sh`
- Create: `tests/test_ise_dry_run.sh`
- Modify: `tests/stubs/terraform` if needed for the ISE root

**Interfaces:**
- Consumes: `terraform/ise` (Task 3), `ise_private_ip` output.
- Produces: an ISE VM applied and reported ready; a teardown that destroys the ISE root.

- [ ] **Step 1: Write `25-ise-up.sh`**

`set -euo pipefail`, source `scripts/lib/common.sh`. Apply `terraform/ise` (prompting unless `ASSUME_YES=1`, like `20-up.sh`), then poll `https://<ise_private_ip>/admin/API/mnt/Version` through the CML host as a jump until it answers, backgrounded with progress. The ISE-ready wait is the long pole (30 to 45 minutes); print elapsed time each poll. `main "$@"` at the bottom.

- [ ] **Step 2: Write `45-ise-down.sh`**

Destroy `terraform/ise` (prompting unless `ASSUME_YES=1`). Never touches bootstrap or persistent.

- [ ] **Step 3: Write `tests/test_ise_dry_run.sh`**

With the `terraform` stub on PATH, assert `25-ise-up.sh --dry-run` plans the ISE apply and the readiness wait, and `45-ise-down.sh --dry-run` plans the destroy. Follow `tests/test_up_dry_run.sh`.

- [ ] **Step 4: Run it**

```bash
bash tests/test_ise_dry_run.sh
```
Expected: `test_ise_dry_run: all passed`.

- [ ] **Step 5: Run the gate and commit**

```bash
tests/run.sh && pre-commit run --files scripts/25-ise-up.sh scripts/45-ise-down.sh tests/test_ise_dry_run.sh
git add scripts/25-ise-up.sh scripts/45-ise-down.sh tests/test_ise_dry_run.sh
git commit -m "feat: ISE bring-up and teardown scripts with a readiness wait"
```

---

### Task 5: Minimal ISE policy as code

**Files:**
- Create: `scripts/lib/ise_config.py`
- Create: `tests/test_ise_config.py`
- Create: `tests/fake_ise_api.py`
- Modify: `scripts/25-ise-up.sh` (call the config step after ISE is ready)

**Interfaces:**
- Consumes: `ise_private_ip`, `ise_admin_password`, and a NAD shared secret from the environment.
- Produces: one network device (the C8000v edge as a NAD) and one authorization rule in ISE, enough to prove RADIUS and CoA. Full policy is Phase 2.

- [ ] **Step 1: Write the failing test against a fake ISE**

In `tests/test_ise_config.py`, stand up `tests/fake_ise_api.py` (an ERS-shaped stub like `tests/fake_cml_api.py`) and assert `ise_config.ensure_network_device(...)` creates a NAD idempotently and returns its id.

- [ ] **Step 2: Run it, expect failure**

```bash
python3 -m unittest tests/test_ise_config.py
```
Expected: FAIL (module or function not defined).

- [ ] **Step 3: Write `ise_config.py`**

Stdlib-only client (`urllib`, `ssl` with verify off for the self-signed ISE cert), Basic auth with the admin password, ERS endpoints for network devices, type hints on every signature. `ensure_network_device` is create-if-missing, mirroring `users.py`.

- [ ] **Step 4: Run it, expect pass**

```bash
python3 -m unittest tests/test_ise_config.py
```
Expected: OK.

- [ ] **Step 5: Wire into `25-ise-up.sh` and commit**

Call `ise_config.py` after the readiness wait, reading the password from the ISE root output and the shared secret from a gitignored env file. Then:

```bash
tests/run.sh && pre-commit run --all-files
git add scripts/lib/ise_config.py tests/test_ise_config.py tests/fake_ise_api.py scripts/25-ise-up.sh
git commit -m "feat: minimal ISE policy as code, one NAD and one rule"
```

---

### Task 6: The transit-side proof topology (C8000v edge as NAD)

**Files:**
- Create: `labs/trustsec-phase1.yaml`
- Modify: `labs/README.md`

**Interfaces:**
- Consumes: the `br-transit` connector (Task 2), `ise_private_ip` (Task 3), the render placeholders (`__LAB_PASSWORD__`, ADR 0006).
- Produces: a running C8000v at `10.100.0.2` configured as a RADIUS client (NAD) pointing at ISE, on the transit bridge. Phase 1 needs no Catalyst 9000v; the edge alone proves the routed path, RADIUS, and CoA.

- [ ] **Step 1: Write `labs/trustsec-phase1.yaml`**

An external connector mapped to `br-transit`, one `cat8000v` edge at `10.100.0.2/24` with a default route to `10.100.0.1`, `aaa` pointing at `__ISE_IP__` with `__RADIUS_SECRET__`, and CoA (`aaa server radius dynamic-author`) enabled. Passwords and the ISE IP are placeholders rendered by `60-import-lab.sh` from `config/mcp-env/labs.env`.

- [ ] **Step 2: Confirm it renders**

```bash
LAB_PASSWORD=x ISE_IP=10.20.2.20 RADIUS_SECRET=y python3 scripts/lib/render_lab.py labs/trustsec-phase1.yaml --pubkey keys/cml-lab.pub >/dev/null && echo ok
```
Expected: `ok`. `tests/test_render_lab.py` already walks every `labs/*.yaml`, so it will cover this file too.

- [ ] **Step 3: Run the gate and commit**

```bash
tests/run.sh && pre-commit run --files labs/trustsec-phase1.yaml labs/README.md
git add labs/trustsec-phase1.yaml labs/README.md
git commit -m "feat: TrustSec Phase 1 proof topology, C8000v edge as NAD"
```

---

### Task 7: End-to-end verification (HUMAN-GATED build)

**Files:**
- Modify: `docs/STATUS.md` (record the result)

**Interfaces:**
- Consumes: everything above, on a live build.

- [ ] **Step 1 (HUMAN-GATED): Build and bring up ISE**

The operator runs preflight, `20-up.sh`, then `25-ise-up.sh`, and imports `labs/trustsec-phase1.yaml`. These are apply steps, so the human runs them.

- [ ] **Step 2: Verify the routed path**

From the C8000v edge console via cml-mcp: `ping 10.20.2.20` reaches ISE, and `test aaa group radius <user> <pass> new-code` returns an Access-Accept.

- [ ] **Step 3: Verify per-device identity and CoA**

In ISE, Operations, RADIUS live logs show the auth sourced from `10.100.0.2`, not a single NATed address. Push a CoA from ISE and confirm the edge receives it.

- [ ] **Step 4: Prove the persistent root was untouched**

```bash
terraform -chdir=terraform/persistent plan
```
Expected: no changes.

- [ ] **Step 5: Record and commit**

Write the result to `docs/STATUS.md` (a dated entry: the routed path proven or the fallback overlay needed) and commit.

---

## Self-review

- **Spec coverage:** host bridge (Task 2), CML connector and C8000v edge (Task 6), disposable ISE root (Task 3), ISE up/down and readiness (Task 4), minimal policy as code (Task 5), Marketplace confirmation and terms (Task 1), verification including CoA and per-device identity and the persistent-plan check (Task 7). All spec sections map to a task.
- **Placeholders:** the ISE Marketplace coordinates and the full ISE VM resource body are the one genuine unknown; Task 1 resolves them and Task 3 consumes them as named variables, so no task hides a placeholder behind vague words. Terraform resource bodies in Task 3 are written against Task 1's confirmed values at implementation time, which is the correct order, not a deferral of substance.
- **Type consistency:** `ise_config.ensure_network_device` and the `ise_image_*` / `ise_vm_size` / `ise_private_ip` names are used consistently across Tasks 1, 3, 4, and 5.

## Execution note

This plan is human-gated infrastructure, not autonomous execution. The fork edit (Task 2), the Marketplace terms (Task 1), and every `terraform apply` (Tasks 4, 7) are stop-and-ask by CLAUDE.md, and ISE costs real money and takes 30 to 45 minutes to boot. The buildable scaffolding (preflight, the Terraform root, the scripts, the policy client, the topology) is test-driven in the kit's patterns and can be built and committed ahead of any apply.
