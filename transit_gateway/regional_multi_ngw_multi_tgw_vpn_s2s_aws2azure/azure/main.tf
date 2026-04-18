resource "azurerm_resource_group" "this" {
  name     = "${var.project}-rg"
  location = var.location
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.project}-vnet"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_subnet" "vm" {
  name                 = "vm-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.vm_subnet_cidr]
}

resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.gateway_subnet_cidr]
}

resource "azurerm_network_security_group" "vm" {
  name                = "${var.project}-vm-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_network_security_rule" "vm_allow_icmp" {
  name                        = "allow-icmp"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Icmp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "vm_allow_ssh" {
  name                        = "allow-ssh-from-vnet-and-aws"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = [var.my_ip_cidr, var.vnet_cidr, var.aws_vpc_cidr]
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_network_security_rule" "vm_allow_http" {
  name                        = "allow-http"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "80"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

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

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}
