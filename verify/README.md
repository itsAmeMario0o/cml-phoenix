# Lab verification (pyATS)

This directory holds the pyATS verification layer described in
[ADR 0009](../docs/decisions/0009-pyats-lab-verification.md). It checks that
a running lab actually works. Two scenarios exist: `cilium-evpn` checks
that every eBGP EVPN neighbor is Established and every VNI is up, and
`trustsec-phase1` checks that the C8000v edge sees ISE as a reachable
RADIUS server, gets an Access-Accept from `test aaa`, and has received a
CoA (the last one fails on an edge with no endpoint session, by design).
What gets checked depends on the scenario. This is a separate tool from the rest of the kit. Nothing in
`scripts/` or `scripts/lib/` imports pyATS, and the kit's own `unittest`
suite runs without it installed.

## Bootstrap

pyATS is a large third-party dependency, so it lives in its own virtual
environment instead of the project's Python. Build it once:

    python3 -m venv verify/.venv
    verify/.venv/bin/pip install -r verify/requirements.txt

`verify/requirements.txt` is the tracked contract: it pins the exact pyATS
version. `verify/.venv` itself is gitignored and disposable. If you need a
newer pyATS, bump the pin in `requirements.txt` and rebuild the venv rather
than upgrading it in place.

## Running a verification

    scripts/80-verify-lab.sh <scenario>

The script generates a fresh testbed from the running CML lab through the
CML API and writes it under `verify/.testbed/`, which is also gitignored.
The testbed is never hand-maintained, so it cannot drift from the topology
it describes. The script then runs the scenario's AEtest job against that
testbed and reports pass or fail per testcase.

A verification only tells you whether a lab that is already built is
healthy. It does not build, deploy, or tear anything down, and it needs
CML credentials to reach the controller, the same gitignored env files the
rest of the kit uses.

## Adding a scenario

Each scenario is a directory under `verify/`, and its name is load-bearing:
it must match a case in `lab_yaml_for_scenario` in
`scripts/80-verify-lab.sh`, which maps the scenario to the tracked `labs/`
file it verifies. The name need not equal the file stem: `verify/cilium-evpn/`
checks `labs/cilium-evpn-blank.yaml`, and `verify/trustsec-phase1/` checks
`labs/trustsec-phase1.yaml`. A scenario directory holds:

- `verify.py`: the AEtest testscript. Its `CommonSetup`, `CommonCleanup`,
  and device-filtering helper come from `verify/lib/scenario.py`
  (`CommonSetup`, `CommonCleanup`, `devices_with_os`), so this file adds
  only its own `Testcase` classes and, if it needs one, a thin os filter
  built on `devices_with_os`.
- `jobfile.py`: six lines that put `verify/lib` on `sys.path` and call
  `scenario_main(runtime, __file__)`, which derives the scenario name from
  the directory `jobfile.py` lives in rather than repeating it as a
  literal.

Following this shape means `scripts/80-verify-lab.sh` can run any scenario
the same way, and a new lab only has to add checks, not invent a new way to
run them.
