resource "azurerm_resource_group" "this" {
  name     = "${var.project}-rg"
  location = var.location
}
