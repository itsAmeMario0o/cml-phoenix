# Subscription and tenant come from ARM_SUBSCRIPTION_ID and the az login
# session. Nothing is hardcoded here on purpose (CLAUDE.md, Never list).
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}
