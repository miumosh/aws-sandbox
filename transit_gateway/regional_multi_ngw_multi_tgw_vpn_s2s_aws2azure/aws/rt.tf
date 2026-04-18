# ------------------------------------------------------------------------------
# Regional Nat Gateway 用 Route Tables (自動生成)
# TGW への戻りルート追加
# ------------------------------------------------------------------------------
# TGW サブネット (Public): Azure からの通信を宛先ベースで分岐
# これがないと NAT GW は de-NAT 後のパケット (dest: 172.16.x.x) をドロップする。
# 自動生成 RT には IGW ルートのみプリセットされるため、VPC CIDR 外への戻りは明示追加が必須。
resource "aws_route" "natgw_return_to_azure" {
  route_table_id         = aws_nat_gateway.regional.route_table_id
  destination_cidr_block = var.azure_vnet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# ------------------------------------------------------------------------------
# Transit Gateway 用 Route Tables
# ------------------------------------------------------------------------------
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

# Transit Gateway 用 各サブネットの Route Tables
# ------------------------------------------------------------------------------
resource "aws_route_table" "tgw" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-rt-tgw" }
}

# default: IGW (NAT GW の上流経路として必要)
resource "aws_route" "tgw_default" {
  route_table_id         = aws_route_table.tgw.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

# VM01 -> VM02 経路: TGW subnet 内の NAT GW へ
resource "aws_route" "tgw_to_vm02" {
  count                  = var.azure_vm02_public_ip != "" ? 1 : 0
  route_table_id         = aws_route_table.tgw.id
  destination_cidr_block = "${var.azure_vm02_public_ip}/32"
  nat_gateway_id         = aws_nat_gateway.regional.id
}

# VM02 -> VM01 経路: EC2 サブネットの EC2 (NAT instance, EIP 保持) の ENI へ
resource "aws_route" "tgw_to_vm01" {
  count                  = var.azure_vm01_public_ip != "" ? 1 : 0
  route_table_id         = aws_route_table.tgw.id
  destination_cidr_block = "${var.azure_vm01_public_ip}/32"
  network_interface_id   = aws_instance.ec2_c.primary_network_interface_id
}

# Azure VNet 宛の戻り: TGW
resource "aws_route" "tgw_to_azure" {
  route_table_id         = aws_route_table.tgw.id
  destination_cidr_block = var.azure_vnet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "tgw_a" {
  subnet_id      = aws_subnet.tgw_a.id
  route_table_id = aws_route_table.tgw.id
}

resource "aws_route_table_association" "tgw_c" {
  subnet_id      = aws_subnet.tgw_c.id
  route_table_id = aws_route_table.tgw.id
}

# ------------------------------------------------------------------------------
# EC2 用 Route Tables
# ------------------------------------------------------------------------------
# EC2 サブネット (NAT GW を持つ public 兼用 az-c, Dummy EC2 用 az-a)
resource "aws_route_table" "ec2_a" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-rt-ec2-a" }
}

resource "aws_route_table" "ec2_c" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-rt-ec2-c" }
}

# EC2 サブネットは両方 public (EC2 に EIP を付け、IGW 直送)
resource "aws_route" "ec2_a_default" {
  route_table_id         = aws_route_table.ec2_a.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route" "ec2_c_default" {
  route_table_id         = aws_route_table.ec2_c.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route" "ec2_a_to_azure" {
  route_table_id         = aws_route_table.ec2_a.id
  destination_cidr_block = var.azure_vnet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route" "ec2_c_to_azure" {
  route_table_id         = aws_route_table.ec2_c.id
  destination_cidr_block = var.azure_vnet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route_table_association" "ec2_a" {
  subnet_id      = aws_subnet.ec2_a.id
  route_table_id = aws_route_table.ec2_a.id
}

resource "aws_route_table_association" "ec2_c" {
  subnet_id      = aws_subnet.ec2_c.id
  route_table_id = aws_route_table.ec2_c.id
}
