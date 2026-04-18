# ■ Azure VPN Gateway + BGP の構成要点
#
# 1. SKU: VpnGw1AZ (non-AZ SKU は Azure が廃止済み)
#    AZ SKU では Public IP にも zones 指定が必須。
#
# 2. BGP 設定の 3 箇所すべてが必要:
#    - VPN Gateway: enable_bgp = true, bgp_settings.peering_addresses.apipa_addresses
#    - Local Network Gateway: bgp_settings (相手側 ASN + peering_address)
#    - Connection: enable_bgp = true, custom_bgp_addresses.primary
#    いずれか 1 つでも欠けると BGP セッションが確立しない。
#
# 3. APIPA アドレス制約:
#    Azure の apipa_addresses は 169.254.21.0 - 169.254.22.255 の範囲のみ許可。
#    AWS 側 VPN Connection の tunnel_inside_cidr もこの範囲内に収める必要がある。
#    AWS がランダムに割り当てるデフォルト値 (169.254.x.x) は範囲外になることが多い。
#
# 4. custom_bgp_addresses:
#    Connection に custom_bgp_addresses を設定しないと、Azure VPN GW は
#    デフォルト BGP IP (GatewaySubnet 内, 例: 172.16.255.30) を BGP ソースとして使用する。
#    AWS は tunnel inside address (169.254.21.2) からの BGP しか受け付けないため、
#    custom_bgp_addresses.primary で明示的に指定する必要がある。
#
resource "azurerm_public_ip" "vpngw" {
  name                = "${var.project}-vpngw-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
}

resource "azurerm_virtual_network_gateway" "this" {
  name                = "${var.project}-vpngw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  type          = "Vpn"
  vpn_type      = "RouteBased"
  active_active = false
  enable_bgp    = true
  sku           = "VpnGw1AZ"

  ip_configuration {
    name                          = "default"
    public_ip_address_id          = azurerm_public_ip.vpngw.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
  }

  bgp_settings {
    asn = 65515

    peering_addresses {
      ip_configuration_name = "default"
      apipa_addresses       = ["169.254.21.2"]
    }
  }
}

# AWS 側 VPN 出力が揃ってから apply (var で制御)
locals {
  create_connection = var.aws_vpn_tunnel1_address != "" && var.aws_vpn_tunnel1_psk != ""
}

resource "azurerm_local_network_gateway" "aws" {
  count               = local.create_connection ? 1 : 0
  name                = "${var.project}-lng-aws"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  gateway_address     = var.aws_vpn_tunnel1_address
  address_space       = [var.aws_vpc_cidr]

  bgp_settings {
    asn                 = var.aws_side_asn
    bgp_peering_address = "169.254.21.1"
  }
}

resource "azurerm_virtual_network_gateway_connection" "aws" {
  count               = local.create_connection ? 1 : 0
  name                = "${var.project}-conn-aws"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.this.id
  local_network_gateway_id   = azurerm_local_network_gateway.aws[0].id

  shared_key = var.aws_vpn_tunnel1_psk
  enable_bgp = true

  custom_bgp_addresses {
    primary = "169.254.21.2"
  }
}
