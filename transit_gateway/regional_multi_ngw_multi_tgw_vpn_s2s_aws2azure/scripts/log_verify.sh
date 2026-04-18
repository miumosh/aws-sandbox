#!/usr/bin/env bash
###############################################################################
# log_verify.sh — AWS TGW Flow Logs / VPC Flow Logs の確認
#
# 確認内容:
#   1. TGW Flow Logs: Azure (172.16.x.x) からの到着パケット
#   2. VPC Flow Logs: TGW ENI 上のトラフィック (NAT 前)
#   3. VPC Flow Logs: Regional NAT GW のトラフィック (NAT 前 ingress / NAT 後 egress / 応答 ingress)
#   4. Cross-AZ 判定: TGW ENI の az-id 分布
#
# 前提: AWS CLI 認証済み、network_verify.sh で疎通確認後に実行 (Flow Logs の集約に最大 10 分)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AWS_DIR="$ROOT/aws"
AZ_DIR="$ROOT/azure"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/log_verify_$(date +%Y%m%d_%H%M).log"
exec > >(tee "$LOGFILE") 2>&1
echo "Log: $LOGFILE"

TGW_LOG=$(cd "$AWS_DIR" && terraform output -raw tgw_flow_log_group)
VPC_LOG=$(cd "$AWS_DIR" && terraform output -raw vpc_flow_log_group)
VM01_IP=$(cd "$AZ_DIR" && terraform output -raw vm01_public_ip)
VM02_IP=$(cd "$AZ_DIR" && terraform output -raw vm02_public_ip)

SINCE=$(date -d '15 minutes ago' +%s000 2>/dev/null || date -v-15M +%s000 2>/dev/null || echo "")
if [[ -z "$SINCE" ]]; then
  echo "WARNING: date コマンドの形式が不明。--start-time を省略"
  TIME_OPT=""
else
  TIME_OPT="--start-time $SINCE"
fi

echo "============================================================"
echo " 対象ログ"
echo "============================================================"
echo "  TGW Flow Log: $TGW_LOG"
echo "  VPC Flow Log: $VPC_LOG"
echo "  VM01: $VM01_IP  VM02: $VM02_IP"
echo "  検索範囲: 過去 15 分"

echo
echo "============================================================"
echo " 1. TGW Flow Logs: Azure (172.16.x.x) からの到着"
echo "============================================================"
echo "  確認ポイント:"
echo "    - srcaddr=172.16.1.x, dstaddr=VM Public IP が表示されること"
echo "    - ingress = VPN attachment からの受信"
echo "    - egress  = VPC attachment への転送"
echo
aws logs filter-log-events \
  --log-group-name "$TGW_LOG" \
  --filter-pattern '"172.16."' \
  $TIME_OPT \
  --max-items 20 \
  --query 'events[].message' \
  --output text 2>/dev/null | head -20 || echo "  (ログなし。集約待ちの可能性あり)"

echo
echo "============================================================"
echo " 2. VPC Flow Logs: TGW ENI トラフィック (172.16.x.x)"
echo "============================================================"
echo "  確認ポイント:"
echo "    - srcaddr=10.0.x.x (TGW ENI IP), pkt-srcaddr=172.16.1.x が表示されること"
echo "    - egress 方向 = TGW ENI から NAT GW / EC2 ENI への転送"
echo
aws logs filter-log-events \
  --log-group-name "$VPC_LOG" \
  --filter-pattern '"172.16.1"' \
  $TIME_OPT \
  --max-items 20 \
  --query 'events[].message' \
  --output text 2>/dev/null | head -20 || echo "  (ログなし)"

echo
echo "============================================================"
echo " 3. VPC Flow Logs: Regional NAT GW トラフィック"
echo "============================================================"
echo "  確認ポイント (3 行が揃えば NAT GW 往復処理が正常):"
echo "    - ingress: 172.16.1.x -> VM02_IP (NAT 前の受信)"
echo "    - egress:  NAT_GW_EIP -> VM02_IP (NAT 後の送出)"
echo "    - ingress: VM02_IP -> NAT_GW_EIP (応答の受信)"
echo
echo "--- VM02 ($VM02_IP) 宛の NAT GW トラフィック ---"
aws logs filter-log-events \
  --log-group-name "$VPC_LOG" \
  --log-stream-name-prefix "nat-" \
  --filter-pattern "\"$VM02_IP\"" \
  $TIME_OPT \
  --max-items 20 \
  --query 'events[].message' \
  --output text 2>/dev/null | head -20 || echo "  (ログなし)"

echo
echo "--- VM01 ($VM01_IP) 宛の NAT GW トラフィック ---"
aws logs filter-log-events \
  --log-group-name "$VPC_LOG" \
  --log-stream-name-prefix "nat-" \
  --filter-pattern "\"$VM01_IP\"" \
  $TIME_OPT \
  --max-items 20 \
  --query 'events[].message' \
  --output text 2>/dev/null | head -20 || echo "  (ログなし)"

echo
echo "============================================================"
echo " 4. Cross-AZ 判定"
echo "============================================================"
echo "  確認ポイント:"
echo "    - az-id フィールドで TGW ENI の AZ を確認"
echo "    - apne1-az1 のみ → 同一 AZ 内で完結"
echo "    - apne1-az1 と apne1-az4 が混在 → Cross-AZ トラフィック発生"
echo
echo "  az-id の分布:"
aws logs filter-log-events \
  --log-group-name "$VPC_LOG" \
  --filter-pattern '"172.16.1" "egress"' \
  $TIME_OPT \
  --max-items 50 \
  --query 'events[].message' \
  --output text 2>/dev/null \
  | awk '{for(i=1;i<=NF;i++){if($i ~ /apne1-az/){print $i}}}' \
  | sort | uniq -c | sort -rn \
  || echo "  (データ不足)"

echo
echo "============================================================"
echo " Flow Log フィールド参照 (VPC)"
echo "============================================================"
echo "  version account interface srcaddr dstaddr srcport dstport proto"
echo "  packets bytes start end action log-status pkt-srcaddr pkt-dstaddr"
echo "  az-id subnet-id flow-direction"
echo
echo "  詳細は scripts/commands.md を参照"
