# pyATS Lab Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pyATS lab-verification layer in an isolated venv, with a per-scenario convention, a stdlib testbed generator, a runner, and verifications for the Cilium EVPN and TrustSec Phase 1 labs.

**Architecture:** A `verify/` tree holds the pyATS venv (pinned requirements), a stdlib testbed generator that pulls a lab's pyATS testbed from CML's REST API, and one directory per scenario with an AEtest testscript and an easypy jobfile. `scripts/80-verify-lab.sh <scenario>` generates the testbed and runs the jobfile in the venv. The core kit stays stdlib only; pyATS is used only to run the AEtest scripts.

**Tech Stack:** Python 3 stdlib (`urllib`, `ssl`, `json`, `unittest`) for the generator and tests; pyATS/Genie (in `verify/.venv`) for the AEtest scripts; bash (bash 3.2, `set -euo pipefail`) for the runner; a stdlib fake CML API server for tests.

## Global Constraints

- The core kit stays stdlib only. `gen_testbed.py`, the runner, and all tests are stdlib. pyATS is imported only inside the AEtest scripts, which run in `verify/.venv`. Nothing in `scripts/`, `scripts/lib/`, or `tests/` imports pyATS.
- Python: stdlib only (outside the venv), type hints on every signature, `unittest`.
- Bash: `set -euo pipefail`, bash 3.2 compatible, quote every variable, no unguarded `rm`, functions under 40 lines, `main "$@"` at the bottom, `[OK]`/`[WARN]`/`[FAIL]` output.
- Secrets: CML address and credentials come from the gitignored env files under `config/mcp-env/`, never a tracked file or a command line. The generated testbed may hold credentials, so it is written to a gitignored `0600` runtime path and never committed.
- Comments explain why and cite the ADR (0009 for this layer, 0004 for secrets). Plain prose, no em-dashes.
- No live CML calls in the build lane. The generator is tested against a stdlib fake CML API; the AEtest scripts are syntax-checked with `py_compile` but run only in the venv against a live lab (the human-gated task). `tests/run.sh` must pass without pyATS installed.
- Scenario names link a verification to its lab: `verify/cilium-evpn/` verifies `labs/cilium-evpn-blank.yaml`; `verify/trustsec-phase1/` verifies `labs/trustsec-phase1.yaml`.

## File Structure

- `verify/requirements.txt` (new, tracked): pinned pyATS deps for the venv.
- `verify/README.md` (new): bootstrap, run, and add-a-scenario instructions.
- `verify/lib/gen_testbed.py` (new, stdlib): fetch a lab's testbed from CML.
- `verify/cilium-evpn/verify.py`, `verify/cilium-evpn/jobfile.py` (new): AEtest.
- `verify/trustsec-phase1/verify.py`, `verify/trustsec-phase1/jobfile.py` (new): AEtest, run later.
- `scripts/80-verify-lab.sh` (new): the runner.
- `tests/fake_cml_testbed_api.py` (new, stdlib): fake CML API for the generator test.
- `tests/test_gen_testbed.py` (new), `tests/test_verify_run.sh` (new).
- `scripts/00-preflight.sh` (modify): optional venv check.
- `.gitignore` (modify): `verify/.venv/` and the testbed runtime path. Editing `.gitignore` is a stop-and-ask; the implementer proposes the lines and the controller applies them.

---

### Task 1: The verify tree scaffold

**Files:**
- Create: `verify/requirements.txt`, `verify/README.md`
- Modify (stop-and-ask): `.gitignore`
- Test: `tests/test_verify_scaffold.py`

**Interfaces:**
- Produces: `verify/requirements.txt` pinning pyATS; `verify/.venv` and the testbed runtime path (`verify/.testbed/`) gitignored. Consumed by all later tasks.

- [ ] **Step 1: Write `verify/requirements.txt`.** Pin the current stable pyATS full distribution with exact versions, for example `pyats[full]==<current stable>`. Add a comment that this file is the tracked contract and the venv (`verify/.venv`) is built from it. Do not install anything in this task; the venv build is the human-gated task.

- [ ] **Step 2: Write `verify/README.md`.** Cover: bootstrap (`python3 -m venv verify/.venv && verify/.venv/bin/pip install -r verify/requirements.txt`), run (`scripts/80-verify-lab.sh <scenario>`), and how to add a scenario (a `verify/<scenario>/` with `verify.py` and `jobfile.py`). Plain prose, no em-dashes.

- [ ] **Step 3: Propose the `.gitignore` lines** `verify/.venv/` and `verify/.testbed/` to the controller (stop-and-ask, since `.gitignore` is protected). The controller applies them.

- [ ] **Step 4: Write `tests/test_verify_scaffold.py`** asserting: `verify/requirements.txt` exists and contains a pinned (`==`) pyATS entry; `git check-ignore verify/.venv` and `verify/.testbed/x` both report ignored.

```python
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class TestVerifyScaffold(unittest.TestCase):
    def test_requirements_pins_pyats(self) -> None:
        req = (ROOT / "verify" / "requirements.txt").read_text()
        self.assertRegex(req, r"(?im)^pyats(\[[a-z]+\])?==")

    def test_venv_and_testbed_gitignored(self) -> None:
        for path in ("verify/.venv/x", "verify/.testbed/x"):
            rc = subprocess.run(["git", "check-ignore", path], cwd=ROOT).returncode
            self.assertEqual(rc, 0, path)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 5: Run it, then gate and commit**

```bash
python3 -m unittest tests/test_verify_scaffold.py -v
tests/run.sh && pre-commit run --files verify/requirements.txt verify/README.md tests/test_verify_scaffold.py
git add verify/requirements.txt verify/README.md tests/test_verify_scaffold.py
git commit -m "feat: pyATS verify tree scaffold and pinned requirements"
```

---

### Task 2: The testbed generator (stdlib) and its fake-server test

**Files:**
- Create: `verify/lib/gen_testbed.py`, `tests/fake_cml_testbed_api.py`, `tests/test_gen_testbed.py`

**Interfaces:**
- Produces: `gen_testbed.fetch_testbed(base_url, token, lab_title) -> str` returning the testbed YAML text, and a CLI `python3 verify/lib/gen_testbed.py <lab_title> <out_file>` that reads the CML address and credentials from the environment, authenticates, resolves the lab id from the title, fetches the testbed, and writes it at mode `0600`. Consumed by Task 3.

- [ ] **Step 1: Write `tests/fake_cml_testbed_api.py`** (stdlib `http.server`, like `tests/fake_cml_api.py`). Endpoints: `POST /api/v0/authenticate` returns a token string; `GET /api/v0/labs` (or the title lookup CML uses) returns a lab id for the known title; `GET /api/v0/labs/<id>/pyats_testbed` returns a small testbed YAML. Reject a wrong token with 401.

- [ ] **Step 2: Write the failing test** `tests/test_gen_testbed.py`: start the fake server, call `gen_testbed.fetch_testbed(...)`, assert it returns the testbed YAML for the known title and raises on an unknown title; run the CLI as a subprocess with the CML env pointed at the fake, assert the out file is written `0600` and that no credential appears in stdout/stderr.

- [ ] **Step 3: Run it, expect failure** (module missing): `python3 -m unittest tests/test_gen_testbed.py`.

- [ ] **Step 4: Write `verify/lib/gen_testbed.py`.** Stdlib `urllib`/`ssl`/`json`, type hints. Read `CML_URL`/`CML_USERNAME`/`CML_PASSWORD` (match the env var names the kit already uses for CML; confirm against `config/mcp-env` and `scripts/lib/common.sh`) from `os.environ`, never argv. Authenticate, resolve the lab id from the title, `GET .../pyats_testbed`, return the text. The CLI writes it with `os.umask(0o077)` then `chmod 0600`, prints only the out path. Comment why the generator is stdlib and separate from the venv (ADR 0009), and cite ADR 0004 for the secret handling. Verify-off SSL context is acceptable for the lab controller; comment it.

- [ ] **Step 5: Run it, expect pass.** `python3 -m unittest tests/test_gen_testbed.py -v`.

- [ ] **Step 6: Gate and commit**

```bash
tests/run.sh && pre-commit run --all-files
git add verify/lib/gen_testbed.py tests/fake_cml_testbed_api.py tests/test_gen_testbed.py
git commit -m "feat: stdlib CML testbed generator for the verify layer"
```

---

### Task 3: The runner and its dry-run test

**Files:**
- Create: `scripts/80-verify-lab.sh`, `tests/test_verify_run.sh`

**Interfaces:**
- Consumes: `verify/lib/gen_testbed.py`, `verify/.venv`, `verify/<scenario>/jobfile.py`, `scripts/lib/common.sh` helpers.
- Produces: a run that writes the testbed to `verify/.testbed/<scenario>.yaml` and runs the scenario's jobfile with easypy in the venv.

- [ ] **Step 1: Write `scripts/80-verify-lab.sh`.** `set -euo pipefail`, source `common.sh`, a `run()` dry-run wrapper like the other scripts. Arguments: `<scenario>` and optional `--dry-run`. Steps: confirm `verify/.venv` exists (else `die` with the bootstrap command from `verify/README.md`); confirm `verify/<scenario>/jobfile.py` exists; `run python3 verify/lib/gen_testbed.py "<lab_title_for_scenario>" verify/.testbed/<scenario>.yaml`; `run verify/.venv/bin/easypy verify/<scenario>/jobfile.py`. Map the scenario to its lab title (a small case or lookup: `cilium-evpn` to the Cilium lab title, `trustsec-phase1` to the TrustSec lab title). Print the report path easypy reports. Functions under 40 lines, `main "$@"` at the bottom.

- [ ] **Step 2: Write `tests/test_verify_run.sh`** (dry-run, no venv, no CML). With `--dry-run`, and a fake `verify/.venv` marker plus a fake `verify/<scenario>/jobfile.py`, assert the plan prints the `gen_testbed.py` call with the right lab title and out path, and the `easypy .../jobfile.py` call, and that no credential appears. Follow `tests/test_ise_dry_run.sh` for style.

- [ ] **Step 3: Run it.** `bash tests/test_verify_run.sh` prints `test_verify_run: all passed`.

- [ ] **Step 4: Gate and commit**

```bash
tests/run.sh && pre-commit run --all-files
git add scripts/80-verify-lab.sh tests/test_verify_run.sh
git commit -m "feat: verify runner, generate testbed then run the jobfile"
```

---

### Task 4: The Cilium EVPN verification

**Files:**
- Create: `verify/cilium-evpn/verify.py`, `verify/cilium-evpn/jobfile.py`

**Interfaces:**
- Consumes: the generated testbed at `verify/.testbed/cilium-evpn.yaml`.
- Produces: an AEtest testscript asserting the Cilium fabric health.

- [ ] **Step 1: Write `verify/cilium-evpn/verify.py`.** A standard AEtest testscript: `CommonSetup` connects to every device in the testbed; a `Testcase` per assertion. Assertions: every eBGP EVPN neighbor is Established (parse `show bgp l2vpn evpn summary` with the Genie parser and check neighbor state), and all four VNIs are up (parse the NVE/VNI show command). `CommonCleanup` disconnects. Use Genie parsers, not regex. The exact parser keys are confirmed against the live fabric in the human-gated run; comment that assumption where a key is used.

- [ ] **Step 2: Write `verify/cilium-evpn/jobfile.py`.** An easypy jobfile that runs `verify.py` against the testbed passed by the runner (`--testbed-file verify/.testbed/cilium-evpn.yaml`).

- [ ] **Step 3: Syntax-check (build lane cannot run pyATS).**

```bash
python3 -m py_compile verify/cilium-evpn/verify.py verify/cilium-evpn/jobfile.py
```

- [ ] **Step 4: Gate and commit**

```bash
tests/run.sh && pre-commit run --files verify/cilium-evpn/verify.py verify/cilium-evpn/jobfile.py
git add verify/cilium-evpn/verify.py verify/cilium-evpn/jobfile.py
git commit -m "feat: Cilium EVPN pyATS verification, BGP sessions and VNIs"
```

---

### Task 5: The TrustSec Phase 1 verification, authored now

**Files:**
- Create: `verify/trustsec-phase1/verify.py`, `verify/trustsec-phase1/jobfile.py`

**Interfaces:**
- Consumes: the generated testbed at `verify/.testbed/trustsec-phase1.yaml`.
- Produces: an AEtest testscript for the C8000v edge, run once the lab is deployed.

- [ ] **Step 1: Write `verify/trustsec-phase1/verify.py`.** AEtest testscript targeting the C8000v edge: the RADIUS server reachable (parse the aaa/radius show command for the ISE server state), a `test aaa group radius <user> <pass> new-code` returning Access-Accept (run the exec command and check the result), and a CoA received (check the dynamic-author counters). Use Genie parsers where one exists, otherwise a device exec with an explicit result check. Comment that this runs only after the TrustSec lab is deployed, and that the ISE-side checks belong to the `cisco.ise` layer (ADR 0009, roadmap 18).

- [ ] **Step 2: Write `verify/trustsec-phase1/jobfile.py`** running `verify.py` against `verify/.testbed/trustsec-phase1.yaml`.

- [ ] **Step 3: Syntax-check.**

```bash
python3 -m py_compile verify/trustsec-phase1/verify.py verify/trustsec-phase1/jobfile.py
```

- [ ] **Step 4: Gate and commit**

```bash
tests/run.sh && pre-commit run --files verify/trustsec-phase1/verify.py verify/trustsec-phase1/jobfile.py
git add verify/trustsec-phase1/verify.py verify/trustsec-phase1/jobfile.py
git commit -m "feat: TrustSec Phase 1 pyATS verification, edge RADIUS and CoA"
```

---

### Task 6: Preflight venv check

**Files:**
- Modify: `scripts/00-preflight.sh`, `tests/test_preflight.sh`

- [ ] **Step 1: Add a check to `scripts/00-preflight.sh`** for `verify/.venv`. It is optional, so a missing venv is a `[WARN]` naming the bootstrap command, not a `[FAIL]`. Follow the existing check pattern (like the ISE Marketplace check that warns when the env file is absent).

- [ ] **Step 2: Extend `tests/test_preflight.sh`** to assert the venv-absent case warns and preflight still passes.

- [ ] **Step 3: Gate and commit**

```bash
tests/run.sh && pre-commit run --files scripts/00-preflight.sh tests/test_preflight.sh
git add scripts/00-preflight.sh tests/test_preflight.sh
git commit -m "feat: preflight warns when the verify venv is absent"
```

---

### Task 7: Bootstrap and run (HUMAN-GATED, live lab)

**Files:**
- Modify: `docs/STATUS.md`

- [ ] **Step 1 (HUMAN-GATED):** bootstrap the venv: `python3 -m venv verify/.venv && verify/.venv/bin/pip install -r verify/requirements.txt`. Pin the resolved versions back into `verify/requirements.txt` if they floated.
- [ ] **Step 2 (HUMAN-GATED):** with the CML env set and the Cilium lab running, `scripts/80-verify-lab.sh cilium-evpn`. Confirm every BGP session Established and all VNIs up in the report. Fix any Genie parser key that differs from the assumption.
- [ ] **Step 3:** the TrustSec verification runs once that lab is deployed; not part of this task.
- [ ] **Step 4:** record the result and the report location in `docs/STATUS.md` and commit.

---

## Self-Review

- **Spec coverage:** venv + requirements + convention (Task 1), stdlib testbed generator (Task 2), runner (Task 3), Cilium verification run now (Task 4), TrustSec verification authored now (Task 5), optional preflight check (Task 6), the live bootstrap and run (Task 7). ADR 0009 covers the dependency exception.
- **Placeholders:** the pinned pyATS version and the exact Genie parser keys are the two knowns confirmed at implementation and the live run; both are flagged, not hidden behind vague words.
- **Type consistency:** `gen_testbed.fetch_testbed(base_url, token, lab_title)`, the `verify/.testbed/<scenario>.yaml` path, the scenario-to-lab-title mapping, and the `verify/<scenario>/` layout are used consistently across tasks.

## Execution note

The build lane is Tasks 1 to 6, committable with no pyATS install and no live CML calls (stdlib generator tested against a fake, runner dry-run, AEtest scripts syntax-checked). Task 7 is the human-gated bootstrap and the first real run against the Cilium fabric.
