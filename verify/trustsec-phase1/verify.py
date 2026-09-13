"""AEtest testscript for the TrustSec Phase 1 edge verification (ADR 0009, Task 5).

Checks three things about the routed path proven by
labs/trustsec-phase1.yaml: the ISE RADIUS server is configured and shows as
reachable, a test AAA authentication against it returns Access-Accept, and a
CoA (RFC 3576) request has actually been received by the edge's
dynamic-author client. All three target the C8000v edge, the one CML node in
this topology; br-transit is an external connector, not a device pyATS
connects to.

This is authored now and run later (Task 7), once the TrustSec lab is
actually deployed: ISE up on the apps subnet and the host transit bridge
(br-transit) in place (ADR 0003). Until then there is nothing to connect to,
so the build lane only syntax-checks this file with py_compile; it never
imports pyATS or runs easypy against it here.

ISE-side checks, such as the live authentication log showing a per-device
source, read ISE rather than a CML node, so they belong to the cisco.ise
Ansible layer on the roadmap (item 18), not to this pyATS verification layer
(ADR 0009's scope note on external services).

CommonSetup connects to every device in the testbed that
scripts/80-verify-lab.sh generates fresh from the running lab
(verify/lib/gen_testbed.py, Task 2), the same as the Cilium EVPN
verification (Task 4, verify/cilium-evpn/verify.py). That testbed uses
CML's console connection for every node, so this script needs no
management-plane reachability to the edge either.
"""
from __future__ import annotations

import os
import re
from typing import Iterator

from pyats import aetest
from pyats.topology import Device, Testbed


def _iosxe_devices(testbed: Testbed) -> Iterator[Device]:
    """Yield only the IOS XE edge from the testbed.

    The TrustSec Phase 1 topology (labs/trustsec-phase1.yaml) has one
    routed node, the cat8000v edge, plus the external br-transit connector,
    which is not a device pyATS connects to. This relies on CML's generated
    testbed tagging the cat8000v node with os "iosxe", the same kind of
    assumption the Cilium os:nxos filter carries (see that file's Task 7
    live-verify note, added after the actual filter shipped). If CML tags
    it differently, this filter is where to adjust; the Task 7 live run
    against this lab is what confirms it.
    """
    for device in testbed.devices.values():
        if getattr(device, "os", "") == "iosxe":
            yield device


class CommonSetup(aetest.CommonSetup):
    """Connect to every device in the generated testbed."""

    @aetest.subsection
    def connect_to_devices(self, testbed: Testbed) -> None:
        for device in testbed.devices.values():
            # log_stdout False keeps easypy's own report readable. connect()
            # raises on failure, which fails this subsection and skips the
            # testcases below rather than running them against a
            # half-connected edge.
            device.connect(log_stdout=False)


class RadiusServerReachable(aetest.Testcase):
    """The ISE RADIUS server is configured on the edge and shows as reachable."""

    @aetest.test
    def check_radius_state(self, testbed: Testbed) -> None:
        checked_any = False
        failures: list[str] = []
        # ISE_IP is the same environment variable scripts/60-import-lab.sh
        # reads to fill __ISE_IP__ into labs/trustsec-phase1.yaml
        # (config/labs.env.example, ADR 0006). When it is also exported for
        # this verify run, the check targets that specific server line;
        # otherwise it accepts any RADIUS server line reporting state UP.
        # Either way it is never hardcoded here, per ADR 0004.
        ise_ip = os.environ.get("ISE_IP", "").strip()
        for device in _iosxe_devices(testbed):
            # No Genie schema for "show aaa servers" is confirmed against
            # this pinned release (pyats[full]==26.8, verify/requirements.txt,
            # ADR 0009) and this platform/image (cat8000v-17-18-02), so this
            # reads the raw exec output instead of guessing a parser key
            # path. "RADIUS: id ..., host <addr>, ..." followed by a
            # "State: current UP" (or "current DEAD") line is stable Cisco
            # IOS/IOS XE output for this command across releases; the Task 7
            # live run is what confirms it against this image.
            output = device.execute("show aaa servers")
            for block in output.split("RADIUS: ")[1:]:
                header, _, rest = block.partition("\n")
                if ise_ip and ise_ip not in header:
                    continue
                checked_any = True
                state_line = next((line for line in rest.splitlines() if "State:" in line), "")
                if "current UP" not in state_line:
                    failures.append(
                        f"{device.name} RADIUS server ({header.strip()}): "
                        f"{state_line.strip() or 'no State line found'}"
                    )
        if not checked_any:
            target = f" for ISE_IP={ise_ip}" if ise_ip else ""
            self.failed("no matching RADIUS server entry found in 'show aaa servers' output" + target)
        if failures:
            self.failed("RADIUS server(s) not reachable: " + "; ".join(failures))
        self.passed("RADIUS server(s) reachable (state UP)")


class RadiusAccessAccept(aetest.Testcase):
    """A test AAA authentication against the RADIUS group returns Access-Accept."""

    @aetest.test
    def check_test_aaa(self, testbed: Testbed) -> None:
        username = os.environ.get("TRUSTSEC_TEST_USERNAME", "").strip()
        password = os.environ.get("TRUSTSEC_TEST_PASSWORD", "").strip()
        if not username or not password:
            # A per-run test identity that must already exist in ISE, not a
            # repo secret (ADR 0004): export TRUSTSEC_TEST_USERNAME and
            # TRUSTSEC_TEST_PASSWORD before the Task 7 live run. Never
            # hardcode a credential here or in a tracked env file.
            self.errored("TRUSTSEC_TEST_USERNAME / TRUSTSEC_TEST_PASSWORD are not set")
            return
        checked_any = False
        failures: list[str] = []
        for device in _iosxe_devices(testbed):
            # "test aaa group radius <user> <pass> new-code" is an exec
            # command, not show output, so there is no Genie parser for it.
            # "radius" here is IOS's built-in server-group keyword (every
            # configured RADIUS server), not the named "ISE-GROUP" method
            # list defined in labs/trustsec-phase1.yaml; that is the literal
            # command the brief for this task specifies. Whether IOS XE on
            # this image accepts that keyword or wants "ISE-GROUP" by name
            # instead is confirmed at the Task 7 live run, and is where to
            # change it if not.
            checked_any = True
            # The test password appears in cleartext in this exec command's
            # console output, which pyATS archives under verify/.archive and
            # the device may log. IOS has no test-aaa form that hides it. Use
            # a throwaway, rotatable ISE test account for TRUSTSEC_TEST_*,
            # never a real user's credential, and treat the archive as
            # sensitive. Confirmed and applied at the Task 7 live run.
            output = device.execute(f"test aaa group radius {username} {password} new-code")
            if "successfully authenticated" not in output.lower():
                failures.append(f"{device.name}: {output.strip()!r}")
        if not checked_any:
            self.failed("no IOS XE edge found to run the test aaa command on")
        if failures:
            self.failed("test aaa did not return Access-Accept: " + "; ".join(failures))
        self.passed("test aaa returned Access-Accept")


class CoAReceived(aetest.Testcase):
    """A CoA request has been received on the edge's dynamic-author (RFC 3576) client."""

    @aetest.test
    def check_coa_counters(self, testbed: Testbed) -> None:
        checked_any = False
        failures: list[str] = []
        for device in _iosxe_devices(testbed):
            # "show aaa server radius dynamic-author" is this task's best
            # known command for the CoA client's counters; the brief itself
            # leaves the exact form open ("show aaa ... dynamic-author").
            # No Genie parser is assumed, only a regex over the counter
            # line reporting requests received. Both the command name and
            # the counter's exact label are confirmed at the Task 7 live
            # run, once ISE has actually sent a CoA to this edge
            # (labs/trustsec-phase1.yaml configures "aaa server radius
            # dynamic-author" as the CoA client).
            output = device.execute("show aaa server radius dynamic-author")
            match = re.search(r"CoA[^\n]*Requests?\s*Received[:\s]+(\d+)", output, re.IGNORECASE)
            if match is None:
                continue
            checked_any = True
            received = int(match.group(1))
            if received <= 0:
                failures.append(f"{device.name}: CoA requests received = {received}")
        if not checked_any:
            self.failed(
                "no CoA request counter found in 'show aaa server radius "
                "dynamic-author' output on any IOS XE edge; the command and "
                "counter label assumed here are unconfirmed (see comment above)"
            )
        if failures:
            self.failed("no CoA received: " + "; ".join(failures))
        self.passed("CoA request received")


class CommonCleanup(aetest.CommonCleanup):
    """Disconnect from every device in the generated testbed."""

    @aetest.subsection
    def disconnect_from_devices(self, testbed: Testbed) -> None:
        for device in testbed.devices.values():
            if device.connected:
                device.disconnect()


if __name__ == "__main__":
    aetest.main()
