locals {
  vm_names = ["vm1", "vm2"]
}

resource "azurerm_linux_virtual_machine" "vm" {
  for_each                        = toset(local.vm_names)
  name                            = "${var.project}-${each.key}"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = "Standard_B1s"
  admin_username                  = var.vm_admin_username
  admin_password                  = var.vm_admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.vm[each.key].id]
  custom_data                     = filebase64("${path.module}/cloud-init.sh")

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

resource "azurerm_network_interface" "vm" {
  for_each            = toset(local.vm_names)
  name                = "${var.project}-${each.key}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "ipcfg"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm[each.key].id
  }
}

resource "azurerm_public_ip" "vm" {
  for_each            = toset(local.vm_names)
  name                = "${var.project}-${each.key}-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}
