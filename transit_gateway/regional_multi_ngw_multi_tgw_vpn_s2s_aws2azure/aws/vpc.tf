resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-igw" }
}

# --- Subnets ---
# tgw-subnet-a: TGW attachment + NAT GW (VM01 -> VM02 経路用)
# tgw-subnet-c: TGW attachment のみ
# ec2-subnet-a: Dummy EC2 配置用 (NAT GW 経由の戻り検証)
# ec2-subnet-c: NAT GW (VM02 -> VM01 経路用) + Dummy EC2
resource "aws_subnet" "tgw_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.tgw_subnet_a_cidr
  availability_zone = var.az_a
  tags              = { Name = "${var.project}-tgw-a" }
}

resource "aws_subnet" "tgw_c" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.tgw_subnet_c_cidr
  availability_zone = var.az_c
  tags              = { Name = "${var.project}-tgw-c" }
}

resource "aws_subnet" "ec2_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.ec2_subnet_a_cidr
  availability_zone       = var.az_a
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project}-ec2-a" }
}

resource "aws_subnet" "ec2_c" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.ec2_subnet_c_cidr
  availability_zone       = var.az_c
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project}-ec2-c" }
}

# --- Regional NAT Gateway (VPC スコープ, サブネット不要) ---
#
# Regional NAT GW は Zonal NAT GW と異なり subnet_id を指定しない。
# 作成時に AWS がルートテーブルを自動生成し、IGW へのデフォルトルートがプリセットされる。
# このルートテーブルは aws_nat_gateway.regional.route_table_id で参照可能。
#
# ■ 戻りルーティングの注意点 (de-NAT 後のパケット)
#   Zonal NAT GW: 配置サブネットの RT が de-NAT 後の戻りルーティングを担う。
#   Regional NAT GW: 自動生成ルートテーブルが担う。VPC CIDR 外の戻り先
#     (例: Azure VNet 172.16.0.0/16) は明示的にルートを追加する必要がある。
#     追加しないと de-NAT 後のパケットがドロップされる。
#
# ■ やってはいけないこと
#   aws_route_table_association の gateway_id に NAT GW ID を指定する
#   「エッジルートテーブル」方式は IGW / VGW 専用であり、NAT GW は非対応。
#   API エラー: "invalid value for parameter gateway-id: nat-xxx"
#
# ■ 正しいアプローチ
#   aws_nat_gateway.regional.route_table_id (自動生成 RT) に aws_route でルートを追加する。
#   TGW は Regional NAT GW ルートテーブルの正式なターゲットとして AWS がサポートしている。
#   参照: https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html
#
resource "aws_eip" "nat_regional_a" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip-regional-a" }
}

resource "aws_eip" "nat_regional_c" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip-regional-c" }
}

resource "aws_nat_gateway" "regional" {
  vpc_id            = aws_vpc.this.id
  connectivity_type = "public"
  availability_mode = "regional"

  availability_zone_address {
    allocation_ids    = [aws_eip.nat_regional_a.id]
    availability_zone = var.az_a
  }

  availability_zone_address {
    allocation_ids    = [aws_eip.nat_regional_c.id]
    availability_zone = var.az_c
  }

  tags       = { Name = "${var.project}-natgw-regional" }
  depends_on = [aws_internet_gateway.this]
}

# --- Route Tables ---
# TGW サブネット (Public): Azure からの通信を宛先ベースで分岐
# Regional NAT GW 自動生成ルートテーブルへの戻りルート追加。
# これがないと NAT GW は de-NAT 後のパケット (dest: 172.16.x.x) をドロップする。
# 自動生成 RT には IGW ルートのみプリセットされるため、VPC CIDR 外への戻りは明示追加が必須。
resource "aws_route" "natgw_return_to_azure" {
  route_table_id         = aws_nat_gateway.regional.route_table_id
  destination_cidr_block = var.azure_vnet_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.this.id
  depends_on             = [aws_ec2_transit_gateway_vpc_attachment.this]
}

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
