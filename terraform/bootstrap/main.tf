# Who is running Terraform. Used to grant data-plane access to the state
# container: subscription Contributor does not include blob data access.
data "azurerm_client_config" "current" {}

locals {
  common_tags = {
    project = "cml-azure-lab"
    owner   = var.owner
    expires = var.expires
    purpose = "terraform-state"
  }
}

variable "location" {
  description = "Azure region for the state storage. Same region as the lab."
  type        = string
  default     = "eastus2"
}

variable "owner" {
  description = "Tag value: who owns these resources."
  type        = string
}

variable "expires" {
  description = "Tag value: review date, YYYY-MM-DD. Informational only."
  type        = string
}

variable "soft_delete_retention_days" {
  description = "Days a deleted or overwritten state blob can be recovered."
  type        = number
  default     = 14
}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-cml-lab-tfstate"
  location = var.location
  tags     = local.common_tags
}

# Storage account names are global and must be 3 to 24 lowercase
# alphanumerics. The random suffix keeps the name unique without a human
# picking one. It lives in local state, which is why that state is precious.
resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "tfstate" {
  name                            = "st${random_string.suffix.result}tfstate"
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = azurerm_resource_group.tfstate.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  # The persistent root authenticates with Azure AD (use_azuread_auth in
  # backend.tf). Shared keys stay on only because the azurerm provider still
  # reads them when managing blob properties; nothing in this repo uses them.
  shared_access_key_enabled = true
  tags                      = local.common_tags

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = var.soft_delete_retention_days
    }
    container_delete_retention_policy {
      days = var.soft_delete_retention_days
    }
  }

  # Losing this account loses the persistent root's state. ADR 0002.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "tfstate_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
