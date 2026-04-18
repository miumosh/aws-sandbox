# 全ルートテーブル サマリ

取得日時: 2026-04-18 18:35 JST
ソース: `scripts/logs/get_route_all_20260418_1835.log`

---

## AWS ルートテーブル一覧

本構成で VPC 内に存在するルートテーブルは計 6 つ (明示作成 4 + 暗黙作成 2)。

| # | RT ID | Name / 種別 | 作成方法 | 関連付け先 | 用途 |
|---|-------|------------|---------|-----------|------|
| 1 | rtb-04e2978fbeb0988bc | rt-tgw | Terraform 明示 | subnet-00c4b13c04eb7fe6a ★ tgw-subnet-a<br>subnet-06cd2b4d4df22854a ★ tgw-subnet-c | TGW サブネットの policy routing |
| 2 | rtb-08047806cceee95cc | (Name なし) | **AWS 暗黙** (Regional NAT GW 作成時に自動生成) | nat-12522e133b562f6f1 ★ Regional NAT GW | NAT GW の de-NAT 後の戻りルーティング |
| 3 | rtb-02a42826ac1a64f2b | rt-ec2-a | Terraform 明示 | subnet-036b9467cba106404 ★ ec2-subnet-a | EC2-a サブネット |
| 4 | rtb-014f4d57097bbc385 | rt-ec2-c | Terraform 明示 | subnet-0df1e5d2028e1dfc6 ★ ec2-subnet-c | EC2-c サブネット |
| 5 | rtb-02aeb1776979fabad | (Name なし) | **AWS 暗黙** (VPC 作成時に自動生成) | Main RT (明示関連付けなし) | VPC メイン RT (未使用) |
| 6 | rtb-067017911eef307e7 | rt-natgw-edge | Terraform 明示 (失敗残骸) | **なし (孤立)** | エッジ RT 方式の試行残骸。Terraform state からは削除済みだが実リソースが残存 |

---

## RT 1: TGW サブネット RT (policy routing)

`rtb-04e2978fbeb0988bc` ★ tgw-regional-ngw-s2s-rt-tgw

関連付け: subnet-00c4b13c04eb7fe6a ★ tgw-subnet-a (10.0.11.0/28, ap-northeast-1a) / subnet-06cd2b4d4df22854a ★ tgw-subnet-c (10.0.22.0/28, ap-northeast-1c)

| Destination | Target | Origin | 用途 |
|-------------|--------|--------|------|
| 20.89.103.44/32 | nat-12522e133b562f6f1 ★ Regional NAT GW | CreateRoute (明示) | VM01→VM02: NAT GW 経由でインターネットへ |
| 20.63.177.124/32 | eni-0a6432b8a429614cd ★ EC2-c NAT instance ENI | CreateRoute (明示) | VM02→VM01: EC2 NAT instance 経由でインターネットへ |
| 172.16.0.0/16 | tgw-0772038b1359447b4 ★ TGW | CreateRoute (明示) | Azure VNet 宛の戻りトラフィック |
| 10.0.0.0/16 | local | CreateRouteTable (暗黙) | VPC ローカル |
| 0.0.0.0/0 | igw-09c1ef699611c053b ★ IGW | CreateRoute (明示) | デフォルトルート |

---

## RT 2: Regional NAT GW 自動生成 RT

`rtb-08047806cceee95cc` ★ (Name なし、AWS が自動生成)

関連付け: nat-12522e133b562f6f1 ★ Regional NAT GW (Gateway association)

| Destination | Target | Origin | 用途 |
|-------------|--------|--------|------|
| 172.16.0.0/16 | tgw-0772038b1359447b4 ★ TGW | CreateRoute (明示) | **de-NAT 後の戻り (手動追加、必須)**。なければ de-NAT 後パケットがドロップされる |
| 10.0.0.0/16 | local | CreateRouteTable (暗黙) | VPC ローカル |
| 0.0.0.0/0 | igw-09c1ef699611c053b ★ IGW | CreateRoute (暗黙) | AWS がプリセット。NAT GW → インターネットの上流経路 |

---

## RT 3: EC2-a サブネット RT

`rtb-02a42826ac1a64f2b` ★ tgw-regional-ngw-s2s-rt-ec2-a

関連付け: subnet-036b9467cba106404 ★ ec2-subnet-a (10.0.1.0/24, ap-northeast-1a)

| Destination | Target | Origin | 用途 |
|-------------|--------|--------|------|
| 172.16.0.0/16 | tgw-0772038b1359447b4 ★ TGW | CreateRoute (明示) | Azure VNet 宛の戻り |
| 10.0.0.0/16 | local | CreateRouteTable (暗黙) | VPC ローカル |
| 0.0.0.0/0 | igw-09c1ef699611c053b ★ IGW | CreateRoute (明示) | EIP 経由の直接インターネット |

---

## RT 4: EC2-c サブネット RT

`rtb-014f4d57097bbc385` ★ tgw-regional-ngw-s2s-rt-ec2-c

関連付け: subnet-0df1e5d2028e1dfc6 ★ ec2-subnet-c (10.0.2.0/24, ap-northeast-1c)

| Destination | Target | Origin | 用途 |
|-------------|--------|--------|------|
| 172.16.0.0/16 | tgw-0772038b1359447b4 ★ TGW | CreateRoute (明示) | Azure VNet 宛の戻り |
| 10.0.0.0/16 | local | CreateRouteTable (暗黙) | VPC ローカル |
| 0.0.0.0/0 | igw-09c1ef699611c053b ★ IGW | CreateRoute (明示) | EIP 経由の直接インターネット |

---

## RT 5: VPC メイン RT (暗黙作成、未使用)

`rtb-02aeb1776979fabad` ★ (Name なし、VPC 作成時に AWS が自動生成)

関連付け: Main RT (どのサブネットにも明示関連付けされていない。明示関連付けのないサブネットが存在すればフォールバックで使用される)

| Destination | Target | Origin | 用途 |
|-------------|--------|--------|------|
| 10.0.0.0/16 | local | CreateRouteTable (暗黙) | VPC ローカル (これしかない) |

備考: 本構成では全サブネットに明示的な RT が関連付けされているため、このメイン RT は実質未使用。

---

## RT 6: エッジ RT (孤立、削除対象)

`rtb-067017911eef307e7` ★ tgw-regional-ngw-s2s-rt-natgw-edge

関連付け: **なし (孤立)**

| Destination | Target | Origin | 用途 |
|-------------|--------|--------|------|
| 172.16.0.0/16 | tgw-0772038b1359447b4 ★ TGW | CreateRoute (明示) | — |
| 10.0.0.0/16 | local | CreateRouteTable (暗黙) | — |

備考: `aws_route_table_association` の `gateway_id` に NAT GW ID を指定する「エッジ RT 方式」を試行した際の残骸。NAT GW は `gateway_id` 非対応のため association に失敗し、Terraform state からは `terraform state rm` で削除済みだが **AWS 上の実リソースは残存**している。手動削除が必要:
```bash
aws ec2 delete-route-table --route-table-id rtb-067017911eef307e7
```

---

## AWS TGW ルートテーブル

`tgw-rtb-0b333e7a79af6a695` ★ TGW Default Route Table (TGW 作成時に暗黙生成)

### TGW Attachment 一覧

| Attachment ID | Type | Resource ID | 説明 |
|---------------|------|-------------|------|
| tgw-attach-0a1a1c729f04353eb | vpc | vpc-0bb009b54b2ab6688 ★ VPC | TGW ↔ VPC 接続 |
| tgw-attach-09ffabfc234f289c6 | vpn | vpn-060cf7d11590a07be ★ VPN Connection | TGW ↔ S2S VPN 接続 (暗黙作成) |

### TGW ルート

| Destination | Attachment | Type | State | 説明 |
|-------------|-----------|------|-------|------|
| 10.0.0.0/16 | tgw-attach-0a1a1c729f04353eb ★ VPC | propagated (暗黙) | active | VPC CIDR 自動伝播 |
| 172.16.0.0/16 | tgw-attach-09ffabfc234f289c6 ★ VPN | propagated (暗黙) | active | Azure VNet CIDR (BGP 受信) |
| 20.63.177.124/32 | tgw-attach-0a1a1c729f04353eb ★ VPC | static (明示) | active | VM01 Public IP → Azure に BGP 広告するため |
| 20.89.103.44/32 | tgw-attach-0a1a1c729f04353eb ★ VPC | static (明示) | active | VM02 Public IP → Azure に BGP 広告するため |

---

## Azure ルートテーブル

### UDR (azurerm_route_table.vm)

関連付け: vm-subnet (172.16.1.0/24)

| Address Prefix | Name | Next Hop Type | 作成方法 | 用途 |
|---------------|------|---------------|---------|------|
| 20.63.177.124/32 | to-peer-vm1 | VirtualNetworkGateway | Terraform 明示 | VM01 Public IP を VPN 経由に強制 |
| 20.89.103.44/32 | to-peer-vm2 | VirtualNetworkGateway | Terraform 明示 | VM02 Public IP を VPN 経由に強制 |
| 10.0.0.0/16 | to-aws | VirtualNetworkGateway | Terraform 明示 | AWS VPC 宛を VPN 経由 |

### VM1 NIC Effective Routes (実効ルート、抜粋)

UDR + BGP + Azure System Route の合成結果。Active なもののみ通信に使用される。

| Source | State | Address Prefix | Next Hop Type | 説明 |
|--------|-------|---------------|---------------|------|
| Default | Active | 172.16.0.0/16 | VnetLocal | VNet 内ローカル (暗黙) |
| User | **Active** | 20.63.177.124/32 | VirtualNetworkGateway | UDR: VM01 宛 → VPN |
| User | **Active** | 20.89.103.44/32 | VirtualNetworkGateway | UDR: VM02 宛 → VPN |
| User | **Active** | 10.0.0.0/16 | VirtualNetworkGateway | UDR: AWS VPC 宛 → VPN |
| VirtualNetworkGateway | **Invalid** | 10.0.0.0/16 | VirtualNetworkGateway | BGP 受信ルート (UDR に上書きされ Invalid) |
| VirtualNetworkGateway | **Invalid** | 20.63.177.124/32 | VirtualNetworkGateway | BGP 受信ルート (UDR に上書きされ Invalid) |
| VirtualNetworkGateway | **Invalid** | 20.89.103.44/32 | VirtualNetworkGateway | BGP 受信ルート (UDR に上書きされ Invalid) |
| Default | Active | 0.0.0.0/0 | Internet | デフォルト: インターネット直接 (暗黙) |
| Default | Active | 10.0.0.0/8 | None | Azure 予約アドレス ブラックホール (暗黙) |
| Default | Active | 172.16.0.0/12 | None | Azure 予約アドレス ブラックホール (暗黙) |
| Default | Active | 192.168.0.0/16 | None | Azure 予約アドレス ブラックホール (暗黙) |

備考: VM2 NIC Effective Routes も VM1 と同一内容。

### BGP Learned Routes (VPN GW が AWS から受信)

| Network | NextHop | Origin | AsPath | 説明 |
|---------|---------|--------|--------|------|
| 172.16.0.0/16 | — | Network | — | 自身の VNet (ローカル) |
| 10.0.0.0/16 | 169.254.21.1 ★ AWS VGW inside IP | EBgp | 64512 | AWS VPC CIDR |
| 20.63.177.124/32 | 169.254.21.1 | EBgp | 64512 | VM01 IP (TGW static route から BGP 広告) |
| 20.89.103.44/32 | 169.254.21.1 | EBgp | 64512 | VM02 IP (TGW static route から BGP 広告) |
| 169.254.21.1/32 | — | Network | — | Tunnel inside IP (ローカル) |

### BGP Advertised Routes (VPN GW が AWS に広告)

| Network | NextHop | Origin | AsPath | 説明 |
|---------|---------|--------|--------|------|
| 172.16.0.0/16 | 169.254.21.2 ★ Azure CGW inside IP | Igp | 65515 | Azure VNet CIDR |

---

## 暗黙作成ルートテーブルの一覧

| RT / ルート | 作成タイミング | 備考 |
|------------|--------------|------|
| rtb-02aeb1776979fabad ★ VPC メイン RT | VPC 作成時 | local ルートのみ。未使用 |
| rtb-08047806cceee95cc ★ NAT GW 自動生成 RT | Regional NAT GW 作成時 | IGW ルートが AWS によりプリセット。172.16.0.0/16→TGW は手動追加 |
| tgw-rtb-0b333e7a79af6a695 ★ TGW Default RT | TGW 作成時 | VPC/VPN の propagated ルートは自動。VM IP /32 の static は手動追加 |
| tgw-attach-09ffabfc234f289c6 ★ VPN Attachment | VPN Connection 作成時 | TGW に VPN を紐付けると自動作成 |
| 各 RT の 10.0.0.0/16 → local ルート | RT 作成時 | VPC CIDR のローカルルート (全 RT に暗黙追加) |
| Azure System Routes (10.0.0.0/8 等 → None) | VNet 作成時 | Azure 予約アドレスのブラックホール (変更不可) |
| Azure VnetLocal (172.16.0.0/16) | VNet 作成時 | VNet 内通信用 (変更不可) |
| Azure Default (0.0.0.0/0 → Internet) | VNet 作成時 | デフォルトのインターネット経路 (UDR で上書き可能) |

---

## Regional NAT GW の Zonal Affinity と Cross-AZ 動作

### 仕様

Regional NAT GW は負荷分散ではなく **Zonal Affinity (ゾーン親和性)** で動作する。

> "Automatically expands and contracts with your workload footprint to **maintain zonal affinity** which provides high availability by default."
> — https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html

| 概念 | 動作 |
|------|------|
| Regional NAT GW の AZ 選択 | 負荷分散ではなく、パケットが入ってきた AZ と同じ AZ で処理 |
| TGW の入口 AZ 選択 | フローハッシュで決定。同一 src/dst ペアは常に同じ AZ |
| 使用される EIP | 処理を行った AZ に `availability_zone_address` で割り当てた EIP |
| 複数 AZ に分散する条件 | 異なる送信元/宛先ペアのトラフィックがある場合 |
| Cross-AZ が発生する条件 | NAT GW がその AZ に未展開の場合 (展開に最大 60 分) |

### トラフィックの AZ 決定フロー

```
Azure VM01 (172.16.1.4)
  → VPN tunnel
    → TGW (フローハッシュで入口 AZ を決定)
      → tgw-subnet-c ENI (10.0.22.9, apne1-az1)  ← 同一 src/dst ペアは常にここ
        → Regional NAT GW (zonal affinity: 入口と同じ Az-c で処理)
          → EIP-c (52.198.215.194) で NAT
            → IGW → Internet → VM02
```

### 検証結果 (100 件テスト, 2026-04-18)

| 項目 | 結果 |
|------|------|
| リクエスト数 | 100 |
| TGW 入口 AZ | 100% apne1-az1 (= ap-northeast-1c, tgw-subnet-c) |
| NAT GW 処理 AZ | 100% apne1-az1 (= ap-northeast-1c) |
| 使用された EIP | 100% 52.198.215.194 (EIP-c, Az-c に割当) |
| Cross-AZ | **発生なし (0/100)** |

全リクエストが同一フロー (172.16.1.4 → 20.89.103.44) のためフローハッシュが固定され、TGW が常に tgw-subnet-c に振り分け、NAT GW も zonal affinity により同じ Az-c で処理した。

### 片側 AZ のみ使用される理由

「負荷分散されない」のではなく、以下の理由で単一 AZ に集中する:

1. TGW のフローハッシュは (src IP, dst IP, protocol, src port, dst port) で計算される
2. VM01 → VM02 の通信は src/dst IP が固定のため、常に同じハッシュ値 → 同じ AZ
3. Regional NAT GW は入口 AZ に追従するだけ (自身では AZ を分散しない)
4. 異なる src/dst ペア (例: VM01 → 別の宛先) であればフローハッシュが変わり、別の AZ に入る可能性がある

### ドキュメント引用

以下は全て https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html からの引用。

> "A regional NAT gateway **automatically expands across Availability Zones based on your workload presence**. Unlike standard NAT gateways (referred to as zonal NAT gateways), which operate in a single Availability Zone, regional NAT gateways follow your workloads to provide automatic high availability."

> "**Automatic high availability** – Automatically expands and contracts with your workload footprint to **maintain zonal affinity** which provides high availability by default."

> "When you launch resources in a new Availability Zone, the regional NAT gateway detects the presence of an network interface(ENI) in that Availability Zone and **automatically expands to that zone**. Similarly, the **NAT Gateway contracts from the Availability Zone that has no active workloads**."

> "It may take your regional NAT Gateway **up to 60 minutes to expand** to a new Availability Zone after a resource is instantiated there. **Until this expansion is complete, the relevant traffic from this resource is processed across zones** by your regional NAT Gateway in one of the existing Availability Zones."

### AZ 障害時の動作 (推測を含む)

AWS ドキュメントには AZ 障害時の Regional NAT GW の具体的な挙動は明記されていない。以下はドキュメントの記述と AWS の一般的な HA 設計から推測した内容。

#### 想定されるフェイルオーバーの流れ

| 段階 | 推測される動作 | 根拠 |
|------|--------------|------|
| 1. AZ 障害発生 | 障害 AZ の NAT GW ENI が応答不能になる | — |
| 2. TGW の検知 | TGW は障害 AZ の VPC ENI へのヘルスチェックに失敗し、フローを正常な AZ の ENI に再振り分けする | TGW の一般的な HA 動作 |
| 3. NAT GW の Cross-AZ 処理 | 正常な AZ に入ったトラフィックを、その AZ の NAT GW で処理 (zonal affinity が維持される) | ドキュメント:「traffic is processed across zones by your regional NAT Gateway in one of the existing Availability Zones」(展開待ち時の記述だが、障害時も同様と推測) |
| 4. EIP の切替 | 障害 AZ の EIP から正常 AZ の EIP に NAT ソースが切り替わる | AZ ごとに EIP が割り当てられているため |

#### 最悪ケースのリスク

| リスク | 内容 | 影響 |
|--------|------|------|
| **一時的な通信断** | TGW が障害 AZ を検知しフローを再振り分けするまでの間 (数秒〜数分)、既存フローが到達不能になる可能性 | 既存 TCP セッションの切断、リトライで回復 |
| **NAT ソース IP の変動** | 障害 AZ の EIP → 正常 AZ の EIP に切り替わる。宛先側で送信元 IP をホワイトリストしている場合、通信がブロックされる | 全 AZ の EIP を宛先側に事前登録する必要あり |
| **展開遅延** | Regional NAT GW が新しい AZ に展開するのに最大 60 分。障害 AZ 復旧後、TGW がその AZ にフローを戻した場合、NAT GW の再展開が間に合わず Cross-AZ 処理が発生する | 一時的な Cross-AZ 通信 (追加の転送コスト発生) |
| **接続状態の喪失** | NAT GW の接続追跡テーブルは AZ ごとに管理されている可能性がある。フェイルオーバー時、既存の NAT セッション情報が失われ de-NAT が機能しなくなる | 既存セッション切断、新規セッションは正常に確立 |

#### 本構成固有のリスク

| リスク | 内容 |
|--------|------|
| VPN トンネルの AZ 依存 | S2S VPN は TGW に直接アタッチされるため、VPN 自体は AZ 障害の影響を受けにくい。ただし TGW の VPC attachment ENI が障害 AZ にある場合、別 AZ の ENI へのフェイルオーバーが必要 |
| de-NAT 戻りルートの AZ 非依存 | NAT GW 自動生成 RT の `172.16.0.0/16 → TGW` ルートは AZ を指定していないため、どの AZ で de-NAT されても TGW に戻すことは可能 |

#### 推奨事項 (本番利用時)

- 全 AZ の EIP を宛先側に事前登録する (AZ フェイルオーバー時のソース IP 変動に備える)
- appliance_mode_support を慎重に検討する (enable にするとフローの AZ 固定が強化されるが、障害時のフェイルオーバーが遅れる可能性)
- NAT GW の CloudWatch メトリクス (`ActiveConnectionCount`, `PacketsDropCount`) を AZ 別に監視し、障害を早期検知する

---

## 削除が必要なリソース

| リソース | ID | 理由 |
|----------|-----|------|
| エッジ RT (孤立) | rtb-067017911eef307e7 | NAT GW エッジ RT 方式の試行残骸。Terraform 管理外。手動削除が必要 |
