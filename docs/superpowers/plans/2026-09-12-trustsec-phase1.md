# TrustSec Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up an external, disposable ISE on the Azure apps subnet that CML switches reach for RADIUS with per-device identity and a working Change of Authorization return path, proving the ADR 0003 routed path.

**Architecture:** The persistent root already provides the Azure half of the routed path (UDR, IP forwarding, NSG) and owns the apps subnet. This plan adds a no-NAT host transit bridge, a C8000v lab edge, ISE deployed by the Azure CLI (not Terraform, at the operator's request after a bad ISE-on-Terraform experience), bring-up and teardown scripts, and a minimal ISE policy applied as code. The full TrustSec fabric and SGT policy are Phase 2.

**Tech Stack:** Azure CLI (`az`) for the ISE VM, NIC, and NSG; Bash (3.2-compatible on the Mac); Python (stdlib only, unittest); the cloud-cml fork under `vendor/`; ISE REST (ERS/OpenAPI).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-09-12-trustsec-phase1-routed-ise-design.md`. ADR 0003 (routed path), ADR 0004 (secrets).
- ISE is the one instance built outside Terraform, by `az` CLI. Its NIC and NSG are `az`-managed too. The persistent apps subnet, route table, and IP forwarding stay Terraform. No `terraform/ise` root.
- No secret in a tracked file. The ISE admin password lives in a gitignored env file and reaches ISE through `--custom-data` (user-data), never on the `az` command line, never in a commit or chat.
- Never `0.0.0.0/0` in an NSG rule. ISE NSG rules are scoped to the operator addresses and the lab summary.
- Bash: `set -euo pipefail`, quote every variable, functions under 40 lines, `main "$@"` at the bottom, `[OK]`/`[WARN]`/`[FAIL]` output.
- Python: stdlib only, type hints on every signature, `unittest`.
- No em-dashes in prose. Comments explain why and cite the ADR.
- `tests/run.sh` and `pre-commit run --all-files` pass before any commit.
- Stop-and-ask gates: anything under `vendor/`, any real `az vm create`/`az group` write against the subscription, installing a tool. Marked HUMAN-GATED below.
- Transit addressing (ADR 0003): host bridge `br-transit` at `10.100.0.1/24`; C8000v lab edge at `10.100.0.2` routing `10.100.0.0/16`; ISE on the apps subnet at `10.20.2.20`.

## Gates and parallelism

The code is highly parallel; the deploy is strictly sequential and human-gated. Two lanes.

**Build lane (parallel, no subscription writes, subagent-friendly).** These carry their own tests against fakes, stubs, and placeholders, and have no ordering between them except where noted:

- Task 1 code: the preflight check and `config/ise.tfvars.example` (read-only `az` research aside).
- Task 2 code: the transit-bridge script file and the smoke assertions (writing the file only; wiring it into the fork is a gate).
- Task 3 code: the `az`-CLI bring-up and teardown scripts with dry-run tests against an `az` stub. Consumes Task 1's confirmed image values, so it lands after Task 1's research but is otherwise independent.
- Task 4: the ISE policy client and its fake-ISE test. Fully independent.
- Task 5: the proof topology, tested by the existing `labs/*.yaml` render walk. Fully independent.

Tasks 1, 4, and 5 can run at the same time. Task 2's file can run alongside them. Task 3 follows Task 1's research.

**Deploy lane (sequential, human-gated, one after another):**

1. Accept the Marketplace terms (Task 1, once per subscription).
2. Wire the transit-bridge script into the fork and bump the submodule (Task 2).
3. Rebuild CML so the new fork runs (`20-up.sh`).
4. `az vm create` the ISE VM, then wait ~30 to 45 minutes for it to be ready (Task 3).
5. Apply the minimal ISE policy (Task 4 runs automatically once ISE answers).
6. Import the proof topology and run verification (Tasks 5, 6).

Nothing in the deploy lane can be parallelized: each step depends on the previous one existing.

---

### Task 1: Confirm the ISE Azure Marketplace offer and preflight it

**Files:**
- Modify: `scripts/00-preflight.sh` (ISE terms and size check)
- Modify: `tests/test_preflight.sh`
- Create: `config/ise.tfvars.example` (records confirmed image coordinates; despite the name it is read by the `az` scripts, kept in the tfvars naming for consistency)

**Interfaces:**
- Produces: `ise_image_publisher`, `ise_image_offer`, `ise_image_sku` (the plan/SKU), `ise_image_version`, `ise_vm_size`, `ise_private_ip`, consumed by Task 3.

- [ ] **Step 1: Research the offer (read-only)**

```bash
az vm image list --all --publisher cisco --query "[?contains(offer,'ise') || contains(offer,'identity')].{offer:offer,sku:sku,version:version}" -o table
```

Record the newest ISE offer, its plan/SKU, and the smallest supported size (per Cisco's "Deploy ISE on Azure" guidance) that fits the subscription quota.

- [ ] **Step 2: Write `config/ise.tfvars.example`**

```hcl
# Copy to config/ise.tfvars (gitignored). Confirmed against the Azure
# Marketplace on 2026-09-12 (TrustSec Phase 1, Task 1). Read by the az
# CLI bring-up script, not Terraform.
ise_image_publisher = "cisco"
ise_image_offer     = "<offer>"
ise_image_sku       = "<sku/plan>"
ise_image_version   = "latest"
ise_vm_size         = "<smallest supported size that fits quota>"
ise_private_ip      = "10.20.2.20"
```

- [ ] **Step 3: Add the preflight check**

In `scripts/00-preflight.sh`, add a `check_ise_marketplace` function that reads `config/ise.tfvars`, `[WARN]`s if it is absent, and otherwise `az vm image terms show` to confirm the terms are accepted (`[OK]`) or `[FAIL]` with the exact `az vm image terms accept` command to run. Call it in the main sequence.

- [ ] **Step 4: Assert it in `tests/test_preflight.sh`**

With the `az` stub returning `true` for `terms show`, assert a filled `ise.tfvars` gives `[OK]` and an absent one gives `[WARN]` without failing preflight. Follow `tests/stubs/az`.

- [ ] **Step 5: Gate and commit**

```bash
tests/run.sh && pre-commit run --files scripts/00-preflight.sh tests/test_preflight.sh config/ise.tfvars.example
git add scripts/00-preflight.sh tests/test_preflight.sh config/ise.tfvars.example
git commit -m "feat: confirm and preflight the ISE Azure Marketplace offer"
```

- [ ] **Step 6 (HUMAN-GATED): Accept the Marketplace terms**

The operator runs the printed `az vm image terms accept` line. Terms acceptance is a subscription change.

---

### Task 2: The host transit bridge customize script (fork)

**Files:**
- Create: `vendor/cloud-cml/modules/deploy/data/06-transit-bridge.sh`
- Modify: the fork's customize sequence to run it (exact file found at implementation)
- Modify: `scripts/90-smoke-test.sh`, `tests/test_smoke.sh`

**Interfaces:**
- Produces: `br-transit` at `10.100.0.1/24`, `net.ipv4.ip_forward=1`, no masquerade for `10.100.0.0/16`. Consumed by Task 5 (connector) and Task 6 (verification).

- [ ] **Step 1: Write the customize script** (same content as the spec; creates the bridge, sets `ip_forward`, warns if a masquerade rule covers the transit range).

- [ ] **Step 2 (HUMAN-GATED): Wire into the fork, commit on `azure-lab`, bump the submodule.** Editing `vendor/` is a stop-and-ask. Cite ADR 0003 in the fork commit.

- [ ] **Step 3: Add smoke assertions** in `scripts/90-smoke-test.sh` over SSH: `br-transit` present at `10.100.0.1`, and `ip_forward` is `1`.

- [ ] **Step 4: Extend `tests/test_smoke.sh`** to assert the two new lines are present and the no-controller path still exits cleanly.

- [ ] **Step 5: Gate and commit the repo-side changes**

```bash
tests/run.sh && pre-commit run --files scripts/90-smoke-test.sh tests/test_smoke.sh
git add scripts/90-smoke-test.sh tests/test_smoke.sh
git commit -m "test: smoke-check the transit bridge and ip_forward"
```

---

### Task 3: ISE bring-up and teardown by Azure CLI

**Files:**
- Create: `scripts/25-ise-up.sh`, `scripts/45-ise-down.sh`
- Create: `scripts/lib/ise-userdata.sh` (renders the ISE user-data from env, mode 600, to the scratchpad)
- Create: `tests/test_ise_dry_run.sh`
- Create: `config/mcp-env/ise.env.example` documentation note in `config/ise.tfvars.example` (the gitignored `ise.env` holds `ISE_ADMIN_PASSWORD`, `ISE_HOSTNAME`, `RADIUS_SECRET`)

**Interfaces:**
- Consumes: `config/ise.tfvars` (Task 1), the persistent `apps_subnet_id` output, `config/mcp-env/ise.env`.
- Produces: an ISE VM at `ise_private_ip`, an ISE NSG, and a NIC, all tagged `project=cml-azure-lab role=ise`, discoverable by tag for teardown.

- [ ] **Step 1: Write `scripts/lib/ise-userdata.sh`**

Renders the ISE Azure user-data (hostname, IP/mask/gw, DNS, NTP, timezone, ERS and OpenAPI enabled, admin password) from `config/mcp-env/ise.env` to a `0600` file under the scratchpad. The admin password never appears on a command line; `az` reads the file with `--custom-data`.

- [ ] **Step 2: Write `scripts/25-ise-up.sh`**

`set -euo pipefail`, source `scripts/lib/common.sh`. Read `config/ise.tfvars` and `ise.env`. Resolve `apps_subnet_id` from the persistent output. Create the ISE NSG (RADIUS 1812/1813 UDP, CoA 1700 UDP, admin 443 TCP, SSH 22 TCP, scoped to the lab summary and the operator addresses, never `0.0.0.0/0`). `az vm create` with the Marketplace image, `--plan`, `--size`, the static private IP on the apps subnet, `--custom-data` the user-data file, and the tags. Then poll `https://<ise_private_ip>/admin/API/mnt/Version` through the CML host jump until it answers, backgrounded with elapsed-time progress (30 to 45 minutes). Prompt before the create unless `ASSUME_YES=1`.

- [ ] **Step 3: Write `scripts/45-ise-down.sh`**

Find ISE resources by the `role=ise` tag and delete the VM, NIC, NSG, OS disk, and public IP if any. Prompt unless `ASSUME_YES=1`. Never touches bootstrap, persistent, or the CML VM.

- [ ] **Step 4: Write `tests/test_ise_dry_run.sh`**

With the `az` stub on PATH, assert `25-ise-up.sh --dry-run` prints the planned `az vm create` (image, plan, size, subnet, tags) and the readiness wait, and that the admin password does not appear in the dry-run output. Assert `45-ise-down.sh --dry-run` plans the tagged deletes. Follow `tests/test_up_dry_run.sh` and extend `tests/stubs/az`.

- [ ] **Step 5: Run it**

```bash
bash tests/test_ise_dry_run.sh
```
Expected: `test_ise_dry_run: all passed`.

- [ ] **Step 6: Gate and commit**

```bash
tests/run.sh && pre-commit run --all-files
git add scripts/25-ise-up.sh scripts/45-ise-down.sh scripts/lib/ise-userdata.sh tests/test_ise_dry_run.sh config/ise.tfvars.example
git commit -m "feat: ISE bring-up and teardown by az CLI with a readiness wait"
```

- [ ] **Step 7 (HUMAN-GATED): the real deploy** happens in Task 6, not here.

---

### Task 4: Minimal ISE policy as code

**Files:**
- Create: `scripts/lib/ise_config.py`, `tests/test_ise_config.py`, `tests/fake_ise_api.py`
- Modify: `scripts/25-ise-up.sh` (call the config step after ISE is ready)

**Interfaces:**
- Consumes: `ise_private_ip`, `ISE_ADMIN_PASSWORD`, `RADIUS_SECRET` from the environment.
- Produces: one network device (the C8000v edge as a NAD) and one authorization rule, enough to prove RADIUS and CoA.

- [ ] **Step 1: Failing test against a fake ISE** in `tests/test_ise_config.py` with `tests/fake_ise_api.py` (ERS-shaped, like `fake_cml_api.py`); assert `ise_config.ensure_network_device(...)` is create-if-missing and returns an id.

- [ ] **Step 2: Run it, expect failure.**
```bash
python3 -m unittest tests/test_ise_config.py
```

- [ ] **Step 3: Write `ise_config.py`** (stdlib `urllib`/`ssl` verify-off, Basic auth, ERS network-device endpoints, type hints, create-if-missing like `users.py`).

- [ ] **Step 4: Run it, expect pass.**

- [ ] **Step 5: Wire into `25-ise-up.sh` and commit**
```bash
tests/run.sh && pre-commit run --all-files
git add scripts/lib/ise_config.py tests/test_ise_config.py tests/fake_ise_api.py scripts/25-ise-up.sh
git commit -m "feat: minimal ISE policy as code, one NAD and one rule"
```

---

### Task 5: The proof topology, C8000v edge as NAD

**Files:**
- Create: `labs/trustsec-phase1.yaml`
- Modify: `labs/README.md`

**Interfaces:**
- Consumes: the `br-transit` connector (Task 2), `ISE_IP` and `RADIUS_SECRET` placeholders (ADR 0006).
- Produces: a running `cat8000v` at `10.100.0.2` as a RADIUS client with CoA, on the transit bridge. Phase 1 needs no Catalyst 9000v; the edge alone proves the routed path, RADIUS, and CoA.

- [ ] **Step 1: Write `labs/trustsec-phase1.yaml`** with an external connector mapped to `br-transit`, a `cat8000v` edge at `10.100.0.2/24` (default route to `10.100.0.1`), `aaa` pointing at `__ISE_IP__` with `__RADIUS_SECRET__`, and `aaa server radius dynamic-author` for CoA. All secrets and the ISE IP are placeholders.

- [ ] **Step 2: Confirm it renders**
```bash
LAB_PASSWORD=x ISE_IP=10.20.2.20 RADIUS_SECRET=y python3 scripts/lib/render_lab.py labs/trustsec-phase1.yaml --pubkey keys/cml-lab.pub >/dev/null && echo ok
```
`tests/test_render_lab.py` already walks every `labs/*.yaml`, so it covers this file. Add `ISE_IP` and `RADIUS_SECRET` to `config/labs.env.example`.

- [ ] **Step 3: Gate and commit**
```bash
tests/run.sh && pre-commit run --files labs/trustsec-phase1.yaml labs/README.md config/labs.env.example
git add labs/trustsec-phase1.yaml labs/README.md config/labs.env.example
git commit -m "feat: TrustSec Phase 1 proof topology, C8000v edge as NAD"
```

---

### Task 6: End-to-end verification (HUMAN-GATED)

**Files:**
- Modify: `docs/STATUS.md`

- [ ] **Step 1 (HUMAN-GATED):** operator runs preflight, `20-up.sh` (new fork), `25-ise-up.sh`, and imports `labs/trustsec-phase1.yaml`.
- [ ] **Step 2:** from the edge via cml-mcp, `ping 10.20.2.20` reaches ISE and `test aaa group radius <user> <pass> new-code` returns Access-Accept.
- [ ] **Step 3:** ISE RADIUS live logs show the auth from `10.100.0.2` (per-device identity, not a NATed address), and a CoA from ISE reaches the edge.
- [ ] **Step 4:** `terraform -chdir=terraform/persistent plan` shows no changes.
- [ ] **Step 5:** record the result in `docs/STATUS.md` and commit.

---

## Self-review

- **Spec coverage:** host bridge (Task 2), CML connector and C8000v edge (Task 5), ISE deploy (Task 3, now az CLI per the operator), ISE up/down and readiness (Task 3), minimal policy as code (Task 4), Marketplace confirmation and terms (Task 1), verification with CoA, per-device identity, and the persistent-plan check (Task 6). The one spec deviation, ISE by `az` instead of Terraform, is recorded in the constraints and architecture.
- **Placeholders:** the Marketplace coordinates are the one unknown; Task 1 resolves them and Tasks 3 consumes them by name. No task hides a placeholder behind vague words.
- **Type consistency:** `ise_config.ensure_network_device`, the `ise_image_*`/`ise_vm_size`/`ise_private_ip` keys, and the `br-transit`/`10.100.0.x` addresses are used consistently across tasks.

## Execution note

The build lane (Tasks 1, 2-file, 3, 4, 5) is buildable and committable now with no subscription writes, and is where subagents work in parallel. The deploy lane is sequential and human-gated: Marketplace terms, the fork wiring and submodule bump, the CML rebuild, the real `az vm create` for ISE and its 30-to-45-minute boot, then policy, import, and verify.
