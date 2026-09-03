output "resource_group_name" {
  description = "Resource group that holds every persistent resource and the CML VM."
  value       = azurerm_resource_group.lab.name
}

output "location" {
  description = "Azure region."
  value       = azurerm_resource_group.lab.location
}

output "storage_account_name" {
  description = "Storage account holding the cml and exports containers."
  value       = azurerm_storage_account.lab.name
}

output "cml_container_name" {
  description = "Container with the CML package and refplat images."
  value       = azurerm_storage_container.cml.name
}

output "exports_container_name" {
  description = "Container with dated lab export folders."
  value       = azurerm_storage_container.exports.name
}

output "ssh_key_name" {
  description = "Azure SSH public key resource name, referenced by the fork as common.key_name."
  value       = azurerm_ssh_public_key.cml.name
}

output "public_ip_name" {
  description = "Static public IP resource name, referenced by the fork as azure.public_ip_name."
  value       = azurerm_public_ip.cml.name
}

output "public_ip_address" {
  description = "Static public IP address of the CML host. Stable across rebuilds."
  value       = azurerm_public_ip.cml.ip_address
}

output "data_disk_id" {
  description = "Resource ID of the persistent data disk, referenced by the fork as azure.data_disk_id."
  value       = azurerm_managed_disk.data.id
}

output "vnet_name" {
  description = "VNet name, referenced by the fork as azure.vnet_name."
  value       = azurerm_virtual_network.lab.name
}

output "cml_subnet_name" {
  description = "CML subnet name, referenced by the fork as azure.subnet_name."
  value       = azurerm_subnet.cml.name
}

output "cml_subnet_id" {
  description = "CML subnet resource ID."
  value       = azurerm_subnet.cml.id
}

output "apps_subnet_id" {
  description = "Apps subnet resource ID, for the ISE and FTD spec."
  value       = azurerm_subnet.apps.id
}

output "apps_subnet_cidr" {
  description = "Apps subnet prefix, referenced by the fork as azure.apps_subnet_cidr for the NSG rule."
  value       = var.apps_subnet_cidr
}

output "cml_private_ip" {
  description = "Static private IP for the CML NIC, referenced by the fork as azure.private_ip."
  value       = var.cml_private_ip
}

output "lab_summary_cidr" {
  description = "Lab summary prefix, referenced by the fork as azure.lab_summary_cidr."
  value       = var.lab_summary_cidr
}

output "app_admin_password" {
  description = "CML application admin password. Rendered into config/cml.yml."
  value       = random_password.app_admin.result
  sensitive   = true
}

output "sys_admin_password" {
  description = "CML sysadmin password. Rendered into config/cml.yml."
  value       = random_password.sys_admin.result
  sensitive   = true
}
