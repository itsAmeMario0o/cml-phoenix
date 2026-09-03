# Static values copied from `terraform -chdir=terraform/bootstrap output`.
# Backend blocks cannot reference variables, which is why they are literal.
# Task 5 replaces the placeholders after the bootstrap apply.
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-cml-lab-tfstate"
    storage_account_name = "st792kcotfstate"
    container_name       = "tfstate"
    key                  = "persistent.tfstate"
    use_azuread_auth     = true
  }
}
