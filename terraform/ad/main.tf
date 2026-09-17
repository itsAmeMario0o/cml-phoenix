locals {
  common_tags = {
    project = "cml-azure-lab"
    owner   = var.owner
    expires = var.expires
    role    = "ad"
  }

  scripts_dir = "${path.module}/../../scripts/ad"

  # Symbols that survive a run-command parameter and a PowerShell string
  # unquoted: no quotes, dollar, backtick, ampersand, or semicolon.
  password_symbols = "!@#%^*-_=+"

  # After promotion the local administrator is the domain's Administrator,
  # a member of Enterprise Admins, which installing an Enterprise CA needs.
  # SYSTEM on a DC is only the machine account and is refused.
  domain_admin = "${var.netbios_name}\\${var.admin_username}"
}

resource "random_password" "admin" {
  length      = 12
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

resource "random_password" "dsrm" {
  length           = 24
  override_special = local.password_symbols
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "random_password" "svc_ise" {
  length           = 24
  override_special = local.password_symbols
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "random_password" "lab_user" {
  length           = 24
  override_special = local.password_symbols
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

# The operator's rule for now: no policy between ISE and the directory,
# because a domain join, Kerberos, LDAP, RPC, and certificate enrollment
# use too many ports to list usefully. Azure's default AllowVnetInBound
# already permits it; this rule states the intent so that a later deny
# cannot cut ISE off by accident. Nothing from the internet is admitted:
# the DC has no public IP and the default DenyAllInBound still applies.
resource "azurerm_network_security_group" "dc" {
  name                = "dc-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "apps_subnet_any" {
  name                        = "apps-subnet-any-in"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.apps_subnet_cidr
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
}

resource "azurerm_network_security_rule" "rdp_from_cml_host" {
  name                        = "rdp-from-cml-host"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = var.cml_private_ip
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
}

resource "azurerm_network_interface" "dc" {
  name                = "dc1-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.apps_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.dc_private_ip
  }
}

resource "azurerm_network_interface_security_group_association" "dc" {
  network_interface_id      = azurerm_network_interface.dc.id
  network_security_group_id = azurerm_network_security_group.dc.id
}

resource "azurerm_windows_virtual_machine" "dc" {
  name                  = "dc1"
  computer_name         = "dc1"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = random_password.admin.result
  network_interface_ids = [azurerm_network_interface.dc.id]
  tags                  = local.common_tags

  # No route to Windows Update and a life of one session: patching would
  # only compete with promotion for the first boot.
  patch_mode                 = "Manual"
  automatic_updates_enabled  = false
  provision_vm_agent         = true
  allow_extension_operations = true

  os_disk {
    name                 = "dc1-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.image_sku
    version   = "latest"
  }

  depends_on = [azurerm_network_interface_security_group_association.dc]
}

# Three run commands, in order. Not two with scripts concatenated: each
# script opens with its own param() block, which PowerShell only accepts
# first in a file. The scripts are the idempotency layer; a rerun of apply
# after a partial failure re-sends only what did not finish.
resource "azurerm_virtual_machine_run_command" "promote" {
  name               = "10-promote-forest"
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.dc.id
  tags               = local.common_tags

  source {
    script = file("${local.scripts_dir}/10-promote-forest.ps1")
  }

  parameter {
    name  = "DomainName"
    value = var.domain_name
  }

  parameter {
    name  = "NetbiosName"
    value = var.netbios_name
  }

  protected_parameter {
    name  = "SafeModePassword"
    value = random_password.dsrm.result
  }
}

resource "azurerm_virtual_machine_run_command" "ca" {
  name               = "20-install-ca"
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.dc.id
  run_as_user        = local.domain_admin
  run_as_password    = random_password.admin.result
  tags               = local.common_tags

  source {
    script = file("${local.scripts_dir}/20-install-ca.ps1")
  }

  parameter {
    name  = "CaCommonName"
    value = var.ca_common_name
  }

  parameter {
    name  = "NetbiosName"
    value = var.netbios_name
  }

  depends_on = [azurerm_virtual_machine_run_command.promote]
}

resource "azurerm_virtual_machine_run_command" "identities" {
  name               = "30-create-identities"
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.dc.id
  run_as_user        = local.domain_admin
  run_as_password    = random_password.admin.result
  tags               = local.common_tags

  source {
    script = file("${local.scripts_dir}/30-create-identities.ps1")
  }

  # Base64 so a multi-line CSV survives as one parameter value.
  parameter {
    name  = "CsvBase64"
    value = base64encode(file("${path.module}/${var.identities_csv_file}"))
  }

  parameter {
    name  = "DomainName"
    value = var.domain_name
  }

  parameter {
    name  = "NetbiosName"
    value = var.netbios_name
  }

  parameter {
    name  = "IseHostName"
    value = var.ise_hostname
  }

  parameter {
    name  = "IseIp"
    value = var.ise_ip
  }

  protected_parameter {
    name  = "LabUserPassword"
    value = random_password.lab_user.result
  }

  protected_parameter {
    name  = "SvcIsePassword"
    value = random_password.svc_ise.result
  }

  depends_on = [azurerm_virtual_machine_run_command.ca]
}
