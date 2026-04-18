# 確認コマンド集

確認は以下の順序で実施する。各ステップが OK であることを確認してから次に進む。

---

## Step 1. VPN トンネル状態の確認

VPN が UP / BGP が確立されていないと後続の疎通確認は全て失敗する。

### AWS 側: VPN Tunnel Telemetry

```bash
cd aws
CONN_ID=$(terraform output -raw vpn_connection_id 2>/dev/null || \
  terraform state show 'aws_vpn_connection.azure[0]' | awk '/^\s*id\s*=/ {print $3; exit}' | tr -d '"')
aws ec2 describe-vpn-connections --vpn-connection-ids "$CONN_ID" \
  --query 'VpnConnections[].VgwTelemetry[].{Outside:OutsideIpAddress,Status:Status,Msg:StatusMessage}' \
  --output table
```

出力例:
```
+----------------+------------------+---------+
|       Msg      |     Outside      | Status  |
+----------------+------------------+---------+
|  1 BGP ROUTES  |  18.176.149.241  |  UP     |  ★ Tunnel 1: UP + BGP ROUTES があれば正常
|  IPSEC IS DOWN |  52.195.139.241  |  DOWN   |  ★ Tunnel 2: active-passive のため DOWN で正常
+----------------+------------------+---------+
```

**判定ポイント:**
- Tunnel 1 が `UP` + `N BGP ROUTES` → 正常
- `IPSEC IS UP` だが Status `DOWN` → IPsec は確立しているが BGP が未確立 (Azure 側の BGP 設定を確認)
- 両方 `DOWN` → IPsec 自体が未確立 (PSK / peer IP の不一致を疑う)

### Azure 側: BGP ピア状態

```bash
az network vnet-gateway list-bgp-peer-status \
  --resource-group tgw-regional-ngw-s2s-rg \
  --name tgw-regional-ngw-s2s-vpngw \
  --output table
```

出力例:
```
Neighbor         ASN    State        ConnectedDuration    RoutesReceived    MessagesSent    MessagesReceived
---------------  -----  -----------  -------------------  ----------------  --------------  ------------------
169.254.21.1     64512  Connected    01:23:45             3                 100             98
                                                          ★ RoutesReceived > 0 かつ State=Connected なら正常
```

**判定ポイント:**
- `State: Connected` + `RoutesReceived > 0` → 正常
- `State: Connecting` → BGP セッション未確立 (APIPA アドレス不一致、custom_bgp_addresses 未設定を疑う)
- 行が空 → Connection の enable_bgp が false

---

## Step 2. BGP ルート広告の確認

VPN が UP でも、必要なルートが広告されていないとトラフィックがトンネルに入らない。

```bash
az network vnet-gateway list-learned-routes \
  --resource-group tgw-regional-ngw-s2s-rg \
  --name tgw-regional-ngw-s2s-vpngw \
  --output table
```

出力例:
```
Network           NextHop       Origin    SourcePeer     AsPath    Weight
----------------  ------------  --------  -------------  --------  --------
172.16.0.0/16                   Network   172.16.255.30            32768     ★ Azure VNet (自身)
10.0.0.0/16       169.254.21.1  EBgp      169.254.21.1   64512     32768     ★ AWS VPC CIDR (BGP受信)
20.63.177.124/32  169.254.21.1  EBgp      169.254.21.1   64512     32768     ★ VM01 Public IP (BGP受信, TGW static route)
20.89.103.44/32   169.254.21.1  EBgp      169.254.21.1   64512     32768     ★ VM02 Public IP (BGP受信, TGW static route)
169.254.21.1/32                 Network   172.16.255.30            32768
```

**判定ポイント:**
- VM01/VM02 の Public IP /32 が `EBgp` で表示 → TGW static route が BGP で広告されている
- VM Public IP が表示されない → TGW ルートテーブルに static route が未登録
- 10.0.0.0/16 が表示されない → BGP 自体が未確立

---

## Step 3. Azure NIC の Effective Routes 確認

UDR + BGP ルートが VM の NIC に反映されているか確認する。

```bash
az network nic show-effective-route-table \
  --resource-group tgw-regional-ngw-s2s-rg \
  --name tgw-regional-ngw-s2s-vm1-nic \
  --output table
```

出力例 (抜粋):
```
Source                 State    Address Prefix    Next Hop Type          Next Hop IP
---------------------  -------  ----------------  ---------------------  -------------
User                   Active   20.89.103.44/32   VirtualNetworkGateway                ★ VM02 宛が VPN GW に向いている
User                   Active   20.63.177.124/32  VirtualNetworkGateway                ★ VM01 宛も同様
User                   Active   10.0.0.0/16       VirtualNetworkGateway                ★ AWS VPC 宛
VirtualNetworkGateway  Active   10.0.0.0/16       VirtualNetworkGateway  20.44.169.122  ★ BGP で受信したルート
Default                Active   0.0.0.0/0         Internet                             ★ その他はインターネット直接
```

**判定ポイント:**
- `20.89.103.44/32 -> VirtualNetworkGateway` が `Active` → UDR でトラフィックが VPN GW に向いている
- `State: Invalid` → 別のルートに上書きされている

---

## Step 4. ICMP 疎通確認

SSH ログイン後、最も基本的な疎通テスト。

```bash
ssh azureuser@<VM01_IP>
```

```bash
ping -c 3 <VM02_IP>
```

出力例:
```
PING 20.89.103.44 (20.89.103.44) 56(84) bytes of data.
64 bytes from 20.89.103.44: icmp_seq=1 ttl=46 time=9.01 ms   ★ 応答あり = 往復経路が確立
64 bytes from 20.89.103.44: icmp_seq=2 ttl=46 time=11.1 ms
64 bytes from 20.89.103.44: icmp_seq=3 ttl=46 time=6.87 ms    ★ TTL=46: 複数ホップ経由 (VPN+NAT GW+Internet)

--- 20.89.103.44 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2002ms
```

**判定ポイント:**
- `0% packet loss` → ICMP 往復経路が確立
- `100% packet loss` → Step 1-3 を再確認。VPN / BGP / ルーティングのいずれかに問題あり

---

## Step 5. HTTP 経由の送信元 IP 確認 (経路検証の本題)

nginx の `/whoami` エンドポイントがリクエスト元 IP を返す。NAT GW / EC2 NAT instance の EIP が表示されることで経路を判定する。

### VM01 → VM02 (Regional NAT GW 経路)

VM01 上で実行:
```bash
curl -s http://<VM02_IP>/whoami
```

出力例:
```
remote_addr=52.198.215.194      ★ Regional NAT GW の EIP が表示されれば正常
host=tgw-regional-ngw-s2s-vm2   ★ VM02 のホスト名
```

**判定ポイント:**
- `remote_addr` が NAT GW EIP (52.193.165.2 or 52.198.215.194) → Regional NAT GW 経路で正常
- `remote_addr` が VM01 自身の Public IP → NAT GW を経由していない (UDR/BGP ルートの問題)
- タイムアウト → NSG で HTTP (port 80) が許可されていない、または経路断

### VM02 → VM01 (EC2 NAT instance 経路)

VM02 上で実行:
```bash
curl -s http://<VM01_IP>/whoami
```

出力例:
```
remote_addr=13.230.83.106       ★ EC2-c NAT instance の EIP が表示されれば正常
host=tgw-regional-ngw-s2s-vm1
```

**判定ポイント:**
- `remote_addr` が EC2-c EIP → EC2 NAT instance 経路で正常

---

## Step 6. nginx アクセスログによる送信元 IP の確認

VM 側のログでも送信元を検証する (Step 5 の裏取り)。

VM02 上で実行:
```bash
sudo tail -10 /var/log/nginx/access.log
```

出力例:
```
52.198.215.194 - - [18/Apr/2026:15:30:01 +0000] "GET /whoami HTTP/1.1" 200 52 "-" "curl/7.81.0"
★ 先頭の IP が Regional NAT GW EIP (52.198.215.194) であれば VM01 -> VM02 経路を確認
```

VM01 上で実行:
```bash
sudo tail -10 /var/log/nginx/access.log
```

出力例:
```
13.230.83.106 - - [18/Apr/2026:15:31:01 +0000] "GET /whoami HTTP/1.1" 200 52 "-" "curl/7.81.0"
★ 先頭の IP が EC2-c EIP (13.230.83.106) であれば VM02 -> VM01 経路を確認
```

---

## Step 7. AWS Flow Logs による詳細経路分析

通信が AWS 内部のどのコンポーネントを経由したかを確認する。

### TGW Flow Logs (Azure -> AWS 到着の確認)

```bash
aws logs filter-log-events \
  --log-group-name /aws/tgw/tgw-regional-ngw-s2s/flow \
  --filter-pattern '"172.16."' \
  --start-time $(date -d '10 minutes ago' +%s000) \
  --max-items 10
```

出力例 (主要フィールド抜粋):
```
172.16.1.4 20.89.103.44 ... 1 3 252 ... OK ... apne1-az1 ... ingress
★ srcaddr=172.16.1.4 (VM01 private IP), dstaddr=20.89.103.44 (VM02 public IP)
★ apne1-az1: TGW が Az-a 側で受信
★ ingress: VPN attachment からの受信
```

### VPC Flow Logs (NAT GW 処理の確認)

```bash
aws logs filter-log-events \
  --log-group-name /aws/vpc/tgw-regional-ngw-s2s/flow \
  --log-stream-name-prefix "nat-" \
  --filter-pattern '"<VM02_IP>"' \
  --start-time $(date -d '10 minutes ago' +%s000) \
  --max-items 10
```

出力例:
```
172.16.1.4 20.89.103.44 ... ACCEPT ... ingress     ★ NAT GW が受信 (NAT 前)
52.198.215.194 20.89.103.44 ... ACCEPT ... egress   ★ NAT GW が送出 (NAT 後, ソース変換済み)
20.89.103.44 52.198.215.194 ... ACCEPT ... ingress  ★ VM02 からの応答が NAT GW に到着
```

**判定ポイント:**
- ingress (NAT 前) + egress (NAT 後) + ingress (応答) の 3 行が揃う → NAT GW の往復処理が正常
- ingress のみ、egress なし → NAT GW の自動生成 RT に戻りルートがない

---

## Step 8. Cross-AZ 判定

TGW が通信をどの AZ に振り分けたかを確認する。

```bash
aws logs filter-log-events \
  --log-group-name /aws/vpc/tgw-regional-ngw-s2s/flow \
  --filter-pattern '"172.16.1.4"' \
  --start-time $(date -d '10 minutes ago' +%s000) \
  --max-items 20
```

出力内の `az-id` フィールドを確認:
```
... apne1-az1 subnet-06cd2b4d4df22854a egress    ★ Az-1 の TGW ENI を経由
```

- `apne1-az1` のみ → 同一 AZ 内で完結 (Cross-AZ なし)
- `apne1-az1` と `apne1-az4` が混在 → Cross-AZ トラフィック発生
- `appliance_mode_support = "enable"` にすると同一フロー内で AZ が固定される

---

## トラブルシューティング用コマンド

### Azure VPN Connection の状態

```bash
az network vpn-connection show \
  --resource-group tgw-regional-ngw-s2s-rg \
  --name tgw-regional-ngw-s2s-conn-aws \
  --query '{status:connectionStatus, enableBgp:enableBgp, inBytes:ingressBytesTransferred, outBytes:egressBytesTransferred}'
```

### AWS TGW サブネットのルートテーブル

```bash
aws ec2 describe-route-tables \
  --filters Name=tag:Name,Values=tgw-regional-ngw-s2s-rt-tgw \
  --query 'RouteTables[].Routes[].{Dest:DestinationCidrBlock,NatGw:NatGatewayId,Igw:GatewayId,Eni:NetworkInterfaceId,Tgw:TransitGatewayId}' \
  --output table
```

### Regional NAT GW 自動生成ルートテーブル

```bash
NAT_RT=$(cd aws && terraform output -json | python3 -c "
import json,sys
# NAT GW の route_table_id は terraform state から取得
" 2>/dev/null || true)
# GUI で確認: VPC > NAT Gateways > 対象 NAT GW > Route table タブ
# 172.16.0.0/16 -> TGW のルートが存在することを確認
```

### Regional NAT GW の状態

```bash
aws ec2 describe-nat-gateways \
  --filter Name=tag:Name,Values=tgw-regional-ngw-s2s-natgw-regional \
  --query 'NatGateways[].{Id:NatGatewayId,State:State,Mode:ConnectivityType,AzMode:AvailabilityMode}'
```
