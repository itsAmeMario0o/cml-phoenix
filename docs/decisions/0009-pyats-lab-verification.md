# 0009: pyATS for lab verification, in an isolated venv

Status: accepted, 2026-09-13

## Context

The lab library is growing. There is the Cilium EVPN fabric, the inline-IPS
FTD lab, and now the TrustSec lab, and more are expected. Each lab has a
"is it actually working" question that today is answered by hand: BGP
sessions established, all VNIs up, the FTDs registered, RADIUS reachable, an
SGT assigned. Hand checks do not scale, they drift, and they leave no
uniform record.

We want a verification layer that is repeatable, produces a uniform report
per lab, and follows one structure so new labs do not each invent their own.
Cisco's pyATS and Genie are built for exactly this: a testbed describes the
lab, Genie parsers turn device output into structured data, AEtest runs the
testcases, and easypy produces the report and archive. CML can generate a
pyATS testbed for any running lab through its API, including for nodes that
have no IP reachability, because the connection is over the CML console.
That last point matters here: our fabric has no management plane, and the
routed labs sit behind the transit path, so console-based access is the only
general way to reach every node.

CLAUDE.md sets a project rule that Python is stdlib only. pyATS is a large
third-party dependency and cannot meet that rule. So adopting it is a
deliberate, bounded exception, recorded here, in the same spirit as the
Textual terminal UI exception noted on the roadmap.

## Decision

Adopt pyATS and Genie as the live-lab verification layer, isolated in its
own virtual environment, as a bounded exception to the stdlib-only rule.

- pyATS lives in a dedicated venv with a pinned requirements file. The core
  kit code stays stdlib only. Nothing in `scripts/` or `scripts/lib/` imports
  pyATS; the verification layer is invoked as a separate tool.
- Verifications are AEtest testscripts, written in Python. The operator
  builds the labs and wants verification integrity and reproducibility under
  direct control, so the low-code Blitz YAML path is not used for now.
- The testbed is generated from CML at verify time through the CML API, into
  a gitignored runtime file. It is never hand-maintained, so it cannot drift
  from the topology.
- Each scenario follows one directory convention so new labs slot into the
  same shape. The verification spec defines it.
- pyATS is required only to verify a running lab. It is not required to
  build, deploy, or tear down anything. The kit's own tests stay stdlib
  `unittest` and run without pyATS installed.

## Consequences

- A new dependency and a venv to provision. The requirements are pinned and
  the venv is gitignored. A bootstrap step creates it; preflight can check
  for it without requiring it.
- `tests/run.sh` stays stdlib only and does not run pyATS. The pyATS
  verifications are a separate layer, run against live labs, not in the unit
  suite. The testbed generator and the runner script can still be covered by
  stdlib tests and dry-runs.
- The verification layer reads live device state. Credentials for the CML
  controller come from the existing gitignored env files, never a tracked
  file, per ADR 0004.
- Verifications reach lab nodes over the CML console by default, so they work
  for the no-management-plane fabric and the routed labs without exposing any
  node. External services that are not CML nodes, such as ISE, are verified
  by their own tooling, not this layer.

## Options considered

1. Hand-rolled stdlib checks. Keeps the stdlib-only rule, but every lab
   reinvents brittle regex over `show` output, which is the sprawl we are
   trying to avoid. Rejected.
2. pyATS with Blitz, verifications as YAML. Lower barrier for others to add
   checks, but the operator wants Python and full control for now. Kept in
   reserve; the convention does not prevent adding Blitz later.
3. Robot Framework or a bespoke harness. More to learn and maintain than
   pyATS, which is Cisco's own and integrates with CML directly. Rejected.
4. pyATS as a general project dependency rather than a venv. Simpler to
   invoke, but it relaxes the stdlib-only rule across the whole kit rather
   than fencing the exception. Rejected in favor of the venv.
