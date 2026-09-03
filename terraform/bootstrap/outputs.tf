# These three values are copied verbatim into terraform/persistent/backend.tf
# by Task 5. If they change, backend.tf must change with them.
output "resource_group_name" {
  description = "Resource group holding the state storage account."
  value       = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  description = "Storage account holding the state container."
  value       = azurerm_storage_account.tfstate.name
}

output "container_name" {
  description = "Blob container holding every remote state file."
  value       = azurerm_storage_container.tfstate.name
}
