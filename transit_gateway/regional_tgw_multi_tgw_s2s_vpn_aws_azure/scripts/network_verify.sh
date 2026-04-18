#!/usr/bin/env bash
###############################################################################
# network_verify.sh — 疎通確認 (ICMP / HTTP / nginx アクセスログ)
#
# 確認内容:
#   0. SSH known_hosts のリセット + sshpass の確認
#   1. VM01 -> AWS EC2 private IP への ICMP (VPN トンネル基本疎通)
#   2. VM01 -> VM02 Public IP への ICMP (NAT GW 経由の往復経路)
#   3. VM01 -> VM02 HTTP /whoami (送信元 IP = NAT GW EIP であること)
#   4. VM02 -> VM01 HTTP /whoami (送信元 IP = EC2-c EIP であること)
#   5. VM02 nginx アクセスログ (VM01 からのリクエストの送信元確認)
#   6. VM01 nginx アクセスログ (VM02 からのリクエストの送信元確認)
#
# 使い方:
#   SSHPASS=<password> ./network_verify.sh
#   または環境変数 VM_PASSWORD を設定
#
# 前提: Azure VM に SSH 可能、cloud-init 完了済み (nginx 起動済み)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AWS_DIR="$ROOT/aws"
AZ_DIR="$ROOT/azure"

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/network_verify_$(date +%Y%m%d_%H%M).log"
exec > >(tee "$LOGFILE") 2>&1
echo "Log: $LOGFILE"

VM01_IP=$(cd "$AZ_DIR" && terraform output -raw vm01_public_ip)
VM02_IP=$(cd "$AZ_DIR" && terraform output -raw vm02_public_ip)
EC2_A_IP=$(cd "$AWS_DIR" && terraform output -raw ec2_a_private_ip)
NATGW_EIP_A=$(cd "$AWS_DIR" && terraform output -raw natgw_regional_eip_a)
NATGW_EIP_C=$(cd "$AWS_DIR" && terraform output -raw natgw_regional_eip_c)
EC2_C_EIP=$(cd "$AWS_DIR" && terraform output -raw ec2_c_public_ip)

echo "============================================================"
echo " 0. SSH 準備"
echo "============================================================"

# known_hosts から VM エントリを削除 (VM 再作成時のホストキー不一致を回避)
echo "  known_hosts から $VM01_IP, $VM02_IP を削除..."
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM01_IP" 2>/dev/null || true
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$VM02_IP" 2>/dev/null || true

# sshpass の確認
if ! command -v sshpass &>/dev/null; then
  echo "  WARNING: sshpass が未インストール。SSH 接続時にパスワード入力が必要"
  echo "  インストール: sudo apt-get install -y sshpass"
  SSH_CMD="ssh"
else
  # SSHPASS 環境変数または VM_PASSWORD から取得
  export SSHPASS="${SSHPASS:-${VM_PASSWORD:-}}"
  if [[ -z "$SSHPASS" ]]; then
    echo -n "  Azure VM パスワード: "
    read -rs SSHPASS
    echo
    export SSHPASS
  fi
  SSH_CMD="sshpass -e ssh"
fi

SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

run_ssh() {
  local host="$1"
  shift
  $SSH_CMD $SSH_OPTS azureuser@"$host" "$@" 2>/dev/null
}

echo
echo "============================================================"
echo " 変数一覧"
echo "============================================================"
echo "  VM01_IP     = $VM01_IP"
echo "  VM02_IP     = $VM02_IP"
echo "  EC2_A_IP    = $EC2_A_IP (private)"
echo "  NATGW_EIP_A = $NATGW_EIP_A"
echo "  NATGW_EIP_C = $NATGW_EIP_C"
echo "  EC2_C_EIP   = $EC2_C_EIP"

echo
echo "============================================================"
echo " 1. VM01 -> AWS EC2-a private IP (VPN トンネル基本疎通)"
echo "============================================================"
echo "  期待: 応答あり (0% packet loss)"
echo
run_ssh "$VM01_IP" "ping -c 3 -W 5 $EC2_A_IP" || echo "  *** FAIL: VPN トンネル経由の基本疎通に失敗。vpn_verify.sh を確認"

echo
echo "============================================================"
echo " 2. VM01 -> VM02 Public IP ICMP (NAT GW 往復経路)"
echo "============================================================"
echo "  期待: 応答あり (0% packet loss, TTL=46 前後)"
echo
run_ssh "$VM01_IP" "ping -c 3 -W 5 $VM02_IP" || echo "  *** FAIL: NAT GW 経由の ICMP 疎通に失敗。routing_verify.sh を確認"

echo
echo "============================================================"
echo " 3. VM01 -> VM02 HTTP /whoami (Regional NAT GW 経路)"
echo "============================================================"
echo "  期待: remote_addr=$NATGW_EIP_A or $NATGW_EIP_C"
echo
RESULT=$(run_ssh "$VM01_IP" "curl -s --max-time 10 http://$VM02_IP/whoami" || echo "TIMEOUT")
echo "  結果: $RESULT"
if echo "$RESULT" | grep -qE "$NATGW_EIP_A|$NATGW_EIP_C"; then
  echo "  >>> OK: Regional NAT GW 経路を確認"
elif echo "$RESULT" | grep -q "TIMEOUT"; then
  echo "  >>> FAIL: タイムアウト。NSG で HTTP (port 80) が許可されているか確認"
else
  echo "  >>> WARN: 期待する NAT GW EIP と異なる送信元。routing_verify.sh を確認"
fi

echo
echo "============================================================"
echo " 4. VM02 -> VM01 HTTP /whoami (EC2 NAT instance 経路)"
echo "============================================================"
echo "  期待: remote_addr=$EC2_C_EIP"
echo
RESULT=$(run_ssh "$VM02_IP" "curl -s --max-time 10 http://$VM01_IP/whoami" || echo "TIMEOUT")
echo "  結果: $RESULT"
if echo "$RESULT" | grep -q "$EC2_C_EIP"; then
  echo "  >>> OK: EC2 NAT instance 経路を確認"
elif echo "$RESULT" | grep -q "TIMEOUT"; then
  echo "  >>> FAIL: タイムアウト。routing_verify.sh を確認"
else
  echo "  >>> WARN: 期待する EC2-c EIP と異なる送信元。routing_verify.sh を確認"
fi

echo
echo "============================================================"
echo " 5. VM02 nginx アクセスログ (VM01 からのリクエスト)"
echo "============================================================"
echo "  期待: 先頭 IP が NAT GW EIP ($NATGW_EIP_A or $NATGW_EIP_C)"
echo
run_ssh "$VM02_IP" "sudo tail -5 /var/log/nginx/access.log" || echo "  (ログ取得失敗)"

echo
echo "============================================================"
echo " 6. VM01 nginx アクセスログ (VM02 からのリクエスト)"
echo "============================================================"
echo "  期待: 先頭 IP が EC2-c EIP ($EC2_C_EIP)"
echo
run_ssh "$VM01_IP" "sudo tail -5 /var/log/nginx/access.log" || echo "  (ログ取得失敗)"

echo
echo "  次のステップ: ./log_verify.sh で AWS Flow Logs を確認"
