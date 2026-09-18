# Lessons learned

Each entry records a symptom, its cause, and the fix. Add one as soon as
something bites, while the fix is still fresh. The earliest entries came
out of the design phase and the build's code reviews, before anything ran
in Azure, which is the cheapest place to learn them.

## SSH to the CML host on port 22 gives a console menu, not a shell

- Symptom: `ssh sysadmin@host` connects but shows the CML console server.
- Cause: on a CML host, port 22 is the breakout console server. The system
  shell listens on 1122.
- Fix: every script uses `-p 1122`. cloud-cml's own `del.sh` hint says so.

## Image copy fails partway with an authentication error

- Symptom: cloud-init log shows azcopy 403 midway through the refplat copy.
- Cause: the SAS token cloud-cml builds at plan time expires. Upstream gives
  one hour.
- Fix: fork patch 6, `azure.sas_validity`, default 4h. Preflight estimates
  the copy time and warns. Keep `config/refplat.txt` small.

## A large file in the repo folder becomes unreadable

- Symptom: `hdiutil attach` or `azcopy` fails on the ISO with a short read.
- Cause: the repo lives under OneDrive, which can replace a synced file with
  an on-demand placeholder.
- Fix: right-click the file in Finder, choose "Always Keep on This Device".
  `software/README.md` says the same.

## terraform init selects azurerm 5.x and validate breaks

- Symptom: unknown argument errors in the fork or a root after a fresh init.
- Cause: upstream's `>= 3.82.0` bound. azurerm 5.0 shipped in 2026.
- Fix: `~> 4.0` in all four roots, `terraform/ad` included since ADR 0010
  (fork patch 0 for the CML root). Root lock files are committed.

## First boot copies every image again even though /data has them

- Symptom: second build takes as long as the first.
- Cause: a symlinked images directory looks empty to `find` in cml.sh, and
  the disk attachment races cloud-init.
- Fix: `05-persist.sh pre` waits for LUN 0, bind-mounts, and empties the
  image list. See plan deviations 1 to 3.

## `terraform output -raw` on an empty state prints "No outputs found" and exits 0

- Symptom: a helper reading a Terraform output got a multi-line warning as
  its value and carried on as if it were a real string.
- Cause: `terraform output -raw <name>` against a state with no outputs
  prints "No outputs found" to stdout and exits 0, so a caller checking only
  the exit code never notices.
- Fix: `tf_out` now uses `output -json` and parses it, returning 1 when the
  named output is absent.

## A chained JMESPath filter on the quota query silently returns nothing

- Symptom: the quota check reported the VM size as not found even though it
  was right there in the raw `az` output.
- Cause: `[?a].b[?c]` does not flatten between the two filters, so the
  second `[?c]` is applied to a list of lists and never matches.
- Fix: the quota query pipes the first filter's result to `[0]` before
  applying the second, so it operates on the object, not the wrapping list.

## Teardown let a registered license through on the retry path

- Symptom: in review, the teardown's license check would have let a still
  registered license through and destroyed the VM anyway. Nobody got bitten
  by this one; a reviewer traced it before the first run.
- Cause: the retry path captured two lines of check output instead of one,
  and the blocking logic only matched a single-line `NOT_REGISTERED`.
- Fix: `license_blocked` now blocks anything but a confirmed single-line
  `NOT_REGISTERED`, including `UNKNOWN`, so an ambiguous or multi-line result
  stops the teardown instead of passing it.

## Unquoted secrets in the rendered YAML broke parsing on certain values

- Symptom: the rendered CML config YAML failed to parse or silently
  truncated a value for some secrets.
- Cause: the three `raw_secret` values were interpolated unquoted, so a
  value containing YAML-significant characters changed the document
  structure instead of staying a scalar string.
- Fix: the three `raw_secret` values are now double-quoted in the template
  and validated after render.

## First boot raced mkfs against mount-by-label

- Symptom: mounting the data disk by label right after formatting it can
  fail on first boot and succeed on a retry.
- Cause: mounting by label right after `mkfs` can run before the kernel's
  udev database has registered the new filesystem's label, so the label
  does not resolve yet.
- Fix: the hook calls `udevadm settle` after `mkfs` and before the
  mount-by-label step.

## License registration status string is unverified

- Symptom: the smoke test may fail on a healthy build.
- Cause: the exact `registration.status` value a real CML controller reports
  once licensed had never been observed; the design assumed `REGISTERED`.
- Fix: seen on 2026-09-05 on a real 2.10 controller: `COMPLETED`. The smoke
  test accepts it, and the remote library's deregister now treats
  `COMPLETED` as still licensed too. What a controller reports after a
  successful deregister is still unobserved; the down script gates on
  `NOT_REGISTERED` and the first teardown will confirm or correct that.

## The v5 family quota could not be raised above zero

- Symptom: every quota request for `Standard EDSv5 Family vCPUs` in eastus2
  came back "unsuccessful" from the portal's automatic approver, at 64 and
  at 32, while the regional total was approved on the spot.
- Cause: the subscription had every v5 family capped at zero in every
  region checked, and newer families defaulted to 10. The automatic
  approver will not lift a family from zero.
- Fix: moved the default size to `Standard_E16ds_v6`, whose family started
  at 10 and was approved to 64. That meant teaching the persistence hook
  to find the data disk on the NVMe link as well as the SCSI one. ADR 0005.

## The persistent apply died on the storage account with a 409

- Symptom: `terraform apply` on the persistent root created 15 of 19
  resources, then failed on the storage account with
  `StorageAccountOperationInProgress: An operation is currently performing
  on this storage account that requires exclusive access`. The account
  existed in Azure a moment later, state Succeeded, but not in Terraform
  state.
- Cause: Azure accepted the create and the azurerm provider's immediate
  follow-up call hit the account while Azure still held its provisioning
  lock. The provider treats the 409 as a failed create, so the resource
  never lands in state, and a re-run would refuse with "already exists".
- Fix: `terraform import azurerm_storage_account.lab <id>` (a human runs
  it, per CLAUDE.md), then plan, which showed only the three resources that
  never ran, then apply. The random suffix was already in state, so the
  name matched. Total cost: five minutes.

## The upload script stopped after the first image and reported success

- Symptom: `10-upload-images.sh` printed 11 OK and exited 0, but the blob
  container held the package, alpine, and nothing else. Preflight then
  failed on eight missing blobs.
- Cause: the upload loop is `while read ... done < refplat.txt`, and azcopy
  reads standard input. The first azcopy call inherited the loop's stdin
  and consumed the rest of the file, so the loop ended after one image.
  The dry run never hit it because the echo stand-in ignores stdin, and
  the dry-run tests were the only tests.
- Fix: `</dev/null` on both azcopy calls inside the loop, and a real-mode
  test with a stub azcopy that drains stdin, asserting five calls for two
  images. Any command run inside a `while read` loop over a file needs the
  same redirect unless it is known not to touch stdin.

## SSH to the host times out while the web UI and the API work fine

- Symptom: after the first real build on 2026-09-05, `https://<ip>` answered
  and Terraform's readiness check passed, but every SSH check in the smoke
  test failed. Ports 22, 1122, and 9090 timed out from the Mac. The host
  was listening on 1122, firewalld allowed it, and sshd logged no
  connection attempts at all, so the drop was at the NSG.
- Cause: the Mac was on Cisco Secure Client. That VPN splits traffic three
  ways and each way shows Azure a different address. Ports 80 and 443 go
  through the Umbrella web gateway and arrive from one address, which is
  the only one `curl -4 ifconfig.me` can ever report, because it is a web
  request. DNS goes through the Umbrella agent straight from the Mac and
  shows the home address, so `dig myip.opendns.com` measures nothing
  useful. Everything else, SSH included, rides the AnyConnect tunnel to a
  headend in AWS and leaves from a pool of exit addresses inside the
  operator's VPN exit range that changes per connection. Four different addresses
  turned up in one afternoon. The allow-lists had only the web gateway
  address, so the browser got in and SSH did not. With the VPN off there
  is a single home address and none of this happens.
- Fix: for VPN use, the allow-lists carry the whole exit block, the
  operator's VPN exit range, plus the home address as a /32. A single /32 from
  the pool breaks on the next connection. The only reliable way to see
  which address SSH arrives from is to let one connection through and
  read `$SSH_CONNECTION` on the host, or the sshd journal. Decide before
  the build whether the lab must be reachable from the VPN, for example to
  pair it with VPN-only resources, and fill the lists accordingly. If the
  VPN is off, the home /32 alone is enough.

## tests/run.sh hangs forever in the upload test

- Symptom: `tests/run.sh` never returns. `ps` shows the stub azcopy from
  `tests/test_upload_dry_run.sh` sitting in `cat` for as long as you leave it.
- Cause: the stub azcopy drains stdin, the way the real one can. Yesterday's
  fix redirected stdin for the two calls inside the image loop but not for
  the package copy above it, so that call inherited the caller's stdin. From
  a terminal that is a tty and nobody notices. From Claude Code, or any
  runner that keeps stdin open and idle, `cat` waits forever.
- Fix: the package copy gets `</dev/null` like the other two. Anything that
  runs azcopy should never inherit stdin.

## Small things the first build taught, none of them fatal

- The NSG belongs to the disposable root. It is created by the fork with
  the VM and destroyed with it. A rule patched by hand with `az network
  nsg rule update` lasts until the next `40-down.sh` and no longer. The
  tfvars allow-lists are the only thing that survives, so change them
  first and treat the CLI patch as a bridge.
- The allow-lists also live inside the VM's cloud-init data, so changing
  them in Terraform replaces the VM. Do not try to fix access with a
  fork apply on a running host. The fork's plan will show "must be
  replaced" until the next rebuild renders the new lists. That is expected.
- The public IP is meant to be permanent. It is a static Standard SKU
  address in the persistent root, so DNS records and the MCP env file stay
  valid across rebuilds. Teardown never touches it. It costs about four
  dollars a month while idle. A dynamic address would mean editing DNS
  after every build, which is the thing the persistent root exists to
  avoid.
- `/data/images` is owned by `virl2` with mode 0711. `sysadmin` can pass
  through it but cannot list it. Count files in the two 0755 directories
  below it instead.
- First runs of `uvx cml-mcp` install 73 packages. On a Mac short of
  memory that alone blew the 60 second MCP check. The second run is fast.
- `git show` and `git log -p` open a pager. From an agent shell that pager
  waits forever on a terminal that is never coming. Use `--no-pager`.

## After a rebuild every script that uses SSH fails with a changed host key

- Symptom: the first teardown and rebuild on 2026-09-05 came up healthy,
  but the smoke test lost every SSH check and a plain `ssh` printed the
  "remote host identification has changed" banner.
- Cause: a rebuilt controller generates new SSH host keys. The scripts
  used `StrictHostKeyChecking=accept-new` against `~/.ssh/known_hosts`,
  which trusts an unknown host but refuses a changed one. That is the
  right instinct and the wrong file: the entry from the previous VM sat
  there under the same address and port.
- Fix: every SSH and SCP call shares `CML_SSH_OPTS` from `common.sh`,
  which points at `keys/known_hosts`, gitignored beside the key pair.
  `20-up.sh` runs `ssh-keygen -R` on that file before the CML apply, so
  the first contact after a build pins the new key. Your own
  `~/.ssh/known_hosts` still holds the old entry; clear it with
  `ssh-keygen -R '[<ip>]:1122'` before you ssh by hand. Persisting the
  host keys on the data disk would keep one identity across rebuilds and
  is a fork patch for another day.

## The rebuild keeps the images, but a new image never arrives

- Symptom: `nxosv9000` was added to `config/refplat.txt` and uploaded
  before the rebuild. The new host had the node definition and not the
  image. The persistence log said "reusing 15 image files, emptying
  refplat image list".
- Cause: the fork's persistence hook is all or nothing. If the data disk
  holds any images it empties the whole copy list, so cloud-cml copies
  nothing. Definitions are a separate list and still copied, which is
  why the yaml arrived alone.
- Fix: the hook now drops only the images whose directory already exists
  under `/data/images` and leaves the rest on the list for cloud-cml to
  copy. It logs how many were there and which ones it is fetching.
  Proven on 2026-09-07 with five new images at once. The log read
  "reusing 16 image files, 5 of 10 listed images already there,
  copying:" followed by the five names, and the post phase counted 30.

## NVMe device names move between boots

- Symptom: `/data` was `/dev/nvme0n2p1` on one boot and `/dev/nvme0n1p1`
  on the next, on the same VM size with the same disk.
- Cause: on v6 sizes the OS disk and the data disk both attach over NVMe
  and the kernel numbers them in the order they answer.
- Fix: nothing to do. The hook mounts through `/dev/disk/azure/data/by-lun/0`,
  which followed the disk both times. Never hardcode an `nvme` path.

## The smoke test fails five checks straight after a build

- Symptom: `90-smoke-test.sh` run right after `20-up.sh` reported the API
  not ready, the license UNREACHABLE, `/data` not mounted, no bind mount,
  and cml-mcp getting a Bad gateway, while the same run counted 30 image
  files on `/data`. Seen 2026-09-10.
- Cause: the host reboots once at the end of the install, after the
  readiness module has already seen the API answer. `uptime` on the host
  read zero minutes. The smoke test landed in the middle of that reboot,
  and the checks that need the controller or a fresh SSH session failed
  while the one that read the disk got through.
- Fix: nothing to repair. Wait until `/api/v0/system_information` says
  `ready: true` again, about a minute after the build prints its URL,
  and rerun. The second run read ten of ten.

## cml-mcp cannot set lab permissions, the API can

- Symptom: `set_cml_lab_permissions` in cml-mcp 0.31.2 answered
  `'str' object has no attribute 'match'` and changed nothing, with a
  well-formed lab id, user id, and `LAB_EDIT`/`LAB_EXEC` list. Seen
  2026-09-10.
- Cause: a bug in the tool's own validation, before any request reaches
  the controller. Nothing on the CML side.
- Fix: talk to the controller directly. `PATCH /api/v0/labs/<id>/associations`
  with `{"groups": [], "users": [{"id": "<user id>", "permissions":
  ["lab_edit", "lab_exec"]}]}`. Two details: the method is PATCH, since
  PUT answers 405, and the permission names are lowercase on 2.10 even
  though the tool's help spells them in capitals. A GET on the same path
  reads them back. Listing users through cml-mcp still works.

## cml-mcp says pyATS is required, then logs in to the switch as cisco

- Symptom: `send_cli_command` answered "PyATS and Genie are required to
  send commands to running devices" on a booted Nexus. Seen 2026-09-10.
- Cause: the plain `cml-mcp` package has no pyATS. The `cml-mcp[pyats]`
  extra carries it, which `docs/design-notes.md` had named from the
  start and the wrapper never used. A second trap sits behind the
  first: the tool logs in to every device as `PYATS_USERNAME` and
  `PYATS_PASSWORD`, cisco and cisco when unset, which no topology in
  `labs/` uses.
- Fix: `scripts/mcp-cml.sh` runs `uvx "cml-mcp[pyats]"` and, when
  `config/mcp-env/labs.env` exists, exports admin and the lab password
  for the tool. Proven the same day: six switch configs of 113 to 158
  lines each went in through the tool in about 30 seconds apiece, with
  no rejected lines, and the fabric came up.

## A new image can reach the controller without a rebuild

- Symptom: FTDv was in blob and on `config/refplat.txt`, but the
  persistence hook only copies images at build time, and a rebuild
  would have thrown away the running Cilium fabric's switch state.
- Cause: the kit's image path was designed around cloud-init. Nothing
  in it covers adding an image to a live controller.
- Fix: the controller has a dropfolder and an API for exactly this.
  From the Mac, a user-delegation read SAS for the one blob, handed on
  stdin to an SSH session on the host, where `azcopy` (already there
  from cloud-cml) pulls the 1.6 GB in two seconds inside Azure. Move
  the file into `/var/local/virl2/dropfolder` owned `www-data:virl2`
  mode 660, then `POST /api/v0/node_definitions` and
  `POST /api/v0/image_definitions` with the two YAML files as raw
  bodies and no content type. The controller moves the qcow2 into
  `/data/images/virl-base-images/<id>/` itself, so the next rebuild's
  hook finds the directory and skips it. Done 2026-09-10 in under a
  minute. Roadmap item 10 should absorb this as the normal path.

## The live image add needs no sudo: the controller has an upload API

- Symptom: repeating the FTDv live add for the two Catalyst 9000v images
  on 2026-09-16, the `install` into `/var/local/virl2/dropfolder` asked
  for sysadmin's sudo password, which a non-interactive SSH session
  cannot answer. The dropfolder is `www-data:virl2` mode 2770 and
  sysadmin is in neither group.
- Cause: the dropfolder is meant to be fed by the controller itself.
  `POST /api/v0/images/upload` takes the file as the request body with
  `X-Original-File-Name` and `X-File-Name` headers and writes it into
  the dropfolder as the right owner. Run from the host against
  `https://127.0.0.1` the 2.5 GB copy takes seconds.
- Fix: pull the blob onto the host with azcopy as before, then
  `curl -X POST -T /tmp/<file> https://127.0.0.1/api/v0/images/upload`
  with the two headers and the bearer token, then `POST
  /node_definitions` and `POST /image_definitions` as before. Two traps
  on the way: `curl --data-binary @file` reads the whole file into
  memory and dies with "out of memory" on a 2.5 GB image, so stream it
  with `-T`; and both Cat9000v image definitions name the same qcow2
  file, so upload it once per image definition, since the controller
  moves the file out of the dropfolder on each register. Both images
  landed under `/data/images/virl-base-images/` owned `libvirt-qemu:virl2`,
  where the persist hook finds them at the next rebuild.

## An Ubuntu LACP bond to a vPC never comes up in CML

- Symptom: the Nexus pair reported Ethernet1/12 "suspended (no LACP
  PDUs)" and vPC 20 down, while the host showed bond0 up and both
  members UP with LOWER_UP. Pings to the HSRP gateway failed. Seen
  2026-09-10 on the FTDv cluster lab's inside host.
- Cause: virtio interfaces report speed and duplex as unknown. The
  Linux 802.3ad bonding driver will not put a member with unknown
  speed into an aggregator, so it never sends an LACP PDU. The bond
  file gave it away: `Speed: Unknown`, `MII Status: down` per member,
  a different aggregator ID on each.
- Fix: `ethtool -s ens2 speed 1000 duplex full` on each member. The
  bond bundled within seconds and the gateway answered. The topology
  now pins the speed in cloud-init and in a oneshot unit for later
  boots. The source Cilium lab's endpoint config had the same line,
  which is where the answer came from.

## A custom Linux image boots but its console stays empty

- Symptom: the Kali node went to BOOTED and its console log had zero
  lines. cml-mcp could not log in; nothing answered on the serial
  port. Seen 2026-09-11 with Kali 2026.2 from the official QEMU image.
- Cause: desktop-oriented images have no getty on ttyS0 and no
  `console=ttyS0` on the kernel line. CML marks such a node booted
  when its boot timeout expires, not because it saw a prompt.
- Fix: edit the base qcow2 once on the host with `qemu-nbd`: mount the
  root partition, symlink `serial-getty@ttyS0.service` into
  `getty.target.wants`, and append `console=tty0 console=ttyS0,115200`
  to the kernel lines in `/boot/grub/grub.cfg` and to
  `GRUB_CMDLINE_LINUX_DEFAULT`. Stop and wipe the node first, since
  its overlay points at the base. Add `video: memory: 16` to the node
  definition so the CML UI also offers VNC, which is the natural way
  to use a desktop image. Both changes are in
  `config/node-definitions/kali.yaml` and the blob library copy.

## sudo over SSH swallowed the script as its password

- Symptom: `sudo: 3 incorrect password attempts` from a one-shot SSH
  session that fed the sysadmin password on stdin and then ran a
  script through a heredoc.
- Cause: the heredoc replaced stdin, so sudo read the first script
  line as the password.
- Fix: scp the script, cache the credential with
  `printf '%s\n' "$P" | sudo -S -p "" true`, then `sudo -n bash script`.

## The FTDv nodes never register with cdFMC: 8305 is refused

- Symptom: both firewalls showed the tenant host as manager and
  Registration Pending for an hour. Seen 2026-09-11.
- Cause, as far as it is known: the tenant host resolves to one
  address, which answers on 443 with the tenant's certificate and
  sends a TCP reset on 8305. That is true from the firewalls, from
  the CML host, and from the operator's Mac, so it is not the Azure
  NSG or the NAT. Cisco's cdFMC troubleshooting page says the cloud
  will not answer 8305 unless the device record is in an onboarding
  state; the records were in that state. A third device in the same
  tenant, onboarded another way, is Online with a manager entry of the
  form `<uuid>DONTRESOLVE:443`.
- What was tried, all from the device side: the generated line with
  the host; `configure network management-port 443`, which the CLI
  refuses below 1025 since it is the device's own listening port; the
  host with a `:443` suffix and `DONTRESOLVE:443`, both "Invalid
  Parameters" on 10.0.0; plain `DONTRESOLVE`, accepted, which leaves
  the device waiting for a manager that never initiates. None
  registered.
- Fix, found by the operator on 2026-09-11: the registration key is
  only live for a short window after Security Cloud Control generates
  it, and the cloud accepts the 8305 handshake only for a device whose
  record is fresh. Generate the key, run `configure manager delete`
  and `configure manager add` at the console within a minute or two,
  and both nodes went to Completed. The reset on 8305 was the cloud
  refusing keys that were hours old, which is what "not in an
  onboarding state" meant. Consequence for the kit: cdFMC values in
  a day-0 rendered at import are stale by the time the node boots, so
  the FTDv day-0 keeps them only as a convenience, and the reliable
  path is registration from the console after boot with keys
  generated at that moment.
- Smaller things learned on the way: `ping system` on the FTD CLI
  runs until interrupted and holds the console; the day-0
  `AdminPassword` must satisfy FTD's complexity rule or the node
  blocks all configuration; `show network` reports the management
  port the device listens on.

## Teardown refused: "export of <id> did not look like a topology"

- Symptom: `40-down.sh` stopped before destroying anything with that
  line for the Cilium lab. Seen 2026-09-11.
- Cause: the export helper accepted a download only if its first line
  was `lab:`. A CML 2.10 export opens with `annotations: []` and
  `smart_annotations: []`, then `nodes:`, and the `lab:` block sits
  near the end. The earlier teardowns passed because their labs were
  small and exported in the older order.
- Fix: the helper now looks for a top-level `lab:` or `nodes:` line
  anywhere in the file. The fake API exports one lab in the 2.10 shape
  so the test covers it. The refusal itself was the right behaviour:
  nothing was destroyed with an export in doubt.

## After a rebuild cml-mcp cannot reach any node console

- Symptom: `send_cli_command` failed on every node with "failed to
  connect via proxy" while the API, the smoke test, and the repo's
  own SSH all worked. Seen 2026-09-11, first console use after a
  rebuild.
- Cause: pyATS reaches consoles through the CML console server on
  port 22 with the Mac's system ssh, which checks `~/.ssh/known_hosts`.
  The rebuilt host has new keys, and the old line for the public IP
  is still there from an earlier manual console session. The repo's
  scripts are immune because they use `keys/known_hosts`, which
  `20-up.sh` clears before each build; the user's own file is not
  touched by anything in the kit.
- Fix: `ssh-keygen -R <the static public IP>` on the Mac, by hand, after every
  rebuild that precedes console work. The kit does not edit files
  outside the repo, so this stays a manual step until cml-mcp can be
  pointed at its own known_hosts.

## A shared user sees no labs until you pass show_all

- Symptom: after 70-users.sh granted a user's group lab_exec on every
  lab, the user authenticated fine but GET /labs returned an empty
  list, which looked like the grant had failed. Seen 2026-09-11.
- Cause: GET /labs defaults to labs the user owns. Shared labs, the
  ones reached through an association, appear only with
  GET /labs?show_all=true. The CML web UI passes show_all, so the
  person sees the labs in the browser; a bare API check does not.
- Fix: nothing to change in the grant. The group association on the
  lab is the right mechanism and it works. When verifying a user's
  access from the API, use show_all=true. Both the group-side write
  (PATCH /groups/{id} associations) and the lab-side write
  (PATCH /labs/{id}/associations groups) set the same underlying
  association; the script uses the group side, one write for all labs.

## terraform hangs or errors on a stale NFS file handle

- Symptom: `terraform fmt`, `validate`, or `init` hangs for several
  minutes with zero CPU use, or fails outright with `read
  .../terraform-provider-<name>: stale NFS file handle`. Seen
  2026-09-15 on `terraform/bootstrap`, `terraform/persistent`, and
  `vendor/cloud-cml` in the same session, at different times.
- Cause: this repo lives under `OneDrive-MarioJRuiz/Projects/`, a
  Files-On-Demand synced folder. The provider binaries cached in each
  root's `.terraform/providers/` are large (the azurerm provider is
  229 MB); OneDrive's virtual filesystem sometimes leaves them as
  cloud-only placeholders even after a prior read pulled them down,
  and a later read against that stale handle fails instead of
  re-fetching. `du` on the file shows 0 blocks despite `ls -la`
  reporting the full size, which confirms a placeholder rather than a
  slow disk.
- Fix: `rm -rf` the affected root's `.terraform` directory and rerun
  `terraform init` (`-backend=false` is enough if only `validate` is
  needed). This only touches the local provider cache, never state,
  so it is safe on `terraform/persistent` too. If the hang shows up
  again on a command that touches no provider at all, such as a bare
  `python3` invocation reading a small tracked file, the cause is
  broader than this one and worth a fresh investigation rather than
  assuming the same fix applies.

## The controller never lists a custom bridge as an external connector

- Symptom: `br-transit` existed on the host at 10.100.0.1/24, but the
  connector rescan (`PUT /api/v0/system/external_connectors`) kept
  listing only `virbr0`, and every lab's `br-transit` connector node
  stayed `DEFINED_ON_CORE` with a null device. Seen 2026-09-16.
- Cause: the low-level driver's scan only admits bridges whose name
  matches `^(bridge|virbr|vlan|local)[0-9]{1,4}$`
  (`simple_drivers/low_level_driver/disk_utils.py`). The name is the
  contract, and `bridge0` is reserved for the system bridge.
- Fix: the transit bridge is `bridge1`. The connector appears as
  "Bridge 1" after a rescan, and a lab connector node whose
  configuration is `bridge1` resolves to it (the key is the device
  name). The tracked topologies and the smoke test use that name now.

## The host forwards nothing from the transit bridge: firewalld

- Symptom: with `bridge1` up and `ip_forward` on, a switch on the
  bridge could ping the host at 10.100.0.1 but a traceroute toward ISE
  ended at hop 2 with `10.100.0.1 !A`, administratively prohibited from
  the host itself. Seen 2026-09-16.
- Cause: CML ships firewalld active (`virl2-initial-setup.py` configures
  it), and firewalld rejects forwarding between interfaces unless a
  policy allows it. A netplan bridge has no such policy.
- Fix: define the transit network as a libvirt network in routed mode
  (`06-transit-bridge.sh`). libvirt creates the bridge, enables
  forwarding, and places it in its `libvirt-routed` zone, whose
  `libvirt-routed-in` and `-out` policies are `ACCEPT` both ways. No
  hand-written firewall rule, and the static route for the rest of
  10.100.0.0/16 lives in the same XML. The `!A` disappeared on the first
  run. One related fact from the same evening: SSH to the Marketplace
  ISE is key-only (`Permission denied (publickey)` for `iseadmin`), so
  an ISE-side capture needs the key the deploy was given, or the GUI.
  This entry first also claimed that a ping from the lab range to ISE
  can never succeed because `ise-nsg` has no ICMP rule. That was wrong,
  and disproved the next day: the pings had failed for the same reason
  RADIUS had, the CML NIC's outbound NSG (see "RADIUS leaves the CML
  host and never reaches ISE"). `ise-nsg`'s own rules are only explicit
  allows; Azure's default AllowVnetInBound still admits the lab range
  on ISE's NIC, ICMP included, and once `lab-transit-out` existed a lab
  switch pinged ISE at once. An NSG's custom allow rules never narrow
  anything by themselves.

## A customize script is shipped to the host and never runs

- Symptom: the first build carrying `06-transit-bridge.sh` copied it to
  `/provision`, and nothing else: no log under `/var/log/provision`, no
  `bridge1`. `05-persist.sh` beside it ran as usual. Seen 2026-09-17.
- Cause: `cml.sh` `postprocess` picks its scripts with
  `grep -E '[0-9]{2}-[[:alnum:]_]+\.sh'`. That class has no hyphen, so a
  name with a second hyphen never matches, and nothing reports the skip.
- Fix: the script is `06-transit.sh`. Name fork customize scripts
  `NN-word.sh` or `NN-two_words.sh`. `tests/test_transit.sh` now asserts
  the name against the same pattern.

## RADIUS leaves the CML host and never reaches ISE

- Symptom: a lab switch's Access-Request showed on `bridge1` and again on
  `eth0 Out` in a host tcpdump, and nothing ever came back. A RADIUS
  filtered `tech dumptcp` on ISE's own interface saw zero packets while
  the switch was sending. Host firewall, UDR, ISE's NSG, and both NAD
  entries all checked out. Two sessions, 2026-09-16 and 09-17.
- Cause: the `VirtualNetwork` service tag expands per NIC from that NIC's
  effective routes (`az network nic list-effective-nsg`, `tagMap`). Only
  `snet-apps` has the UDR for 10.100.0.0/16, so ISE's NIC counts the lab
  range as VirtualNetwork and the CML NIC does not. A forwarded packet
  sourced from 10.100.0.3 matched neither `AllowVnetOutBound` nor
  `AllowInternetOutBound` on the CML NIC, and `DenyAllOutBound` dropped
  it silently. `test-ip-flow` cannot model this; it refuses a local IP
  that is not the NIC's own.
- Fix: `lab-transit-out` on the CML NSG, outbound, 10.100.0.0/16 to the
  apps subnet, the mirror of `lab-transit-in`. It is in the fork's
  `azure/main.tf` for every build from now on. The first reply arrived
  400 ms after the rule did. The rule was added by hand to the running
  NSG that day, so it is absent from that root's Terraform state; the
  next teardown removes the NSG and the next build owns the rule.

## A link made through the CML API carries nothing: the interface is STOPPED

- Symptom: a node and a link were added to a running lab through the API
  (`POST /labs/<id>/nodes`, `POST /labs/<id>/links`). The link reported
  `STARTED`, both nodes showed the port up/up, the new node's frames
  appeared in a link capture, and the existing switch's port showed 0
  packets input and none of its own frames on the wire. A full restart
  of the switch changed nothing. Seen 2026-09-17, an hour spent on it
  while testing 802.1X.
- Cause: the API wires the link but leaves the interface on the already
  running node in state `STOPPED`. The UI starts it for you; the API does
  not, and a node stop and start does not either. Guest operating systems
  cannot see this: the virtual Catalyst reports the port connected
  regardless.
- Fix: `PUT /api/v0/labs/<lab>/interfaces/<interface id>/state/start`.
  Check with `GET /labs/<lab>/nodes/<node>/interfaces?data=true`: every
  linked interface must read `STARTED`. `GET /pcap/<link id>` after
  `PUT .../links/<link>/capture/start` is the quickest way to see which
  side of a link is silent.

## A new endpoint on an 802.1X port is refused at once: single-host violation

- Symptom: after swapping the test endpoint on `sw1` Gi1/0/2, the new
  Linux supplicant got an immediate EAP-Failure with no TLS exchange, and
  ISE recorded nothing. `show access-session` said no sessions. Seen
  2026-09-17.
- Cause: the port was in the default single-host mode and still held the
  previous endpoint's authorized session. The new MAC logged
  `%AUTHMGR-5-SECURITY_VIOLATION ... new MAC address is seen`, and the
  default violation action err-disabled the port
  (`show interfaces Gi1/0/2 status`), which the supplicant only sees as
  failure.
- Fix: `clear access-session interface <port>`, then `shutdown` and
  `no shutdown` to recover the port. For lab ports that change endpoints,
  `authentication violation replace`, or `authentication host-mode
  multi-auth` where several MACs are expected. Check the port status
  before suspecting EAP, certificates, or ISE.

## ISE asks to restart after a DNS change, and answering no cancels the change

- Symptom: on ISE's CLI, `ip name-server 10.20.2.10` printed a notice that
  DNS changed and asked "Do you want to restart ISE now? Proceed?
  [yes,no]". Answered `no`, to restart later at a better moment. ISE
  printed "Aborted: by user" and `show running-config` still had the old
  name server. Seen 2026-09-17.
- Cause: the question is worded as if it were about timing, and it is about
  the change. `no` throws the command away. ISE has no way to change DNS
  now and restart later.
- Fix: answer `yes` and plan for the wait. The prompt came back after about
  7 minutes saying "ISE Processes are initializing", and the Application
  Server took a few minutes more (`show application status ise`). The same
  holds for `no ip name-server` and `ip domain-name`; the domain name
  restart took about 11 minutes. `docs/ISE-AD-BUILD.md`, Part 2.

## ISE's `ip name-server` adds to the list, it does not replace it

- Symptom: after `ip name-server 10.20.2.10` and its restart, the running
  config read `ip name-server 8.8.8.8 10.20.2.10`. The public resolver
  from the portal deploy was still there, and still first. Seen 2026-09-17.
- Cause: the command appends. With 8.8.8.8 in front, lookups for
  `corp.rooez.com` go to a server that knows nothing about it.
- Fix: `no ip name-server 8.8.8.8`, which asks for another restart and
  needs `yes`. A repoint is therefore three commands and three restarts
  (add, remove, `ip domain-name`), 30 to 40 minutes in all. A fresh deploy
  with Primary Name Server 10.20.2.10 and DNS domain `corp.rooez.com` in
  the portal form costs nothing, which is why `24-ad-up.sh` runs before the
  ISE deploy.

## ISE refuses a config command right after a restart: "configuration database is locked"

- Symptom: `ip domain-name corp.rooez.com`, typed as soon as the prompt
  returned from the previous restart, was refused with "the configuration
  database is locked by session NNN admin http (rest from 127.0.0.1)".
  Nobody else was logged in. Seen once, 2026-09-17.
- Cause: the session holding the lock is ISE's own initialization. The CLI
  prompt comes back while "ISE Processes are initializing", well before the
  services are up.
- Fix: wait until `show application status ise` shows the Application
  Server `running`, then type the command again. The retry worked.

## ISE's `nslookup` fails while DNS works

- Symptom: after the repoint, `nslookup` on ISE's CLI failed with
  "/usr/bin/host: parse of /etc/resolv.conf failed". Seen 2026-09-17 on
  3.5.0.527.
- Cause: not known. Resolution itself was fine at the same moment. We did
  not run `nslookup` before the change, so we cannot say whether the
  repoint broke it or it never worked on this image.
- Fix: check with `ping dc1` instead. It has to resolve to
  `dc1.corp.rooez.com (10.20.2.10)` and get replies, which proves both the
  name server and the search domain. Then
  `show running-config | include name-server` and `| include domain-name`.

## An expect block written on one line never matches and waits out its timeout

- Symptom: an expect script driving ISE's CLI sat for the whole timeout at
  every prompt and then carried on. It looked exactly like ISE hanging,
  and about an hour went to it on 2026-09-17.
- Cause: `expect { -re {pattern} {} timeout {...} }` written on one line is
  parsed as a single glob pattern, not as a block of pattern and action
  pairs. It never matches anything, expect waits the full timeout in
  silence, and the script falls through as if all were well.
- Fix: write the block across several lines, one pattern and action per
  line. When an automated CLI session is slow by exactly the timeout at
  every step, suspect the script before the device. The helper scripts from
  that session lived in a session scratchpad and are not in this repo.

## The ISE join over ERS fails with "Falied to send http get request" or a 401

- Symptom: two ways the ERS calls for the Active Directory join go wrong.
  A 401 on every call, with a password known to be right (first met on
  2026-09-16 in `ise_config.py`). And, on 2026-09-17,
  `PUT /ers/config/activedirectory/<id>/join` failing with "Falied to send
  http get request" (ISE's spelling).
- Cause: the 401 is the username. The Marketplace image's admin account is
  `iseadmin`, for ERS as well as the GUI, and `admin` does not exist. The
  second is the `node` value in the join body: the short name `ise1` is not
  accepted.
- Fix: authenticate as `iseadmin`, and give the node as the FQDN,
  `ise1.corp.rooez.com`. The two request bodies are in
  `docs/ISE-AD-BUILD.md`, Part 3.

## A failed ISE join says "nodes not able to join/remove" and nothing else

- Symptom: the join returned HTTP 500, "nodes not able to join/remove :
  [ise1.corp.rooez.com]". `ad_agent.log` had only
  `LW_ERROR_NOT_JOINED_TO_AD` status lines. The DC's Security log had only
  Audit Success: a TGT for `svc-ise`, a password reset on `ISE1$`, the
  account enabled. Seen 2026-09-17.
- Cause: the API message never carries the reason. `ad_agent.log` at its
  default level does not log the attempt. The DC does not audit an LDAP
  write that it denies, by default, so a refusal leaves no event there.
- Fix: the reason is only in ISE's `ise-psc.log`, which holds the join's
  full step log and its final error: `show logging application ise-psc.log
  | include Fatal`. It takes several minutes and pages with `--More--`.
  Read it to the end before settling on a cause; the next entry is why.

## Denied attribute writes in the ISE join log were not why the join failed

- Symptom: the join's step log showed `ISE1$` created, enabled, and given a
  password, `dNSHostName` and the SPNs written, then `operatingSystem`,
  `operatingSystemVersion`, and `msDS-SupportedEncryptionTypes` with no
  success line, and a final "Access is denied", error code 5. Seen
  2026-09-17.
- Cause: two separate things. `svc-ise` had only create-computer on
  `CN=Computers` (`dsacls ... /G "CORP\svc-ise:CC;computer"`), and an
  object's creator may write only a short list of its attributes (logon
  information, description, displayName, sAMAccountName, account
  restrictions, and the validated writes for DNS host name and SPN). Those
  three are outside the list, so they were denied. But Cisco lists setting
  the OS attributes as optional, and the denials were not fatal. After the
  grant below every attribute was written, the log said "Attributes was
  setted successfully", and the join failed on the same final line anyway.
  The denials were the only visible refusals in the log, so they took the
  blame and sent the debugging the wrong way for a while.
- Fix: `dsacls "CN=Computers,DC=corp,DC=rooez,DC=com" /I:S /G
  "CORP\svc-ise:WP;;computer"`, now in `30-create-identities.ps1`. It is
  kept because it lets ISE record its OS and version on its computer object
  (`Cisco Identity Services Engine`, `3.5.0.527`, encryption types 28) and
  keeps the step log clean. It is not a fix for the join. When a log shows
  a denial, check whether the run ended there before acting on it.

## The ISE join fails with access denied after a step log that succeeds throughout

- Symptom: ISE 3.5.0.527 joining a Windows Server 2025 domain as
  `svc-ise`. Every step in `ise-psc.log` succeeds, attributes included, and
  the join ends with "Join Operation Failed: Access is denied, Error Name:
  ERROR_ACCESS_DENIED, Error Code: 5". The DC's Security log is all Audit
  Success. Seen 2026-09-17.
- Cause: Cisco Field Notice FN74321, "Cisco Identity Services Engine Fails
  to Join Microsoft Active Directory Domain Services Hosted on Windows
  Server 2025"
  (https://www.cisco.com/c/en/us/support/docs/field-notices/743/fn74321.html),
  regression bug CSCwr77017. A Server 2025 DC by default refuses the legacy
  SAM RPC password change methods when called remotely
  (`SamrChangePasswordUser`, `SamrOemChangePasswordUser2`,
  `SamrUnicodeChangePasswordUser2`) and accepts only
  `SamrUnicodeChangePasswordUser4`. The notice lists ISE 3.1 through 3.4 P1
  and does not mention 3.5, but it applies. Proven on the DC: with
  `HKLM\SYSTEM\CurrentControlSet\Control\SAM`, DWORD
  `AuditLegacyPasswordRpcMethods` = 1 (logging only, Microsoft KB5004605),
  SAM logged event 16985 in the System log (provider
  `Microsoft-Windows-Directory-Services-SAM`) twice during a join, both
  from 10.20.2.20 as `ISE1$`: `SamrSetInformationUser`, then
  `SamrUnicodeChangePasswordUser2`, one of the three blocked methods.
- Fix: on the DC,
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SAM`,
  DWORD `SamrChangeUserPasswordApiPolicy` = 3 (1 blocks all, 2 allows the
  strong method only and is the behavior when unset, 3 allows all), and
  then restart the DC. The value is read at startup. Set on the running DC
  and read back as 3, it changed nothing and the join failed the same way;
  after `az vm restart` of `dc1` the same join call returned 204. Neither
  Cisco's notice nor the policy's description mentions a restart.
  `10-promote-forest.ps1` sets the value before the promotion reboot so a
  new DC needs no extra one. The cheap first check next time: summary event
  16984 in the DC's System log, "detected N legacy password change or set
  RPC method calls in the past 60 minutes", appears at the time of each
  failed join even without the verbose value. Value 3 lowers a DC default
  and is accepted for this lab only, until Cisco fixes 3.5 (ADR 0010
  amendment). A customer's Server 2025 domain will need the same setting or
  a fixed ISE patch.

## Updating an ISE join point over ERS returns 405

- Symptom: `PUT /ers/config/activedirectory/<id>` with the join point and
  its new groups was refused with HTTP 405, "The requested Method is not
  supported for that resource". Seen 2026-09-17.
- Cause: the Active Directory resource does not support a plain update.
  Changes go through named operations on the join point.
- Fix: `PUT /ers/config/activedirectory/<id>/addGroups`, with
  `{"ERSActiveDirectory": {...}}` holding the object as GET returned it
  minus `link`, plus `"adgroups": {"groups": [{"name", "sid", "type"}]}`.
  It returns 204. The names, SIDs, and types come from
  `PUT .../<id>/getGroupsByDomain` with additionalData
  `domain=corp.rooez.com`. SIDs change with every build of the forest, so
  read them each time and never hardcode them.

## ISE's API gives connection reset, then refused, after ISE restarts

- Symptom: calls to `https://localhost:8443` failed with connection reset
  and later connection refused, after the restarts of the DNS repoint. It
  looked like ISE still coming up. Seen 2026-09-17.
- Cause: the `ise` SSH forward through the CML host had dropped. ISE was
  fine.
- Fix: `scripts/50-tunnels.sh up`. Check the tunnel before waiting on ISE.

## `AD_ADMIN_USERNAME` already carries the domain prefix

- Symptom: an ad hoc admin command sent to the DC through
  `run-as-admin.ps1` failed with "No mapping between account names and
  security IDs". Seen 2026-09-17.
- Cause: the caller put `CORP\` in front of `AD_ADMIN_USERNAME`, and the
  value in `config/mcp-env/ad.env` already reads `CORP\labadmin`.
- Fix: pass the variable as it is. The way to run one admin command on the
  DC without RDP is the repo's `run-as-admin.ps1` with the command in place
  of its marker line, delivered by `az vm run-command invoke`, with the
  password read from a mode 0600 file through az's `@file` argument syntax
  so it never shows in a process listing.

## `40-down.sh` fails at the destroy with "no file exists at 06-transit-bridge.sh"

- Symptom: the export and the license release passed, then
  `terraform destroy` in `vendor/cloud-cml` stopped with "Error in function
  call" on the `templatefile` of `cloud-config.txt`: no file exists at
  `data/06-transit-bridge.sh`. The CML VM kept running. Seen 2026-09-17.
- Cause: Terraform renders the cloud-config template for a destroy as well
  as for a build, and the template reads every script named under
  `app.customize` in `config/cml.yml`. That file is rendered at build time
  and gitignored. It was rendered before the fork renamed the script to
  `06-transit.sh`, so it named a file that no longer existed.
- Fix: `40-down.sh` now renders `config/cml.yml` again before the destroy,
  so the file always matches the fork it is destroyed with. On the day it
  was corrected by hand and the destroy step rerun with its three `TF_VAR_`
  exports.

## A lab export does not contain what was typed on a running node

- Symptom: none yet; caught before the teardown on 2026-09-17. `sw1` in the
  hand-built "cat9kv probe" lab carried its whole AAA, RADIUS, 802.1X, and
  MAB configuration in running-config only.
- Cause: `30-export-labs.sh` downloads each lab as CML holds it, and CML
  holds the configuration the node was created with. It asks a node for its
  running configuration only when told to.
- Fix: before the export,
  `PUT /api/v0/labs/<lab>/nodes/<node>/extract_configuration` for each node
  whose running configuration matters. On CML 2.10 the lab level form of
  that call answers 404, and nodes that cannot extract (external
  connectors, alpine, ubuntu) answer 400. The export of 2026-09-17,
  `exports/20260917T214927Z`, has `sw1`'s configuration because of it.

## A pipe into grep hid a failed teardown

- Symptom: `scripts/40-down.sh ... | grep ...` reported exit code 0 while
  the destroy inside it had failed. Seen 2026-09-17.
- Cause: without `set -o pipefail` a pipeline's status is its last
  command's, and grep was content.
- Fix: run teardown and build scripts unpiped, or under `pipefail` with
  `PIPESTATUS` printed, and check Azure afterwards:
  `az vm list -g rg-cml-lab` should be empty.

## `45-ise-down.sh` reported success and left the ISE disk behind

- Symptom: the script listed and deleted the NIC, the NSG, and the public
  address, printed `[OK]`, and `ise1osdisk` was still in the resource group,
  tagged `role=ise` and billing. Seen 2026-09-17.
- Cause: the lookup ran `az resource list --tag role=ise` across the
  subscription and kept rows whose `resourceGroup` equalled `rg-cml-lab`.
  Azure reports a disk's resource group in upper case, `RG-CML-LAB`, and a
  JMESPath comparison is case sensitive, so the disk never made the list.
  Nothing failed, because nothing was asked to delete it.
- Fix: `az resource list --resource-group <rg>` with the tag in the query,
  `[?tags.role=='ise']`. The resource group filter runs on Azure's side and
  ignores case. Do not compare `resourceGroup` in a query anywhere. After a
  teardown, list the resource group and read it; an `[OK]` only says the
  script deleted what it found.

## A die inside a command substitution does not stop the script

- Symptom: `24-ad-up.sh` printed five `[FAIL] persistent output ...
  unavailable` lines, then ran terraform with five empty `-var=` arguments
  and exited 0. `45-ise-down.sh` did the same with an empty
  `--resource-group` and deleted whatever that listed. Found by the
  architecture review and the stub-driven run tests, 2026-09-17.
- Cause: bash runs a `$(...)` subshell with errexit switched off, and bash
  3.2 has no `inherit_errexit`. A `die` inside `"x=$(fn)"` in argument
  position only empties that argument. Capturing the whole function with
  `lines="$(fn)" || die` does not help either: the subshell keeps going
  after the inner exit and returns the status of its last echo. A process
  substitution `done < <(fn)` never reports a status at all.
- Fix: resolve each value with a plain assignment in the calling shell,
  `v="$(fn)"` on its own line, which `set -e` does stop on, and pass results
  back through a variable or an array, never through a pipe or a
  substitution. Inside a function that must run in `$(...)`, every
  `x="$(out_or_placeholder x)"` needs its own `|| return 1`, as
  `find_ise_resources` now has. The dry-run tests cannot see this class;
  the real runs in `tests/test_*_run.sh` do.

## A for loop over a command substitution hides the command's failure

- Symptom: `cml-remote.sh export-labs` printed "exported 0 labs" and exited
  0 while `GET /labs` was answering 500. `40-down.sh` took that as a good
  export and would have destroyed the VM with the labs on it. Proven
  against a fake API, 2026-09-17.
- Cause: `for id in $(lab_ids)` discards the substitution's exit status; an
  empty word list is a normal empty loop.
- Fix: `ids="$(lab_ids)"` first, then `for id in ${ids}`, with `lab_ids`
  returning its own failure. `30-export-labs.sh` also counts the exported
  files against a fresh `list-labs` before the upload.

## Azure refuses to delete an NSG or a public IP a NIC still references

- Symptom: `45-ise-down.sh` would have stopped part way on any listing that
  put `ise-nsg` or `ise1-ip` before the NIC. The 2026-09-17 teardown worked
  because the order happened to be kind.
- Cause: `az resource list` promises no order, and the NSG and public IP
  stay bound to the NIC until the NIC is gone.
- Fix: delete in passes by type, VM, then NICs, then everything else; carry
  on past a failed delete with a `[FAIL]` line; list by tag again at the
  end and treat any row as a failure. The `[OK]` line is withheld when a
  delete failed, so the summary carries the result.

## A dead jump host looked like ISE taking 45 minutes to boot

- Symptom: `25-ise-up.sh --post-deploy` printed "still waiting" for the
  whole readiness timeout while the CML host was down or its key rejected.
- Cause: the poll turned every ssh failure into curl's `000`, so a dead jump
  and a booting ISE were the same to it.
- Fix: `cml_ssh true || die` once before the loop, so a jump that does not
  answer fails at once and names itself. Tested with the ssh stub at exit
  255.

## A test that reads the operator's gitignored config passes only on that machine

- Symptom: `tests/run.sh` failed in a fresh worktree on
  `tests/test_ise_dry_run.sh` ("config/mcp-env/ise.env missing") while
  passing in the main checkout. Seen 2026-09-17.
- Cause: one case ran `25-ise-up.sh` without `ISE_ENV_FILE`, so it read the
  real, gitignored file.
- Fix: every case points the env file at a fixture. Run `tests/run.sh` in a
  clean worktree before opening a PR; a worktree has none of the gitignored
  files and is the honest test of the gate.

## PowerShell binds a bare dash flag to the helper's own parameters

- Symptom: `Invoke-Native sh -c '...'` ran the string after `-c` as the
  command, and `Invoke-Native certutil -setreg ...` would bind `-setreg`
  the same way if a parameter started with those letters. Seen while
  testing the helper, 2026-09-17.
- Cause: the parameter binder matches a dash token against the function's
  own parameters by prefix before it reaches the remaining-arguments list.
- Fix: quote every dash flag handed to a native command through such a
  helper (`'-setreg'`, `'-crl'`); `tests/test_ad_powershell.sh` asserts no
  unquoted flag follows an `Invoke-Native` call.

## `easypy --help` crashes on Python 3.14

- Symptom: `verify/.venv/bin/easypy --help` ends with `AttributeError:
  'pyATS_HelpFormatter' object has no attribute '_format_actions_usage'`
  and prints no options. Seen 2026-09-17.
- Cause: pyATS's help formatter relies on a private argparse method that
  Python 3.14 removed.
- Fix: read the option names from the parser rather than the help text, for
  example by wrapping `add_argument` in a spy before importing
  `pyats.easypy.main`. easypy registers `-archive_dir` and `-runinfo_dir`,
  single dash and underscore, which `80-verify-lab.sh` now passes so the
  archive stays under `verify/`.

## Every script fails with "CML API forward not up" after a build

- Symptom: a script, or Claude Code's cml MCP server, stops at once with
  `[FAIL] CML API forward not up on 127.0.0.1:9443. Run: scripts/50-tunnels.sh up`.
  A `tunnels.conf` from before says "has no cml forward", and a `cml.env`
  from before says "CML_API_BASE missing".
- Cause: since ADR 0012 every controller login rides the `cml` SSH forward,
  and nothing falls back to the public address on purpose.
- Fix: `scripts/50-tunnels.sh up` first, then the script; reconnect the MCP
  server after the forward is up. An old `config/tunnels.conf` needs the
  line `cml 9443 127.0.0.1 443`, and an old `cml.env` needs
  `CML_API_BASE=https://127.0.0.1:9443` (the next `20-up.sh` writes it).
  The local port in both files must agree.
