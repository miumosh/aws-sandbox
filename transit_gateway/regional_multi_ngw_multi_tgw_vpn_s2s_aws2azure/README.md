# Regional TGW + NAT Gateway + S2S VPN (AWS <-> Azure)

## 概要

- AWS Transit Gateway を介した Azure からの通信を AWS Regional NAT Gateway 経由でインターネットへ出す構成の検証。
- Azure VM 2 台は Public IP を保持し、nginx (`/whoami` エンドポイント) で送信元 IP を返す。`curl` による経路判定と nginx アクセスログによる裏取りを行う。
- AWS 側で宛先 VM Public IP によって egress デバイスを切り替えるポリシールーティング (Regional NAT GW / EC2 NAT instance) を実装する。

### 検証項目
- Azure から AWS TGW → Regional NAT Gateway 経由でインターネットへ出す際の挙動
- 動作上の不備 (非対称経路、MTU、AZ スコープ) の有無
- TGW Az-a からの通信が NAT GW Az-a を使用するか、Cross-AZ となるかの判定
- VM01 → VM02: TGW サブネットの RT から Regional NAT Gateway 経由で IGW → Internet
- VM02 → VM01: TGW サブネットの RT から EC2 サブネット内の EC2 (NAT instance, EIP) を経由し、EC2 の Global IP で IGW → Internet
- EC2 2 台は同一設定の NAT instance (EC2-a / EC2-c 同等)。VM02 → VM01 の active path は EC2-c
- Regional NAT GW は VPC 単位で作成され、サブネットを指定しない。AZ 分散は AWS が自動で行う (ワークロードが存在する AZ に動的に拡張/縮退)
- VPC Flow Logs / TGW Flow Logs による通信経路の確認
- Azure VM は nginx `/whoami` の `remote_addr` と nginx アクセスログで送信元 IP を確認する

## アーキテクチャ

```
[Azure VNet 172.16.0.0/16]
  ├─ vm-subnet (172.16.1.0/24)   UDR:
  │    │   10.0.0.0/16  -> VirtualNetworkGateway
  │    │   VM01_IP/32   -> VirtualNetworkGateway  (VM02 -> VM01 を強制 AWS 経由)
  │    │   VM02_IP/32   -> VirtualNetworkGateway  (VM01 -> VM02 を強制 AWS 経由)
  │    ├─ vm1 (Ubuntu, nginx /whoami)  Public IP: VM01_IP
  │    └─ vm2 (Ubuntu, nginx /whoami)  Public IP: VM02_IP
  └─ GatewaySubnet
       └─ Azure VPN Gateway (VpnGw1AZ, BGP ASN 65515)
              │  IPsec S2S + BGP
              ▼
       AWS VPN Connection (TGW attach)
              │
[AWS VPC 10.0.0.0/16]   TGW (ASN 64512)
  ├─ tgw-subnet-a (10.0.11.0/28, Az-a)    TGW-ENI
  ├─ tgw-subnet-c (10.0.22.0/28, Az-c)    TGW-ENI
  ├─ ec2-subnet-a (10.0.1.0/24, Az-a)     EC2-a NAT instance (EIP_A)
  └─ ec2-subnet-c (10.0.2.0/24, Az-c)     EC2-c NAT instance (EIP_C)

  Regional NAT GW (VPC スコープ、サブネット非配置)
    availability_mode = "regional"
    vpc_id のみ指定、subnet_id 指定不可
    AWS がワークロード在席 AZ に自動で ENI を展開・縮退
    Private IP 割当不可 (Private NAT 用途は Zonal NAT GW を使用)
              │
          IGW -> Internet

[TGW subnet RT] (policy routing)
  0.0.0.0/0        -> IGW                       (デフォルト; 通常未使用)
  VM02_IP/32       -> Regional NAT GW (単一 ID)  # VM01 -> VM02 経路
  VM01_IP/32       -> EC2-c ENI (NAT instance)  # VM02 -> VM01 経路
  172.16.0.0/16    -> TGW                       (戻り)

[Regional NAT GW 自動生成 RT] (de-NAT 後の戻りルーティング)
  0.0.0.0/0        -> IGW                       (AWS がプリセット)
  172.16.0.0/16    -> TGW                       (手動追加, 必須)

[TGW RT] (BGP 広告)
  10.0.0.0/16      -> VPC attachment             (自動伝播)
  VM01_IP/32       -> VPC attachment             (static route, BGP で Azure に広告)
  VM02_IP/32       -> VPC attachment             (static route, BGP で Azure に広告)

[EC2 subnet RT]    default -> IGW (EIP 経由で直接インターネット)
```

### 送信元 IP による経路判定

| フロー | 経由 | 期待ソース IP |
|--------|------|---------------|
| VM01 -> VM02 | Regional NAT GW (VPC スコープ) | EIP_NAT |
| VM02 -> VM01 | EC2-c NAT instance (ec2-subnet-c) | EIP_C |

EC2-a も EC2-c と同一設定の NAT instance として起動しており、RT を切り替えることで AZ-a 側経路検証にも利用可能。

相手 VM 側の nginx `/whoami` レスポンス (`remote_addr`) および nginx アクセスログの送信元 IP により経路を判定する。

## ディレクトリ構成

```
.
├── aws/                         # AWS Terraform (VPC / TGW / NAT GW / EC2 / VPN / Flow Logs)
├── azure/                       # Azure Terraform (VNet / VM x2 nginx / VPN GW / UDR)
│   └── cloud-init.sh           # Azure VM 用 cloud-init (nginx + /whoami)
├── scripts/
│   ├── vpn_verify.sh               # VPN トンネル / BGP セッション / ルート広告の確認
│   ├── routing_verify.sh           # AWS / Azure 双方の主要ルートテーブル確認
│   ├── network_verify.sh           # ICMP / HTTP 疎通 + 送信元 IP 判定 (sshpass 対応)
│   ├── log_verify.sh               # TGW / VPC Flow Logs の確認
│   ├── get_route_all.sh            # AWS / Azure 全ルートテーブル網羅取得 (暗黙作成含む)
│   ├── test_tgw_to_ngw_cross_az.sh # Cross-AZ 判定テスト (100 回リクエスト + Flow Logs 分析)
│   ├── commands.md                 # 確認コマンド詳細リファレンス (出力例 + 判定ポイント)
│   └── logs/                       # スクリプト実行ログ出力先 (.gitignore で除外)
├── request.md
└── README.md
```

## 前提条件
- Terraform >= 1.5
- hashicorp/aws プロバイダ >= 6.41.0 (Regional NAT Gateway 対応)
- AWS CLI / Azure CLI 認証済み
- SSH はパスワード認証 (鍵不要)。AWS EC2: `ec2-user` / Azure VM: `azureuser`
- 各ディレクトリの `terraform.tfvars.sample` を `terraform.tfvars` として複製すること

## デプロイ手順 (4 段階)

依存関係 (AWS VPN IP/PSK、Azure VPN IP、Azure VM Public IP) が両方向で必要なため、段階 apply とする。

### 1. AWS 側 (基盤のみ)

```bash
cd aws
cp terraform.tfvars.sample terraform.tfvars   # 必要に応じて編集
terraform init && terraform apply
```

本段階で VPC / TGW / NAT GW x2 / Dummy EC2 / Flow Logs を構築する。VPN Connection および VM 別ポリシールートは未生成。

### 2. Azure 側 (VM + VPN Gateway, Connection なし)

```bash
cd ../azure
cp terraform.tfvars.sample terraform.tfvars   # 必要に応じて編集
terraform init && terraform apply
```

- VNet / VM x2 (cloud-init で nginx + `/whoami` エンドポイント) / VPN Gateway を構築する
- VPN Gateway の作成には 30〜45 分を要する
- VM01 / VM02 の Public IP を静的に確保する

### 3. AWS 側再 apply (VPN Connection + ポリシールート)

```bash
cd ../aws
AZ_VPN_IP=$(cd ../azure && terraform output -raw vpn_gateway_public_ip)
AZ_VNET_CIDR=$(cd ../azure && terraform output -raw vnet_cidr)
VM01_IP=$(cd ../azure && terraform output -raw vm01_public_ip)
VM02_IP=$(cd ../azure && terraform output -raw vm02_public_ip)

terraform apply \
  -var "azure_vpn_gateway_public_ip=$AZ_VPN_IP" \
  -var "azure_vnet_cidr=$AZ_VNET_CIDR" \
  -var "azure_vm01_public_ip=$VM01_IP" \
  -var "azure_vm02_public_ip=$VM02_IP"

# 依存関係グラフを出力（オプション）
terraform graph | dot -Tpng > dependency_graph.png
```

- Customer Gateway / VPN Connection を生成する
- TGW subnet RT に VM01_IP/32, VM02_IP/32 のポリシールートを追加する

### 4. Azure 側再 apply (VPN Connection + BGP)

```bash
cd ../azure
terraform apply \
  -var "aws_vpn_tunnel1_address=$(cd ../aws && terraform output -raw vpn_tunnel1_address)" \
  -var "aws_vpn_tunnel1_psk=$(cd ../aws && terraform output -raw vpn_tunnel1_psk)" \
  -var "aws_tunnel1_vgw_inside_address=$(cd ../aws && terraform output -raw vpn_tunnel1_vgw_inside_address)" \
  -var "aws_tunnel1_cgw_inside_address=$(cd ../aws && terraform output -raw vpn_tunnel1_cgw_inside_address)"

# 依存関係グラフを出力（オプション）
terraform graph | dot -Tpng > dependency_graph.png
```

数分〜十数分で VPN トンネルが UP、BGP セッションが確立される。確認コマンド:

```bash
az network vnet-gateway list-bgp-peer-status \
  --resource-group tgw-regional-ngw-s2s-rg \
  --name tgw-regional-ngw-s2s-vpngw \
  --output table

az network vnet-gateway list-learned-routes \
  --resource-group tgw-regional-ngw-s2s-rg \
  --name tgw-regional-ngw-s2s-vpngw \
  --output table
```

BGP learned routes に `10.0.0.0/16` (VPC CIDR) および VM Public IP /32 が EBgp で表示されることを確認する。

### 5. 動作確認

以下の順序で 4 つの確認スクリプトを実行する。各スクリプトは前のステップが OK であることを前提とする。
詳細なコマンドリファレンスは `scripts/commands.md` を参照。

```bash
cd scripts

# (1) VPN トンネル / BGP セッション / BGP ルート広告の確認
#     Tunnel 1 が UP + BGP ROUTES、Azure 側 BGP State=Connected を確認する
./vpn_verify.sh

# (2) AWS / Azure 双方のルートテーブル確認
#     TGW subnet RT に VM Public IP /32 ルートが存在すること
#     Regional NAT GW 自動生成 RT に 172.16.0.0/16 -> TGW が存在すること
#     Azure NIC effective routes に VM IP /32 -> VirtualNetworkGateway が Active であること
./routing_verify.sh

# (3) ICMP / HTTP 疎通確認 + 送信元 IP 判定 (SSH 経由で自動実行)
#     VM01 -> VM02: curl /whoami の remote_addr が NAT GW EIP であること
#     VM02 -> VM01: curl /whoami の remote_addr が EC2-c EIP であること
#     nginx アクセスログで送信元 IP を裏取り
./network_verify.sh

# (4) AWS TGW / VPC Flow Logs の確認 (network_verify.sh 実行後 5-10 分待ってから)
#     TGW Flow Logs に 172.16.x.x の到着パケットが存在すること
#     NAT GW の ingress (NAT前) / egress (NAT後) / ingress (応答) の 3 行が揃うこと
#     Cross-AZ 判定: az-id の分布を確認
./log_verify.sh

# (5) AWS / Azure 全ルートテーブルの網羅取得 (任意)
#     VPC 内の全 RT (メイン RT / NAT GW 自動生成 RT 含む) + TGW RT + Azure UDR / Effective Routes
#     暗黙作成されたルートテーブルや孤立 RT の確認にも使用する
./get_route_all.sh
```

全スクリプトの実行ログは `scripts/logs/<スクリプト名>_YYYYMMDD_HHMM.log` に自動出力される。

#### VM 再作成時の注意

Azure VM の `custom_data` (cloud-init) を変更すると VM が再作成される。再作成後は以下の対応が必要:

1. **SSH ホストキーの更新**: VM 再作成でホストキーが変わるため、接続前に known_hosts から旧エントリを削除する
   ```bash
   ssh-keygen -f ~/.ssh/known_hosts -R $VM01_IP
   ssh-keygen -f ~/.ssh/known_hosts -R $VM02_IP
   ```
2. **cloud-init の完了待ち**: VM 起動直後は nginx がまだインストールされていない場合がある。ログイン後に `cloud-init status --wait` で完了を確認してからテストを実施する
3. **Public IP の確認**: Static 割当のため通常は変わらないが、念のため `terraform output` で確認する。IP が変わった場合は AWS 側の再 apply (第 3 段階) が必要

## Knowledge (構築・検証で得られた知見)

### TGW / Regional NAT GW の Cross-AZ 動作

#### Regional NAT GW の Zonal Affinity (ゾーン親和性)

Regional NAT GW は負荷分散ではなく **Zonal Affinity** で動作する。AWS ドキュメントに以下の記載がある:

> "Automatically expands and contracts with your workload footprint to **maintain zonal affinity** which provides high availability by default."
> — https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html

| 概念 | 動作 |
|------|------|
| Regional NAT GW の AZ 選択 | 負荷分散ではなく、**パケットが入ってきた AZ と同じ AZ で処理** (zonal affinity) |
| TGW の入口 AZ 選択 | **フローハッシュ**で決定。同一 src/dst ペアは常に同じ AZ に入る |
| 複数 AZ に分散する条件 | **異なる送信元/宛先ペア**のトラフィックがある場合 |
| Cross-AZ が発生する条件 | NAT GW がその AZ に未展開の場合 (展開に最大 60 分)。展開済みであれば同一 AZ で処理される |
| 使用される EIP | 処理を行った AZ に `availability_zone_address` で割り当てた EIP |

#### 検証結果 (100 件テスト)

VM01 → VM02 に HTTP リクエストを 100 回実行した結果:

| 項目 | 結果 |
|------|------|
| TGW 入口 AZ | 100% apne1-az1 (= ap-northeast-1c, tgw-subnet-c) |
| NAT GW 処理 AZ | 100% apne1-az1 (= ap-northeast-1c) |
| 使用された EIP | 100% 52.198.215.194 (EIP-c, Az-c に割当) |
| Cross-AZ | **発生なし** |

全リクエストが同一フロー (172.16.1.4 → 20.89.103.44) のためフローハッシュが固定され、TGW が常に tgw-subnet-c に振り分け、NAT GW も同じ Az-c で処理した。これは zonal affinity の仕様通りの動作。

#### 確認方法

```bash
cd scripts
SSHPASS=<password> ./test_tgw_to_ngw_cross_az.sh
```

100 回のリクエストを実行し、Flow Logs の集約を待ってから TGW / NAT GW の AZ 分布を自動集計する。

#### 補足: AZ ID マッピング

AZ Name と AZ ID のマッピングは AWS アカウント固有。本アカウントでは:

| AZ Name | AZ ID | 配置リソース |
|---------|-------|------------|
| ap-northeast-1a | apne1-az4 | tgw-subnet-a, ec2-subnet-a, EC2-a |
| ap-northeast-1c | apne1-az1 | tgw-subnet-c, ec2-subnet-c, EC2-c |

#### ドキュメント引用

以下は全て https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html からの引用。

> "A regional NAT gateway **automatically expands across Availability Zones based on your workload presence**. Unlike standard NAT gateways (referred to as zonal NAT gateways), which operate in a single Availability Zone, regional NAT gateways follow your workloads to provide automatic high availability."

> "**Automatic high availability** – Automatically expands and contracts with your workload footprint to **maintain zonal affinity** which provides high availability by default."

> "When you launch resources in a new Availability Zone, the regional NAT gateway detects the presence of an network interface(ENI) in that Availability Zone and **automatically expands to that zone**. Similarly, the **NAT Gateway contracts from the Availability Zone that has no active workloads**."

> "It may take your regional NAT Gateway **up to 60 minutes to expand** to a new Availability Zone after a resource is instantiated there. **Until this expansion is complete, the relevant traffic from this resource is processed across zones** by your regional NAT Gateway in one of the existing Availability Zones."

#### AZ 障害時の動作 (推測を含む)

AWS ドキュメントには AZ 障害時の Regional NAT GW の具体的な挙動は明記されていない。以下はドキュメントの記述と AWS の一般的な HA 設計から推測した内容。

#### 想定されるフェイルオーバーの流れ

| 段階 | 推測される動作 | 根拠 |
|------|--------------|------|
| 1. AZ 障害発生 | 障害 AZ の NAT GW ENI が応答不能になる | — |
| 2. TGW の検知 | TGW は障害 AZ の VPC ENI へのヘルスチェックに失敗し、フローを正常な AZ の ENI に再振り分けする | TGW の一般的な HA 動作 |
| 3. NAT GW の Cross-AZ 処理 | 正常な AZ に入ったトラフィックを、その AZ の NAT GW で処理する (zonal affinity が維持される) | ドキュメント:「traffic is processed across zones by your regional NAT Gateway in one of the existing Availability Zones」(展開待ち時の記述だが、障害時も同様と推測) |
| 4. EIP の切替 | 障害 AZ の EIP から正常 AZ の EIP に NAT ソースが切り替わる | AZ ごとに EIP が割り当てられているため |

#### 最悪ケースのリスク

| リスク | 内容 | 影響 |
|--------|------|------|
| **一時的な通信断** | TGW が障害 AZ を検知し、フローを再振り分けするまでの間 (数秒〜数分)、既存フローが到達不能になる可能性がある | 既存 TCP セッションの切断、リトライで回復 |
| **NAT ソース IP の変動** | 障害 AZ の EIP から正常 AZ の EIP に切り替わる。宛先側で送信元 IP をホワイトリストしている場合、通信がブロックされる | 全 AZ の EIP を宛先側に事前登録する必要あり |
| **展開遅延** | Regional NAT GW が新しい AZ に展開するのに最大 60 分かかる。障害 AZ が復旧し、TGW がその AZ にフローを戻した場合、NAT GW の再展開が間に合わず Cross-AZ 処理が発生する | 一時的な Cross-AZ 通信 (追加の転送コストが発生) |
| **障害中の接続状態の喪失** | NAT GW の接続追跡テーブルは AZ ごとに管理されている可能性がある。障害 AZ から正常 AZ にフェイルオーバーした場合、既存の NAT セッション情報が失われ、de-NAT が機能しなくなる | 既存セッション切断、新規セッションは正常に確立 |

#### 本構成固有のリスク

| リスク | 内容 |
|--------|------|
| VPN トンネルの AZ 依存 | S2S VPN は TGW に直接アタッチされるため、VPN 自体は AZ 障害の影響を受けにくい。ただし TGW の VPC attachment ENI が障害 AZ にある場合、別 AZ の ENI へのフェイルオーバーが必要 |
| de-NAT 戻りルートの AZ 非依存 | NAT GW 自動生成 RT の `172.16.0.0/16 → TGW` ルートは AZ を指定していないため、どの AZ で de-NAT されても TGW に戻すことは可能 |

#### 本構成における AZ 障害耐性

本構成では以下 2 点により、上記リスクの多くが軽減されている。

**1. TGW ENI を 2 AZ に展開済み**

TGW VPC Attachment で `tgw-subnet-a` (Az-a) と `tgw-subnet-c` (Az-c) の両方を指定しているため、両 AZ に ENI が存在する。片方の AZ が障害になっても、TGW はもう片方の AZ の ENI にフローを振り替えることが可能。

```hcl
# aws/tgw.tf
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  subnet_ids = [aws_subnet.tgw_a.id, aws_subnet.tgw_c.id]  # 両 AZ に ENI を展開
}
```

**2. Regional NAT GW を Manual mode で両 AZ に明示展開済み**

`availability_zone_address` ブロックで Az-a / Az-c それぞれに EIP を手動割当しており、この指定が NAT GW の AZ 展開指示を兼ねる。Automatic mode と異なり、`availability_zone_address` で指定した AZ には初めから NAT GW が展開されるため、「展開遅延 (最大 60 分)」のリスクが発生しない。

```hcl
# aws/vpc.tf
resource "aws_nat_gateway" "regional" {
  availability_mode = "regional"
  availability_zone_address {
    allocation_ids    = [aws_eip.nat_regional_a.id]
    availability_zone = var.az_a    # Az-a に展開
  }
  availability_zone_address {
    allocation_ids    = [aws_eip.nat_regional_c.id]
    availability_zone = var.az_c    # Az-c に展開
  }
}
```

> "Manual mode – In this mode, you manually manage IP addresses and control network address translation for each Availability Zone."

**結果として両 AZ のリソース展開状況:**

| コンポーネント | Az-a (apne1-az4) | Az-c (apne1-az1) |
|---|---|---|
| TGW ENI | tgw-subnet-a に展開済み | tgw-subnet-c に展開済み |
| Regional NAT GW | EIP-a (52.193.165.2) で展開済み | EIP-c (52.198.215.194) で展開済み |

片方の AZ が障害になった場合:
- TGW が正常 AZ の ENI にフローを振り替える
- Regional NAT GW は正常 AZ に既に展開済みのため、展開待ちなく処理を継続
- NAT ソース IP は正常 AZ の EIP に切り替わる

#### 推奨事項

- **全 AZ の EIP を宛先側に事前登録する**: AZ フェイルオーバー時にソース IP が変わるため
- **本番環境では appliance_mode_support を慎重に検討する**: enable にするとフローの AZ 固定が強化されるが、障害時のフェイルオーバーが遅れる可能性がある
- **監視**: NAT GW の CloudWatch メトリクス (`ActiveConnectionCount`, `PacketsDropCount`) を AZ 別に監視し、障害を早期検知する

#### `appliance_mode_support` について

- 現状 `disable` でも同一フローは同一 AZ で処理されている (フローハッシュの性質)
- `enable` にすると、異なるフロー (異なる src/dst ペア) でも同一セッション内で AZ が固定される
- 非対称経路防止が必要なミドルボックス構成 (ファイアウォール等) で有効

### EC2 ダミー削除時の NAT GW 挙動検証

```bash
cd aws
terraform destroy -target=aws_instance.ec2_a -target=aws_instance.ec2_c
aws ec2 describe-nat-gateways
```

NAT GW は EC2 とは独立しており削除されない想定。Regional NAT GW はワークロード在席 AZ に自動で ENI を展開するため、EC2 削除により対象 AZ のワークロードが消失した場合、該当 AZ の ENI が自動縮退することを観察する (反映に最大 60 分程度を要する場合あり)。

### 注意事項

#### Regional NAT GW のルーティング

- Regional NAT GW は作成時に AWS がルートテーブルを自動生成し、IGW へのデフォルトルートをプリセットする。Terraform では `aws_nat_gateway.regional.route_table_id` で参照する。
- **de-NAT 後の戻りルート追加は必須**。VPC CIDR 外の戻り先 (Azure VNet 172.16.0.0/16 など) は自動生成 RT に含まれないため、`aws_route` で TGW 向けルートを明示追加する。追加しないと de-NAT 後のパケットがドロップされ、片方向通信となる。
- **やってはいけないこと**: `aws_route_table_association` の `gateway_id` に NAT GW ID を指定してエッジルートテーブルを関連付ける方式。`gateway_id` は IGW / VGW 専用であり NAT GW は非対応 (`InvalidParameterValue: invalid value for parameter gateway-id: nat-xxx`)。GUI 上でエッジルートテーブルの設定が可能に見えるが、Terraform (provider 6.41.0 時点) ではこの方式は使用できない。正しいアプローチは自動生成 RT への直接ルート追加。
- TGW は Regional NAT GW ルートテーブルの正式なターゲットとして AWS がサポートしている。参照: https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html

#### Azure-AWS BGP VPN 接続

- **APIPA アドレス制約**: Azure VPN GW の BGP peering に使用する APIPA アドレスは `169.254.21.0` 〜 `169.254.22.255` の範囲のみ許可。AWS 側 VPN Connection の `tunnel_inside_cidr` もこの範囲内に明示指定する必要がある。AWS がデフォルトで割り当てる値は範囲外となることが多い。
- **BGP 設定の 3 箇所**: Azure 側で BGP を有効にするには以下 3 箇所すべての設定が必要。いずれか 1 つでも欠けると BGP セッションが確立しない:
  1. VPN Gateway: `enable_bgp = true` + `bgp_settings.peering_addresses.apipa_addresses`
  2. Local Network Gateway: `bgp_settings` (相手側 ASN + `bgp_peering_address`)
  3. Connection: `enable_bgp = true` + `custom_bgp_addresses.primary`
- **custom_bgp_addresses**: 未設定の場合、Azure VPN GW はデフォルト BGP IP (GatewaySubnet 内アドレス) を BGP ソースとして使用するが、AWS は tunnel inside address からの BGP しか受け付けないため、セッションが `Connecting` のまま確立されない。
- **TGW static route による BGP 広告**: Azure VPN GW は BGP learned routes に含まれる宛先のみトンネルに転送する。VPC CIDR は TGW が自動広告するが、VM Public IP 等の外部アドレスは TGW ルートテーブルに static route として登録しないと Azure 側に広告されず、UDR で VirtualNetworkGateway に向けてもトンネルに入らない。

#### NSG / Security Group と NAT 後の送信元 IP

- NAT GW / EC2 NAT instance を経由した通信は送信元 IP が EIP に変換される。Azure NSG で SSH 等の送信元制限を行っている場合、NAT 後の EIP が許可リストに含まれていないと TCP 通信がブロックされる。ICMP は NSG で `source_address_prefix = "*"` としているため影響を受けない。
- 検証時に SSH 疎通も必要な場合は、NSG の SSH ルールに NAT GW EIP / EC2 EIP を追加すること。HTTP (port 80) は NSG で `source_address_prefix = "*"` としているため影響を受けない。nginx `/whoami` による送信元 IP 確認のみであれば追加不要。

#### その他

- ヘアピン通信: VM01 → VM02 を Azure 内部ではなく AWS 経由とするため、Azure 側 UDR で VM Public IP /32 を VirtualNetworkGateway に指定する。Azure VNet の System Route は Public IP 宛を Internet 扱いとするため、UDR で明示的に上書きする必要がある (VNet 内 private IP は直接ルーティングされる)。
- 本構成は VPN トンネル 2 本 (AWS 既定) / BGP 動的ルーティング (AWS ASN 64512, Azure ASN 65515) による簡易構成。冗長性は本番利用時に別途検討すること。
- Azure VPN Gateway は SKU `VpnGw1AZ` を使用する。本検証でゾーン冗長は不要だが、Azure が non-AZ SKU (VpnGw1) を廃止したため AZ SKU の使用が必須となっている。AZ SKU では Public IP にも `zones` 指定が必要。
- Azure VPN Gateway (VpnGw1AZ) は約 \$0.19/hr、AWS S2S VPN は \$0.05/hr + 転送量、Regional NAT GW は処理量課金。
- Security Group / NSG は検証用に広めの設定とする。
- destroy 順序: Azure → AWS (VPN の依存関係のため)。
- cloud-init のログは Azure VM で `sudo tail /var/log/cloud-init-output.log` により確認する。

## 参考リンク

- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway
- https://dev.classmethod.jp/articles/site_vpn_azure_aws/
- https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html
- https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateways-regional.html
- https://docs.aws.amazon.com/vpc/latest/tgw/tgw-vpc-attachments.html
- https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html
- https://docs.aws.amazon.com/vpc/latest/tgw/tgw-flow-logs.html
- https://learn.microsoft.com/ja-jp/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings
- https://aws.amazon.com/jp/blogs/networking-and-content-delivery/centralized-egress-to-internet/
