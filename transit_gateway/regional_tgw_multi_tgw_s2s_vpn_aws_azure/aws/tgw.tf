resource "aws_ec2_transit_gateway" "this" {
  description                     = "${var.project} TGW"
  amazon_side_asn                 = 64512
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"
  tags                            = { Name = "${var.project}-tgw" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = aws_ec2_transit_gateway.this.id
  vpc_id             = aws_vpc.this.id
  subnet_ids         = [aws_subnet.tgw_a.id, aws_subnet.tgw_c.id]

  # appliance_mode_support を enable にすると AZ またぎが保たれる (非対称経路防止)
  # 今回は検証観点なので disable のまま
  appliance_mode_support = "disable"
  dns_support            = "enable"

  tags = { Name = "${var.project}-tgw-attach-vpc" }
}

# VM public IP を TGW ルートテーブルに static route として追加。
# TGW が BGP で Azure に広告し、Azure VPN GW がこれらの宛先をトンネル経由と認識する。
#
# ■ なぜ必要か
#   Azure VPN GW は BGP learned routes に含まれる宛先のみトンネルに転送する。
#   VPC CIDR (10.0.0.0/16) は TGW が自動広告するが、VM の Public IP は
#   AWS のアドレス空間外のため自動広告されない。
#   TGW static route として登録することで BGP 広告対象に含まれる。
#   Azure UDR (VM_IP/32 -> VirtualNetworkGateway) だけでは不十分で、
#   VPN GW 側にも対応する BGP ルートが必要。
resource "aws_ec2_transit_gateway_route" "vm01_via_vpc" {
  count                          = var.azure_vm01_public_ip != "" ? 1 : 0
  destination_cidr_block         = "${var.azure_vm01_public_ip}/32"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this.association_default_route_table_id
}

resource "aws_ec2_transit_gateway_route" "vm02_via_vpc" {
  count                          = var.azure_vm02_public_ip != "" ? 1 : 0
  destination_cidr_block         = "${var.azure_vm02_public_ip}/32"
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this.association_default_route_table_id
}
