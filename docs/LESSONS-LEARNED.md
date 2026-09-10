# Lessons learned

Symptom, cause, fix. Add an entry the moment something bites, while the
fix is still fresh. The first few came out of the design phase and the
build's code reviews, before anything ran in Azure, which is the cheapest
time to learn them.

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
- Fix: `~> 4.0` in all three roots (fork patch 0). Root lock files are committed.

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
  headend in AWS and leaves from a pool of exit addresses inside
  151.186.182.0/24 that changes per connection. Four different addresses
  turned up in one afternoon. The allow-lists had only the web gateway
  address, so the browser got in and SSH did not. With the VPN off there
  is a single home address and none of this happens.
- Fix: for VPN use, the allow-lists carry the whole exit block
  `151.186.182.0/24` plus the home address as a /32. A single /32 from
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
