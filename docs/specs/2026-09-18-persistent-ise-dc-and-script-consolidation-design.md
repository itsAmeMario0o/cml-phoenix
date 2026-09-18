# Persistent ISE and directory, and one command to start

Status: draft, approved in conversation on 2026-09-18, not yet built.

## What this changes

Today every session rebuilds three things: the CML VM, the domain
controller, and ISE. The CML rebuild takes twenty minutes and works. The
other two take an hour and a half between them, need a portal form and a
first login by hand, and then need the join, the groups, and the switch's
network device put back by hand. The start on 2026-09-18 took about two
hours and ten separate touches, listed in `docs/STATUS.md`.

After this change only CML rebuilds per session. The domain controller and
ISE are built once, stopped and deallocated between sessions, and started
again at the next one. Deallocated means the compute is not billed and the
disk keeps everything: the forest, the CA, the identities, ISE's join, its
certificates, and its policy. They are deleted only when the operator
chooses to, for example when ISE's 90 day evaluation runs out.

The start becomes three commands and no form:

    scripts/20-up.sh        # CML, tunnels, rescan, cloudflared, reimport, users
    scripts/24-ad-up.sh     # starts dc1 if it exists, builds it if not
    scripts/25-ise-up.sh    # starts ise1 if it exists; otherwise the portal, then the rest

and the stop:

    scripts/40-down.sh      # export, deregister, destroy CML
    scripts/45-ise-down.sh  # deallocate ise1 (--destroy to delete)
    scripts/46-ad-down.sh   # deallocate dc1 (--destroy to delete)

## Why

Two reasons, and they are the operator's own words from the brainstorm:
come back to a working lab, and be able to rerun any step after a failure.

The waiting and the touches all sit on the two servers that do not need to
be rebuilt to be useful. Nothing on them depends on the CML VM's identity:
the CML public address is static, the route for the lab range lives in the
persistent root, and ISE's network devices are lab addresses. So CML can
keep being disposable underneath them.

Rerunnable was already the pattern (create if missing, skip if present);
`24-ad-up.sh` proved it on 2026-09-18 by resuming at the CA step after a
fix. This design keeps that pattern and adds no state file. A script that
can be rerun is the resume.

## ISE: 300 GB on Standard SSD

Cisco's Azure guide allows 300 to 2400 GB on Premium SSD, Standard SSD, or
Standard HDD, and `Standard_D8s_v4` is the smallest instance ISE 3.5
supports (`Standard_D4s_v4` was dropped in 3.5). Compute costs nothing
while deallocated, so the instance stays `D8s_v4`. The disk is what bills
while idle, by tier, and 600 GB rounds up to the 1 TB tier:

| Disk | Tier | Idle per month, East US 2 list |
|---|---|---|
| 600 GB Premium SSD (deployed 2026-09-18) | P30 | $123 |
| 300 GB Standard SSD (this design) | E20 | $38 |

A managed disk cannot shrink, so the current ISE is redeployed once with
Volume Size 300 and Disk Storage Type Standard SSD. That redeploy is the
last time the portal form is filled in until the evaluation expires.
`docs/ISE-AD-BUILD.md (Part 2)`, `docs/BUILD-FROM-SCRATCH.md`, and
`docs/PREREQUISITES.md` change to those two values, and ADR 0008 gains an
amendment recording the lifecycle and the disk decision. The DC's 30 GB
Standard SSD is about $2 a month and stays as it is.

Prices are from Azure's retail price API on 2026-09-18 and should be read
as approximate.

## Scripts: fold the hand steps into the scripts that stop short

Ponytail's reading of the 2026-09-18 start: not too many parts, parts that
end one step early. No orchestrator, no state file, no new script. Each
touch goes into the script it belongs to.

| Touch on 2026-09-18 | Goes into | How |
|---|---|---|
| External connector rescan | `20-up.sh` | one `PUT /api/v0/system/external_connectors` after the API is ready |
| cloudflared reinstall | `20-up.sh` | the token from `cloudflare-tunnel.env` and the sudo password from the persistent outputs, both over stdin, as done by hand on 2026-09-18; skipped with a `[WARN]` when the env file is absent |
| Re-import of the last export | `20-up.sh` | import every YAML in the newest `exports/<stamp>/`, or in blob when the local copy is missing; labs left stopped |
| `70-users.sh` | `20-up.sh` calls it | it is already idempotent |
| Tunnels and smoke test retries | `20-up.sh` | wait for `system_information.ready` on the host before printing done; start the tunnels itself |
| First login password change | `25-ise-up.sh` | a `[FAIL]` on ERS 401 that says "log in once and set the password to ISE_ADMIN_PASSWORD"; the runbook says it before the script |
| Join point, join, groups | `25-ise-up.sh` via `ise_config.py` | the four ERS calls proven on 2026-09-17 and 2026-09-18 (`POST activedirectory`, `PUT .../join`, `PUT .../getGroupsByDomain`, `PUT .../addGroups`), create if missing; `svc-ise`'s password from `ad.env` |
| `sw1` network device and its rule | `ise_config.py` | the NAD list becomes data (`config/ise-nads.csv`, name and address; the shared secret stays in `labs.env`), one rule per NAD |
| `--post-deploy` | deleted | the flag has one mode |

And the lifecycle branch, the only new logic:

- `24-ad-up.sh`: if `dc1` exists and is deallocated, `az vm start`, wait for
  the directory to answer, print the two values, exit. If it exists and
  runs, just the checks. If it does not exist, the build as today.
- `25-ise-up.sh`: the same for `ise1`, with "does not exist" meaning "print
  the portal values and stop; rerun after the deploy".
- `45-ise-down.sh` and `46-ad-down.sh`: `az vm deallocate` by default;
  `--destroy` does what they do today. `40-down.sh` stays as it is.
- `00-preflight.sh` and `90-smoke-test.sh` learn the deallocated state so a
  stopped server is `[OK] deallocated`, not a failure.

The DC's Terraform root stays the way to create `dc1`. It is applied once
and never destroyed unless `--destroy` is asked for. Its local state now
lives across sessions, which ADR 0011 already covers.

## What is deliberately not in this design

- No orchestrator or `up.sh` that calls the three scripts. Three commands
  is fine, and each one being rerunnable matters more than one command.
- No state file. Idempotence is the state.
- No Terraform for ISE. ADR 0008 stands: the Marketplace template fails
  through the API and the portal works. It is now filled in once a quarter.
- No move of the DC or ISE state to blob. It lives for the life of the
  servers, on the operator's Mac, per ADR 0011.
- No Python rewrite. The folded steps are the same bash, calling the same
  `az`, `curl`, and `ssh`, and get the same stub-driven run tests.

## Tests

Every folded step gets a case in the existing stub-driven run tests
(`tests/test_up_run.sh` is new; the others exist): rescan called once after
ready; cloudflared skipped with `[WARN]` when the env file is absent and
installed when present; reimport of a fixture export folder; the start
branch with the `az` stub reporting `VM deallocated`, `VM running`, and
not found; the 401 message; deallocate as the default and destroy behind
the flag. `ise_config.py`'s join calls get fake-server cases in
`tests/test_ise_config.py` following the network-device ones.

## Order of work

1. Redeploy ISE with the 300 GB Standard SSD (portal, by hand, once) and
   deallocate the current one first so both never run together. Delete
   the old ISE after the new one is joined.
2. `45-ise-down.sh` and `46-ad-down.sh`: deallocate by default.
3. `24-ad-up.sh` and `25-ise-up.sh`: the start branch.
4. `ise_config.py`: join, groups, NADs from data; `25-ise-up.sh` calls it.
5. `20-up.sh`: rescan, cloudflared, reimport, users, the ready wait.
6. Docs: the deploy guide, the build guide, ADR 0008 amendment, STATUS.

Each step is its own PR with its tests, and each leaves the lab usable.

## Success

A session starts with three commands and no form, in about thirty
minutes, of which CML is all of it. Any of the three can be rerun after a
failure without undoing the others. Stopping is three commands. The idle
bill for the two servers is about $40 a month. The from-scratch path is
still proven, on the day the evaluation expires.
