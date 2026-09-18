# Deep Dive: the cml-azure-lab kit itself

> Describes the kit as of 2026-09-13. Since then: `scripts/lib/ise_config.py`
> has run against ISE 3.5, the 24/25/45/46 scripts and `terraform/ad` build
> and remove the directory and ISE per session, and `bridge1` carries the routed path.

**Generated**: 2026-09-13
**Phase**: Design study of the tooling that sits above the cloud-cml fork
**Files**:
- `terraform/bootstrap/*.tf`, `terraform/persistent/*.tf`
- `scripts/00-preflight.sh` through `scripts/90-smoke-test.sh`
- `scripts/lib/common.sh`, `cml-remote.sh`, `mcp_call.py`, `render_cml_config.py`,
  `render_lab.py`, `tfvars.py`, `users.py`
- `tests/run.sh`, `tests/stubs/az`, `tests/stubs/terraform`, `tests/test_*.{sh,py}`
- `verify/README.md`, `verify/lib/gen_testbed.py`, `verify/requirements.txt`
- `.mcp.json`, `scripts/mcp-cml.sh`, `config/mcp-env/`

This code was written by Claude Code against `docs/specs/2026-09-02-cml-azure-lab-design.md`
and the ADRs in `docs/decisions/`. The companion deep dive,
`deep-dive/cloud-cml-azure-2026-09-02.md`, covers the vendored Cisco Terraform
module. This one covers what the operator actually runs day to day: the
three Terraform roots, the numbered scripts, the test harness, the pyATS
verification layer, and the MCP wiring that lets Claude Code drive a live
controller. The goal is the same as the companion piece: understand what
this does and why before changing it, not accept it because a model wrote it.

---

## 1. Three Terraform roots by lifetime

### What it does

The repo splits Terraform into three independent state files instead of one:

| Root | State | Holds | Destroyed |
|---|---|---|---|
| `terraform/bootstrap/` | local, in the repo folder | `rg-cml-lab-tfstate`, one storage account | never |
| `terraform/persistent/` | Azure blob, inside the bootstrap account | `rg-cml-lab`: VNet, subnets, static public IP, SSH key resource, 512 GB data disk, two `random_password` resources | never |
| `vendor/cloud-cml` | local, inside the submodule | the CML VM, its NIC, NSG, and disk attachment | every session |

`terraform/persistent/backend.tf` names the bootstrap account literally,
because a backend block cannot read a variable:

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-cml-lab-tfstate"
    storage_account_name = "st792kcotfstate"
    container_name       = "tfstate"
    key                  = "persistent.tfstate"
    use_azuread_auth     = true
  }
}
```

(`terraform/persistent/backend.tf:1-12`). Backend configuration is evaluated
before any variable or data source exists, so the bootstrap root's output
has to be copied in by hand, once, right after the first bootstrap apply.
`scripts/20-up.sh`'s `apply_bootstrap` checks that this copy actually
happened (`grep -q "storage_account_name.*${sa}" backend.tf`,
`scripts/20-up.sh:88-91`) rather than trusting whoever edited the file.

The data disk and the state storage account both carry
`lifecycle { prevent_destroy = true }` (`terraform/persistent/main.tf:88-90`).
The two `random_password` resources that hold the CML admin and sysadmin
passwords live in the same root (`main.tf:166-176`) and are marked
`sensitive` on their outputs (`outputs.tf:84,90`), which keeps Terraform
from printing them during a normal `plan` or `apply`.

### Why it was built this way

ADR 0002's reasoning: `prevent_destroy` is a lifecycle flag, and a flag can
be edited, forgotten, or overridden with `-target` plus a confirmation. A
`terraform destroy` in one root still *attempts* to destroy the flagged
resource and only fails at that step, by which point everything else in the
root is already gone. The blast radius needs to be structural: a script
physically cannot run `destroy` against a directory it never opens. Three
directories give `scripts/40-down.sh` no path to the other two roots at all
(`scripts/40-down.sh:82-96` calls `terraform -chdir="${CLOUD_CML}" destroy`
and nothing else ever calls `destroy`).

The split also matches cost and risk. The 512 GB Premium disk bills
continuously, roughly 75 USD a month per ADR 0002, specifically so the
~30 GB of reference platform images never has to be re-copied from local
software into blob storage, then into the VM, on every rebuild: a small
recurring cost traded for a large recurring wait. The public IP persists
for the same reason, so the cml-mcp configuration never changes across a
rebuild. State backend choice follows the lifetime split in reverse:
bootstrap state has to be local because nothing exists yet to hold a remote
backend; persistent state has to be remote because losing the local copy
would mean losing track of billed Azure resources and two passwords; the
CML root's state stays local, inside the gitignored submodule, because
upstream cloud-cml manages it that way and nothing in it outlives
`scripts/40-down.sh`.

### Alternatives considered

One root with `prevent_destroy` plus a STOP-and-ask rule against running
top-level `destroy` (ADR 0002 option 1) depends entirely on discipline at
the moment of the command, with no structural backstop. Two roots
(persistent plus CML) was rejected because the persistent root's own blob
backend needs a storage account to already exist somewhere, so something
still has to create that account with local state first. Three roots is
one more directory than a from-scratch design would reach for; the ADR
says so directly and accepts it.

### Concepts

Blast radius as a structural property, not a policy: state boundaries
should match failure-cost boundaries, and the tool that can destroy state
should have no code path to a state file it must never touch. This
generalizes past Terraform, a CI job with separate cloud accounts per
environment gets the same property from IAM rather than a `--yes` flag.
Use it whenever a wrong action costs far more than an extra directory or
credential; a single scope guarded by lifecycle flags is cheaper and fine
when the actions are reversible or one trusted person runs every command
by hand, and stops being fine once an agent or CI job can invoke the
destructive command unattended.

Remote state as a lock, not just a backup: the blob backend with
`use_azuread_auth = true` buys durability against a lost laptop and,
through Azure Blob's lease mechanism, serialization against two concurrent
`apply` runs corrupting the same state file. Local state has neither
property, acceptable here only because nothing else ever runs `apply`
against the bootstrap root concurrently.

### Further reading

- https://developer.hashicorp.com/terraform/language/state/remote
- https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#prevent_destroy
- https://learn.microsoft.com/en-us/azure/developer/terraform/store-state-in-azure-storage
- https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-overview

---

## 2. The operator script pipeline

### What it does

Ten numbered scripts under `scripts/`, plus `scripts/lib/` for shared logic,
form one linear pipeline: preflight, upload, up, export, down, tunnels,
import, users, verify, smoke test. Every script sources
`scripts/lib/common.sh` first and follows the same shape: a header comment
naming what it checks or does, `set -euo pipefail`, small functions, and
`main "$@"` gated behind a `BASH_SOURCE` check so a test can `source` the
file without running it.

`common.sh` resolves `REPO_ROOT` from its own path regardless of the
caller's working directory (`common.sh:12`), defines the three-tier logger:

```bash
pass() { printf "${green}[OK]${reset}    %s\n" "$1"; ok=$((ok + 1)); }
warn() { printf "${yellow}[WARN]${reset}  %s\n" "$1"; warns=$((warns + 1)); }
miss() { printf "${red}[FAIL]${reset}  %s\n" "$1"; fail=$((fail + 1)); }
```

(`common.sh:25-27`), and wraps `terraform output` behind `tf_out`
(`common.sh:64-70`), which every script calls for a persistent-root value
rather than shelling out to `terraform output -raw NAME` directly.

`scripts/00-preflight.sh` is read-only: Azure login, toolchain, `terraform
fmt`/`validate` on all three roots, the submodule pin, the tfvars file,
vCPU quota, uploaded blobs, ISE Marketplace terms, the pyATS venv, in that
order (`00-preflight.sh:256-275`), writing a timestamped `.preflight-ok`
marker only when nothing failed. `scripts/20-up.sh` sequences the build:
check the marker's age, generate an SSH keypair if missing, apply
bootstrap if needed, apply persistent, refuse if a CML VM already exists,
render `config/cml.yml`, forget the previous host's SSH key, apply the CML
root, write `config/mcp-env/cml.env`. `scripts/40-down.sh` mirrors it in
reverse: export labs, stop labs, release the Smart License, destroy the
CML root only.

`scripts/lib/cml-remote.sh` never runs on the Mac in production; it is
piped over SSH and executed on the CML host itself, for example
`cml_ssh "bash -s -- export-labs /data/exports/${stamp}" < "${REMOTE_LIB}"`
(pattern in `30-export-labs.sh:41-43`, `40-down.sh:46`,
`90-smoke-test.sh:55`). It reads the controller's own admin credentials
from `/provision/vars.sh`, group-readable by sysadmin (`cml-remote.sh:23-31`),
authenticates to the loopback API on `127.0.0.1:8001`, and exposes
`list-labs`, `export-labs`, `stop-labs`, `license-status`, `deregister`.
It stays bash 3.2 compatible even though it never runs on the Mac, so the
same file is exercised by `tests/test_cml_remote.sh` without a drifting copy.

### The Python half of scripts/lib

Six scripts under `scripts/lib/` are Python instead of bash, and all six
are stdlib only. `tfvars.py` is a hand-rolled parser for the subset of HCL
`config/cml.tfvars` actually uses:

```python
_STRING = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$')
_NUMBER = re.compile(r"^(-?\d+)\s*(?:#.*)?$")
_LIST = re.compile(r"^\[(.*)\]\s*(?:#.*)?$")
```

(`tfvars.py:21-24`). It accepts exactly `key = "string"`, `key = 123`,
`key = true|false`, and a flat list of quoted strings, one assignment per
line, and raises `ValueError` naming the line on anything else
(`tfvars.py:48`). `render_cml_config.py` fills `config/cml.yml.tftpl` with
`string.Template` and checks its own inputs before writing anything: it
refuses a CIDR list containing `0.0.0.0/0` (`:61-62`) and refuses a secret
value holding a character that cannot sit inside a double-quoted YAML
scalar (`:65-77`), because a stray quote in a rendered password would
otherwise produce a file that parses into the wrong string rather than
failing loudly. `render_lab.py` does the equivalent for `labs/*.yaml`
topologies, which carry `__LAB_PASSWORD__`/`__LAB_SSH_PUBKEY__`
placeholders instead of real values (ADR 0006):

```python
PLACEHOLDER = re.compile(r"__([A-Z][A-Z0-9_]*)__")
missing = sorted(n for n in names if n not in filled)
if missing:
    raise ValueError("missing or empty: " + ", ".join(missing))
```

(`render_lab.py:23,33-35`). It refuses to render a file with any
placeholder left unfilled, which is the difference between a lab that
carries no baked-in password and one that silently ships Cisco's default,
the exact failure ADR 0006 exists to prevent. `users.py` is the largest of
the six; its central choice is idempotency: `apply()` reads the
controller's existing users and groups first, creates only what is missing
(`:212-224`), unions wanted group membership with what already exists
rather than replacing it (`:229-233`), and writes only new rows to the
credentials CSV, never touching an existing password (`:294-296`). That
lets `scripts/70-users.sh` run after every rebuild without resetting a
password a colleague already changed, the point ADR 0007 calls out.

### Design choices

Bash 3.2 compatibility: macOS ships bash 3.2 (2007, last GPLv2 release) as
`/bin/bash`, which lacks associative arrays and treats an empty array
reference under `set -u` as unbound. `scripts/70-users.sh` guards against
that directly:

```bash
# Bash 3.2 calls an empty array unbound under set -u, hence the guard.
python3 "${USERS_PY}" apply --csv "${csv}" --credentials "${USERS_CREDENTIALS}" ${dry_run[@]+"${dry_run[@]}"}
```

(`70-users.sh:66`). Targeting 3.2 rather than requiring `brew install bash`
keeps the kit runnable on a stock Mac with zero setup.

Stdlib-only Python: CLAUDE.md's rule is explicit, and ADR 0009 treats it as
load-bearing enough to need a formal exception for pyATS. A stdlib script
has no supply chain to audit and runs on any Python 3 already on the Mac.
The cost is real: `tfvars.py`'s regex parser would break on real HCL syntax
it does not support (nested blocks, interpolation); the kit accepts that
because `cml.tfvars` never needs more than the subset it parses.

The `[OK]`/`[WARN]`/`[FAIL]` convention exists because some conditions are
informational rather than blocking, a missing `verify/.venv` should not
stop a build unrelated to pyATS (`00-preflight.sh:248-254`), but a missing
`ARM_SUBSCRIPTION_ID` should. Every script shares the same vocabulary and
the same exit contract, nonzero only on `[FAIL]`.

Dry-run everywhere: every mutating script implements it with the same
`run()` wrapper, echoing `+ $*` in place of executing:

```bash
run() { if [[ "${DRY_RUN}" == "1" ]]; then echo "+ $*"; else "$@"; fi; }
```

(`20-up.sh:34-40`, `30-export-labs.sh:23-29`, `40-down.sh:32-38`,
`10-upload-images.sh:31-37`). Because the wrapper is syntactic, mirroring
`set -x`'s `+` convention, the dry-run path exercises the real control flow
and argument construction rather than a separate mocked implementation
that could drift from what actually runs, and it is exactly what the
dry-run tests assert against: the printed `+ ...` lines and their order.

Secrets through tfvars and gitignored renders, never through Terraform:
ADR 0004's line is that Terraform reads only `random_password` resources
and its own state, never this repo's `cml.tfvars` or `mcp-env/*`.
`render_cml_config.py` accepts its two passwords through environment
variables, not `--set NAME=VALUE`, so they never appear in `ps` output
(`20-up.sh:121-123`), and writes the rendered file at mode 0600
(`render_cml_config.py:145`). The mcp-env directory ignores everything in
itself by default (`*` / `!.gitignore`, `config/mcp-env/.gitignore:2-3`),
so a new secret file dropped there needs no `.gitignore` edit, which
matters because CLAUDE.md requires a human for any `.gitignore` change.

The CML host as an SSH jump: ADR 0003 gives the CML host the only public
IP among lab nodes because ISE and FTD need to see each switch at its own
address for RADIUS Change of Authorization, which rules out NAT, and Azure
will not deliver frames to an unregistered MAC, which rules out bridging.
`scripts/50-tunnels.sh` opens `ssh -N -L` forwards through port 1122 on the
CML host (`50-tunnels.sh:64-65`), and every script touching a lab node over
SSH goes through the same port, which is the host's system shell; port 22
is the console server (`cml-remote.sh:1-2`).

### Alternatives considered

A monolithic `build.sh` dispatching on `$1` would have fewer files but no
independent dry-run and no independently testable units, and
`test_up_dry_run.sh` would have to fake an entire large script rather than
source ten-line functions. A Makefile would give free dependency ordering
but no natural home for the `[OK]`/`[WARN]`/`[FAIL]` counters or a shared
`common.sh`. Ansible would give idempotency primitives for free at the cost
of a real dependency and a DSL for what is, at this scale, straight-line
logic: apply three roots in order, render one file, write one env file.

### Concepts

Idempotent operator scripts: running one twice produces the same end
state as running it once, with the second run doing nothing harmful.
`users.py`'s existing-user check and `apply_bootstrap`'s skip-if-applied
(`20-up.sh:79-81`) are both instances. The alternative, an operator
remembering which step already ran, scales badly past one person; the
extra existence-check code is worth it whenever a script might reasonably
be re-run after a partial failure, which is most operator tooling.

Dry-run as a projection of real control flow, not a separate mode: a thin
wrapper around the same call sequence guarantees the preview cannot lie
about ordering or arguments, at the cost of never showing a command's
*result*, only that it would run. Terraform's own `plan` is the deeper
alternative when resource-level diffs matter more than call ordering.

A stdlib-only discipline as a supply-chain boundary: treating `pip install`
as a decision needing its own ADR makes dependency risk visible at the
point it is introduced, instead of accumulating silently across many small
requirements edits.

### Further reading

- https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin
- https://www.gnu.org/software/bash/manual/bash.html#Shell-Parameter-Expansion
- https://docs.python.org/3/library/re.html
- https://docs.python.org/3/library/secrets.html
- https://man.openbsd.org/ssh#L

---

## 3. The test strategy

### What it does

`tests/run.sh` is the gate CLAUDE.md requires before any commit: `bash -n`
on every script, `shellcheck --severity=warning --external-sources` on the
same set, `python3 -m unittest discover` for every `tests/test_*.py`, and
every `tests/test_*.sh` run directly (`tests/run.sh:16-50`). Any failure
sets `failed=1` and the script exits nonzero regardless of which passes
succeeded, so a shellcheck warning cannot hide behind a passing unit test.

`tests/stubs/az` and `tests/stubs/terraform`, placed first on `PATH`, make
the bash tests possible without a real subscription or state.
`tests/stubs/terraform` matches on the literal command line:

```bash
case "$*" in
  *"output -raw public_ip_address"*) echo "203.0.113.5" ;;
  *"output -json cml2info"*) echo '{"address":"203.0.113.5", ...}' ;;
  *) echo "terraform stub: unhandled: $*" >&2; exit 1 ;;
esac
```

The `*) exit 1` fallback matters: any script calling Terraform in a way the
stub does not recognize fails the test loudly rather than getting empty
output a careless caller might treat as success. `tests/stubs/az` does the
same for `az account show`, `vm show`, `vm image terms show`, and supports
env-var switches (`AZ_STUB_AUTH_FAIL=1`, `AZ_STUB_RG_MISSING=1`) so one
file produces both the happy path and the specific failure modes
`refuse_if_vm_exists` must tell apart (an auth failure is not "no VM").

`tests/test_up_dry_run.sh` is representative: it runs `20-up.sh --dry-run`
with the stubs on `PATH`, asserts specific `+ ...` lines appear, then
asserts their relative order by locating each line number and comparing
them (`test_up_dry_run.sh:42-48`). It moves aside any real
`.preflight-ok` marker before running and restores it in a trap on exit
(`:14-18`), because the same machine might have a genuine build in
progress. On the Python side, `tests/fake_cml_api.py`,
`fake_cml_testbed_api.py`, and `fake_ise_api.py` give the unit tests a real
loopback socket to talk to instead of a mocked `urllib.request`, so
`test_gen_testbed.py` checks real request and response bytes.

### Why this shape, and its limits

Bash has no native mocking framework the way `unittest.mock` exists for
Python, so a `PATH`-level stub is the natural seam for intercepting `az`
and `terraform` without touching the scripts under test. The split keeps
`tests/run.sh` runnable with nothing beyond stdlib Python and the tools
CLAUDE.md already lists; nothing in the suite needs a live subscription,
controller, or pyATS.

It catches a broken bash syntax error, a shellcheck-flagged unquoted
variable, a change to `20-up.sh`'s ordering a dry-run test asserts
against, a regression in `tfvars.py`'s parser, a `render_lab.py` change
that lets a placeholder through unfilled, a `users.py` change that would
reset a password. It cannot catch whether `terraform apply` actually
succeeds against real Azure, whether the CML controller's real API shape
still matches what `cml-remote.sh` expects (a field rename and every stub
keeps happily returning the old shape), whether tunnels forward traffic
end to end, or whether quota or Marketplace terms have changed. Those gaps
are exactly what `00-preflight.sh` and `90-smoke-test.sh` cover against a
real subscription, and why ADR 0002 requires a real `terraform plan`
showing no changes on the persistent root after a build, something no stub
can simulate.

### Concepts

Test doubles chosen per language, not per test: bash gets a `PATH`-level
stub because that is the seam for external processes in a shell script;
Python gets fake HTTP servers because that is the seam for `urllib.request`
calls. Forcing one technique across both languages adds a translation
layer with its own bugs for no real gain.

The persistent gap between unit tests and integration reality: a stub that
fails loudly on anything unrecognized still cannot detect drift in the
shape of a response it already matches by command line. That gap is why a
smoke test against the real system, run after every real build, is the
other half of the verification story unit tests alone never close.

### Further reading

- https://docs.python.org/3/library/unittest.html
- https://www.shellcheck.net/wiki/
- https://developer.hashicorp.com/terraform/cli/commands/plan
- https://learn.microsoft.com/en-us/cli/azure/reference-index

---

## 4. The verify/ pyATS layer

### What it does

`verify/` holds a lab-verification layer on Cisco's pyATS and Genie, in its
own venv (`verify/.venv`, gitignored) with a pinned `verify/requirements.txt`.
`scripts/80-verify-lab.sh` drives it: resolve the scenario's tracked lab
title from `labs/*.yaml` through `render_lab.py --print-title`, so the
title used to find the lab on the controller can never drift from the
tracked file (the guarantee ADR 0006 owns), generate a fresh pyATS testbed
from the running lab through `verify/lib/gen_testbed.py`, then hand it to
the scenario's `easypy` jobfile. `gen_testbed.py` is stdlib-only Python
that authenticates and fetches `/api/v0/labs/{id}/pyats_testbed`:

```python
def fetch_testbed(base_url: str, token: str, lab_title: str) -> str:
    lab_id = _lab_id_for_title(base_url, token, lab_title)
    return _request(base_url, f"/api/v0/labs/{lab_id}/pyats_testbed", token=token, as_json=False)
```

(`gen_testbed.py:97-105`). The testbed is generated at verify time, never
hand-maintained, and written with a narrowed umask before the file exists,
then `chmod 0600` again afterward in case an old, looser copy remains
(`:108-122`), because a pyATS testbed can carry console credentials for
every node.

### Why it has its own venv (ADR 0009)

pyATS is not stdlib, and Genie's parsers pull a substantial dependency
tree. ADR 0009 treats adopting it as a deliberate, bounded exception,
fenced structurally rather than by policy: nothing in `scripts/` or
`scripts/lib/` imports pyATS, the kit's own `unittest` suite runs with no
pyATS installed, and the venv is gitignored and rebuilt from a pinned
requirements file rather than upgraded in place. `gen_testbed.py` sits on
the stdlib side of that fence even though it lives under `verify/`,
specifically so testbed generation stays covered by `tests/run.sh`
(`test_gen_testbed.py`) while only the AEtest scripts that need pyATS's
connect and parse machinery live inside the venv boundary.

The other deciding fact: CML can generate a pyATS testbed for any running
lab through its own API, including console-only access for nodes with no
IP reachability. The fabric labs in this kit have no management plane and
the routed labs sit behind a transit path, so console access through the
CML controller is the only general way to reach every node, and pyATS
consumes exactly that kind of testbed. AEtest scripts in Python, not
pyATS's lower-code Blitz YAML path, because the operator wants direct
control over a lower barrier for other contributors; the directory
convention (`verify.py` plus `jobfile.py` per scenario, named to match the
scenario and the `labs/` file stem) does not prevent adding Blitz later.

### Consequences

A verification run only tells you whether an already-built lab is healthy;
it builds, deploys, and tears down nothing (`80-verify-lab.sh:29`). It
needs the same gitignored CML credentials as the rest of the kit, never a
separate tracked one, and it reads live state over the CML console, so it
verifies CML nodes only; ISE and FTD get their own tooling.

### Alternatives considered

Hand-rolled stdlib checks (`ssh` plus regex over `show` output) was ADR
0009's option 1: every new lab would reinvent brittle parsing rather than
reuse Genie's maintained parsers, the sprawl a shared layer prevents. Robot
Framework or a bespoke harness was rejected for the same reason, plus the
fact that pyATS is Cisco's own tooling and integrates with CML's testbed
endpoint natively.

### Concepts

Fencing a dependency exception structurally: rather than relaxing a
stdlib-only rule everywhere, ADR 0009 draws the boundary at the process
level and enforces it by what imports what, the same pattern as the three
Terraform roots in section 1. Use it whenever a dependency is valuable for
one bounded part of a system but a liability if it spread; the
alternative, adopting it project-wide, is simpler to invoke but removes
the ability to reason about the rest of the codebase as dependency-free.

Generated configuration over hand-maintained configuration: the testbed is
fetched fresh every time rather than checked in, for the same reason
`config/cml.yml` is rendered rather than hand-edited, a hand-maintained
file drifts from what it describes until something fails confusingly. The
alternative, a checked-in template, is more portable to environments that
cannot reach a live controller at test-generation time, an advantage this
kit does not need since verification always targets one live lab.

### Further reading

- https://developer.cisco.com/docs/pyats/
- https://developer.cisco.com/docs/genie-docs/
- https://pubhub.devnetcloud.com/media/pyats/docs/aetest/index.html
- https://pubhub.devnetcloud.com/media/pyats/docs/easypy/index.html
- https://developer.cisco.com/docs/modeling-labs/

---

## 5. The cml-mcp wiring

### What it does

`.mcp.json` registers one MCP server:

```json
{
  "mcpServers": {
    "cml": { "type": "stdio", "command": "bash", "args": ["scripts/mcp-cml.sh"] }
  }
}
```

Claude Code launches `bash scripts/mcp-cml.sh` as a subprocess and talks
JSON-RPC over stdin and stdout, the same stdio transport
`scripts/lib/mcp_call.py` implements standalone for the smoke test
(`mcp_call.py:24-66`). `mcp-cml.sh` does not implement a server itself; it
loads credentials and execs the real one:

```bash
main() {
  [[ -f "${ENV_FILE}" ]] || { echo "mcp-cml: ${ENV_FILE} missing" >&2; exit 1; }
  set -a
  source "${ENV_FILE}"
  [[ -f "${LAB_ENV_FILE}" ]] && source "${LAB_ENV_FILE}"
  set +a
  exec uvx "cml-mcp[pyats]" "$@"
}
```

(condensed from `scripts/mcp-cml.sh:17-35`). `ENV_FILE` is
`config/mcp-env/cml.env`, written by `20-up.sh` at the end of a build with
`CML_URL`, `CML_USERNAME`, `CML_PASSWORD`, `CML_VERIFY_SSL`
(`20-up.sh:162-179`). `LAB_ENV_FILE` is the operator's own
`config/mcp-env/labs.env`, which can carry `PYATS_USERNAME`/`PYATS_PASSWORD`
so cml-mcp's `pyats` extra can log in to lab devices, not just the
controller. `set -a` exports everything sourced from both files so `exec
uvx` inherits it without listing each variable; `exec` replaces the
wrapper's own process rather than forking, so the running MCP server is a
direct child of Claude Code with no intermediate shell holding credentials
longer than necessary. `uvx "cml-mcp[pyats]"` runs the published package
through `uv`'s ephemeral-environment runner, so its own dependencies are
resolved and cached outside this repo, nothing to add to a requirements
file here.

### Why it is wired this way

Claude Code's MCP configuration accepts only a command and arguments, no
way to source a file inline, which is the gap the wrapper's own header
comment states: "Claude Code cannot source a file itself, hence this
wrapper." Keeping the credential load in the wrapper rather than inlining
values into `.mcp.json` keeps that file free of secrets and committable
as-is, consistent with ADR 0004's rule that secrets live only in
gitignored files under `config/`. Deferring to `uvx` rather than vendoring
cml-mcp follows the same reasoning as pyATS's isolated venv in section 4: a
third-party MCP server is a dependency with its own release cadence, and
`uvx` trades pinned reproducibility for picking up new releases without a
repo change.

### Alternatives considered

Writing credentials directly into `.mcp.json` removes the wrapper at the
cost of a file that now holds a live password and needs a hand edit on
every rebuild instead of an automatic env-file rewrite. A project-local
virtualenv with `cml-mcp` pinned would give a reproducible, offline-usable
version at the cost of one more thing for `00-preflight.sh` to know how to
bootstrap, which the kit avoids by pushing that to `uv`'s own caching.

### Concepts

Wrapper scripts as an adapter between a fixed integration surface and a
flexible one: Claude Code's MCP config accepts a command line, nothing
more, and the kit's need is "run this, but load secrets from a file
first." A thin exec wrapper bridges a rigid interface and a requirement it
was never designed to express, without patching the interface itself; the
same pattern shows up in systemd's `EnvironmentFile=` and Docker's
`--env-file`, which eventually grew native support for the same gap.

`exec` versus a plain subprocess call: replacing the wrapper's own process
image with the target program means one fewer process holding the sourced
environment, and signals reach the real server directly instead of needing
forwarding by a still-alive wrapper. Skip `exec` when the wrapper needs to
run something after the child exits; this one never does.

### Further reading

- https://modelcontextprotocol.io/docs/concepts/transports
- https://code.claude.com/docs/en/mcp
- https://docs.astral.sh/uv/guides/tools/
- https://www.gnu.org/software/bash/manual/bash.html#Bourne-Shell-Builtins

---

## Closing note

Every section above traces back to a written decision, an ADR or the
design spec, rather than an unstated preference. That traceability is
itself worth noticing: the value of an ADR before a structural choice is
not process for its own sake. It is the difference between "why does this
repo have three Terraform roots" being answerable by reading one file in
thirty seconds, versus reconstructed from the code's shape, which is
slower and, after enough rebuilds, wrong.
