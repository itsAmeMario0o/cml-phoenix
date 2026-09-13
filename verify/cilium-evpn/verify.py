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
device in the testbed understands these commands.
"""
from __future__ import annotations

from typing import Any, Iterator

from pyats import aetest
from pyats.topology import Device, Testbed


def _nxos_devices(testbed: Testbed) -> Iterator[Device]:
    """Yield only the NX-OS fabric switches from the testbed.

    This relies on CML's generated testbed tagging the nexus9300v nodes with
    os "nxos". That is confirmed at the Task 7 live run, the same as the Genie
    parser keys below; if CML tags them differently, this filter is where to
    adjust.
    """
    for device in testbed.devices.values():
        if getattr(device, "os", "") == "nxos":
            yield device


class CommonSetup(aetest.CommonSetup):
    """Connect to every device in the generated testbed."""

    @aetest.subsection
    def connect_to_devices(self, testbed: Testbed) -> None:
        for device in testbed.devices.values():
            # log_stdout False keeps easypy's own report readable. connect()
            # raises on failure, which fails this subsection and skips the
            # testcases below rather than running them against a
            # half-connected fabric.
            device.connect(log_stdout=False)


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
    """Every VNI on every NX-OS device is up."""

    @aetest.test
    def check_vnis(self, testbed: Testbed) -> None:
        checked_any = False
        failures: list[str] = []
        for device in _nxos_devices(testbed):
            parsed: dict[str, Any] = device.parse("show nve vni")
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


class CommonCleanup(aetest.CommonCleanup):
    """Disconnect from every device in the generated testbed."""

    @aetest.subsection
    def disconnect_from_devices(self, testbed: Testbed) -> None:
        for device in testbed.devices.values():
            if device.connected:
                device.disconnect()


if __name__ == "__main__":
    aetest.main()
