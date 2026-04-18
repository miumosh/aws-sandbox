###
# Azure 側 VPN Gateway を Customer Gateway として AWS に登録し、
# TGW に Site-to-Site VPN attachment として紐付ける。
# azure_vpn_gateway_public_ip が空なら VPN リソースは作らない。
###

locals {
  create_vpn = var.azure_vpn_gateway_public_ip != ""
}

resource "aws_customer_gateway" "azure" {
  count      = local.create_vpn ? 1 : 0
  bgp_asn    = 65515 # Azure VPN Gateway default ASN
  ip_address = var.azure_vpn_gateway_public_ip
  type       = "ipsec.1"
  tags       = { Name = "${var.project}-cgw-azure" }
}

# BGP (static_routes_only = false) を使用する。
# tunnel_inside_cidr は Azure APIPA 範囲 (169.254.21.0 - 169.254.22.255) 内に
# 収める必要がある。範囲外の場合、Azure VPN GW の bgp_settings.peering_addresses に
# apipa_addresses として登録できず BGP セッションが確立されない。
# /30 内の割当: .1 = AWS VGW, .2 = Azure CGW
resource "aws_vpn_connection" "azure" {
  count               = local.create_vpn ? 1 : 0
  customer_gateway_id = aws_customer_gateway.azure[0].id
  transit_gateway_id  = aws_ec2_transit_gateway.this.id
  type                = "ipsec.1"
  static_routes_only  = false
  tunnel1_inside_cidr = "169.254.21.0/30"
  tunnel2_inside_cidr = "169.254.21.4/30"
  tags                = { Name = "${var.project}-vpn-azure" }
}
