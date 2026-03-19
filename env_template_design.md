# dev-shared 環境別テンプレート設計 & dev-demo環境追加計画

## 方針概要

1. まず **dev-demo環境を新規作成** する（Phase 1）
2. その後、余裕のあるタイミングで **既存3環境のリソースをimport** する（Phase 2）
3. ECS TaskDefinitionは **初期定義のみCFn管理、以降はCI/CDに委任**

---

## 1. 背景

### 現状の課題

- 既存3環境（develop, dev-ope, dev-front）のRDS/ECS/CI/CD等は**各環境ごとに独立した34スタック**で管理されている
- dev-sharedの共有リソース（VPC, ALB等）は01〜06の**環境別ループデプロイ対応テンプレート**（`_env_` パターン）で再設計済み
- しかし**RDS, ECS, ECR, CI/CD等の環境固有テンプレートがdev-sharedにまだ存在しない**
- 今後dev-demo環境を追加する際に、旧方式（環境ごとに34スタック）ではスケールしない

### ゴール

- 環境固有リソース（RDS, ECS等）も `_env_` パターンで再設計し、`deploy.sh` のループで全環境に自動デプロイできるようにする
- **dev-demo**: 新テンプレートから新規作成（Phase 1で先行）
- **既存3環境**: テンプレート検証後にCloudFormation importで新スタックに取り込む（Phase 2で後日実施）

---

## 2. 新規作成するテンプレート一覧

`dev_shared/templates/` に追加予定：

| テンプレート | 種別 | 内容 | 参考元（dev-ope） |
|-------------|------|------|--------------------|
| `DEV_SHARED_07_env_rds.yaml` | 環境別 | Aurora Serverless v2 クラスタ + インスタンス + サブネットグループ + パラメータグループ | 17_RDS |
| `DEV_SHARED_08_env_ecs.yaml` | 環境別 | ECSクラスタ + 全サービス（api, batch, mailpit, redis）のタスク定義・サービス・ログ | 23, 26, 303, 402 |
| `DEV_SHARED_09_env_ecr.yaml` | 環境別 | ECRリポジトリ | 22_ECR |
| `DEV_SHARED_10_env_pipeline.yaml` | 環境別 | CodeBuild + CodeDeploy + CodePipeline | 28〜32 |

### テンプレート設計方針

- 全テンプレートで `EnvName` パラメータを受け取り、リソース名に環境名を含める
- 共有リソース（VPC, Subnet, ALB, SG等）は `Fn::ImportValue` で参照
- dev-opeの既存テンプレートをベースに、SSM Parameter Store参照 → `Fn::ImportValue` に書き換え
- Mappings で環境ごとの差分（RDSキャパシティ、タスクCPU/メモリ等）を吸収
- RDSパスワードはMappingsにハードコードせず、**Secrets Manager管理**に移行
- ECS TaskDefinitionは**初期定義のみCFn管理**。CI/CDが新リビジョンをデプロイするため、CFnとの競合を避ける

### レビュー指摘事項の反映

- ECS系テンプレート（旧案: 08〜12の5本）を `08_env_ecs.yaml` 1本に統合（アーキテクトレビュー指摘）
- RDSパスワードのSecrets Manager移行（SRE/CFnレビュー指摘）
- KMSキーのExportがdev-sharedに不在のため、既存KMSを参照する設計 or dev-sharedにKMSスタック追加が必要（要検討）

---

## 3. Phase 1: dev-demo環境の新規作成

### 概要

新テンプレート（07〜10）を設計・実装し、**dev-demoのみを新規作成**する。
既存3環境（develop, dev-ope, dev-front）は旧スタックのまま触らない。

### deploy.sh の修正方針

既存の環境別テンプレート（02_env_sg, 04_env_lb）は既に3環境分デプロイ済み。
新規テンプレート（07〜10）はdev-demoのみにデプロイする制御が必要。

```bash
# 方法: テンプレートごとに対象環境を切り替える
# 既存テンプレート（02, 04）: 全環境（develop, dev-ope, dev-front, dev-demo）
# 新規テンプレート（07〜10）: dev-demoのみ（既存環境のimportは Phase 2 で実施）

# deploy.sh の ENVIRONMENTS はそのまま全環境を定義
ENVIRONMENTS=("develop" "dev-ope" "dev-front" "dev-demo")

# 新規テンプレートの対象環境を制御する関数を追加
get_env_list_for_template() {
  local filename=$1
  case "$filename" in
    *07_env_rds*|*08_env_ecs*|*09_env_ecr*|*10_env_pipeline*)
      # Phase 2でimport完了するまでは dev-demo のみ
      echo "dev-demo"
      ;;
    *)
      # 既存テンプレートは全環境
      echo "${ENVIRONMENTS[@]}"
      ;;
  esac
}
```

### deploy.sh への追加設定

```bash
# get_env_lb_params に追加
dev-demo)
  echo "ApiCertArn=<dev-demo用API ACM証明書ARN>" \
       "MailpitCertArn=<dev-demo用Mailpit ACM証明書ARN>" \
       "ApiHostHeader=api-dev-demo.shikigaku-cloud.com" \
       "MailpitHostHeader=mailpit-dev-demo.shikigaku-cloud.com"
  ;;
```

### 既存テンプレートの修正

以下のファイルの `EnvName` の `AllowedValues` に `"dev-demo"` を追加：
- `DEV_SHARED_02_env_sg.yaml`
- `DEV_SHARED_04_env_lb.yaml`
- 新規作成する `07_env_rds.yaml` 〜 `10_env_pipeline.yaml`

`04_env_lb.yaml` の `EnvPriority` Mappings にもエントリ追加が必要。

### 事前に必要なAWSリソース（テンプレート外）

- [ ] ACM証明書: `api-dev-demo.shikigaku-cloud.com` 用
- [ ] ACM証明書: `mailpit-dev-demo.shikigaku-cloud.com` 用
- [ ] Route53: DNS設定（別OUで対応）
- [ ] Secrets Manager: DB認証情報
- [ ] dev-demoのドメイン名・サブドメインの確定
- [ ] dev-demoのRDS初期データの要否

### Phase 1 の実施手順

```
1. KMSキーの参照方針を決定（既存KMS参照 or dev-sharedにKMSスタック追加）
2. ACM証明書の準備
3. テンプレート設計・実装（07〜10）
4. deploy.sh にdev-demoエントリ追加 + テンプレート対象環境制御
5. 既存テンプレート（02, 04）の AllowedValues にdev-demo追加
6. deploy.sh 実行でdev-demo環境の全リソースを新規作成
7. DNS設定 + 動作確認
```

---

## 4. Phase 2: 既存3環境のリソースインポート（後日実施）

### 概要

Phase 1でdev-demoにより実地検証されたテンプレートを使い、既存3環境のリソースをimportする。
テンプレートが検証済みのためimport時のドリフトも最小限に抑えられる。

### 前提: CloudFormation resource import の仕組み

- 既存のAWSリソースを、新しいCloudFormationスタックの管理下に取り込める
- リソースの再作成は発生しない（ダウンタイムなし）
- インポート対象リソースには `DeletionPolicy: Retain` が必須
- **1つのリソースは1つのスタックにしか属せない**（最大の制約）
  - → 旧スタックをRetain付きで削除してからimportする必要がある

### importサポート状況

今回必要な全リソースタイプはimportをサポートしている：

| リソースタイプ | import | 識別子 |
|---------------|--------|--------|
| `AWS::RDS::DBCluster` | OK | `DBClusterIdentifier` |
| `AWS::RDS::DBInstance` | OK | `DBInstanceIdentifier` |
| `AWS::RDS::DBSubnetGroup` | OK | `DBSubnetGroupName` |
| `AWS::RDS::DBParameterGroup` | OK | `DBParameterGroupName` |
| `AWS::ECS::Cluster` | OK | `ClusterName` |
| `AWS::ECS::Service` | OK | `ServiceName` + `Cluster` |
| `AWS::ECS::TaskDefinition` | 注意 | リビジョンごとに不変。import可能だが特定リビジョンを指定 |
| `AWS::ECR::Repository` | OK | `RepositoryName` |
| `AWS::Logs::LogGroup` | OK | `LogGroupName` |

### Export依存関係の調査結果

import対象スタックのExportについて調査済み。**ほぼブロッカーなし**。

| 旧スタック | Export名 | 他スタックから参照 | 削除可否 |
|-----------|----------|-------------------|---------|
| 17_RDS | `RDSDBCluster` | なし | そのまま削除OK |
| 23_ECS_Cluster | `ECSClusterApi`, `ECSClusterAdminer` | なし | そのまま削除OK |
| 22_ECR | `ECRRepository` | なし | そのまま削除OK |
| 26_ECS_Api | TG Blue/Green, Listener, Service, TaskDef | コメントアウト済み参照のみ | そのまま削除OK |
| 401_Redis_SG | `EC2SecurityGroupRedisEcs` | なし | そのまま削除OK |
| 402_ECS_Redis | — | — | そのまま削除OK |
| **301_mailpit_SG** | `EC2SecurityGroupMailpit` 等 | **303_mailpitが参照** | **303を先に処理** |

唯一の依存: 301_mailpit_SG → 303_mailpit。削除順序を守れば問題なし。
dev-sharedではMailpit SGは `02_env_sg.yaml` に統合済みのため、旧301のSGはimportせず廃棄する。

### インポート手順（方法B: 旧スタック削除 → 新スタックにimport）

```
1. 旧スタックの全リソースに DeletionPolicy: Retain を追加してスタック更新
2. Retain付与をCLIで確認（aws cloudformation get-template で全リソースにRetainがあることを検証）
3. 旧スタックを delete-stack（リソースはRetainで残り、CFn管理外になる）
4. 新スタックに create-change-set --change-set-type IMPORT で取り込む
5. execute-change-set を実行、完了を待機
6. ドリフト検出で差分確認、必要に応じてテンプレート修正
7. import後に DeletionPolicy: Retain を Snapshot 等に変更
```

### インポートの実施例（RDS、dev-opeの場合）

```bash
PROFILE="dev-skg04"
REGION="ap-northeast-1"

# --------------------------------------------------
# Step 1: 旧スタックの全リソースに DeletionPolicy: Retain を追加
# --------------------------------------------------
aws cloudformation deploy \
  --template-file DEV_OPE2_17_RDS_retain.yaml \
  --stack-name DEV-OPE2-17-RDS \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --profile "$PROFILE" --region "$REGION"

# --------------------------------------------------
# Step 2: Retain付与を確認
# --------------------------------------------------
aws cloudformation get-template \
  --stack-name DEV-OPE2-17-RDS \
  --profile "$PROFILE" --region "$REGION" \
  --query 'TemplateBody' --output text | grep -c 'DeletionPolicy'
# → リソース数と一致することを確認

# --------------------------------------------------
# Step 3: 旧スタックを削除（リソースは残る）
# --------------------------------------------------
aws cloudformation delete-stack \
  --stack-name DEV-OPE2-17-RDS \
  --profile "$PROFILE" --region "$REGION"

aws cloudformation wait stack-delete-complete \
  --stack-name DEV-OPE2-17-RDS \
  --profile "$PROFILE" --region "$REGION"

# --------------------------------------------------
# Step 4: 新スタックにimport
# --------------------------------------------------
aws cloudformation create-change-set \
  --stack-name DEV-SHARED-07-env-rds-dev-ope \
  --change-set-name import-rds \
  --change-set-type IMPORT \
  --template-body file://templates/DEV_SHARED_07_env_rds.yaml \
  --parameters ParameterKey=EnvName,ParameterValue=dev-ope \
  --resources-to-import '[
    {"ResourceType":"AWS::RDS::DBCluster","LogicalResourceId":"RDSDBCluster","ResourceIdentifier":{"DBClusterIdentifier":"dev-ope-skg04"}},
    {"ResourceType":"AWS::RDS::DBInstance","LogicalResourceId":"RDSDBInstance1","ResourceIdentifier":{"DBInstanceIdentifier":"dev-ope-serverless-instance1"}},
    {"ResourceType":"AWS::RDS::DBSubnetGroup","LogicalResourceId":"RDSDBSubnetGroup","ResourceIdentifier":{"DBSubnetGroupName":"dev-shared-skg04-db-subnet-group"}},
    {"ResourceType":"AWS::RDS::DBParameterGroup","LogicalResourceId":"RDSDBParameterGroup","ResourceIdentifier":{"DBParameterGroupName":"dev-ope-skg04-parameter-group"}}
  ]' \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile "$PROFILE" --region "$REGION"

# --------------------------------------------------
# Step 5: チェンジセットを確認・実行
# --------------------------------------------------
aws cloudformation describe-change-set \
  --stack-name DEV-SHARED-07-env-rds-dev-ope \
  --change-set-name import-rds \
  --profile "$PROFILE" --region "$REGION"

aws cloudformation execute-change-set \
  --stack-name DEV-SHARED-07-env-rds-dev-ope \
  --change-set-name import-rds \
  --profile "$PROFILE" --region "$REGION"

# import完了を待機
aws cloudformation wait stack-import-complete \
  --stack-name DEV-SHARED-07-env-rds-dev-ope \
  --profile "$PROFILE" --region "$REGION"

# --------------------------------------------------
# Step 6: ドリフト検出
# --------------------------------------------------
aws cloudformation detect-stack-drift \
  --stack-name DEV-SHARED-07-env-rds-dev-ope \
  --profile "$PROFILE" --region "$REGION"
```

### import失敗時のロールバック

- import用チェンジセットが失敗した場合、リソースは「CFn管理外」のまま残る
- ロールバック手段: 旧テンプレート（Retain付き）で `create-change-set --change-set-type IMPORT` を実行し、旧スタックに再import
- リソース自体は動き続けるため、サービス影響なし

### Phase 2 の実施手順

```
1. deploy.sh のテンプレート対象環境制御を更新（dev-demoのみ → 全環境に拡大）
2. 1環境ずつimport実施（dev-opeから先行）:
   a. 旧スタックに DeletionPolicy: Retain 追加 → デプロイ → 確認
   b. 旧スタック削除
   c. 新スタックにimport
   d. ドリフト検出・修正
   e. deploy.sh 実行で正常にデプロイされることを確認
3. 全環境完了後、旧VPCの残りリソースを削除
```

---

## 5. リスクと懸念事項

### リスク

| リスク | 影響度 | 対策 |
|--------|--------|------|
| import時にテンプレートと実態の設定差分でドリフトが発生 | 中 | import後にドリフト検出を実施。差分はテンプレート側を修正 |
| 旧スタック削除時にDeletionPolicy: Retain漏れでリソースが消える | 高 | `get-template` でRetain付与をCLIで機械的に確認してから削除 |
| 旧スタック削除後〜import完了前の「CFn管理外」期間 | 中 | 作業は1スタックずつ素早く「削除→即import」で実施 |
| DeletionProtection有効のRDSでdelete-stack時の挙動 | 中 | 事前にRetain動作を確認。DeletionProtection自体はリソース属性なのでRetainで残る |
| import直後のdeploy.sh実行でドリフトにより意図しない変更 | 高 | ドリフト検出・修正を完了してからdeploy.sh実行 |
| ECS TaskDefinitionのCI/CDとCFnの競合 | 中 | 初期定義のみCFn管理。CI/CDが新リビジョンを作成するため、CFnはTaskDefinitionを更新しない |
| 旧スタックのExportが他スタックから参照されていてdelete-stack失敗 | 高 | 調査済み。301_mailpit_SG→303_mailpitの依存のみ。削除順序を守る |

### 要確認事項

- [ ] KMSキーの参照方針（既存KMS参照 or dev-sharedにKMSスタック追加）
- [ ] Secrets Manager / KMS の共有方針（環境別 or 共有）
- [ ] dev-demoのドメイン名・サブドメインの確定
- [ ] dev-demoのRDS初期データの要否
- [x] 旧スタック間の `!ImportValue` 依存関係の洗い出し → **調査完了、ほぼブロッカーなし**
- [x] ECS TaskDefinitionの管理方針 → **初期定義のみCFn管理、以降はCI/CDに委任**
