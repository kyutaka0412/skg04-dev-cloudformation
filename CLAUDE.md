# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Shikigaku Cloud (識学クラウド)** プロジェクト（プロジェクトコード: `skg04`）のdev-shared統合VPC用CloudFormationテンプレート。
複数の開発環境（develop, dev-ope, dev-front, dev-demo）を1つのVPCに統合し、環境別テンプレートのループデプロイで管理する。

## Deployment

```bash
cd dev_shared
bash deploy.sh
```

`deploy.sh` は `./templates/` 配下のテンプレートを番号順にデプロイする。
- 共有テンプレート（`_env_` を含まない）: 1回デプロイ
- 環境別テンプレート（`_env_` を含む）: `ENVIRONMENTS` リストの環境数分ループデプロイ

**AWS profile**: `dev-skg04`
**Default region**: `ap-northeast-1`
**Capabilities**: `CAPABILITY_NAMED_IAM`

テンプレートの検証:
```bash
aws cloudformation validate-template --template-body file://templates/TEMPLATE.yaml --profile dev-skg04
```

## Template Architecture

### テンプレート一覧とデプロイ順序

| # | テンプレート | 種別 | 内容 |
|---|-------------|------|------|
| 01 | `DEV_SHARED_01_network.yaml` | 共有 | VPC, Subnet, IGW, EIP, NAT, Route Table, S3 Gateway Endpoint, 共有SG（ALB, Adminer, Mgt） |
| 02 | `DEV_SHARED_02_env_sg.yaml` | 環境別 | ApiSG, RdsSG, RedisSG, MailpitWebSG, MailpitSmtpSG |
| 03 | `DEV_SHARED_03_lb.yaml` | 共有 | 統合ALB + HTTPSリスナー |
| 04 | `DEV_SHARED_04_env_lb.yaml` | 環境別 | Target Group, リスナールール, SNI証明書 |
| 05 | `DEV_SHARED_05_adminer.yaml` | 共有 | Adminer ECSタスク + サービス |
| 06 | `DEV_SHARED_06_bastion.yaml` | 共有 | 踏み台サーバ |
| 07 | `DEV_SHARED_07_env_rds.yaml` | 環境別 | Aurora Serverless v2（予定） |
| 08 | `DEV_SHARED_08_env_ecs.yaml` | 環境別 | ECSクラスタ + 全サービス（予定） |
| 09 | `DEV_SHARED_09_env_ecr.yaml` | 環境別 | ECRリポジトリ（予定） |
| 10 | `DEV_SHARED_10_env_pipeline.yaml` | 環境別 | CI/CDパイプライン（予定） |

### Cross-Stack References

テンプレート間は `Fn::ImportValue` で参照。Export名は `${MyEnvironment}-${MyProject}-{リソース名}` パターン。
環境別テンプレートは `${MyEnvironment}-${MyProject}-${EnvName}-{リソース名}` パターン。

テンプレート修正時は、依存元と依存先のExport/ImportValueを確認すること。

### 共有リソース vs 環境別リソース

- **共有リソース**: VPC, Subnet, NAT, ALB, Adminer, Bastion — 全環境で共有
- **環境別リソース**: SG, TG, RDS, ECS, ECR, Pipeline — 環境ごとに独立

環境別テンプレートはファイル名に `_env_` を含む。`deploy.sh` がこのパターンで自動判別する。

## Environment Configuration

### 環境追加時の手順

1. `deploy.sh` の `ENVIRONMENTS` にエントリ追加
2. `deploy.sh` の `get_env_lb_params` に case 追加（ACM証明書ARN、ホストヘッダ）
3. 各環境別テンプレートの `EnvName` の `AllowedValues` に追加
4. `04_env_lb.yaml` の `EnvPriority` Mappings にエントリ追加

### 現在の環境

| 環境 | 用途 | ドメイン |
|------|------|---------|
| develop | 開発環境 | `*-develop.shikigaku-cloud.com` |
| dev-ope | 運用開発環境 | `*-dev-ope.shikigaku-cloud.com` |
| dev-front | フロント開発環境 | `*-dev-front.shikigaku-cloud.com` |
| dev-demo | デモ環境（追加予定） | `*-dev-demo.shikigaku-cloud.com` |

### SGの組み合わせ

各ECSタスクにアタッチするSGの組み合わせ:
- API = ApiSG + RdsSG + RedisSG + SGSharedMgt
- Batch = RdsSG + SGSharedMgt
- Mailpit = MailpitWebSG + MailpitSmtpSG + SGSharedMgt
- Redis = RedisSG + SGSharedMgt
- Adminer = SGSharedAdminer + SGSharedMgt

## Conventions

- テンプレート命名: `DEV_SHARED_{NUMBER}_{SERVICE}.yaml` / 環境別は `DEV_SHARED_{NUMBER}_env_{SERVICE}.yaml`
- スタック命名: ファイル名のアンダースコアをハイフンに変換（環境別は末尾に `-{EnvName}` が付く）
- タグ: 全リソースに `environment`, `project`, `managed_by`, `service_role` タグ
- AWSリソースのDescriptionは英語、CloudFormationメタデータのDescriptionは日本語OK
- テンプレート内のコメントは日本語

## Directory Structure

```
dev_shared/
  templates/              # CloudFormationテンプレート
  deploy.sh               # デプロイスクリプト
  destroy.sh              # 削除スクリプト
  migration_procedure.md  # VPC移行手順書
  env_template_design.md  # 環境別テンプレート設計書
  CLAUDE.md               # このファイル
```

## Related Documents

- `migration_procedure.md` — 旧VPCからdev-shared VPCへの移行手順（Phase 2〜4）
- `env_template_design.md` — 環境別テンプレートの設計方針、dev-demo新規作成手順、既存環境importの計画
