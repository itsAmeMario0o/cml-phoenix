"""easypy jobfile for the TrustSec Phase 1 verification scenario (ADR 0009, Task 5).

scripts/80-verify-lab.sh runs `easypy jobfile.py` with no other arguments
(see its run_jobfile()), so this jobfile resolves the testbed path itself
rather than reading it off a --testbed-file flag the runner never passes.
It sits at verify/trustsec-phase1/jobfile.py, one directory below
verify/.testbed/trustsec-phase1.yaml, the file the runner generates fresh
from the running lab on every invocation (verify/lib/gen_testbed.py, Task
2). This mirrors verify/cilium-evpn/jobfile.py (Task 4) exactly; only the
scenario name differs.

Authored now, run later: this file is only syntax-checked by py_compile
until the TrustSec lab is actually deployed (Task 7). Nothing here imports
pyATS at build time beyond what py_compile itself tolerates by not
executing the module.
"""
from __future__ import annotations

import os
from typing import Any

from genie.testbed import load

from pyats.easypy import run

_SCENARIO_DIR = os.path.dirname(os.path.abspath(__file__))
_VERIFY_DIR = os.path.dirname(_SCENARIO_DIR)
TESTBED_FILE = os.path.join(_VERIFY_DIR, ".testbed", "trustsec-phase1.yaml")
TESTSCRIPT = os.path.join(_SCENARIO_DIR, "verify.py")


def main(runtime: Any) -> None:
    """Entry point easypy calls.

    Loads the generated testbed through genie.testbed.load rather than the
    plain pyats topology loader, so every device carries the .parse()
    method Genie adds, the same as the Cilium jobfile. verify.py's RADIUS
    and CoA testcases read raw exec output rather than a Genie parser (see
    the comments in verify.py explaining why), but CommonSetup and
    CommonCleanup still expect Genie-flavored Device objects, so the
    loader stays consistent with the other scenario.
    """
    testbed = load(TESTBED_FILE)
    run(testscript=TESTSCRIPT, runtime=runtime, testbed=testbed)
