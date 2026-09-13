"""easypy jobfile for the Cilium EVPN verification scenario (ADR 0009, Task 4).

scripts/80-verify-lab.sh runs `easypy jobfile.py` with no other arguments
(see its run_jobfile()), so this jobfile resolves the testbed path itself
rather than reading it off a --testbed-file flag the runner never passes.
It sits at verify/cilium-evpn/jobfile.py, one directory below
verify/.testbed/cilium-evpn.yaml, the file the runner generates fresh from
the running lab on every invocation (verify/lib/gen_testbed.py, Task 2).
"""
from __future__ import annotations

import os
from typing import Any

from genie.testbed import load

from pyats.easypy import run

_SCENARIO_DIR = os.path.dirname(os.path.abspath(__file__))
_VERIFY_DIR = os.path.dirname(_SCENARIO_DIR)
TESTBED_FILE = os.path.join(_VERIFY_DIR, ".testbed", "cilium-evpn.yaml")
TESTSCRIPT = os.path.join(_SCENARIO_DIR, "verify.py")


def main(runtime: Any) -> None:
    """Entry point easypy calls.

    Loads the generated testbed through genie.testbed.load rather than the
    plain pyats topology loader, so every device carries the .parse()
    method Genie adds. verify.py's testcases depend on Genie parsers, not
    regex, per ADR 0009.
    """
    testbed = load(TESTBED_FILE)
    run(testscript=TESTSCRIPT, runtime=runtime, testbed=testbed)
