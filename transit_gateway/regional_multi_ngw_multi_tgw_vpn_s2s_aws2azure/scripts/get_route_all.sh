#!/usr/bin/env bash
###############################################################################
# get_route_all.sh — AWS / Azure 全ルートテーブルの網羅的取得
#
# 取得内容:
#   [AWS]
#     1. VPC 内の全ルートテーブル (明示作成 + VPC メイン RT + NAT GW 自動生成 RT)
#        - RT ID / Name / 関連付け (サブネット or ゲートウェイ) / 全ルート
#     2. VPC 内の全サブネット一覧 (RT との対応確認用)
#     3. Regional NAT GW 情報 (自動生成 RT ID を含む)
#     4. TGW ルートテーブル (default RT の全ルート + attachment 情報)
#     5. TGW attachment 一覧 (VPC / VPN の区別)
#
#   [Azure]
#     6. UDR (Route Table) の全ルート定義
#     7. VM NIC の Effective Routes (UDR + BGP + System Route の実効値)
#     8. VPN Gateway の BGP Learned Routes
#     9. NSG ルール一覧
#
# 前提: AWS CLI / Azure CLI 認証済み、全段階の Terraform apply 完了
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AWS_DIR="$ROOT/aws"
AZ_DIR="$ROOT/azure"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/get_route_all_$(date +%Y%m%d_%H%M).log"
exec > >(tee "$LOGFILE") 2>&1
echo "Log: $LOGFILE"
echo "取得日時: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- 変数取得 ---
VPC_ID=$(cd "$AWS_DIR" && terraform output -raw vpc_id)
TGW_ID=$(cd "$AWS_DIR" && terraform output -raw tgw_id)
PROJECT="tgw-regional-ngw-s2s"
RG="${PROJECT}-rg"
VPNGW="${PROJECT}-vpngw"

echo
echo "################################################################"
echo "# AWS"
echo "################################################################"

echo
echo "============================================================"
echo " A1. VPC サブネット一覧"
echo "============================================================"
aws ec2 describe-subnets \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[].{Id:SubnetId,Name:Tags[?Key==`Name`].Value|[0],Cidr:CidrBlock,Az:AvailabilityZone}' \
  --output table

echo
echo "============================================================"
echo " A2. VPC 内の全ルートテーブル"
echo "============================================================"
echo "  (明示作成 + VPC メイン RT + NAT GW 自動生成 RT を含む)"
echo

RT_IDS=$(aws ec2 describe-route-tables \
  --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'RouteTables[].RouteTableId' --output text)

for RT_ID in $RT_IDS; do
  RT_NAME=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Tags[?Key==`Name`].Value|[0]' --output text 2>/dev/null)
  IS_MAIN=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Associations[?Main==`true`] | length(@)' --output text)
  ASSOC_SUBNETS=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Associations[?SubnetId!=`null`].SubnetId' --output text)
  ASSOC_GW=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Associations[?GatewayId!=`null`].GatewayId' --output text)

  echo "------------------------------------------------------------"
  echo "  RT: $RT_ID"
  if [[ "$RT_NAME" != "None" && -n "$RT_NAME" ]]; then
    echo "  Name: $RT_NAME"
  fi
  if [[ "$IS_MAIN" -gt 0 ]]; then
    echo "  Type: VPC メインルートテーブル (暗黙作成)"
  fi
  if [[ -n "$ASSOC_SUBNETS" && "$ASSOC_SUBNETS" != "None" ]]; then
    echo "  関連付け (Subnet): $ASSOC_SUBNETS"
  fi
  if [[ -n "$ASSOC_GW" && "$ASSOC_GW" != "None" ]]; then
    echo "  関連付け (Gateway): $ASSOC_GW"
  fi
  if [[ -z "$ASSOC_SUBNETS" || "$ASSOC_SUBNETS" == "None" ]] && \
     [[ -z "$ASSOC_GW" || "$ASSOC_GW" == "None" ]] && \
     [[ "$IS_MAIN" -eq 0 ]]; then
    echo "  関連付け: なし (孤立 RT)"
  fi
  echo

  aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Routes[].{Dest:DestinationCidrBlock,GatewayId:GatewayId,NatGatewayId:NatGatewayId,NetworkInterfaceId:NetworkInterfaceId,TransitGatewayId:TransitGatewayId,State:State,Origin:Origin}' \
    --output table
  echo
done

echo
echo "============================================================"
echo " A3. Regional NAT GW 情報"
echo "============================================================"
NATGW_RT=$(cd "$AWS_DIR" && terraform state show 'aws_nat_gateway.regional' 2>/dev/null \
  | awk '/^\s*route_table_id\s*=/ {print $3; exit}' | tr -d '"' || echo "")
NATGW_ID=$(cd "$AWS_DIR" && terraform state show 'aws_nat_gateway.regional' 2>/dev/null \
  | awk '/^\s*id\s*=/ {gsub(/"/, ""); print $3; exit}' || echo "")
echo "  NAT GW ID:       $NATGW_ID"
echo "  自動生成 RT ID:  $NATGW_RT"
echo
echo "  上記 RT は A2 セクション内で $NATGW_RT として出力済み"
echo "  関連付け (Gateway) に $NATGW_ID が表示されていれば NAT GW の自動生成 RT"

echo
echo "============================================================"
echo " A4. TGW Attachment 一覧"
echo "============================================================"
aws ec2 describe-transit-gateway-attachments \
  --filters Name=transit-gateway-id,Values="$TGW_ID" \
  --query 'TransitGatewayAttachments[].{Id:TransitGatewayAttachmentId,Type:ResourceType,ResourceId:ResourceId,State:State}' \
  --output table

echo
echo "============================================================"
echo " A5. TGW ルートテーブル"
echo "============================================================"
TGW_RT_ID=$(aws ec2 describe-transit-gateways \
  --transit-gateway-ids "$TGW_ID" \
  --query 'TransitGateways[0].Options.AssociationDefaultRouteTableId' --output text)
echo "  TGW Default RT: $TGW_RT_ID"
echo
aws ec2 search-transit-gateway-routes \
  --transit-gateway-route-table-id "$TGW_RT_ID" \
  --filters "Name=type,Values=static,propagated" \
  --query 'Routes[].{Dest:DestinationCidrBlock,Type:Type,State:State,AttachId:TransitGatewayAttachments[0].TransitGatewayAttachmentId,ResourceType:TransitGatewayAttachments[0].ResourceType}' \
  --output table

echo
echo "################################################################"
echo "# Azure"
echo "################################################################"

echo
echo "============================================================"
echo " B1. UDR (Route Table) 定義内容"
echo "============================================================"
az network route-table route list \
  --resource-group "$RG" \
  --route-table-name "${PROJECT}-rt-vm" \
  --output table 2>/dev/null \
  || echo "  (UDR not available)"

echo
echo "============================================================"
echo " B2. VM1 NIC Effective Routes"
echo "============================================================"
echo "  (UDR + BGP + Azure System Route の実効値)"
echo
az network nic show-effective-route-table \
  --resource-group "$RG" \
  --name "${PROJECT}-vm1-nic" \
  --output table 2>/dev/null \
  || echo "  (Effective routes not available)"

echo
echo "============================================================"
echo " B3. VM2 NIC Effective Routes"
echo "============================================================"
az network nic show-effective-route-table \
  --resource-group "$RG" \
  --name "${PROJECT}-vm2-nic" \
  --output table 2>/dev/null \
  || echo "  (Effective routes not available)"

echo
echo "============================================================"
echo " B4. VPN Gateway BGP Learned Routes"
echo "============================================================"
az network vnet-gateway list-learned-routes \
  --resource-group "$RG" \
  --name "$VPNGW" \
  --output table 2>/dev/null \
  || echo "  (BGP learned routes not available)"

echo
echo "============================================================"
echo " B5. VPN Gateway BGP Advertised Routes (to AWS)"
echo "============================================================"
BGP_PEER=$(az network vnet-gateway list-bgp-peer-status \
  --resource-group "$RG" --name "$VPNGW" \
  --query 'value[0].neighbor' --output tsv 2>/dev/null || echo "")
if [[ -n "$BGP_PEER" ]]; then
  az network vnet-gateway list-advertised-routes \
    --resource-group "$RG" \
    --name "$VPNGW" \
    --peer "$BGP_PEER" \
    --output table 2>/dev/null \
    || echo "  (Advertised routes not available)"
else
  echo "  (BGP peer not found)"
fi

echo
echo "============================================================"
echo " B6. NSG ルール一覧"
echo "============================================================"
az network nsg rule list \
  --resource-group "$RG" \
  --nsg-name "${PROJECT}-vm-nsg" \
  --output table 2>/dev/null \
  || echo "  (NSG rules not available)"

echo
echo "============================================================"
echo " B7. GatewaySubnet の Effective Routes (System Routes)"
echo "============================================================"
echo "  (GatewaySubnet には NIC がないため直接取得不可。"
echo "   BGP learned/advertised routes で代替確認済み)"

echo
echo "  完了。サマリは check_route_table_summary.md として別途作成"
