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

resource "aws_eip" "nat_regional_a" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip-regional-a" }
}

resource "aws_eip" "nat_regional_c" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip-regional-c" }
}