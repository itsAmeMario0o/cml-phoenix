variable "resource_group_name" {
  description = "Resource group the persistent root owns. Passed by scripts/24-ad-up.sh from that root's output."
  type        = string
}

variable "location" {
  description = "Azure region. Passed from the persistent root's output so the DC lands beside ISE."
  type        = string
}

variable "apps_subnet_id" {
  description = "ID of snet-apps, the subnet ISE sits on. Passed from the persistent root's output."
  type        = string
}

variable "apps_subnet_cidr" {
  description = "Prefix of snet-apps. Everything on it, ISE included, reaches the DC on every port."
  type        = string
}

variable "cml_private_ip" {
  description = "The CML host's private address. RDP reaches the DC through an SSH forward on that host."
  type        = string
}

variable "owner" {
  description = "Tag value: who owns these resources."
  type        = string
}

variable "expires" {
  description = "Tag value: review date, YYYY-MM-DD. Informational only."
  type        = string
}

variable "vm_size" {
  description = "DC size. B2ms is burstable, 2 vCPU and 8 GB, in a family with quota here; Basv2 and DSv5 have none (2026-09-17)."
  type        = string
  default     = "Standard_B2ms"
}

variable "dc_private_ip" {
  description = "Static address of the DC on snet-apps, beside ISE at .20."
  type        = string
  default     = "10.20.2.10"
}

variable "admin_username" {
  description = "Local administrator, which becomes the domain's built-in Administrator on promotion."
  type        = string
  default     = "labadmin"
}

variable "domain_name" {
  description = "Forest root domain. A child of the public zone so it never shadows lab.rooez.com."
  type        = string
  default     = "corp.rooez.com"
}

variable "netbios_name" {
  description = "NetBIOS name of the domain."
  type        = string
  default     = "CORP"
}

variable "ca_common_name" {
  description = "Common name of the Enterprise Root CA on the DC."
  type        = string
  default     = "corp-rooez-CA"
}

variable "ise_hostname" {
  description = "ISE's host name, for its A record in the domain zone."
  type        = string
  default     = "ise1"
}

variable "ise_ip" {
  description = "ISE's private address, for its A and PTR records."
  type        = string
  default     = "10.20.2.20"
}

variable "identities_csv_file" {
  description = "Tracked CSV of lab users and groups, relative to this root."
  type        = string
  default     = "../../config/ad-identities.csv"
}
