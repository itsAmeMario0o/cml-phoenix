output "dc_private_ip" {
  description = "The DC's address: ISE's primary name server."
  value       = azurerm_network_interface.dc.private_ip_address
}

output "domain_name" {
  description = "Forest root domain: ISE's DNS domain."
  value       = var.domain_name
}

output "netbios_name" {
  description = "NetBIOS name of the domain."
  value       = var.netbios_name
}

output "admin_username" {
  description = "Domain administrator for RDP, as NETBIOS\\name."
  value       = "${var.netbios_name}\\${var.admin_username}"
}

output "admin_password" {
  description = "Password of the administrator account."
  value       = random_password.admin.result
  sensitive   = true
}

output "svc_ise_password" {
  description = "Password of svc-ise, the account ISE joins the domain with."
  value       = random_password.svc_ise.result
  sensitive   = true
}

output "lab_user_password" {
  description = "Shared password of the lab users in config/ad-identities.csv."
  value       = random_password.lab_user.result
  sensitive   = true
}
