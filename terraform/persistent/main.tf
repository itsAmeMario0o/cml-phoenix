data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "lab" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags
}

# ---- Storage: CML package, refplat images, lab exports --------------------

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "lab" {
  name                            = "stcmllab${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  # cloud-cml builds a read-only SAS from the account's connection string so
  # the VM can pull images with azcopy. That needs shared keys on. ADR 0001.
  shared_access_key_enabled = true
  tags                      = local.common_tags
}

resource "azurerm_storage_container" "cml" {
  name                  = "cml"
  storage_account_id    = azurerm_storage_account.lab.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "exports" {
  name                  = "exports"
  storage_account_id    = azurerm_storage_account.lab.id
  container_access_type = "private"
}

# The Mac uploads images and exports with azcopy using the az login session
# (AZCOPY_AUTO_LOGIN_TYPE=AZCLI). That is data-plane access, granted here.
resource "azurerm_role_assignment" "lab_blob" {
  scope                = azurerm_storage_account.lab.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---- Identity and addressing that must not change between builds ---------

resource "azurerm_ssh_public_key" "cml" {
  name                = "sshkey-cml-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  public_key          = file("${path.root}/${var.ssh_public_key_file}")
  tags                = local.common_tags
}

# Standard SKU is required for a static IP that survives VM deletion. The
# cml-mcp config on the Mac points at this address. ADR 0003.
resource "azurerm_public_ip" "cml" {
  name                = "pip-cml-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# ---- Data disk: refplat images and exports live here -----------------------

resource "azurerm_managed_disk" "data" {
  name                 = "disk-cml-lab-data"
  resource_group_name  = azurerm_resource_group.lab.name
  location             = azurerm_resource_group.lab.location
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = local.common_tags

  # This disk is the whole point of the persistent root. ADR 0002.
  lifecycle {
    prevent_destroy = true
  }
}

# ---- Network -----------------------------------------------------------------

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-cml-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [var.vnet_cidr]
  tags                = local.common_tags
}

resource "azurerm_subnet" "cml" {
  name                 = "snet-cml"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.cml_subnet_cidr]
}

resource "azurerm_subnet" "apps" {
  name                 = "snet-apps"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.apps_subnet_cidr]
}

resource "azurerm_subnet" "fw_mgmt" {
  name                 = "snet-fw-mgmt"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.fw_mgmt_subnet_cidr]
}

resource "azurerm_subnet" "fw_inside" {
  name                 = "snet-fw-inside"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.fw_inside_subnet_cidr]
}

resource "azurerm_subnet" "fw_outside" {
  name                 = "snet-fw-outside"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.fw_outside_subnet_cidr]
}

# Azure's fabric, not the VM's routing table, decides where a packet from the
# apps subnet goes. Without this UDR the lab summary falls to the Internet
# route and is dropped. The CML NIC must also have IP forwarding on, which
# the fork sets. ADR 0003.
resource "azurerm_route_table" "apps" {
  name                          = "rt-apps"
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = azurerm_resource_group.lab.location
  bgp_route_propagation_enabled = false
  tags                          = local.common_tags

  route {
    name                   = "lab-summary-via-cml"
    address_prefix         = var.lab_summary_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.cml_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "apps" {
  subnet_id      = azurerm_subnet.apps.id
  route_table_id = azurerm_route_table.apps.id
}

# ---- Secrets: generated here, read back with terraform output ---------------

# 16 characters, no specials, matching cloud-cml's dummy secret manager so
# the YAML we render needs no escaping. ADR 0004.
resource "random_password" "app_admin" {
  length  = 16
  special = false
}

resource "random_password" "sys_admin" {
  length  = 16
  special = false
}
