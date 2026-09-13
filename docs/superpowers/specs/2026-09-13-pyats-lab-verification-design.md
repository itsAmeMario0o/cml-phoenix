# pyATS lab verification

Status: draft, 2026-09-13.

This spec adds a verification layer for the labs. Each scenario gets a
repeatable check that a lab is actually working, with a uniform report, so
the library can grow without every lab inventing its own hand checks. The
tool is Cisco's pyATS and Genie, isolated in a virtual environment, as
decided in ADR 0009.

## Context

The library has the Cilium EVPN fabric, the inline-IPS FTD lab, and the
TrustSec lab, with more coming. Today "is it working" is answered by hand:
BGP sessions established, all VNIs up, the FTDs registered, RADIUS reachable.
That does not scale and leaves no record. pyATS gives a testbed that
describes a lab, Genie parsers that turn device output into structured data,
AEtest that runs the testcases, and easypy that produces the report. CML
generates a pyATS testbed for any running lab through its API, over the CML
console, so nodes need no IP reachability. That fits our fabric, which has no
management plane, and the routed labs, which sit behind the transit path.

ADR 0009 decided to adopt pyATS in its own venv, with verifications written
as AEtest Python testscripts, and the testbed generated from CML at verify
time. This spec turns that into a concrete structure and proves it on one
lab.

## Goal and scope

In scope:

- A dedicated `verify/` tree with the pyATS venv, pinned requirements, and a
  per-scenario convention so new labs slot into one shape.
- A testbed generator that pulls the pyATS testbed for a lab from CML at
  verify time, into a gitignored runtime file.
- A verify runner, `scripts/80-verify-lab.sh <scenario>`, that generates the
  testbed, runs the scenario's easypy jobfile, and archives the report.
- Two scenarios retrofitted to the convention:
  - The Cilium EVPN fabric, which is running and has clear, verifiable state.
    This is the end-to-end worked example, authored and run now.
  - The TrustSec Phase 1 lab. Its verification is authored now and runs once
    the lab is deployed, since ISE and the transit bridge are not up yet.
    The checks target the C8000v edge, a CML node: the RADIUS server
    reachable, a `test aaa` returning Access-Accept, and a CoA received.

Out of scope, deferred:

- Retrofitting the IPS and FTD lab to the convention. It follows once the
  two focus labs are done.
- TrustSec's ISE-side checks, such as the live authentication log showing a
  per-device source. Those read ISE, not a CML node, so they belong to the
  `cisco.ise` layer on the roadmap, not to pyATS.
- Blitz, the low-code YAML path. ADR 0009 chose AEtest for now.
- CI. The runner produces a report that CI can consume later.

## Architecture

### The venv, isolated

The core kit stays stdlib only. pyATS lives in a venv the kit code never
imports:

- `verify/requirements.txt`, tracked, pins pyATS and the CML client with
  exact versions.
- `verify/.venv`, gitignored, is the environment. A bootstrap step creates
  it from the requirements. Preflight can check for it and warn, without
  requiring it, so a run that does not verify still passes.

### The per-scenario convention

Verification lives beside the topologies, not inside them, so `labs/` stays
one topology per file and this tree stays one verification per scenario:

```
verify/
  requirements.txt        tracked, pinned pyATS deps
  README.md               how to run a verification, how to add one
  lib/gen_testbed.py      pulls the testbed from CML for a lab
  <scenario>/
    verify.py             the AEtest testscript
    jobfile.py            the easypy jobfile that runs verify.py
```

The scenario name links a verification to its lab: `verify/cilium-evpn/`
checks the lab whose topology is `labs/cilium-evpn-blank.yaml`. A new lab is
verified by adding one `verify/<scenario>/` directory, nothing else.

### Testbed generation from CML

`verify/lib/gen_testbed.py` asks CML for the pyATS testbed of a named lab and
writes it to a gitignored runtime path. It reads the CML address and
credentials from the gitignored env files the kit already uses, never from a
tracked file. The generated testbed connects to nodes over the CML console,
so a lab with no IP reachability still verifies. Because the testbed comes
from the running lab, it cannot drift from the topology.

### The runner

`scripts/80-verify-lab.sh <scenario>`:

- Confirms the venv exists, or tells the operator to bootstrap it.
- Generates the testbed for the scenario's lab from CML.
- Runs `verify/<scenario>/jobfile.py` with easypy inside the venv.
- Leaves the report and archive where easypy writes them, and prints the
  path. A dry run prints the plan and touches nothing.

The runner is bash in the kit's style. It holds no pyATS logic itself; it
activates the venv and calls easypy.

### The AEtest testscript

`verify/<scenario>/verify.py` is a normal AEtest testscript: a common setup
that connects to the testbed, testcases that use Genie parsers and learned
state to assert the lab's health, and a common cleanup. For the worked
example, Cilium EVPN, the testcases assert that every eBGP EVPN session is
Established and that all four VNIs are up, which is the state the lab is
already checked for by hand. The TrustSec testscript is written to the same
shape but targets the C8000v edge: the RADIUS server reachable, a `test aaa`
returning Access-Accept, and a CoA received. It is authored alongside the
Cilium example and runs once the TrustSec lab is deployed.

### What stays stdlib

The kit's own tests stay stdlib `unittest` and run without pyATS installed.
`tests/run.sh` does not run pyATS. The testbed generator and the runner get
stdlib tests and a dry-run so their plumbing is covered without a live lab.

## Secrets

- CML address and credentials come from the gitignored env files under
  `config/mcp-env/`, read at verify time. No secret is written to a tracked
  file, per ADR 0004.
- The generated testbed may contain credentials, so it is written to a
  gitignored runtime path and is never committed.

## Verification

1. `verify/requirements.txt` installs cleanly into `verify/.venv`.
2. `scripts/80-verify-lab.sh --dry-run cilium-evpn` prints the plan: generate
   the testbed, run the jobfile, no live calls, no secret in the output.
3. Against the running Cilium EVPN lab, `scripts/80-verify-lab.sh
   cilium-evpn` generates the testbed, runs the AEtest script, and reports
   every BGP session Established and all VNIs up, with a saved report.
4. The TrustSec testscript exists and is well-formed. Its structure is
   checked now (it imports and lists its testcases); the live run against
   the edge waits until the TrustSec lab is deployed.
5. `tests/run.sh` still passes and does not require pyATS.

## Risks and fallback

- pyATS is a large dependency. Keeping it in a venv the kit never imports
  bounds the blast radius; if it ever breaks, the kit and its tests are
  unaffected.
- Testbed generation depends on CML API reachability and credentials. If CML
  is not reachable, the runner fails clearly at the generate step rather than
  producing a misleading result.
- Genie parsers track platform output and can lag a new image. If a parser
  is missing for a node, the testcase says so rather than passing silently.

## Open questions

- The exact CML testbed endpoint and client to use for generation, virl2
  client library or the testbed API directly, decided at implementation.
- Whether the venv lives at `verify/.venv` or a shared tools location,
  decided at implementation; the requirements file is the tracked contract
  either way.
- Whether a later Blitz path is worth adding for contributors who do not want
  Python, revisited when someone other than the operator writes a lab.
