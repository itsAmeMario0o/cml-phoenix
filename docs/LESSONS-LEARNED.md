# Lessons learned

Symptom, cause, fix. Add an entry the moment something bites, before the
fix is forgotten. Entries from the design phase are here so they are not
learned twice.

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

- Symptom: a helper reading a Terraform output treated an empty state as a
  successful empty string instead of failing.
- Cause: `terraform output -raw <name>` against a state with no outputs
  prints "No outputs found" to stdout and exits 0, so a caller checking only
  the exit code never notices.
- Fix: `tf_out` now uses `output -json` and parses it, returning 1 when the
  named output is absent.

## A chained JMESPath filter on the quota query silently returns nothing

- Symptom: the quota check always came back empty even when the family was
  present in the raw `az` output.
- Cause: `[?a].b[?c]` does not flatten between the two filters, so the
  second `[?c]` is applied to a list of lists and never matches.
- Fix: the quota query pipes the first filter's result to `[0]` before
  applying the second, so it operates on the object, not the wrapping list.

## Teardown let a registered license through on the retry path

- Symptom: the teardown's license check let a registered license slip past
  the block and proceed to destroy the VM.
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

- Symptom: the data disk mount occasionally failed on the very first boot,
  succeeding on a retry or a reboot.
- Cause: mounting by label right after `mkfs` can run before the kernel's
  udev database has registered the new filesystem's label, so the label
  does not resolve yet.
- Fix: the hook calls `udevadm settle` after `mkfs` and before the
  mount-by-label step.
