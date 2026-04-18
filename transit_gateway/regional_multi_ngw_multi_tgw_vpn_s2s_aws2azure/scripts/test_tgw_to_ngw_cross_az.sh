#!/usr/bin/env bash
###############################################################################
# test_tgw_to_ngw_cross_az.sh — Cross-AZ 判定テスト (VM01 → VM02 大量アクセス)
#
# 目的:
#   VM01 から VM02 に対して HTTP リクエストを 100 回実行し、
#   全リクエストが同一 AZ 内で完結しているか (Cross-AZ が発生していないか) を
#   VPC Flow Logs / TGW Flow Logs から統計的に判定する。
#
# 確認観点:
#   1. TGW ENI がどの AZ (subnet) で受信したか
#   2. Regional NAT GW がどの AZ で処理し、どの EIP を使用したか
#   3. Cross-AZ トラフィックの発生率
#
# 使い方:
#   SSHPASS=<password> ./test_tgw_to_ngw_cross_az.sh
#   または環境変数 VM_PASSWORD を設定
#
# 前提:
#   - Azure VM に SSH 可能、nginx 起動済み
#   - VPC Flow Logs / TGW Flow Logs が有効
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AWS_DIR="$ROOT/aws"
AZ_DIR="$ROOT/azure"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/test_tgw_to_ngw_cross_az_$(date +%Y%m%d_%H%M).log"
exec > >(tee "$LOGFILE") 2>&1
echo "Log: $LOGFILE"
echo "実行日時: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- 変数取得 ---
VM01_IP=$(cd "$AZ_DIR" && terraform output -raw vm01_public_ip)
VM02_IP=$(cd "$AZ_DIR" && terraform output -raw vm02_public_ip)
NATGW_EIP_A=$(cd "$AWS_DIR" && terraform output -raw natgw_regional_eip_a)
NATGW_EIP_C=$(cd "$AWS_DIR" && terraform output -raw natgw_regional_eip_c)
TGW_LOG=$(cd "$AWS_DIR" && terraform output -raw tgw_flow_log_group)
VPC_LOG=$(cd "$AWS_DIR" && terraform output -raw vpc_flow_log_group)

REQUEST_COUNT=100
WAIT_SECONDS=300

echo
echo "============================================================"
echo " テスト条件"
echo "============================================================"
echo "  VM01 (src)      : $VM01_IP (172.16.1.4)"
echo "  VM02 (dst)      : $VM02_IP"
echo "  NAT GW EIP-a    : $NATGW_EIP_A (ap-northeast-1a = apne1-az4)"
echo "  NAT GW EIP-c    : $NATGW_EIP_C (ap-northeast-1c = apne1-az1)"
echo "  リクエスト数     : $REQUEST_COUNT"
echo "  Flow Log 待機    : ${WAIT_SECONDS}秒 (集約反映待ち)"
echo "  経路: VM01 → VPN → TGW → tgw-subnet → Regional NAT GW → IGW → VM02"

# --- SSH 準備 ---
echo
echo "============================================================"
echo " 1. SSH 準備"
echo "============================================================"
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM01_IP" 2>/dev/null || true

if ! command -v sshpass &>/dev/null; then
  echo "  ERROR: sshpass が必要です。sudo apt-get install -y sshpass"
  exit 1
fi

export SSHPASS="${SSHPASS:-${VM_PASSWORD:-}}"
if [[ -z "$SSHPASS" ]]; then
  echo -n "  Azure VM パスワード: "
  read -rs SSHPASS
  echo
  export SSHPASS
fi

SSH_CMD="sshpass -e ssh"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

run_ssh() {
  $SSH_CMD $SSH_OPTS azureuser@"$VM01_IP" "$@" 2>/dev/null
}

# --- テスト前タイムスタンプ ---
TEST_START=$(date +%s)
TEST_START_MS=$((TEST_START * 1000))

echo
echo "============================================================"
echo " 2. VM01 → VM02 HTTP リクエスト ${REQUEST_COUNT} 回実行"
echo "============================================================"
echo "  開始: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo

# VM01 上で 100 回 curl を実行し、各レスポンスの remote_addr を収集
RESULT=$(run_ssh "for i in \$(seq 1 $REQUEST_COUNT); do curl -s --max-time 5 http://$VM02_IP/whoami | head -1; done")

if [[ -z "$RESULT" ]]; then
  echo "  ERROR: SSH 接続またはリクエストに失敗"
  exit 1
fi

echo "  完了: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- レスポンス集計 ---
echo
echo "============================================================"
echo " 3. レスポンス集計 (remote_addr = NAT 後のソース IP)"
echo "============================================================"

TOTAL=$(echo "$RESULT" | wc -l)
EIP_A_COUNT=$(echo "$RESULT" | grep -c "$NATGW_EIP_A" || true)
EIP_C_COUNT=$(echo "$RESULT" | grep -c "$NATGW_EIP_C" || true)
OTHER_COUNT=$((TOTAL - EIP_A_COUNT - EIP_C_COUNT))

echo "  総リクエスト数 : $TOTAL"
echo
echo "  | EIP | AZ | 件数 | 割合 |"
echo "  |-----|----|------|------|"
printf "  | %s | ap-northeast-1a (apne1-az4) | %d | %s |\n" "$NATGW_EIP_A" "$EIP_A_COUNT" "$(awk "BEGIN{printf \"%.1f%%\", $EIP_A_COUNT * 100 / $TOTAL}")"
printf "  | %s | ap-northeast-1c (apne1-az1) | %d | %s |\n" "$NATGW_EIP_C" "$EIP_C_COUNT" "$(awk "BEGIN{printf \"%.1f%%\", $EIP_C_COUNT * 100 / $TOTAL}")"
if [[ "$OTHER_COUNT" -gt 0 ]]; then
  printf "  | (その他/エラー) | — | %d | %s |\n" "$OTHER_COUNT" "$(awk "BEGIN{printf \"%.1f%%\", $OTHER_COUNT * 100 / $TOTAL}")"
fi

echo
if [[ "$EIP_A_COUNT" -eq 0 || "$EIP_C_COUNT" -eq 0 ]]; then
  USED_AZ=""
  if [[ "$EIP_A_COUNT" -gt 0 ]]; then USED_AZ="ap-northeast-1a (apne1-az4)"; fi
  if [[ "$EIP_C_COUNT" -gt 0 ]]; then USED_AZ="ap-northeast-1c (apne1-az1)"; fi
  echo "  >>> 判定: 全 $TOTAL 件が単一 AZ ($USED_AZ) の EIP を使用。Cross-AZ なし"
else
  echo "  >>> 判定: 複数 AZ の EIP が使用されている。NAT GW 側で Cross-AZ の可能性あり"
  echo "           (TGW のフローハッシュにより入口 AZ が分散した可能性)"
fi

# --- VM02 アクセスログ集計 ---
echo
echo "============================================================"
echo " 4. VM02 nginx アクセスログ集計 (送信元 IP)"
echo "============================================================"

ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM02_IP" 2>/dev/null || true
VM02_LOG=$($SSH_CMD $SSH_OPTS azureuser@"$VM02_IP" "sudo tail -${REQUEST_COUNT} /var/log/nginx/access.log 2>/dev/null | grep '/whoami' | awk '{print \$1}' | sort | uniq -c | sort -rn" 2>/dev/null || echo "")

if [[ -n "$VM02_LOG" ]]; then
  echo "  | 件数 | 送信元 IP |"
  echo "  |------|----------|"
  echo "$VM02_LOG" | while read -r count ip; do
    printf "  | %d | %s |\n" "$count" "$ip"
  done
else
  echo "  (ログ取得失敗)"
fi

# --- Flow Logs 待機 ---
echo
echo "============================================================"
echo " 5. Flow Logs 集約待機 (${WAIT_SECONDS}秒)"
echo "============================================================"
echo "  Flow Logs は最大 10 分の集約遅延があるため待機します"
echo "  開始: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  完了予定: $(date -d "+${WAIT_SECONDS} seconds" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -v+${WAIT_SECONDS}S '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "unknown")"
echo

ELAPSED=0
INTERVAL=30
while [[ $ELAPSED -lt $WAIT_SECONDS ]]; do
  REMAINING=$((WAIT_SECONDS - ELAPSED))
  printf "\r  待機中... 残り %d 秒  " "$REMAINING"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo
echo "  待機完了: $(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- TGW Flow Logs 分析 ---
echo
echo "============================================================"
echo " 6. TGW Flow Logs: 入口 AZ の分布"
echo "============================================================"
echo "  検索: srcaddr=172.16.1.4, dstaddr=$VM02_IP"
echo

TGW_FLOWS=$(aws logs filter-log-events \
  --log-group-name "$TGW_LOG" \
  --filter-pattern "\"172.16.1.4\" \"$VM02_IP\"" \
  --start-time "$TEST_START_MS" \
  --query 'events[].message' \
  --output text 2>/dev/null || echo "")

if [[ -n "$TGW_FLOWS" ]]; then
  echo "  --- 入口 AZ (ingress) の分布 ---"
  echo "$TGW_FLOWS" | tr '\t' '\n' | grep "ingress" | \
    awk '{for(i=1;i<=NF;i++){if($i ~ /apne1-az/){az=$i}; if($i ~ /subnet-/){sn=$i}}; if(az!="") print az, sn}' | \
    sort | uniq -c | sort -rn | while read -r count az subnet; do
      printf "  | %d 件 | %s | %s |\n" "$count" "$az" "$subnet"
    done

  echo
  echo "  --- 出口 AZ (egress → VPC) の分布 ---"
  echo "$TGW_FLOWS" | tr '\t' '\n' | grep "egress" | \
    awk '{for(i=1;i<=NF;i++){if($i ~ /apne1-az/){az=$i}; if($i ~ /subnet-/){sn=$i}}; if(az!="") print az, sn}' | \
    sort | uniq -c | sort -rn | while read -r count az subnet; do
      printf "  | %d 件 | %s | %s |\n" "$count" "$az" "$subnet"
    done
else
  echo "  (TGW Flow Logs にデータなし。集約遅延の可能性あり)"
fi

# --- VPC Flow Logs: NAT GW 処理 AZ 分析 ---
echo
echo "============================================================"
echo " 7. VPC Flow Logs: Regional NAT GW の処理 AZ 分布"
echo "============================================================"
echo "  検索: NAT GW ストリーム (nat-*), dstaddr=$VM02_IP"
echo

NATGW_FLOWS=$(aws logs filter-log-events \
  --log-group-name "$VPC_LOG" \
  --log-stream-name-prefix "nat-" \
  --filter-pattern "\"$VM02_IP\"" \
  --start-time "$TEST_START_MS" \
  --query 'events[].message' \
  --output text 2>/dev/null || echo "")

if [[ -n "$NATGW_FLOWS" ]]; then
  echo "  --- NAT GW ingress (NAT 前) の AZ 分布 ---"
  echo "$NATGW_FLOWS" | tr '\t' '\n' | grep "ingress" | \
    awk '{for(i=1;i<=NF;i++){if($i ~ /apne1-az/){print $i}}}' | \
    sort | uniq -c | sort -rn | while read -r count az; do
      printf "  | %d 件 | %s |\n" "$count" "$az"
    done

  echo
  echo "  --- NAT GW egress (NAT 後) の AZ + ソース IP 分布 ---"
  echo "$NATGW_FLOWS" | tr '\t' '\n' | grep "egress" | \
    awk '{for(i=1;i<=NF;i++){if($i ~ /apne1-az/){az=$i}}; print az, $4}' | \
    sort | uniq -c | sort -rn | while read -r count az srcip; do
      printf "  | %d 件 | %s | src=%s |\n" "$count" "$az" "$srcip"
    done
else
  echo "  (NAT GW Flow Logs にデータなし。集約遅延の可能性あり)"
fi

# --- VPC Flow Logs: TGW ENI の AZ 分布 ---
echo
echo "============================================================"
echo " 8. VPC Flow Logs: TGW ENI トラフィックの AZ 分布"
echo "============================================================"
echo "  検索: pkt-srcaddr=172.16.1.4, pkt-dstaddr=$VM02_IP"
echo

ENI_FLOWS=$(aws logs filter-log-events \
  --log-group-name "$VPC_LOG" \
  --filter-pattern "\"172.16.1.4\" \"$VM02_IP\" \"egress\"" \
  --start-time "$TEST_START_MS" \
  --query 'events[].message' \
  --output text 2>/dev/null || echo "")

if [[ -n "$ENI_FLOWS" ]]; then
  echo "  --- TGW ENI egress の AZ + subnet 分布 ---"
  echo "$ENI_FLOWS" | tr '\t' '\n' | grep -v "^$" | \
    awk '{for(i=1;i<=NF;i++){if($i ~ /apne1-az/){az=$i}; if($i ~ /subnet-/){sn=$i}}; if(az!="") print az, sn}' | \
    sort | uniq -c | sort -rn | while read -r count az subnet; do
      printf "  | %d 件 | %s | %s |\n" "$count" "$az" "$subnet"
    done
else
  echo "  (VPC Flow Logs にデータなし。集約遅延の可能性あり)"
fi

# --- 総合判定 ---
echo
echo "============================================================"
echo " 9. 総合判定"
echo "============================================================"
echo
echo "  AZ ID マッピング (本アカウント):"
echo "    apne1-az1 = ap-northeast-1c (tgw-subnet-c / NAT GW EIP-c: $NATGW_EIP_C)"
echo "    apne1-az4 = ap-northeast-1a (tgw-subnet-a / NAT GW EIP-a: $NATGW_EIP_A)"
echo

echo "  HTTP レスポンスによる EIP 分布:"
echo "    EIP-a ($NATGW_EIP_A, Az-a): $EIP_A_COUNT / $TOTAL 件"
echo "    EIP-c ($NATGW_EIP_C, Az-c): $EIP_C_COUNT / $TOTAL 件"
echo

if [[ "$EIP_A_COUNT" -eq 0 && "$EIP_C_COUNT" -eq "$TOTAL" ]]; then
  echo "  >>> 結論: 全 $TOTAL 件が Az-c (apne1-az1) で処理。Cross-AZ は発生していない"
  echo "            TGW 入口も NAT GW 処理も同一 AZ で完結"
elif [[ "$EIP_C_COUNT" -eq 0 && "$EIP_A_COUNT" -eq "$TOTAL" ]]; then
  echo "  >>> 結論: 全 $TOTAL 件が Az-a (apne1-az4) で処理。Cross-AZ は発生していない"
  echo "            TGW 入口も NAT GW 処理も同一 AZ で完結"
elif [[ "$EIP_A_COUNT" -gt 0 && "$EIP_C_COUNT" -gt 0 ]]; then
  echo "  >>> 結論: 複数 AZ に分散。ただしこれは Cross-AZ とは限らない"
  echo "            TGW のフローハッシュにより入口 AZ が分散し、"
  echo "            各 AZ の NAT GW が同一 AZ 内で処理した可能性がある"
  echo "            Flow Logs の AZ ペア (TGW ENI az-id vs NAT GW az-id) で詳細判定"
  echo
  echo "  Cross-AZ の定義: TGW ENI の AZ ≠ NAT GW 処理の AZ"
  echo "  Flow Logs の Section 6-8 で AZ ペアを確認してください"
fi

echo
echo "  テスト完了: $(date '+%Y-%m-%d %H:%M:%S %Z')"
