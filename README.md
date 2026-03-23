# skg04-dev-cloudformation

識学クラウド（skg04）dev-shared 統合VPC用 CloudFormation テンプレート。

複数の開発環境（develop, dev-ope, dev-front, dev-demo）を1つのVPCに統合し、環境別テンプレートのループデプロイで管理します。

## 前提条件

- AWS CLI v2
- AWS プロファイル `dev-skg04` が設定済みであること
- リージョン: `ap-northeast-1`

## ディレクトリ構成

```
├── templates/                    # CloudFormation テンプレート
│   ├── DEV_SHARED_01_network.yaml    # VPC, Subnet, IGW, NAT, Route Table, 共有SG
│   ├── DEV_SHARED_02_env_sg.yaml     # 環境別SG（Api, Rds, Redis, Mailpit）
│   ├── DEV_SHARED_03_lb.yaml         # 統合ALB + HTTPSリスナー
│   ├── DEV_SHARED_04_env_lb.yaml     # 環境別 Target Group, リスナールール
│   ├── DEV_SHARED_05_adminer.yaml    # Adminer ECSタスク + サービス
│   └── DEV_SHARED_06_bastion.yaml    # 踏み台サーバ
├── deploy.sh                     # デプロイスクリプト
├── destroy.sh                    # 削除スクリプト
├── env_template_design.md        # 環境別テンプレート設計書
└── migration_procedure.md        # VPC移行手順書
```

## デプロイ

```bash
bash deploy.sh
```

`deploy.sh` は `templates/` 配下のテンプレートを番号順にデプロイします。

- **共有テンプレート**（`_env_` を含まない）: 1回デプロイ
- **環境別テンプレート**（`_env_` を含む）: 環境数分ループデプロイ

### テンプレートの検証

```bash
aws cloudformation validate-template \
  --template-body file://templates/DEV_SHARED_01_network.yaml \
  --profile dev-skg04
```

### 削除

```bash
bash destroy.sh
```

## アーキテクチャ

### 共有リソース vs 環境別リソース

| 種別 | リソース | 説明 |
|------|----------|------|
| 共有 | VPC, Subnet, NAT, ALB, Adminer, Bastion | 全環境で1つ |
| 環境別 | SG, Target Group, RDS, ECS, ECR, Pipeline | 環境ごとに独立 |

### Cross-Stack 参照

テンプレート間は `Fn::ImportValue` で参照します。

- 共有リソース: `${MyEnvironment}-${MyProject}-{リソース名}`
- 環境別リソース: `${MyEnvironment}-${MyProject}-${EnvName}-{リソース名}`

### 環境一覧

| 環境 | 用途 | ドメイン |
|------|------|---------|
| develop | 開発環境 | `*-develop.shikigaku-cloud.com` |
| dev-ope | 運用開発環境 | `*-dev-ope.shikigaku-cloud.com` |
| dev-front | フロント開発環境 | `*-dev-front.shikigaku-cloud.com` |
| dev-demo | デモ環境（追加予定） | `*-dev-demo.shikigaku-cloud.com` |

## 環境の追加方法

1. `deploy.sh` の `ENVIRONMENTS` にエントリを追加
2. `deploy.sh` の `get_env_lb_params` に case を追加（ACM証明書ARN、ホストヘッダ）
3. 各環境別テンプレートの `EnvName` の `AllowedValues` に追加
4. `04_env_lb.yaml` の `EnvPriority` Mappings にエントリを追加

詳細は `env_template_design.md` を参照してください。
