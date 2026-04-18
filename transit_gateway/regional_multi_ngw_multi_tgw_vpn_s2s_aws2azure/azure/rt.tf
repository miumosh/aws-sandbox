# --- UDR: VM サブネットから default を Virtual Network Gateway 経由にする ---
# これにより VM01/VM02 の相手 public IP 宛も AWS 経由で出る (ヘアピン検証)
resource "azurerm_route_table" "vm" {
  name                          = "${var.project}-rt-vm"
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  bgp_route_propagation_enabled = true
}

resource "azurerm_route" "to_aws" {
  name                = "to-aws"
  resource_group_name = azurerm_resource_group.this.name
  route_table_name    = azurerm_route_table.vm.name
  address_prefix      = var.aws_vpc_cidr
  next_hop_type       = "VirtualNetworkGateway"
}

# VM01/VM02 同士の Public IP 宛を強制的に VPN 経由に振る
# (System route では Internet 扱いになり AWS を経由しないため)
resource "azurerm_route" "to_peer_vm" {
  for_each            = toset(local.vm_names)
  name                = "to-peer-${each.key}"
  resource_group_name = azurerm_resource_group.this.name
  route_table_name    = azurerm_route_table.vm.name
  address_prefix      = "${azurerm_public_ip.vm[each.key].ip_address}/32"
  next_hop_type       = "VirtualNetworkGateway"
}

resource "azurerm_subnet_route_table_association" "vm" {
  subnet_id      = azurerm_subnet.vm.id
  route_table_id = azurerm_route_table.vm.id
}