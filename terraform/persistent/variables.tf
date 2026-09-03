variable "location" {
  description = "Azure region. Must match the bootstrap root."
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

variable "ssh_public_key_file" {
  description = "Path to the RSA public key for the CML host, relative to this root."
  type        = string
  default     = "../../keys/cml-lab.pub"
}

variable "data_disk_size_gb" {
  description = "Size of the persistent data disk that holds refplat images and exports."
  type        = number
  default     = 512
}

variable "vnet_cidr" {
  description = "Address space of the lab VNet."
  type        = string
  default     = "10.20.0.0/16"
}

variable "cml_subnet_cidr" {
  description = "Subnet for the CML host."
  type        = string
  default     = "10.20.1.0/24"
}

variable "apps_subnet_cidr" {
  description = "Subnet for ISE and future appliances. Carries the route to the lab."
  type        = string
  default     = "10.20.2.0/24"
}

variable "fw_mgmt_subnet_cidr" {
  description = "Reserved for FTDv management."
  type        = string
  default     = "10.20.3.0/24"
}

variable "fw_inside_subnet_cidr" {
  description = "Reserved for FTDv inside."
  type        = string
  default     = "10.20.4.0/24"
}

variable "fw_outside_subnet_cidr" {
  description = "Reserved for FTDv outside."
  type        = string
  default     = "10.20.5.0/24"
}

variable "lab_summary_cidr" {
  description = "Summary prefix for every network inside CML. Routed to the CML host. ADR 0003."
  type        = string
  default     = "10.100.0.0/16"
}

variable "cml_private_ip" {
  description = "Static private IP of the CML host. Next hop for the lab summary route."
  type        = string
  default     = "10.20.1.10"
}
