"""Shared jobfile and testcase boilerplate for verify/ scenarios (ADR 0009).

Every scenario under verify/ follows the same shape (verify/README.md,
"Adding a scenario"): a jobfile.py that loads the generated testbed and
hands it to verify.py's AEtest job, and a verify.py whose CommonSetup
connects to every device and whose CommonCleanup disconnects from every
device. That shape was being copy-pasted whole into each new scenario;
this module holds it once, so a new scenario adds only its own testcases
and an os filter, not a second copy of the connect/disconnect/load dance.
"""
from __future__ import annotations

import os
from typing import Any, Iterator

from genie.testbed import load
from pyats import aetest
from pyats.easypy import run
from pyats.topology import Device, Testbed


def scenario_main(runtime: Any, jobfile_path: str) -> None:
    """Entry point every scenario's jobfile.py calls, as
    scenario_main(runtime, __file__).

    The scenario name is read from the directory jobfile_path lives in,
    never repeated as a literal: a scenario directory rename used to
    silently break the testbed lookup instead of failing loudly, since
    each jobfile hardcoded its own scenario's file name. Deriving it here
    once removes that trap for every scenario at once. genie.testbed.load,
    not the plain pyats topology loader, so every device carries the
    .parse() method Genie adds (ADR 0009: Genie parsers, not regex).
    """
    scenario_dir = os.path.dirname(os.path.abspath(jobfile_path))
    verify_dir = os.path.dirname(scenario_dir)
    scenario = os.path.basename(scenario_dir)
    testbed_file = os.path.join(verify_dir, ".testbed", f"{scenario}.yaml")
    testscript = os.path.join(scenario_dir, "verify.py")
    testbed = load(testbed_file)
    run(testscript=testscript, runtime=runtime, testbed=testbed)


def devices_with_os(testbed: Testbed, os_name: str) -> Iterator[Device]:
    """Yield only the devices CML's generated testbed tags with the given
    os string ("nxos", "iosxe", ...). If CML ever tags a platform
    differently, this is the one place to adjust for every scenario."""
    for device in testbed.devices.values():
        if getattr(device, "os", "") == os_name:
            yield device


class CommonSetup(aetest.CommonSetup):
    """Connect to every device in the generated testbed."""

    @aetest.subsection
    def connect_to_devices(self, testbed: Testbed) -> None:
        for device in testbed.devices.values():
            # log_stdout False keeps easypy's own report readable. connect()
            # raises on failure, which fails this subsection and skips the
            # testcases below rather than running them against a
            # half-connected lab.
            device.connect(log_stdout=False)


class CommonCleanup(aetest.CommonCleanup):
    """Disconnect from every device in the generated testbed."""

    @aetest.subsection
    def disconnect_from_devices(self, testbed: Testbed) -> None:
        for device in testbed.devices.values():
            if device.connected:
                device.disconnect()
