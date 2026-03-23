# dev-demo環境 デプロイ手順書

## 概要

dev-shared統合VPCにdev-demo環境を新規追加する手順。
既存3環境（develop, dev-ope, dev-front）には影響を与えない。

## 前提条件

- AWS CLI が設定済み（profile: `dev-skg04`）
- MFA認証済みのセッション
- Route53のDNS管理権限（別OUの場合は依頼が必要）

---

## 事前準備

### 1. ACM証明書の発行

API用とMailpit用の2つの証明書を発行する。

```bash
# API用
aws acm request-certificate \
  --domain-name "api-dev-demo.shikigaku-cloud.com" \
  --validation-method DNS \
  --region ap-northeast-1 \
  --profile dev-skg04

# Mailpit用
aws acm request-certificate \
  --domain-name "mailpit-dev-demo.shikigaku-cloud.com" \
  --validation-method DNS \
  --region ap-northeast-1 \
  --profile dev-skg04
```

発行後、DNS検証レコードをRoute53に追加し、ステータスが `ISSUED` になるまで待機する。

```bash
# 検証状況の確認
aws acm list-certificates \
  --query 'CertificateSummaryList[?contains(DomainName, `dev-demo`)]' \
  --region ap-northeast-1 \
  --profile dev-skg04
```

### 2. GitHub Connection ARN の確認

既存のCodeStar Connectionを流用するか、新規作成する。

```bash
# 既存Connection一覧
aws codestar-connections list-connections \
  --region ap-northeast-1 \
  --profile dev-skg04 \
  --query 'Connections[].{Name:ConnectionName,Arn:ConnectionArn,Status:ConnectionStatus}' \
  --output table
```

既存の流用可能な候補：
- `dev-skg04-github-connection`（ap-northeast-1）
- `dev-ope-skg04-github-connection`（ap-northeast-1）

### 3. GitHubリポジトリの準備

- `dev-demo` ブランチを作成
- `buildspec.dev-demo.yml` を作成（既存の `buildspec.dev-ope.yml` 等を参考に）
- `buildspec.dev-demo.migration.yml` を作成

### 4. deploy.sh の PLACEHOLDER 置換

`deploy.sh` の以下の箇所を実際のARNに置き換える。

```bash
# (1) dev-demo ACM証明書ARN（69-72行目付近）
dev-demo)
  echo "ApiCertArn=arn:aws:acm:ap-northeast-1:186095208202:certificate/<実際のARN>" \
       "MailpitCertArn=arn:aws:acm:ap-northeast-1:186095208202:certificate/<実際のARN>" \
       "ApiHostHeader=api-dev-demo.shikigaku-cloud.com" \
       "MailpitHostHeader=mailpit-dev-demo.shikigaku-cloud.com"
  ;;

# (2) GitHub Connection ARN（86行目付近）
GITHUB_CONNECTION_ARN="arn:aws:codestar-connections:ap-northeast-1:186095208202:connection/<実際のARN>"
```

**PLACEHOLDERが残ったままデプロイすると `validate_no_placeholders` により自動停止する。**

---

## デプロイ実行

### デプロイの流れ

`deploy.sh` を実行すると、テンプレートが番号順にデプロイされる。

| # | テンプレート | 既存3環境 | dev-demo | 所要時間目安 |
|---|-------------|----------|----------|-------------|
| 01 | network | 変更なしスキップ | - | - |
| 02 | env_sg | 変更なしスキップ | **新規作成** | ~1分 |
| 03 | lb | 変更なしスキップ | - | - |
| 04 | env_lb | 変更なしスキップ | **新規作成** | ~1分 |
| 05 | adminer | 変更なしスキップ | - | - |
| 06 | bastion | 変更なしスキップ | - | - |
| 07 | env_rds | - | **新規作成** | ~5-10分 |
| 08 | env_ecr | - | **新規作成** | ~1分 |
| 09 | env_ecs | - | **新規作成** | ~3-5分 |
| 10 | env_pipeline | - | **新規作成** | ~2分 |

- 既存3環境は `--no-fail-on-empty-changeset` により変更なしでスキップされる
- 新規テンプレート（07-10）は `get_env_list_for_template` により **dev-demoのみ** にデプロイされる
- 合計所要時間: 約15-20分

### 実行コマンド

```bash
cd /Volumes/DataVault/work/shikigaku/cloudformation_template/skg04-dev-cloudformation
bash deploy.sh
```

### 作成されるスタック一覧

| スタック名 | 内容 |
|-----------|------|
| DEV-SHARED-02-env-sg-dev-demo | セキュリティグループ（Api, RDS, Redis, Mailpit） |
| DEV-SHARED-04-env-lb-dev-demo | Target Group + Listener Rule + SNI証明書 |
| DEV-SHARED-07-env-rds-dev-demo | KMS + Aurora Serverless v2 |
| DEV-SHARED-08-env-ecr-dev-demo | ECRリポジトリ |
| DEV-SHARED-09-env-ecs-dev-demo | ECS 4クラスタ（api, batch, mailpit, redis） |
| DEV-SHARED-10-env-pipeline-dev-demo | CodeBuild + CodePipeline + IAMロール + S3 |

---

## デプロイ後の設定

### 1. DNS設定

ALBのDNS名を確認し、Route53にレコードを作成する。

```bash
# ALB DNS名の確認
aws cloudformation list-exports \
  --region ap-northeast-1 --profile dev-skg04 \
  --query 'Exports[?Name==`dev-shared-skg04-SharedAlbDnsName`].Value' \
  --output text
```

Route53に以下のレコードを作成:

| レコード名 | タイプ | 値 |
|-----------|-------|---|
| `api-dev-demo.shikigaku-cloud.com` | CNAME or Alias | ALBのDNS名 |
| `mailpit-dev-demo.shikigaku-cloud.com` | CNAME or Alias | ALBのDNS名 |

### 2. 動作確認

```bash
# RDSエンドポイントの確認
aws cloudformation list-exports \
  --region ap-northeast-1 --profile dev-skg04 \
  --query 'Exports[?Name==`dev-shared-skg04-dev-demo-RDSDBClusterEndpoint`].Value' \
  --output text

# ECSサービスの状態確認
for svc in api batch mailpit redis; do
  echo "=== $svc ==="
  aws ecs describe-services \
    --cluster "dev-shared-skg04-dev-demo-$svc" \
    --services "dev-shared-skg04-dev-demo-$svc" \
    --query 'services[0].{Status:status,Running:runningCount,Desired:desiredCount}' \
    --region ap-northeast-1 --profile dev-skg04 \
    --output table
done

# APIのヘルスチェック（DNS設定後）
curl -I https://api-dev-demo.shikigaku-cloud.com/health_check

# Mailpit Web UI（DNS設定後）
curl -I https://mailpit-dev-demo.shikigaku-cloud.com/

# Adminerからdev-demo RDSに接続確認
# https://adminer-develop.shikigaku-cloud.com で接続先をdev-demoのRDSエンドポイントに指定
```

### 3. RDSの本番クローン（必要な場合）

空DBで作成後、本番データを投入する場合:

```bash
# 本番クラスタからスナップショットを取得してリストア
# ※ 具体的な手順は本番環境の管理者と調整
```

---

## 初期状態の注意点

- **APIサービスは `nginx:latest` で起動する**。CI/CDパイプラインが初回ビルド・デプロイを完了するまでは仮の状態
- **Batchサービスは ECRリポジトリのイメージを参照する**が、初回はイメージが存在しないため起動に失敗する。パイプラインの初回実行で解消される
- **CodePipelineはGitHubの `dev-demo` ブランチへのpushで自動トリガー**される

---

## トラブルシューティング

### デプロイが途中で失敗した場合

```bash
# スタックの状態確認
aws cloudformation describe-stacks \
  --stack-name DEV-SHARED-XX-env-YYY-dev-demo \
  --region ap-northeast-1 --profile dev-skg04 \
  --query 'Stacks[0].{Status:StackStatus,Reason:StackStatusReason}'

# イベントログの確認（失敗原因の特定）
aws cloudformation describe-stack-events \
  --stack-name DEV-SHARED-XX-env-YYY-dev-demo \
  --region ap-northeast-1 --profile dev-skg04 \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].{Resource:LogicalResourceId,Reason:ResourceStatusReason}' \
  --output table
```

- `ROLLBACK_COMPLETE` 状態のスタックは `deploy.sh` が自動削除して再作成する
- RDS作成失敗時は、KMSキーの権限やサブネットグループの設定を確認

### PLACEHOLDERエラーが出た場合

```
ERROR: PLACEHOLDER values detected in parameters.
```

→ `deploy.sh` 内のACM証明書ARNまたはGitHub Connection ARNが未設定。「事前準備 Step 4」を確認。

### ECSサービスが起動しない場合

```bash
# タスクの停止理由を確認
aws ecs list-tasks \
  --cluster dev-shared-skg04-dev-demo-api \
  --desired-status STOPPED \
  --region ap-northeast-1 --profile dev-skg04

aws ecs describe-tasks \
  --cluster dev-shared-skg04-dev-demo-api \
  --tasks <タスクARN> \
  --query 'tasks[0].stoppedReason' \
  --region ap-northeast-1 --profile dev-skg04
```

よくある原因:
- ECRにイメージがない（Batchは初回ビルド前に発生）
- セキュリティグループの設定不備（RDS/Redis接続エラー）
- タスク実行ロールの権限不足（ECRからのイメージプル失敗）

---

## 削除手順（環境の破棄）

dev-demo環境のみを削除する場合は、依存関係の逆順で個別に削除する。

```bash
PROFILE="dev-skg04"
REGION="ap-northeast-1"

# 10 → 09 → 08 → 07 → 04 → 02 の順序で削除
for stack in \
  DEV-SHARED-10-env-pipeline-dev-demo \
  DEV-SHARED-09-env-ecs-dev-demo \
  DEV-SHARED-08-env-ecr-dev-demo \
  DEV-SHARED-07-env-rds-dev-demo \
  DEV-SHARED-04-env-lb-dev-demo \
  DEV-SHARED-02-env-sg-dev-demo; do
  echo "Deleting $stack..."
  aws cloudformation delete-stack \
    --stack-name "$stack" \
    --region "$REGION" --profile "$PROFILE"
  aws cloudformation wait stack-delete-complete \
    --stack-name "$stack" \
    --region "$REGION" --profile "$PROFILE"
  echo "Deleted: $stack"
done
```

**注意:** RDSは `DeletionPolicy: Snapshot` によりスナップショットが自動作成される。KMSキーはスタック削除で削除されるため、スナップショットの復元にはKMSキーが必要な点に注意（復元予定がある場合は先にKMSキーのARNを記録しておく）。

---

## 関連ドキュメント

- `env_template_design.md` — 環境別テンプレート設計・Phase 2 import計画
- `migration_procedure.md` — 旧VPCからdev-shared VPCへの移行手順
- `CLAUDE.md` — テンプレート構成・命名規則・SG組み合わせ
