# 0012: CML API calls ride the SSH forward, not the public address

Status: accepted, 2026-09-17

## Context

Since the first build, `scripts/20-up.sh` has written `CML_VERIFY_SSL=false`
into `config/mcp-env/cml.env` next to `CML_URL=https://<public ip>`. Every
script that logs in to the controller then sent the admin password to that
public address with certificate checks off: `scripts/lib/users.py`,
`verify/lib/gen_testbed.py`, `scripts/60-import-lab.sh` (`curl -k`), and
cml-mcp itself, which `scripts/mcp-cml.sh` starts with the same file.
`scripts/lib/common.sh` and `scripts/90-smoke-test.sh` also polled the
public address with `curl -sk` for readiness, which carries no secret but is
the same unverified leg.

The controller's certificate is self-signed and CML regenerates it on a
timer (`docs/ACCESS.md`), so there is nothing stable to pin. With
verification off, a login is a bearer credential sent to whoever answers
on that IP and port. The NSG restricts which source addresses may connect.
It says nothing about who sits between the Mac and Azure, a VPN exit or a
hotel network for instance. The architecture review of 2026-09-17
listed this as item 15 and noted that no ADR had recorded the tradeoff.

ISE already does this differently. `scripts/25-ise-up.sh` opens a local SSH
forward through the CML host to ISE's private address and points
`scripts/lib/ise_config.py` at `https://127.0.0.1:<port>` through
`ISE_API_BASE`. Verification is off there too, and the docstring says why:
the internet leg is the SSH session, whose host key is pinned in
`keys/known_hosts` (`CML_SSH_OPTS` in `common.sh`, accept-new, forgotten by
`20-up.sh` before each rebuild). The unverified TLS leg is loopback to
loopback. The CML controller sits on the very host that jump goes through,
and its API is nginx on the host's own 443, so the same shape costs one
more line in `config/tunnels.conf`.

## Decision

Every script and the MCP server reach the controller through a forward
named `cml` in `config/tunnels.conf`, `cml 9443 127.0.0.1 443`, started by
`scripts/50-tunnels.sh up` alongside the others. `20-up.sh` writes two
addresses into `cml.env`: `CML_URL`, the public address, for the browser
and for humans, and `CML_API_BASE=https://127.0.0.1:9443`, which is the only
one any code dials.

`load_cml_env` in `common.sh` enforces it. `CML_API_BASE` must be present,
must match `http(s)://127.0.0.1:<port>`, and that port must be listening on
the Mac, or the caller dies with a `[FAIL]` naming `scripts/50-tunnels.sh
up`. There is no fallback to `CML_URL`. `users.py` and `gen_testbed.py`
read `CML_API_BASE` and nothing else. `mcp-cml.sh` sources the same
function and hands cml-mcp `CML_API_BASE` under the name it expects,
`CML_URL`. `60-import-lab.sh` curls `CML_API_BASE`. `50-tunnels.sh up`
refuses a conf with no `cml` line, so an operator with a file from before
this ADR is told which line to add rather than which command to rerun.

The readiness poll moved onto the host. `cml_api_ready` now runs
`curl -sk https://127.0.0.1/api/v0/system_information` over `cml_ssh`, so
the `-k` applies to the host's own loopback and the internet leg is the
pinned SSH session. `90-smoke-test.sh` uses that helper, gains a check that
the forward listens, and lists it before the cml-mcp check so the failure
reads as "run 50-tunnels.sh up" and not as a stack trace from mcp_call.py.

`CML_VERIFY_SSL=false` stays, with its meaning narrowed: it now applies to
the forwarded loopback URL only. It stays off on that leg on purpose. The
URL names `127.0.0.1` and the certificate names the controller, so
hostname verification would fail whatever the certificate said. Fetching
the certificate after each build and pinning its fingerprint would fix
that, and was considered below. It adds a step to every rebuild, and CML's
periodic regeneration would break the pin at an unpredictable time. The SSH
host key already gives the property a pin would give, on the one hop that
crosses the internet.

## Consequences

- `scripts/50-tunnels.sh up` comes before any script that logs in to the
  controller, and before Claude Code starts cml-mcp. `20-up.sh` prints it
  as the next step. A script run without the forward fails before its
  first request, with the command to run.
- The local port lives in two places, `config/tunnels.conf` and `cml.env`.
  If they disagree, `load_cml_env` reports the forward as down. Change both
  or neither.
- The GUI in a browser still goes to the public address over the
  self-signed certificate, and the operator still clicks through. Nothing
  about that changed; `docs/ACCESS.md` describes the Cloudflare front door
  for anyone who wants a real certificate there.
- What remains unverified: the loopback leg of every API call, the loopback
  poll on the host, and one real gap, the fork's own `cml2` provider in
  `vendor/cloud-cml/main.tf`. During `20-up.sh` it logs in to the public
  address as admin with `skip_verify = true` so its readiness module can
  read `system_information`. That is the same exposure this ADR closes for
  the scripts, once per build, in a file this repo does not edit without a
  human deciding to. It is named here so the fork's next patch can take it
  up; the forward cannot help there because the host does not exist yet
  when the provider is configured.
- The ISE forward keeps its own short-lived shape in `25-ise-up.sh`. Two
  patterns for one idea is a small cost; folding ISE into `tunnels.conf`
  would make `25-ise-up.sh` depend on a file the operator edits by hand.
- `tests/run.sh` proves the wiring against a fake API on a loopback port:
  the public `CML_URL` in every test fixture is a dead TEST-NET address, so
  any code that still dialled it would hang and fail.

## Options considered

1. Leave it, with an ADR that says the NSG is enough. Rejected. The NSG
   decides who may connect, not who is on the path, and the same password
   opens every lab and every user account on the controller.
2. Fetch the controller's certificate after each build and pin its
   fingerprint in `cml.env`. Rejected for now. It works, but it is a new
   moving part on every rebuild, the hostname mismatch on `127.0.0.1` means
   the pin would have to replace hostname checking rather than add to it,
   and CML's timed regeneration would invalidate it mid-session.
3. One long-lived forward in `config/tunnels.conf`, with `CML_API_BASE`
   enforced by `load_cml_env`. Chosen. It reuses `50-tunnels.sh` as it
   stands, gives cml-mcp a stable address that survives the whole session,
   and the enforcement sits in the one function every script already calls.
4. Each script opens its own short-lived forward, as `25-ise-up.sh` does.
   Rejected for CML. cml-mcp runs for hours and cannot own a forward, and
   a forward per script would copy the same two dozen lines into each.
