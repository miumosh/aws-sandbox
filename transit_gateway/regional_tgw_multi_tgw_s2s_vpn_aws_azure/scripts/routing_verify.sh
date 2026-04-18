#!/usr/bin/env bash
###############################################################################
# routing_verify.sh — AWS / Azure 双方のルートテーブル確認
#
# 確認内容:
#   1. AWS TGW サブネットのルートテーブル (policy routing)
#   2. AWS Regional NAT GW 自動生成ルートテーブル (de-NAT 戻りルート)
#   3. AWS EC2 サブネットのルートテーブル
#   4. AWS TGW ルートテーブル (BGP 広告用 static routes)
#   5. Azure NIC Effective Routes (UDR + BGP の実効ルート)
#   6. Azure UDR (Route Table) の定義内容
#
# 前提: AWS CLI / Azure CLI 認証済み、全段階の Terraform apply 完了
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AWS_DIR="$ROOT/aws"
AZ_DIR="$ROOT/azure"
PROJECT="tgw-regional-ngw-s2s"
RG="${PROJECT}-rg"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/routing_verify_$(date +%Y%m%d_%H%M).log"
exec > >(tee "$LOGFILE") 2>&1
echo "Log: $LOGFILE"

echo "============================================================"
echo " 1. AWS TGW サブネット RT (policy routing)"
echo "============================================================"
echo "  VM Public IP /32 -> NAT GW or EC2 ENI のルートが存在すること"
echo
aws ec2 describe-route-tables \
  --filters Name=tag:Name,Values="${PROJECT}-rt-tgw" \
  --query 'RouteTables[].Routes[].{Dest:DestinationCidrBlock,NatGw:NatGatewayId,Igw:GatewayId,Eni:NetworkInterfaceId,Tgw:TransitGatewayId,Status:State}' \
  --output table

echo
echo "============================================================"
echo " 2. AWS Regional NAT GW 自動生成 RT (de-NAT 戻りルート)"
echo "============================================================"
echo "  172.16.0.0/16 -> TGW のルートが存在すること (なければ de-NAT 後ドロップ)"
echo
cd "$AWS_DIR"
NATGW_RT=$(terraform state show 'aws_nat_gateway.regional' 2>/dev/null \
  | awk '/^\s*route_table_id\s*=/ {print $3; exit}' | tr -d '"' || true)
if [[ -n "$NATGW_RT" ]]; then
  aws ec2 describe-route-tables \
    --route-table-ids "$NATGW_RT" \
    --query 'RouteTables[].Routes[].{Dest:DestinationCidrBlock,Igw:GatewayId,Tgw:TransitGatewayId,Status:State}' \
    --output table
else
  echo "  (NAT GW route_table_id を取得できず。GUI で確認: VPC > NAT Gateways > Route table タブ)"
fi

echo
echo "============================================================"
echo " 3. AWS EC2 サブネット RT"
echo "============================================================"
echo "--- ec2-a ---"
aws ec2 describe-route-tables \
  --filters Name=tag:Name,Values="${PROJECT}-rt-ec2-a" \
  --query 'RouteTables[].Routes[].{Dest:DestinationCidrBlock,Igw:GatewayId,Tgw:TransitGatewayId,Status:State}' \
  --output table
echo "--- ec2-c ---"
aws ec2 describe-route-tables \
  --filters Name=tag:Name,Values="${PROJECT}-rt-ec2-c" \
  --query 'RouteTables[].Routes[].{Dest:DestinationCidrBlock,Igw:GatewayId,Tgw:TransitGatewayId,Status:State}' \
  --output table

echo
echo "============================================================"
echo " 4. AWS TGW ルートテーブル (static routes / BGP 広告)"
echo "============================================================"
echo "  VM Public IP /32 -> VPC attachment の static route が存在すること"
echo
TGW_ID=$(cd "$AWS_DIR" && terraform output -raw tgw_id 2>/dev/null || echo "")
if [[ -n "$TGW_ID" ]]; then
  TGW_RT=$(aws ec2 describe-transit-gateways \
    --transit-gateway-ids "$TGW_ID" \
    --query 'TransitGateways[0].Options.AssociationDefaultRouteTableId' \
    --output text)
  aws ec2 search-transit-gateway-routes \
    --transit-gateway-route-table-id "$TGW_RT" \
    --filters "Name=type,Values=static,propagated" \
    --query 'Routes[].{Dest:DestinationCidrBlock,Type:Type,State:State,AttachId:TransitGatewayAttachments[0].TransitGatewayAttachmentId}' \
    --output table
fi

echo
echo "============================================================"
echo " 5. Azure NIC Effective Routes (VM1)"
echo "============================================================"
echo "  VM02_IP/32 -> VirtualNetworkGateway が Active であること"
echo
az network nic show-effective-route-table \
  --resource-group "$RG" \
  --name "${PROJECT}-vm1-nic" \
  --output table 2>/dev/null \
  || echo "  (Effective routes not available)"

echo
echo "============================================================"
echo " 6. Azure UDR 定義内容"
echo "============================================================"
az network route-table route list \
  --resource-group "$RG" \
  --route-table-name "${PROJECT}-rt-vm" \
  --output table 2>/dev/null \
  || echo "  (UDR not available)"

echo
echo "  次のステップ: ./network_verify.sh で疎通確認"
