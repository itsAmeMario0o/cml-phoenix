locals {
  resource_group_name = "rg-cml-lab"

  common_tags = {
    project = "cml-azure-lab"
    owner   = var.owner
    expires = var.expires
  }
}
