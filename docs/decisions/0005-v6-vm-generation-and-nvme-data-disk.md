# 0005: E-series v6 as the default size, data disk found on either link

Status: accepted, 2026-09-04

## Context

The spec picked `Standard_E16ds_v5`. On 2026-09-04 the quota request for
the Edsv5 family in eastus2 was refused by the automatic approver at 64 and
again at 32, and every v5 family on the subscription sat at zero in every
region checked. Newer families defaulted to 10. The v5 series is Intel Ice
Lake from 2021. For a greenfield lab there was no reason to open a support
case for the older platform.

The catch with v6 and v7 is the disk interface. Those sizes attach disks
over NVMe only, so the data disk does not appear at
`/dev/disk/azure/scsi1/lun0`, which is the one path the persistence hook
waited for. Everything else already coped: the Ubuntu 24.04 image supports
both controllers, the preflight script derives the quota family from
whatever size is configured, and the Terraform attachment at LUN 0 does not
care how the guest sees the disk.

## Decision

`Standard_E16ds_v6` is the default in `config/cml.tfvars.example`. Same
shape as before, 16 vCPU and 128 GB, Intel Emerald Rapids, nested
virtualization supported, 13 percent more per hour on demand and less than
half the v5 price on spot in eastus2.

The persistence hook on the fork checks two links for the LUN 0 disk and
uses whichever appears first: `/dev/disk/azure/data/by-lun/0`, which the
Azure udev rules create on NVMe sizes, then `/dev/disk/azure/scsi1/lun0` for
SCSI sizes. Both carry a `-part1` link for the first partition, so the rest
of the script is unchanged. The size is a free choice in the tfvars file.
`DATA_DEV` still pins one path when set.

## Consequences

- The Edsv6 family quota is what has to be raised, not Edsv5. It was
  approved at 64 the same day.
- v6 presents its local temp disk as a raw NVMe device instead of mounting
  it at `/mnt`. Nothing in the fork or the scripts uses the temp disk. The
  first real build confirms that.
- The NVMe by-lun link depends on the `azure-vm-utils` package, which the
  24.04 image carries from its updates pocket as of September 2025. If the
  link is missing on a fresh boot the script times out with both paths in
  the log, and the fix is to set `DATA_DEV` to the raw namespace.
- AMD sizes (`Eadsv6`) are cheaper and support nested virtualization, but
  Cisco validates its images on Intel. Not chosen for the first build.

## Options considered

1. Support case for Edsv5. Rejected. Days of waiting for a five year old
   platform that Microsoft is visibly steering new subscriptions away from.
2. v7 (Granite Rapids). Rejected. Same shape, 44 percent more per hour, and
   nothing in CML benefits.
3. v6 with the two-link lookup. Chosen. Fifteen lines on the fork.
