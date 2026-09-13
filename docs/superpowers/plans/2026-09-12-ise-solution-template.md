# ISE Deploy by the Azure Solution Template Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the raw VM-image ISE deploy with Cisco's Azure Marketplace solution template, run by `az deployment group create`, disposable and torn down by tag.

**Architecture:** A tracked, customized copy of Cisco's ARM template (`config/ise/template.json`) is deployed into `rg-cml-lab` on the existing `snet-apps` subnet. `scripts/25-ise-up.sh` renders a `0600` parameters file from `config/mcp-env/ise.env`, ensures a scoped NSG, deploys, waits through the CML host jump, and applies policy. `scripts/45-ise-down.sh` deletes every `role=ise` resource. The hand-rolled user-data renderer is removed.

**Tech Stack:** Bash (bash 3.2, `set -euo pipefail`), Python 3 stdlib (`json`, `urllib`, `ssl`, `unittest`), Azure CLI, ARM JSON. Fake API servers for tests. The `az`/`terraform` stubs under `tests/stubs/`.

## Global Constraints

- Bash: `set -euo pipefail`, bash 3.2 compatible (macOS), quote every variable, no unguarded `rm`, functions under 40 lines, `main "$@"` at the bottom, `[OK]`/`[WARN]`/`[FAIL]` output.
- Python: stdlib only, type hints on every signature, `unittest`.
- Secrets (`ISE_ADMIN_PASSWORD`, `RADIUS_SECRET`, the `systemPassword`) never appear on a command line, in a tracked file, or in dry-run output. They live in the gitignored `config/mcp-env/ise.env` and are written only into a `0600` parameters file. Load `senior-secops` and name it for every task that touches these.
- Never `0.0.0.0/0` in any allowed list. Never hardcode subscription or tenant IDs.
- Comments explain why and cite the ADR. Plain prose, no em-dashes.
- Deploy identifiers, verbatim: image `cisco:cisco-ise-virtual:cisco-ise_3_5:3.5.527`; plan name `cisco-ise_3_5`, publisher `cisco`, product `cisco-ise-virtual`. Static private IP `10.20.2.20`. VM size `Standard_D8s_v4`. Region `eastus2`. Resource group `rg-cml-lab`, VNet `vnet-cml-lab`, subnet `snet-apps`. Lab summary `10.100.0.0/16`. CML host `10.20.1.10`.
- Tag every ISE resource `project=cml-azure-lab` and `role=ise` so teardown is by tag.
- The captured Cisco template is in `software/ise-solution-template/template.json` (gitignored). Copy from it; do not re-download.
- No real Azure or ISE calls in the build lane. Only stubbed dry-runs and fake-server unit tests. The real deploy is the human-gated Task 7.

---

## File Structure

- `config/ise/template.json` (new, tracked): the customized ARM template.
- `config/ise.env.example` (rewritten): the solution-template deploy keys.
- `scripts/lib/ise_params.py` (new): renders the `0600` deployment parameters.
- `scripts/25-ise-up.sh` (rewritten): `az deployment group create` flow.
- `scripts/45-ise-down.sh` (modified): tag teardown for the template's resources.
- `scripts/lib/ise_config.py` (modified): NAD on ERS, authorization rule on the OpenAPI.
- `scripts/lib/ise-userdata.sh` (deleted).
- `tests/test_ise_template.py` (new), `tests/test_ise_params.py` (new).
- `tests/test_ise_dry_run.sh` (rewritten), `tests/fake_ise_api.py` (modified), `tests/test_ise_config.py` (modified), `tests/stubs/az` (extended).
- `docs/decisions/0008-ise-by-azure-solution-template.md` (new).
- `docs/ROADMAP.md` (modified): the Bastion note.

---

### Task 1: The customized template and ADR 0008

**Files:**
- Create: `config/ise/template.json`, `docs/decisions/0008-ise-by-azure-solution-template.md`, `tests/test_ise_template.py`
- Reference: `software/ise-solution-template/template.json` (gitignored source)

**Interfaces:**
- Produces: a tracked ARM template with `project=cml-azure-lab role=ise` tags on the `publicIPAddresses`, `networkInterfaces`, and `virtualMachines` resources. Plan `cisco-ise_3_5`, image version `3.5.527`. Consumed by Task 3.

- [ ] **Step 1: Copy the captured template.** `cp software/ise-solution-template/template.json config/ise/template.json`.

- [ ] **Step 2: Add tags to the three resources.** In `config/ise/template.json`, add a `tags` object `{ "project": "cml-azure-lab", "role": "ise" }` to the `Microsoft.Network/publicIPAddresses` and `Microsoft.Network/networkInterfaces` resources, and change the VM's existing `"tags": { "Tag1": "ManagedVM" }` to `{ "project": "cml-azure-lab", "role": "ise" }`. Leave every parameter, variable, and the `plan`/`imageReference` blocks unchanged.

- [ ] **Step 3: Write the failing test** `tests/test_ise_template.py`:

```python
import json
import unittest
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent.parent / "config" / "ise" / "template.json"


class TestIseTemplate(unittest.TestCase):
    def setUp(self) -> None:
        self.doc = json.loads(TEMPLATE.read_text())

    def _resource(self, type_name: str) -> dict:
        for res in self.doc["resources"]:
            if res.get("type") == type_name:
                return res
        self.fail(f"no resource of type {type_name}")

    def test_vm_image_and_plan(self) -> None:
        vm = self._resource("Microsoft.Compute/virtualMachines")
        img = vm["properties"]["storageProfile"]["imageReference"]
        self.assertEqual(img["sku"], "cisco-ise_3_5")
        self.assertEqual(img["version"], "3.5.527")
        self.assertEqual(vm["plan"]["name"], "cisco-ise_3_5")

    def test_role_tags_on_disposable_resources(self) -> None:
        for type_name in (
            "Microsoft.Compute/virtualMachines",
            "Microsoft.Network/networkInterfaces",
            "Microsoft.Network/publicIPAddresses",
        ):
            tags = self._resource(type_name).get("tags", {})
            self.assertEqual(tags.get("role"), "ise", type_name)
            self.assertEqual(tags.get("project"), "cml-azure-lab", type_name)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 4: Run it, expect pass** (Steps 1-2 already made it pass): `python3 -m unittest tests/test_ise_template.py -v`.

- [ ] **Step 5: Write ADR 0008** `docs/decisions/0008-ise-by-azure-solution-template.md`: decision to deploy ISE from Cisco's Azure solution template rather than the raw VM image; the VM-image path failed to boot because the hand-rolled user-data used `ntpserver` (should be `primaryntpserver`) and injected `ipv4address`/`ipv4netmask`/`ipv4gateway` keys that are not in Cisco's Azure set. Consequence: ISE gets a Standard public IP for outbound to Security Cloud Control and Entra, consciously overriding the ADR 0003 consequence that ISE has no public IP; the override is outbound only, inbound stays closed by default plus a scoped NSG, and administration is via the CML host jump so a changing operator IP never matters. Plain prose, no em-dashes.

- [ ] **Step 6: Gate and commit**

```bash
tests/run.sh && pre-commit run --files config/ise/template.json tests/test_ise_template.py docs/decisions/0008-ise-by-azure-solution-template.md
git add config/ise/template.json tests/test_ise_template.py docs/decisions/0008-ise-by-azure-solution-template.md
git commit -m "feat: customized ISE ARM template and ADR 0008"
```

---

### Task 2: The env example and the parameters renderer

**Files:**
- Rewrite: `config/ise.env.example`
- Create: `scripts/lib/ise_params.py`, `tests/test_ise_params.py`

**Interfaces:**
- Produces: `ise_params.render_parameters(env: dict[str, str], pubkey: str, nsg_name: str) -> dict` returning the Azure deployment parameters object, and a CLI `python3 scripts/lib/ise_params.py <out_file> --nsg <name>` that reads `os.environ` and `keys/cml-lab.pub`, writes the parameters JSON at mode `0600`, and prints nothing secret. Consumed by Task 3.

- [ ] **Step 1: Rewrite `config/ise.env.example`** with these keys and explanatory comments (no secrets, secrets shown only as commented placeholders):

```
# Copy to config/mcp-env/ise.env (gitignored) and fill in. Read by
# scripts/00-preflight.sh, scripts/25-ise-up.sh, and scripts/lib/ise_params.py.
# ISE deploys from Cisco's Azure solution template. ADR 0003, ADR 0008.

# Confirmed against the Azure Marketplace on 2026-09-12. Terms already accepted.
ISE_IMAGE_PUBLISHER=cisco
ISE_IMAGE_OFFER=cisco-ise-virtual
ISE_IMAGE_SKU=cisco-ise_3_5
ISE_IMAGE_VERSION=3.5.527
ISE_PLAN_NAME=cisco-ise_3_5

ISE_HOSTNAME=ise1
ISE_VM_SIZE=Standard_D8s_v4
ISE_STORAGE_TYPE=Premium_LRS
ISE_VOLUME_SIZE=600
ISE_PRIVATE_IP=10.20.2.20
ISE_PUBLIC_IP_NAME=ise1-ip

# First-boot config. These map to the ISE Azure user-data keys.
ISE_DNS_DOMAIN=rooez.com
ISE_PRIMARY_NAMESERVER=8.8.8.8
ISE_PRIMARY_NTP=time.google.com
ISE_TIMEZONE=Etc/UTC
ISE_ERS=yes
ISE_PXGRID=yes

# The only source allowed to reach the ISE admin ports (443, 22): the CML
# host, since all operator access is through the CML jump (ADR 0003, 0008).
ISE_ADMIN_SOURCE_CIDR=10.20.1.10/32

# --- Secrets below: set only in config/mcp-env/ise.env, never here. ADR 0004.
# The iseadmin GUI/CLI password. ISE policy: 6-25 chars, upper+lower+number,
# no "iseadmin"/"cisco", specials only from @~*!,+=_-.
# ISE_ADMIN_PASSWORD=CHANGE-ME-not-a-real-password
# RADIUS shared secret with the C8000v edge NAD.
# RADIUS_SECRET=CHANGE-ME-not-a-real-secret
```

- [ ] **Step 2: Write the failing test** `tests/test_ise_params.py`:

```python
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parent.parent / "scripts" / "lib"
sys.path.insert(0, str(LIB))
import ise_params  # noqa: E402

ENV = {
    "ISE_HOSTNAME": "ise1",
    "ISE_VM_SIZE": "Standard_D8s_v4",
    "ISE_STORAGE_TYPE": "Premium_LRS",
    "ISE_VOLUME_SIZE": "600",
    "ISE_PRIVATE_IP": "10.20.2.20",
    "ISE_PUBLIC_IP_NAME": "ise1-ip",
    "ISE_DNS_DOMAIN": "rooez.com",
    "ISE_PRIMARY_NAMESERVER": "8.8.8.8",
    "ISE_PRIMARY_NTP": "time.google.com",
    "ISE_TIMEZONE": "Etc/UTC",
    "ISE_ERS": "yes",
    "ISE_PXGRID": "yes",
    "ISE_ADMIN_PASSWORD": "Sup3rSecret-Test",
}
PUBKEY = "ssh-rsa AAAATESTKEY test@lab"


class TestIseParams(unittest.TestCase):
    def test_render_maps_values_and_static_ip(self) -> None:
        params = ise_params.render_parameters(ENV, PUBKEY, "ise-nsg")["parameters"]
        self.assertEqual(params["hostName"]["value"], "ise1")
        self.assertEqual(params["managementPrivateIP"]["value"], "10.20.2.20")
        self.assertEqual(params["managementNSG"]["value"], "ise-nsg")
        self.assertEqual(params["SSHKeyPairName"]["value"], PUBKEY)
        self.assertEqual(params["instanceType"]["value"], "Standard_D8s_v4")
        self.assertEqual(params["publicIpNewOrExisting"]["value"], "new")
        self.assertEqual(params["publicIpSku"]["value"], "Standard")
        self.assertEqual(params["publicIpAllocationMethod"]["value"], "Static")
        self.assertEqual(params["primaryNTPServer"]["value"], "time.google.com")
        self.assertEqual(params["systemPassword"]["value"], "Sup3rSecret-Test")

    def test_missing_password_raises(self) -> None:
        env = dict(ENV)
        del env["ISE_ADMIN_PASSWORD"]
        with self.assertRaises(KeyError):
            ise_params.render_parameters(env, PUBKEY, "ise-nsg")

    def test_cli_writes_0600_and_no_secret_on_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "params.json"
            pub = Path(d) / "k.pub"
            pub.write_text(PUBKEY)
            env = dict(os.environ)
            env.update(ENV)
            env["ISE_PUBKEY_FILE"] = str(pub)
            proc = subprocess.run(
                [sys.executable, str(LIB / "ise_params.py"), str(out), "--nsg", "ise-nsg"],
                env=env, capture_output=True, text=True, check=True,
            )
            self.assertNotIn("Sup3rSecret-Test", proc.stdout)
            self.assertNotIn("Sup3rSecret-Test", proc.stderr)
            mode = stat.S_IMODE(out.stat().st_mode)
            self.assertEqual(mode, 0o600)
            doc = json.loads(out.read_text())
            self.assertEqual(doc["parameters"]["systemPassword"]["value"], "Sup3rSecret-Test")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run it, expect failure** (module missing): `python3 -m unittest tests/test_ise_params.py`.

- [ ] **Step 4: Write `scripts/lib/ise_params.py`.** Stdlib only, type hints. `render_parameters(env, pubkey, nsg_name)` builds the full parameters object matching `config/ise/template.json`'s parameter names: `hostName`, `SSHKeyPairName` (=pubkey), `managementNetwork` (`vnet-cml-lab`), `managementSubnet` (`snet-apps`), `managementNSG` (=nsg_name), `managementPrivateIP` (=`ISE_PRIVATE_IP`), `publicIpName` (=`ISE_PUBLIC_IP_NAME`), `publicIpNewOrExisting`=`new`, `publicIpResourceGroupName`=`rg-cml-lab`, `publicIpAllocationMethod`=`Static`, `publicIpSku`=`Standard`, `timeZone`, `instanceType` (=`ISE_VM_SIZE`), `storageType`, `volumeSize` (int), `DNSDomain`, `primaryNameServer`, `primaryNTPServer`, `ERS`, `PXGrid`, `systemPassword` (=`ISE_ADMIN_PASSWORD`, raise `KeyError` if unset). Wrap each as `{"value": ...}`. The CLI: `main(argv)` reads the out path and `--nsg`, reads the pubkey from `ISE_PUBKEY_FILE` (default `keys/cml-lab.pub`), writes JSON with `os.umask(0o077)` before create then `os.chmod(path, 0o600)`, prints only a non-secret confirmation. Secrets come from `os.environ`, never argv.

- [ ] **Step 5: Run it, expect pass.** `python3 -m unittest tests/test_ise_params.py -v`.

- [ ] **Step 6: Gate and commit**

```bash
tests/run.sh && pre-commit run --all-files
git add config/ise.env.example scripts/lib/ise_params.py tests/test_ise_params.py
git commit -m "feat: ISE deploy parameters renderer and env example"
```

---

### Task 3: Rewrite the up script for the solution-template deploy

**Files:**
- Rewrite: `scripts/25-ise-up.sh`
- Rewrite: `tests/test_ise_dry_run.sh`
- Modify: `tests/stubs/az`

**Interfaces:**
- Consumes: `config/mcp-env/ise.env`, `config/ise/template.json`, `scripts/lib/ise_params.py`, the persistent outputs `resource_group_name`, `location`, `lab_summary_cidr`, `public_ip_address`. Uses `scripts/lib/ise_config.py` for the policy step (Task 5) and `scripts/lib/common.sh` helpers (`run`, `confirm`, `require_cmd`, `require_env`, `tf_out`, `die`, `pass`, `CML_SSH_OPTS`).
- Produces: an ISE deployment tagged `role=ise` and a scoped `ise-nsg`.

- [ ] **Step 1: Write the new `scripts/25-ise-up.sh`.** Keep the Phase 1 helpers and structure (source `common.sh`, `run()` wrapper for dry-run, `out_or_placeholder`, `load_ise_env`, the CML-jump `open_ise_forward`/`close_ise_forward` and `wait_for_ise_ready` and `apply_ise_policy` from the prior version). Replace `create_vm`/`create_nsg`/`render_userdata`/`tag_nic` with:
  - `ensure_nsg`: `az network nsg create -g <rg> -n ise-nsg -l <loc> --tags project=cml-azure-lab role=ise`; then rules `allow-radius` (Udp, ports `1812 1813`, source `${LAB_SUMMARY_CIDR}`) and `allow-admin` (Tcp, ports `443 22`, source `${ISE_ADMIN_SOURCE_CIDR}`). No `0.0.0.0/0`.
  - `render_params`: `run python3 "${REPO_ROOT}/scripts/lib/ise_params.py" "${PARAMS_FILE}" --nsg ise-nsg` with `ISE_ADMIN_PASSWORD` and the rest already exported by `load_ise_env`. `PARAMS_FILE` is a `0600` path under the scratchpad (use `mktemp`).
  - `deploy`: `run az deployment group create -g "${RESOURCE_GROUP}" -n ise-$(date +%s) --template-file "${REPO_ROOT}/config/ise/template.json" --parameters "@${PARAMS_FILE}"`.
  - `tag_osdisk`: after deploy, `run az disk update -g "${RESOURCE_GROUP}" -n "${ISE_HOSTNAME}osdisk" --set tags.project=cml-azure-lab tags.role=ise` so the disk is disposable by tag too.
  - `main` order: `require_env ARM_SUBSCRIPTION_ID`; `require_cmd az terraform jq python3 ssh`; `load_ise_env`; resolve `RESOURCE_GROUP`/`LOCATION`/`LAB_SUMMARY_CIDR`/`CML_PUBLIC_IP` from persistent outputs; `confirm "Deploy ISE ${ISE_IMAGE_SKU} (${ISE_VM_SIZE}) into ${RESOURCE_GROUP} at ${ISE_PRIVATE_IP}?" || die "declined"`; `ensure_nsg`; `render_params`; `deploy`; `tag_osdisk`; `wait_for_ise_ready`; `apply_ise_policy`. Add `ISE_ADMIN_SOURCE_CIDR` to `load_ise_env`'s required checks. Prompt gated by `ASSUME_YES=1` via `confirm`. Delete the params file on exit with a `trap` (it holds the password).

- [ ] **Step 2: Extend `tests/stubs/az`** to answer `az network nsg create`, `az network nsg rule create`, `az deployment group create`, and `az disk update` (print the invocation, exit 0), following the existing stub style.

- [ ] **Step 3: Rewrite `tests/test_ise_dry_run.sh`** with the `az` stub on PATH, fixture `ise.env` (including `ISE_ADMIN_PASSWORD=Sup3rSecretTestOnly-DoNotLeak` and `ISE_ADMIN_SOURCE_CIDR=10.20.1.10/32`), `ASSUME_YES=1`, `ISE_ENV_FILE` override, and a fake `keys/cml-lab.pub`. Assert the up dry-run:
  - plans `az network nsg create ... -n ise-nsg`, the `allow-radius` rule with `1812 1813` from `10.100.0.0/16`, the `allow-admin` rule with `443 22` from `10.20.1.10/32`;
  - asserts `assert_not_contains "no 0.0.0.0/0" "0.0.0.0/0" "${up_out}"`;
  - plans `az deployment group create ... --template-file` `.../config/ise/template.json` `--parameters @`;
  - plans `az disk update ... -n ise1osdisk ... role=ise`;
  - the readiness wait and the policy step are planned;
  - `assert_not_contains "password never printed" "Sup3rSecretTestOnly-DoNotLeak" "${up_out}"`.

- [ ] **Step 4: Run it.** `bash tests/test_ise_dry_run.sh` prints `test_ise_dry_run: all passed`.

- [ ] **Step 5: Gate and commit**

```bash
tests/run.sh && pre-commit run --all-files
git add scripts/25-ise-up.sh tests/test_ise_dry_run.sh tests/stubs/az
git commit -m "feat: deploy ISE by az deployment group create with a scoped NSG"
```

---

### Task 4: Teardown for the template's resources

**Files:**
- Modify: `scripts/45-ise-down.sh`, `tests/test_ise_dry_run.sh` (the down section)

**Interfaces:**
- Consumes: the `role=ise` tag on the VM, NIC, public IP, NSG (from the template and the up script) and the disk (tagged by `tag_osdisk`).

- [ ] **Step 1: Confirm the delete dispatch covers every type.** `scripts/45-ise-down.sh` already deletes by `role=ise` tag with a `delete_by_type` case for `virtualMachines`, `networkInterfaces`, `networkSecurityGroups`, `disks`, and `publicIPAddresses`. Verify the case list includes all five; the template plus `tag_osdisk` tag all of them, so no name-based fallback is needed. Add `require_cmd az terraform jq` in `main` (it calls `tf_out`).

- [ ] **Step 2: Add a down-section assertion** in `tests/test_ise_dry_run.sh`: with the `az` stub returning a tagged VM, NIC, public IP, NSG, and disk, assert the down dry-run plans a delete for each of the five types and that VM deletion is ordered first (the existing ordering check).

- [ ] **Step 3: Run it.** `bash tests/test_ise_dry_run.sh` passes.

- [ ] **Step 4: Gate and commit**

```bash
tests/run.sh && pre-commit run --files scripts/45-ise-down.sh tests/test_ise_dry_run.sh
git add scripts/45-ise-down.sh tests/test_ise_dry_run.sh
git commit -m "feat: tag teardown covers the ISE template resources and disk"
```

---

### Task 5: Move the authorization rule to the ISE OpenAPI

**Files:**
- Modify: `scripts/lib/ise_config.py`, `tests/fake_ise_api.py`, `tests/test_ise_config.py`

**Interfaces:**
- Produces: `ensure_network_device` stays on the ERS API (`/ers/config/networkdevice`); `ensure_authorization_rule` and the policy-set lookup move to the ISE OpenAPI (`/api/v1/policy/network-access/policy-set` and `.../policy-set/<id>/authorization`), which return plain arrays, not the ERS `SearchResult` wrapper.

- [ ] **Step 1: Update `tests/fake_ise_api.py`** so the network-device endpoints keep the ERS shape, and add OpenAPI endpoints under `/api/v1/policy/network-access/policy-set` (GET returns a plain array of `{"id","name"}`) and `/api/v1/policy/network-access/policy-set/<id>/authorization` (GET returns a plain array, POST creates and returns the new rule with an id). Keep the existing Basic-auth check.

- [ ] **Step 2: Update `tests/test_ise_config.py`** so the authorization-rule tests exercise the OpenAPI endpoints: `ensure_authorization_rule(client, policy_set_name, rule_name, sgt)` is create-if-missing and idempotent (second call returns the same id, no second POST). Network-device tests stay on ERS. Run it, expect failure.

- [ ] **Step 3: Update `scripts/lib/ise_config.py`.** Keep the ERS client for network devices. Add OpenAPI request helpers (same host, path prefix `/api/v1`, JSON not the ERS `SearchResult` shape). Rewrite `find_policy_set_id`, `find_authorization_rule_id`, `create_authorization_rule`, and `ensure_authorization_rule` to use the OpenAPI paths and the plain-array responses. Type hints throughout; comment why the split exists (ERS for network devices, OpenAPI for policy, ADR 0008 and the Phase 1 review). Run the tests, expect pass.

- [ ] **Step 4: Gate and commit**

```bash
tests/run.sh && pre-commit run --all-files
git add scripts/lib/ise_config.py tests/fake_ise_api.py tests/test_ise_config.py
git commit -m "fix: apply the ISE authorization rule through the OpenAPI"
```

---

### Task 6: Remove the user-data renderer and record the roadmap note

**Files:**
- Delete: `scripts/lib/ise-userdata.sh`
- Modify: `docs/ROADMAP.md`
- Verify: no remaining references to `ise-userdata.sh`

- [ ] **Step 1: Delete `scripts/lib/ise-userdata.sh`** and confirm nothing references it: `grep -rn "ise-userdata" scripts tests config` returns nothing (the up script was rewritten in Task 3 to stop sourcing it). If a reference remains, remove it.

- [ ] **Step 2: Add a ROADMAP item** under "Access and trust": an optional Azure Bastion for browser access to lab VMs without the CML jump, noting it is a persistent paid resource needing its own subnet and not required while the CML jump serves as the access path. Plain prose, no em-dashes. Run the humanizer audit on the addition.

- [ ] **Step 3: Gate and commit**

```bash
tests/run.sh && pre-commit run --all-files
git add -A scripts/lib docs/ROADMAP.md
git commit -m "refactor: drop the ISE user-data renderer, note Bastion on the roadmap"
```

---

### Task 7: End-to-end verification (HUMAN-GATED)

**Files:**
- Modify: `docs/STATUS.md`

- [ ] **Step 1 (HUMAN-GATED):** operator runs `scripts/00-preflight.sh`, then `scripts/25-ise-up.sh` (real). ISE deploys from the template and boots.
- [ ] **Step 2:** ISE answers on its admin API through the CML jump within the readiness window (first boot succeeds, which the VM-image path could not).
- [ ] **Step 3:** the policy step registers the edge NAD (ERS) and one authorization rule (OpenAPI) against real ISE 3.5.
- [ ] **Step 4:** from the edge, `ping 10.20.2.20` and a `test aaa` return an Access-Accept, with the ISE live log showing source `10.100.0.2`.
- [ ] **Step 5:** `scripts/45-ise-down.sh` removes every `role=ise` resource, and `terraform -chdir=terraform/persistent plan` shows no changes.
- [ ] **Step 6:** record the result in `docs/STATUS.md` and commit.

---

## Self-Review

- **Spec coverage:** customized template + tags (Task 1), env + params renderer with secrets discipline (Task 2), the `az deployment group create` flow + scoped NSG + reachability via the jump (Task 3), tag teardown incl. the disk (Task 4), the ERS/OpenAPI policy fix (Task 5), removal of the user-data renderer + Bastion roadmap note (Task 6), end-to-end verification (Task 7). ADR 0008 covers the approach change and the public-IP override.
- **Placeholders:** none. The captured template is the concrete source for Task 1; every parameter name is fixed by that file.
- **Type consistency:** `render_parameters(env, pubkey, nsg_name)`, the `ise.env` key names, the `ise-nsg` name, the `role=ise` tag, and the addresses (`10.20.2.20`, `10.20.1.10`, `10.100.0.0/16`) are used identically across tasks.

## Execution note

The build lane is Tasks 1-6, all committable with no subscription writes (stubbed dry-runs and fake-server unit tests). Task 7 is the human-gated real deploy and is the first boot test.
