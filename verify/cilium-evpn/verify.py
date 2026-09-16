"""AEtest testscript for the Cilium EVPN fabric verification (ADR 0009, Task 4).

Checks two things about the fabric described in labs/cilium-evpn-blank.yaml:
every eBGP EVPN neighbor is Established, and every VNI is up. Both are
Genie-parsed, not regex over raw show output, per ADR 0009.

CommonSetup connects to every device in the testbed that
scripts/80-verify-lab.sh generates fresh from the running lab
(verify/lib/gen_testbed.py, Task 2). That testbed uses CML's console
connection for every node, which is why this script needs no management-
plane reachability to the fabric it is checking.

Devices are nexus9300v spines and leaves (NX-OS). The generated testbed
also carries the kind host and the two Ubuntu endpoints from the lab
topology; those have no BGP or NVE state to check, so both testcases below
filter to devices whose testbed os is nxos rather than assuming every
device in the testbed understands these commands. Within that nxos set,
VnisUp skips any device where "show nve vni" itself does not exist (the
spines, which route-reflect EVPN but never terminate a VTEP), rather than
assuming every nxos device runs NVE too (caught live, Task 7).
"""
from __future__ import annotations

import os
import sys
from typing import Any, Iterator

from genie.metaparser.util.exceptions import InvalidCommandError
from pyats import aetest
from pyats.topology import Device, Testbed

_LIB_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "lib")
if _LIB_DIR not in sys.path:
    sys.path.insert(0, _LIB_DIR)

from scenario import CommonCleanup as _CommonCleanup  # noqa: E402
from scenario import CommonSetup as _CommonSetup  # noqa: E402
from scenario import devices_with_os  # noqa: E402,F401


# AEtest only discovers CommonSetup/CommonCleanup/Testcase subclasses that
# are defined in the testscript's own module; a name merely imported from
# scenario.py is invisible to it, and the job silently skips setup and
# cleanup instead of failing loudly (caught live, Task 7). Re-declaring
# each one here, empty, is enough for discovery to find it.
class CommonSetup(_CommonSetup):
    pass


class CommonCleanup(_CommonCleanup):
    pass


def _nxos_devices(testbed: Testbed) -> Iterator[Device]:
    """The NX-OS fabric switches from the testbed. Relies on CML's
    generated testbed tagging the nexus9300v nodes with os "nxos". That is
    confirmed at the Task 7 live run, the same as the Genie parser keys
    below; if CML tags them differently, verify/lib/scenario.py's
    devices_with_os is where to adjust, for every scenario at once."""
    return devices_with_os(testbed, "nxos")


class BgpEvpnNeighborsEstablished(aetest.Testcase):
    """Every eBGP EVPN neighbor on every NX-OS device is Established."""

    @aetest.test
    def check_neighbors(self, testbed: Testbed) -> None:
        checked_any = False
        failures: list[str] = []
        for device in _nxos_devices(testbed):
            parsed: dict[str, Any] = device.parse("show bgp l2vpn evpn summary")
            # Genie's nxos parser for this command
            # (genie.libs.parser.nxos.show_bgp.ShowBgpL2vpnEvpnSummary) nests
            # each neighbor at instance -> vrf -> address_family -> neighbor,
            # and sets 'state' to the literal string 'established' once the
            # State/PfxRcd column holds a numeric prefix count instead of a
            # BGP state name (Idle, Active, ...). Confirmed by reading the
            # genieparser source pinned by verify/requirements.txt
            # (pyats[full]==26.8, ADR 0009); the live fabric run (Task 7) is
            # the final check against the actual command output on this lab.
            for instance in parsed.get("instance", {}).values():
                for vrf in instance.get("vrf", {}).values():
                    for af_name, af_data in vrf.get("address_family", {}).items():
                        for neighbor_id, neighbor in af_data.get("neighbor", {}).items():
                            checked_any = True
                            state = str(neighbor.get("state", "")).lower()
                            if state != "established":
                                failures.append(
                                    f"{device.name} {af_name} neighbor {neighbor_id}: "
                                    f"state={state!r}"
                                )
        if not checked_any:
            self.failed(
                "no eBGP EVPN neighbors were found in any device's "
                "'show bgp l2vpn evpn summary' output"
            )
        if failures:
            self.failed("neighbors not Established: " + "; ".join(failures))
        self.passed("all eBGP EVPN neighbors Established")


class VnisUp(aetest.Testcase):
    """Every VNI on every NX-OS device that runs NVE (the leaves) is up."""

    @aetest.test
    def check_vnis(self, testbed: Testbed) -> None:
        checked_any = False
        failures: list[str] = []
        for device in _nxos_devices(testbed):
            try:
                parsed: dict[str, Any] = device.parse("show nve vni")
            except InvalidCommandError:
                # Spines never run NVE: they route-reflect the EVPN
                # control plane (BUILD-ORDER.md's "Where spine and leaf
                # actually differ") but never get "feature nv overlay",
                # so "show nve vni" does not exist on them at all, "%
                # Invalid command". Not every NX-OS device in this
                # fabric terminates a VTEP; skip the ones where the
                # command itself is unsupported rather than erroring
                # the whole check (caught live, Task 7).
                continue
            # Genie's nxos parser for this command
            # (genie.libs.parser.nxos.show_vxlan.ShowNveVni) nests each VNI
            # at <nve interface> -> 'vni' -> <vni id> -> 'vni_state', a
            # lowercased string ('up', 'down', ...). Confirmed by reading
            # the genieparser source pinned by verify/requirements.txt
            # (pyats[full]==26.8, ADR 0009); the live fabric run (Task 7) is
            # the final check against the actual command output on this lab.
            for nve_name, nve_data in parsed.items():
                for vni_id, vni_data in nve_data.get("vni", {}).items():
                    checked_any = True
                    state = str(vni_data.get("vni_state", "")).lower()
                    if state != "up":
                        failures.append(f"{device.name} {nve_name} vni {vni_id}: state={state!r}")
        if not checked_any:
            self.failed("no VNIs were found in any device's 'show nve vni' output")
        if failures:
            self.failed("VNIs not up: " + "; ".join(failures))
        self.passed("all VNIs up")


if __name__ == "__main__":
    aetest.main()
