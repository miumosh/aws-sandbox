# 検証結果サマリ

検証日時: 2026-04-18 17:57〜18:12 JST

## 総合判定

| # | 経路 | 想定パス | 実測ソース IP | 判定 |
|---|------|----------|---------------|------|
| 1 | VM01 → VM02 | Azure VM01 → VPN → TGW → Regional NAT GW → IGW → Internet → Azure VM02 | `52.198.215.194` (NAT GW EIP-c) | OK |
| 2 | VM02 → VM01 | Azure VM02 → VPN → TGW → EC2-c NAT instance → IGW → Internet → Azure VM01 | `13.230.83.106` (EC2-c EIP) | OK |

---

## 1. VPN / BGP 状態 (vpn_verify)

### AWS VPN Tunnel Telemetry

| Tunnel | Outside IP | Status | Message | 判定 |
|--------|-----------|--------|---------|------|
| 1 | 18.176.149.241 | **UP** | 1 BGP ROUTES | 正常 |
| 2 | 52.195.139.241 | DOWN | IPSEC IS DOWN | 正常 (active-passive) |

### Azure BGP Peer Status

| Neighbor | ASN | State | Connected Duration | Routes Received | 判定 |
|----------|-----|-------|--------------------|-----------------|------|
| 169.254.21.1 | 64512 | **Connected** | 02:12:44 | 3 | 正常 |

### Azure BGP Learned Routes

| Network | NextHop | Origin | AsPath | 説明 |
|---------|---------|--------|--------|------|
| 172.16.0.0/16 | — | Network | — | Azure VNet (自身) |
| 10.0.0.0/16 | 169.254.21.1 | EBgp | 64512 | AWS VPC CIDR |
| 20.63.177.124/32 | 169.254.21.1 | EBgp | 64512 | VM01 Public IP (TGW static route) |
| 20.89.103.44/32 | 169.254.21.1 | EBgp | 64512 | VM02 Public IP (TGW static route) |
| 169.254.21.1/32 | — | Network | — | Tunnel inside IP |

---

## 2. ルートテーブル (routing_verify)

### AWS TGW サブネット RT (policy routing)

| Destination | Target | Type | Status | 用途 |
|-------------|--------|------|--------|------|
| 20.89.103.44/32 | nat-12522e133b562f6f1 | NAT GW | active | VM01→VM02: Regional NAT GW 経由 |
| 20.63.177.124/32 | eni-0a6432b8a429614cd | ENI | active | VM02→VM01: EC2-c NAT instance 経由 |
| 172.16.0.0/16 | tgw-0772038b1359447b4 | TGW | active | Azure VNet 戻り |
| 10.0.0.0/16 | local | IGW | active | VPC ローカル |
| 0.0.0.0/0 | igw-09c1ef699611c053b | IGW | active | デフォルト |

### AWS Regional NAT GW 自動生成 RT

| Destination | Target | Status | 備考 |
|-------------|--------|--------|------|
| 172.16.0.0/16 | tgw-0772038b1359447b4 | active | de-NAT 後の戻り (手動追加、必須) |
| 10.0.0.0/16 | local | active | VPC ローカル |
| 0.0.0.0/0 | igw-09c1ef699611c053b | active | AWS がプリセット |

### AWS TGW ルートテーブル (BGP 広告)

| Destination | Attachment | Type | Status | 説明 |
|-------------|-----------|------|--------|------|
| 10.0.0.0/16 | tgw-attach-0a1a1c729f04353eb (VPC) | propagated | active | VPC CIDR 自動伝播 |
| 172.16.0.0/16 | tgw-attach-09ffabfc234f289c6 (VPN) | propagated | active | Azure VNet BGP 受信 |
| 20.63.177.124/32 | tgw-attach-0a1a1c729f04353eb (VPC) | static | active | VM01 IP → Azure に BGP 広告 |
| 20.89.103.44/32 | tgw-attach-0a1a1c729f04353eb (VPC) | static | active | VM02 IP → Azure に BGP 広告 |

### Azure NIC Effective Routes (VM1, 抜粋)

| Source | State | Address Prefix | Next Hop Type | 説明 |
|--------|-------|---------------|---------------|------|
| User | **Active** | 20.89.103.44/32 | VirtualNetworkGateway | VM02 宛 → VPN 経由 |
| User | **Active** | 20.63.177.124/32 | VirtualNetworkGateway | VM01 宛 → VPN 経由 |
| User | **Active** | 10.0.0.0/16 | VirtualNetworkGateway | AWS VPC 宛 → VPN 経由 |
| Default | Active | 0.0.0.0/0 | Internet | その他 → 直接インターネット |

### Azure UDR 定義

| Address Prefix | Name | Next Hop Type | Status |
|---------------|------|---------------|--------|
| 20.63.177.124/32 | to-peer-vm1 | VirtualNetworkGateway | Succeeded |
| 20.89.103.44/32 | to-peer-vm2 | VirtualNetworkGateway | Succeeded |
| 10.0.0.0/16 | to-aws | VirtualNetworkGateway | Succeeded |

---

## 3. 疎通確認 (network_verify)

### ICMP

| テスト | Source | Destination | 結果 | RTT (avg) | TTL |
|--------|--------|-------------|------|-----------|-----|
| VPN 基本疎通 | VM01 (172.16.1.4) | EC2-a (10.0.1.161) | **0% loss** | 5.99ms | 125 |
| NAT GW 経由 | VM01 (172.16.1.4) | VM02 (20.89.103.44) | **0% loss** | 7.17ms | 46 |

### HTTP /whoami (送信元 IP 判定)

| テスト | Source VM | Destination VM | remote_addr (実測) | 期待値 | 判定 |
|--------|-----------|---------------|-------------------|--------|------|
| Regional NAT GW 経路 | VM01 | VM02 | **52.198.215.194** | 52.193.165.2 or 52.198.215.194 | OK |
| EC2 NAT instance 経路 | VM02 | VM01 | **13.230.83.106** | 13.230.83.106 | OK |

### nginx アクセスログ

| VM | ログ内の送信元 IP | 期待値 | リクエスト | 判定 |
|----|------------------|--------|-----------|------|
| VM02 | 52.198.215.194 | NAT GW EIP | GET /whoami | OK |
| VM01 | 13.230.83.106 | EC2-c EIP | GET /whoami | OK |

---

## 4. AWS Flow Logs 分析 (log_verify)

### TGW Flow Logs: VM01 → VM02 (Regional NAT GW 経路)

| 方向 | src | dst | proto | port | attachment | az-id | 説明 |
|------|-----|-----|-------|------|-----------|-------|------|
| ingress (VPN→TGW) | 172.16.1.4 | 20.89.103.44 | TCP | 38020→80 | tgw-attach-09ffabfc (VPN) | apne1-az1 | Azure から到着 |
| egress (TGW→VPC) | 172.16.1.4 | 20.89.103.44 | TCP | 38020→80 | tgw-attach-0a1a1c72 (VPC) | apne1-az1 | VPC に転送 |
| ingress (VPC→TGW) | 20.89.103.44 | 172.16.1.4 | TCP | 80→38020 | tgw-attach-0a1a1c72 (VPC) | apne1-az1 | NAT GW de-NAT 後の戻り |
| egress (TGW→VPN) | 20.89.103.44 | 172.16.1.4 | TCP | 80→38020 | tgw-attach-09ffabfc (VPN) | apne1-az1 | Azure へ返送 |

### TGW Flow Logs: VM02 → VM01 (EC2 NAT instance 経路)

| 方向 | src | dst | proto | port | attachment | az-id | 説明 |
|------|-----|-----|-------|------|-----------|-------|------|
| ingress (VPN→TGW) | 172.16.1.5 | 20.63.177.124 | TCP | 55208→80 | tgw-attach-09ffabfc (VPN) | apne1-az1 | Azure から到着 |
| egress (TGW→VPC) | 172.16.1.5 | 20.63.177.124 | TCP | 55208→80 | tgw-attach-0a1a1c72 (VPC) | apne1-az1 | VPC に転送 |
| ingress (VPC→TGW) | 20.63.177.124 | 172.16.1.5 | TCP | 80→55208 | tgw-attach-0a1a1c72 (VPC) | apne1-az1 | EC2 NAT 後の戻り |
| egress (TGW→VPN) | 20.63.177.124 | 172.16.1.5 | TCP | 80→55208 | tgw-attach-09ffabfc (VPN) | apne1-az1 | Azure へ返送 |

### VPC Flow Logs: Regional NAT GW (nat-12522e133b562f6f1)

| 方向 | srcaddr | dstaddr | proto | port | pkt-srcaddr | pkt-dstaddr | 説明 |
|------|---------|---------|-------|------|-------------|-------------|------|
| ingress | 172.16.1.4 | 20.89.103.44 | ICMP | — | 172.16.1.4 | 20.89.103.44 | NAT 前: VM01 → VM02 |
| egress | 52.198.215.194 | 20.89.103.44 | ICMP | — | 52.198.215.194 | 20.89.103.44 | NAT 後: ソース変換済み |
| ingress | 20.89.103.44 | 52.198.215.194 | ICMP | — | 20.89.103.44 | 52.198.215.194 | 応答: VM02 → NAT GW |
| egress | 20.89.103.44 | 172.16.1.4 | ICMP | — | 20.89.103.44 | 172.16.1.4 | de-NAT 後: 戻りパケット |
| ingress | 172.16.1.4 | 20.89.103.44 | TCP | 38020→80 | 172.16.1.4 | 20.89.103.44 | NAT 前: HTTP リクエスト |
| egress | 52.198.215.194 | 20.89.103.44 | TCP | 26291→80 | 52.198.215.194 | 20.89.103.44 | NAT 後: ポートも変換 |
| ingress | 20.89.103.44 | 52.198.215.194 | TCP | 80→26291 | 20.89.103.44 | 52.198.215.194 | 応答: HTTP レスポンス |
| egress | 20.89.103.44 | 172.16.1.4 | TCP | 80→38020 | 20.89.103.44 | 172.16.1.4 | de-NAT 後: 戻り |

### VPC Flow Logs: EC2-c NAT instance (eni-0a6432b8a429614cd)

| 方向 | srcaddr | dstaddr | proto | port | pkt-srcaddr | pkt-dstaddr | subnet | 説明 |
|------|---------|---------|-------|------|-------------|-------------|--------|------|
| ingress | 172.16.1.5 | 10.0.2.154 | TCP | 36260→80 | 172.16.1.5 | 20.63.177.124 | ec2-subnet-c | NAT 前: TGW ENI → EC2-c |
| egress | 10.0.2.154 | 172.16.1.5 | TCP | 80→36260 | 20.63.177.124 | 172.16.1.5 | ec2-subnet-c | 応答: EC2-c → TGW ENI |
| ingress | 172.16.1.5 | 10.0.2.154 | TCP | 55208→80 | 172.16.1.5 | 20.63.177.124 | ec2-subnet-c | 2 回目のリクエスト |
| egress | 10.0.2.154 | 172.16.1.5 | TCP | 80→55208 | 20.63.177.124 | 172.16.1.5 | ec2-subnet-c | 2 回目の応答 |

---

## 5. Cross-AZ 判定

### az-id 分布 (VPC Flow Logs, egress 方向, 172.16.x.x ソース)

| az-id | 件数 | 説明 |
|-------|------|------|
| apne1-az1 | 9 | 主要トラフィック (VM Public IP 宛は全てこの AZ) |
| apne1-az4 | 1 | EC2-a private IP (10.0.1.161) への ICMP 応答のみ |

### 判定

| トラフィック種別 | Cross-AZ | 備考 |
|-----------------|----------|------|
| VM01 → VM02 (NAT GW 経路) | なし | apne1-az1 で完結 |
| VM02 → VM01 (EC2 NAT instance 経路) | なし | apne1-az1 で完結 |
| VM01 → EC2-a private IP (ICMP) | **あり** | ingress: apne1-az1 (TGW ENI) → egress: apne1-az4 (EC2-a のある AZ) |

Cross-AZ は EC2-a (Az-a = apne1-az4) への private IP 通信でのみ発生。
VM Public IP 宛のポリシールーティング通信は全て apne1-az1 で完結しており、
`appliance_mode_support = "disable"` の状態でも Cross-AZ は発生していない。

---

## リソース一覧

| リソース | ID / IP | 説明 |
|----------|---------|------|
| VPC | vpc-0bb009b54b2ab6688 | 10.0.0.0/16 |
| TGW | tgw-0772038b1359447b4 | ASN 64512 |
| Regional NAT GW | nat-12522e133b562f6f1 | VPC スコープ |
| NAT GW EIP (Az-a) | 52.193.165.2 | — |
| NAT GW EIP (Az-c) | 52.198.215.194 | 今回の検証で使用された EIP |
| EC2-a | 10.0.1.161 / 54.250.215.180 | Az-a NAT instance |
| EC2-c | 10.0.2.154 / 13.230.83.106 | Az-c NAT instance (active) |
| TGW VPC Attachment | tgw-attach-0a1a1c729f04353eb | — |
| TGW VPN Attachment | tgw-attach-09ffabfc234f289c6 | — |
| Azure VM01 | 172.16.1.4 / 20.63.177.124 | — |
| Azure VM02 | 172.16.1.5 / 20.89.103.44 | — |
| Azure VPN GW | 20.44.169.122 | VpnGw1AZ, BGP ASN 65515 |
