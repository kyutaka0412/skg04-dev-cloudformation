# dev-shared VPC 移行手順書

## 全体フェーズ

| Phase | 内容 | 状態 |
|-------|------|------|
| Phase 1 | 共有リソースの新規作成（VPC, Subnet, NAT, SG, ALB, TG, Adminer, Bastion） | **完了** |
| Phase 2 | データ層の移行（RDS） - スナップショット→復元 | 未実施 |
| Phase 3 | コンピュート層の切り替え（ECS） - サービス更新→DNS切替え | 未実施 |
| Phase 4 | 旧リソースの削除（旧VPC, NAT, ALB, RDS等） | 未実施 |
| Phase 5 | CloudFormationスタック構成の整理 | 未実施 |

## 実施順序（推奨）

```
1. dev-shared VPCリソースをデプロイ（Phase 1 - 完了済み）
2. 1環境ずつ移行（developから開始）:
   a. RDSスナップショット取得 → 新VPCで復元（Phase 2）
   b. RDS接続先（SSMパラメータ等）を新エンドポイントに更新
   c. ECSサービスのネットワーク設定+TGをupdate-serviceで更新（Phase 3）
   d. DNS切り替え（別OUで対応）
   e. 動作確認
3. 全環境完了後、旧リソースを削除（Phase 4）
```

---

## Phase 2: RDS移行手順（環境ごとに実施）

### 概要

各環境のAurora Serverless v2クラスタを旧VPCから新VPC（dev-shared）に移行する。

**方法**: スナップショットから新VPCで復元（開発環境なので新規作成でもOK）

### 現状

| 環境 | クラスタID | エンジン | サブネットグループ | DeletionProtection |
|------|-----------|---------|------------------|-------------------|
| develop | dev-skg04 | aurora-mysql 8.0.3.08.2 | dev-skg04-subnet-group | true |
| dev-ope | dev-ope-skg04 | aurora-mysql 8.0.3.08.2 | dev-ope-skg04-subnet-group | true |
| dev-front | dev-front-skg04 | aurora-mysql 8.0.3.08.2 | dev-front-skg04-subnet-group | true |

### 手順（1環境分、develop を例に）

```bash
PROFILE="dev-skg04"
REGION="ap-northeast-1"
OLD_CLUSTER="dev-skg04"
NEW_CLUSTER="dev-shared-develop-skg04"  # 命名は要検討

# --------------------------------------------------
# Step 1: スナップショット取得
# --------------------------------------------------
aws rds create-db-cluster-snapshot \
  --db-cluster-identifier "$OLD_CLUSTER" \
  --db-cluster-snapshot-identifier "${OLD_CLUSTER}-migration-snapshot" \
  --profile "$PROFILE" --region "$REGION"

# スナップショット完了を待機
aws rds wait db-cluster-snapshot-available \
  --db-cluster-snapshot-identifier "${OLD_CLUSTER}-migration-snapshot" \
  --profile "$PROFILE" --region "$REGION"

# --------------------------------------------------
# Step 2: 新VPCのサブネットグループで復元
# --------------------------------------------------
# ※ dev-shared VPCのDB Subnet Group名は 01_network で作成済み
aws rds restore-db-cluster-from-snapshot \
  --db-cluster-identifier "$NEW_CLUSTER" \
  --snapshot-identifier "${OLD_CLUSTER}-migration-snapshot" \
  --engine aurora-mysql \
  --engine-version "8.0.mysql_aurora.3.08.2" \
  --db-subnet-group-name "dev-shared-skg04-db-subnet-group" \
  --vpc-security-group-ids "<新VPCのdevelop用RdsSGのID>" \
  --serverless-v2-scaling-configuration MinCapacity=0,MaxCapacity=1 \
  --db-cluster-parameter-group-name "dev-skg04-cluster-parameter-group" \
  --kms-key-id "arn:aws:kms:ap-northeast-1:186095208202:key/957ce928-26ad-4dc4-8a6c-c76858dd6625" \
  --deletion-protection \
  --profile "$PROFILE" --region "$REGION"

# クラスタ作成完了を待機
aws rds wait db-cluster-available \
  --db-cluster-identifier "$NEW_CLUSTER" \
  --profile "$PROFILE" --region "$REGION"

# --------------------------------------------------
# Step 3: Serverless v2 インスタンス追加
# --------------------------------------------------
aws rds create-db-instance \
  --db-instance-identifier "${NEW_CLUSTER}-serverless-instance" \
  --db-cluster-identifier "$NEW_CLUSTER" \
  --db-instance-class "db.serverless" \
  --engine aurora-mysql \
  --profile "$PROFILE" --region "$REGION"

# インスタンス作成完了を待機
aws rds wait db-instance-available \
  --db-instance-identifier "${NEW_CLUSTER}-serverless-instance" \
  --profile "$PROFILE" --region "$REGION"

# --------------------------------------------------
# Step 4: 新クラスタのエンドポイント確認
# --------------------------------------------------
aws rds describe-db-clusters \
  --db-cluster-identifier "$NEW_CLUSTER" \
  --query 'DBClusters[0].[Endpoint,ReaderEndpoint]' \
  --output text \
  --profile "$PROFILE" --region "$REGION"

# --------------------------------------------------
# Step 5: SSMパラメータにエンドポイントを登録（ECSタスクから参照）
# --------------------------------------------------
# ※ 既存のSSMパラメータパスに合わせて設定
# aws ssm put-parameter --name "/cf-values/develop/rds-endpoint" \
#   --value "<新クラスタのエンドポイント>" --type String --overwrite \
#   --profile "$PROFILE" --region "$REGION"
```

### 注意事項

- **クラスタパラメータグループ**（`dev-skg04-cluster-parameter-group`）はVPCに依存しないので既存のものをそのまま使える
- **KMSキー**も同一アカウント・同一リージョンなのでそのまま使える
- **DeletionProtection**: 新クラスタも`true`にしておく
- **セキュリティグループID**: `dev-shared`の環境別RdsSGのIDを指定（`aws cloudformation describe-stacks`で取得）
- 開発環境でデータが不要なら、スナップショット復元の代わりに新規作成でもOK

---

## Phase 3: ECS切り替え手順（環境ごとに実施）

### 概要

各環境のECSサービスのネットワーク設定（Subnet/SG）とロードバランサー設定（TG）を旧VPC → 新VPC（dev-shared）に変更する。
`update-service` でネットワーク設定とロードバランサー設定の両方を更新できるため、サービスの削除・再作成は不要。

### 現状（develop環境）

| サービス | クラスタ | 用途 | ALB TG |
|---------|---------|------|--------|
| api | dev-skg04-api | APIサーバ | あり |
| batch | dev-skg04-batch | バッチ処理 | なし |
| mailpit | dev-skg04-mailpit | メールテスト | あり |
| redis | dev-skg04-redis | キャッシュ | なし |

### 手順（1環境分、develop を例に）

```bash
PROFILE="dev-skg04"
REGION="ap-northeast-1"
ENV="develop"

# --------------------------------------------------
# Step 0: 新VPCのリソースIDを取得
# --------------------------------------------------
# Subnet
PRIVATE_SUBNET_A=$(aws cloudformation describe-stacks \
  --stack-name DEV-SHARED-01-network \
  --query 'Stacks[0].Outputs[?OutputKey==`EC2SubnetPrivateA`].OutputValue' \
  --output text --profile "$PROFILE" --region "$REGION")

PRIVATE_SUBNET_C=$(aws cloudformation describe-stacks \
  --stack-name DEV-SHARED-01-network \
  --query 'Stacks[0].Outputs[?OutputKey==`EC2SubnetPrivateC`].OutputValue' \
  --output text --profile "$PROFILE" --region "$REGION")

# SG（環境別）
API_SG=$(aws cloudformation describe-stacks \
  --stack-name "DEV-SHARED-02-env-sg-${ENV}" \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiSG`].OutputValue' \
  --output text --profile "$PROFILE" --region "$REGION")

RDS_SG=$(aws cloudformation describe-stacks \
  --stack-name "DEV-SHARED-02-env-sg-${ENV}" \
  --query 'Stacks[0].Outputs[?OutputKey==`RdsSG`].OutputValue' \
  --output text --profile "$PROFILE" --region "$REGION")

REDIS_SG=$(aws cloudformation describe-stacks \
  --stack-name "DEV-SHARED-02-env-sg-${ENV}" \
  --query 'Stacks[0].Outputs[?OutputKey==`RedisSG`].OutputValue' \
  --output text --profile "$PROFILE" --region "$REGION")

MAILPIT_WEB_SG=$(aws cloudformation describe-stacks \
  --stack-name "DEV-SHARED-02-env-sg-${ENV}" \
  --query 'Stacks[0].Outputs[?OutputKey==`MailpitWebSG`].OutputValue' \
  --output text --profile "$PROFILE" --region "$REGION")

MAILPIT_SMTP_SG=$(aws cloudformation describe-stacks \
  --stack-name "DEV-SHARED-02-env-sg-${ENV}" \
  --query 'Stacks[0].Outputs[?OutputKey==`MailpitSmtpSG`].OutputValue' \
  --output text --profile "$PROFILE" --region "$REGION")

# SG（共有）
MGT_SG=$(aws cloudformation describe-stacks \
  --stack-name DEV-SHARED-01-network \
  --query 'Stacks[0].Outputs[?OutputKey==`SGSharedMgt`].OutputValue' \
  --output text --profile "$PROFILE" --region "$REGION")

# Target Group
API_TG=$(aws cloudformation describe-stacks \
  --stack-name "DEV-SHARED-04-env-lb-${ENV}" \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiTargetGroup`].OutputValue' \
  --output text --profile "$PROFILE" --region "$REGION")

MAILPIT_TG=$(aws cloudformation describe-stacks \
  --stack-name "DEV-SHARED-04-env-lb-${ENV}" \
  --query 'Stacks[0].Outputs[?OutputKey==`MailpitTargetGroup`].OutputValue' \
  --output text --profile "$PROFILE" --region "$REGION")

# --------------------------------------------------
# Step 1: RDSのエンドポイントを更新（SSMパラメータ or 環境変数）
# --------------------------------------------------
# ECSタスク定義でRDS接続先をどう管理しているか次第
# SSMパラメータの場合:
# aws ssm put-parameter --name "/cf-values/develop/rds-endpoint" \
#   --value "<新クラスタのエンドポイント>" --type String --overwrite \
#   --profile "$PROFILE" --region "$REGION"

# --------------------------------------------------
# Step 2: 全ECSサービスのネットワーク設定を更新
# --------------------------------------------------
# ※ ローリングアップデートのサービスは update-service で
#    ネットワーク設定（Subnet/SG）とロードバランサー設定（TG）の両方を変更可能
# ※ 参考: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/update-service-parameters.html

# Batch（ALBなし / SG: RdsSG + SGSharedMgt）
aws ecs update-service \
  --cluster dev-skg04-batch \
  --service dev-skg04-batch \
  --network-configuration "awsvpcConfiguration={
    subnets=[$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_C],
    securityGroups=[$RDS_SG,$MGT_SG],
    assignPublicIp=DISABLED
  }" \
  --force-new-deployment \
  --profile "$PROFILE" --region "$REGION"

# Redis（ALBなし / SG: RedisSG + SGSharedMgt）
aws ecs update-service \
  --cluster dev-skg04-redis \
  --service dev-skg04-redis \
  --network-configuration "awsvpcConfiguration={
    subnets=[$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_C],
    securityGroups=[$REDIS_SG,$MGT_SG],
    assignPublicIp=DISABLED
  }" \
  --force-new-deployment \
  --profile "$PROFILE" --region "$REGION"

# API（ALBあり / SG: ApiSG + RdsSG + RedisSG + SGSharedMgt / TG: 新TGに変更）
aws ecs update-service \
  --cluster dev-skg04-api \
  --service dev-skg04-api \
  --network-configuration "awsvpcConfiguration={
    subnets=[$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_C],
    securityGroups=[$API_SG,$RDS_SG,$REDIS_SG,$MGT_SG],
    assignPublicIp=DISABLED
  }" \
  --load-balancers "targetGroupArn=$API_TG,containerName=api,containerPort=80" \
  --force-new-deployment \
  --profile "$PROFILE" --region "$REGION"

# Mailpit（ALBあり / SG: MailpitWebSG + MailpitSmtpSG + SGSharedMgt / TG: 新TGに変更）
aws ecs update-service \
  --cluster dev-skg04-mailpit \
  --service dev-skg04-mailpit \
  --network-configuration "awsvpcConfiguration={
    subnets=[$PRIVATE_SUBNET_A,$PRIVATE_SUBNET_C],
    securityGroups=[$MAILPIT_WEB_SG,$MAILPIT_SMTP_SG,$MGT_SG],
    assignPublicIp=DISABLED
  }" \
  --load-balancers "targetGroupArn=$MAILPIT_TG,containerName=mailpit,containerPort=8025" \
  --force-new-deployment \
  --profile "$PROFILE" --region "$REGION"

# --------------------------------------------------
# Step 3: DNS切り替え
# --------------------------------------------------
# 各サブドメインのCNAME/Aliasを統合ALBに向ける
# ※ Route53は別OUで管理しているので、そちらで対応

# --------------------------------------------------
# Step 4: 動作確認
# --------------------------------------------------
# - 各環境のAPIにHTTPSでアクセスできること
# - Adminerから各環境のRDSに接続できること
# - Mailpitが正常に動作すること
```

---

## 重要な注意点

### ECSサービスの `loadBalancers` は `update-service` で変更可能

ローリングアップデート（デプロイコントローラ: `ECS`）のサービスであれば、`aws ecs update-service` でネットワーク設定（Subnet/SG）に加えて **loadBalancers（ターゲットグループ）も変更可能**。
サービスの削除・再作成は不要で、CodePipelineのトランジション無効化も不要。

参考: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/update-service-parameters.html

> For services that use rolling updates, you can add, update, or remove Elastic Load Balancing target groups.

### CodePipelineへの影響

- `update-service` でのTG変更はサービスが維持されるため、**CodePipelineへの影響なし**
- CodePipelineのDeployステージは `Provider: ECS`（標準デプロイ）で、**ClusterName + ServiceName** のみを参照している

### セキュリティグループIDの取得

```bash
# 環境別SGのIDを一括取得
aws cloudformation describe-stacks \
  --stack-name "DEV-SHARED-02-env-sg-develop" \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table \
  --profile dev-skg04 --region ap-northeast-1
```

---

## Phase 4: 旧リソースの削除

全環境の移行・動作確認が完了したら、旧VPCのリソースを削除する。

### 削除前の確認

```bash
# 旧ALBへのトラフィックが0であることを確認（CloudWatch）
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name RequestCount \
  --dimensions Name=LoadBalancer,Value=<旧ALBのARN suffix> \
  --start-time $(date -u -v-1d +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 3600 \
  --statistics Sum \
  --profile dev-skg04 --region ap-northeast-1
```

### 削除対象

各環境（develop, dev-ope, dev-front）ごとに以下を削除：
1. 旧ALB / Target Group / Listener
3. 旧RDSクラスタ（最終スナップショット取得後）
4. 旧NAT Gateway
5. 旧EIP
6. 旧Security Group
7. 旧Subnet
8. 旧VPC

**注意**: CloudFormationスタックで管理されている場合は、スタック単位で逆順に削除する。

---

## Phase 5: CloudFormationスタック構成の整理

旧環境の34スタック構成を5〜7スタックに集約する。Phase 4完了後に実施。
