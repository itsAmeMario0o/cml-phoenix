locals {
  resource_group_name = "rg-cml-lab"

  common_tags = {
    project = "cml-azure-lab"
    owner   = var.owner
    expires = var.expires
  }

  # Every resource name below is exported by outputs.tf and consumed by the
  # fork or by scripts/, so a literal here is contract surface, not a
  # cosmetic label (CLAUDE.md: no magic strings). Named once here rather
  # than spelled out at each resource.
  storage_account_prefix = "stcmllab"
  cml_container_name     = "cml"
  exports_container_name = "exports"
  ssh_key_name           = "sshkey-cml-lab"
  public_ip_name         = "pip-cml-lab"
  data_disk_name         = "disk-cml-lab-data"
  vnet_name              = "vnet-cml-lab"
  cml_subnet_name        = "snet-cml"
  apps_subnet_name       = "snet-apps"
  fw_mgmt_subnet_name    = "snet-fw-mgmt"
  fw_inside_subnet_name  = "snet-fw-inside"
  fw_outside_subnet_name = "snet-fw-outside"
  apps_route_table_name  = "rt-apps"
  lab_summary_route_name = "lab-summary-via-cml"
}
