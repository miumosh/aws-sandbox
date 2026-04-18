output "vnet_cidr" {
  value = var.vnet_cidr
}

output "vpn_gateway_public_ip" {
  value = azurerm_public_ip.vpngw.ip_address
}

output "vm_public_ips" {
  value = { for k, v in azurerm_public_ip.vm : k => v.ip_address }
}

output "vm01_public_ip" {
  value = azurerm_public_ip.vm["vm1"].ip_address
}

output "vm02_public_ip" {
  value = azurerm_public_ip.vm["vm2"].ip_address
}

output "vm_private_ips" {
  value = { for k, v in azurerm_network_interface.vm : k => v.private_ip_address }
}
