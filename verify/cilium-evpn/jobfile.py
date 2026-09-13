"""easypy jobfile for the Cilium EVPN verification scenario (ADR 0009, Task 4).

Delegates to verify/lib/scenario.py's scenario_main, the shared shape
every scenario's jobfile follows (verify/README.md, "Adding a scenario").
"""
from __future__ import annotations

import os
import sys
from typing import Any

_LIB_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib")
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)

from scenario import scenario_main  # noqa: E402


def main(runtime: Any) -> None:
    scenario_main(runtime, __file__)
