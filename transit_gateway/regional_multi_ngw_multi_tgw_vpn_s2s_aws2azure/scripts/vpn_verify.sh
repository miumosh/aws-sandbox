#!/usr/bin/env bash
###############################################################################
# vpn_verify.sh — VPN トンネル状態 / BGP セッション / BGP ルート広告の確認
#
# 確認内容:
#   1. Terraform outputs (AWS / Azure 双方の IP・ID 一覧)
#   2. AWS 側 VPN Tunnel Telemetry (IPsec UP/DOWN, BGP ROUTES)
#   3. Azure 側 BGP ピア状態 (Connected / Connecting)
#   4. Azure 側 BGP Learned Routes (AWS から広告されたルート)
#   5. 期待する送信元 IP のサマリ
#
# 前提: AWS CLI / Azure CLI 認証済み、全段階の Terraform apply 完了
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AWS_DIR="$ROOT/aws"
AZ_DIR="$ROOT/azure"
RG="tgw-regional-ngw-s2s-rg"
VPNGW="tgw-regional-ngw-s2s-vpngw"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/vpn_verify_$(date +%Y%m%d_%H%M).log"
exec > >(tee "$LOGFILE") 2>&1
echo "Log: $LOGFILE"

echo "============================================================"
echo " 1. Terraform Outputs"
echo "============================================================"
echo "--- AWS ---"
cd "$AWS_DIR" && terraform output
echo
echo "--- Azure ---"
cd "$AZ_DIR" && terraform output

echo
echo "============================================================"
echo " 2. VPN Tunnel Status (AWS side)"
echo "============================================================"
cd "$AWS_DIR"
CONN_ID=$(terraform state show 'aws_vpn_connection.azure[0]' 2>/dev/null \
  | awk '/^\s*id\s*=/ {print $3; exit}' | tr -d '"' || true)
if [[ -n "$CONN_ID" ]]; then
  aws ec2 describe-vpn-connections --vpn-connection-ids "$CONN_ID" \
    --query 'VpnConnections[].VgwTelemetry[].{Outside:OutsideIpAddress,Status:Status,Msg:StatusMessage}' \
    --output table
  echo
  echo "  判定: Tunnel 1 が UP + 'N BGP ROUTES' であれば正常"
  echo "        Tunnel 2 は active-passive のため DOWN で正常"
else
  echo "  (VPN Connection が未作成)"
fi

echo
echo "============================================================"
echo " 3. BGP Peer Status (Azure side)"
echo "============================================================"
az network vnet-gateway list-bgp-peer-status \
  --resource-group "$RG" --name "$VPNGW" --output table 2>/dev/null \
  || echo "  (BGP peer status not available)"
echo
echo "  判定: State=Connected, RoutesReceived > 0 であれば正常"

echo
echo "============================================================"
echo " 4. BGP Learned Routes (Azure side)"
echo "============================================================"
az network vnet-gateway list-learned-routes \
  --resource-group "$RG" --name "$VPNGW" --output table 2>/dev/null \
  || echo "  (BGP learned routes not available)"
echo
echo "  判定: VM Public IP /32 が EBgp (AsPath=64512) で表示されていること"

VM01_IP=$(cd "$AZ_DIR" && terraform output -raw vm01_public_ip 2>/dev/null || echo "")
VM02_IP=$(cd "$AZ_DIR" && terraform output -raw vm02_public_ip 2>/dev/null || echo "")
NATGW_EIP_A=$(cd "$AWS_DIR" && terraform output -raw natgw_regional_eip_a 2>/dev/null || echo "")
NATGW_EIP_C=$(cd "$AWS_DIR" && terraform output -raw natgw_regional_eip_c 2>/dev/null || echo "")
EC2_C_EIP=$(cd "$AWS_DIR" && terraform output -raw ec2_c_public_ip 2>/dev/null || echo "")

echo
echo "============================================================"
echo " 5. 期待する送信元 IP サマリ"
echo "============================================================"
echo "  VM01 ($VM01_IP) -> VM02 ($VM02_IP) : Regional NAT GW  期待ソース: $NATGW_EIP_A or $NATGW_EIP_C"
echo "  VM02 ($VM02_IP) -> VM01 ($VM01_IP) : EC2-c NAT inst.  期待ソース: $EC2_C_EIP"
echo
echo "  次のステップ: ./routing_verify.sh でルートテーブルを確認"
