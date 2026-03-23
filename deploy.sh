#!/bin/bash

# ==============================================================================
# dev-shared 統合VPC デプロイスクリプト
#
# 1. 共有リソース（network, lb, adminer）を番号順に1回デプロイ
# 2. 環境別リソース（_env_を含むファイル）を環境数分ループデプロイ
#
# 環境追加時:
#   1. ENVIRONMENTS にエントリ追加
#   2. get_env_lb_params に case 追加
#   3. テンプレート内の AllowedValues / Mappings にもエントリ追加
# ==============================================================================

set -euo pipefail

# スクリプトのディレクトリを基準にする
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"

# AWSプロファイル
AWS_PROFILE="dev-skg04"

# 使用リージョン
AWS_REGION="ap-northeast-1"

# 環境名リスト（追加時はここに追加）
ENVIRONMENTS=("develop" "dev-ope" "dev-front" "dev-demo")

# ==============================================================================
# ALB関連の設定
#   統合ALB: 1つのALBで全環境のAPI/Mailpit/Adminerをルーティング
# ==============================================================================

# --- 統合ALBテンプレート（03_lb）用: デフォルト証明書 ---
DEFAULT_CERT_ARN="arn:aws:acm:ap-northeast-1:186095208202:certificate/5352e452-6e37-4d40-8bf4-c962b8871577"

# --- 共有Adminerテンプレート（05_adminer）用 ---
ADMINER_HOST_HEADER="adminer-develop.shikigaku-cloud.com"
ADMINER_CERT_ARN="arn:aws:acm:ap-northeast-1:186095208202:certificate/cc4c7e1a-3e03-43f3-b68b-6042693201fd"

# ==============================================================================
# 環境別ALBパラメータ（連想配列の代わりに関数で返す）
# 環境追加時はここに case を追加する
# ==============================================================================
get_env_lb_params() {
  local env_name=$1
  case "$env_name" in
    develop)
      echo "ApiCertArn=arn:aws:acm:ap-northeast-1:186095208202:certificate/5352e452-6e37-4d40-8bf4-c962b8871577" \
           "MailpitCertArn=arn:aws:acm:ap-northeast-1:186095208202:certificate/52f0b432-6da7-47cf-beba-5317a5052246" \
           "ApiHostHeader=api-develop.shikigaku-cloud.com" \
           "MailpitHostHeader=mailpit-develop.shikigaku-cloud.com"
      ;;
    dev-ope)
      echo "ApiCertArn=arn:aws:acm:ap-northeast-1:186095208202:certificate/bf8d1810-12e9-4963-a789-0b00be1739af" \
           "MailpitCertArn=arn:aws:acm:ap-northeast-1:186095208202:certificate/5c115217-0c37-48aa-aac4-8010377c3ce9" \
           "ApiHostHeader=api-dev-ope.shikigaku-cloud.com" \
           "MailpitHostHeader=mailpit-dev-ope.shikigaku-cloud.com"
      ;;
    dev-front)
      echo "ApiCertArn=arn:aws:acm:ap-northeast-1:186095208202:certificate/5d4c6a1a-154c-485f-b221-15b91ad646db" \
           "MailpitCertArn=arn:aws:acm:ap-northeast-1:186095208202:certificate/0d0dfb52-20eb-4d4f-aebb-cc621eaf4195" \
           "ApiHostHeader=api-dev-front.shikigaku-cloud.com" \
           "MailpitHostHeader=mailpit-dev-front.shikigaku-cloud.com"
      ;;
    dev-demo)
      # TODO: ACM証明書ARNを発行後に設定する
      echo "ApiCertArn=arn:aws:acm:ap-northeast-1:186095208202:certificate/PLACEHOLDER-API-DEV-DEMO" \
           "MailpitCertArn=arn:aws:acm:ap-northeast-1:186095208202:certificate/PLACEHOLDER-MAILPIT-DEV-DEMO" \
           "ApiHostHeader=api-dev-demo.shikigaku-cloud.com" \
           "MailpitHostHeader=mailpit-dev-demo.shikigaku-cloud.com"
      ;;
    *)
      echo "ERROR: Unknown environment: $env_name" >&2
      exit 1
      ;;
  esac
}

# ==============================================================================
# パイプライン関連の設定
# ==============================================================================

# GitHub Connection ARN（CodeStar）
GITHUB_CONNECTION_ARN="arn:aws:codestar-connections:ap-northeast-1:186095208202:connection/PLACEHOLDER-GITHUB-CONNECTION"

# ==============================================================================
# テンプレートごとの対象環境リストを返す
# 新規テンプレート（07〜10）はPhase 2でimport完了するまでdev-demoのみ
# ==============================================================================
get_env_list_for_template() {
  local filename=$1
  case "$filename" in
    *07_env_rds*|*08_env_ecr*|*09_env_ecs*|*10_env_pipeline*)
      # Phase 2でimport完了するまでは dev-demo のみ
      echo "dev-demo"
      ;;
    *)
      # 既存テンプレートは全環境
      echo "${ENVIRONMENTS[@]}"
      ;;
  esac
}

# ==============================================================================
# ROLLBACK_COMPLETE スタックの自動削除
# ==============================================================================
cleanup_failed_stack() {
  local stack_name=$1
  local stack_status
  stack_status=$(aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [ "$stack_status" = "ROLLBACK_COMPLETE" ]; then
    echo "  Stack $stack_name is in ROLLBACK_COMPLETE state. Deleting..."
    aws cloudformation delete-stack \
      --stack-name "$stack_name" \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE"
    aws cloudformation wait stack-delete-complete \
      --stack-name "$stack_name" \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE"
    echo "  Deleted: $stack_name"
  fi
}

# ==============================================================================
# 共有スタックのデプロイ（番号順に1回ずつ）
# ==============================================================================
deploy_shared_stack() {
  local template_file=$1
  local stack_name=$2
  shift 2

  echo "=========================================="
  echo "Deploying shared stack: $stack_name"
  echo "  Template: $template_file"
  echo "=========================================="

  cleanup_failed_stack "$stack_name"

  if [ $# -gt 0 ]; then
    aws cloudformation deploy \
      --template-file "$template_file" \
      --stack-name "$stack_name" \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE" \
      --capabilities CAPABILITY_NAMED_IAM \
      --no-fail-on-empty-changeset \
      --parameter-overrides "$@"
  else
    aws cloudformation deploy \
      --template-file "$template_file" \
      --stack-name "$stack_name" \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE" \
      --capabilities CAPABILITY_NAMED_IAM \
      --no-fail-on-empty-changeset
  fi

  echo "Successfully deployed: $stack_name"
  echo ""
}

# ==============================================================================
# 環境別スタックのデプロイ（環境数分ループ）
# ==============================================================================
deploy_env_stack() {
  local template_file=$1
  local base_stack_name=$2
  local env_name=$3
  shift 3
  local stack_name="${base_stack_name}-${env_name}"

  echo "=========================================="
  echo "Deploying env stack: $stack_name"
  echo "  Template: $template_file"
  echo "  Environment: $env_name"
  echo "=========================================="

  cleanup_failed_stack "$stack_name"

  # PLACEHOLDERチェック
  validate_no_placeholders "$@"

  aws cloudformation deploy \
    --template-file "$template_file" \
    --stack-name "$stack_name" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset \
    --parameter-overrides "EnvName=${env_name}" "$@"

  echo "Successfully deployed: $stack_name"
  echo ""
}

# ==============================================================================
# テンプレート別のパラメータを取得
# ==============================================================================
get_shared_params() {
  local filename=$1
  case "$filename" in
    *03_lb*)
      echo "DefaultCertArn=${DEFAULT_CERT_ARN}"
      ;;
    *05_adminer*)
      echo "AdminerHostHeader=${ADMINER_HOST_HEADER}" \
           "AdminerCertArn=${ADMINER_CERT_ARN}"
      ;;
    *)
      echo ""
      ;;
  esac
}

get_env_params() {
  local filename=$1
  local env_name=$2
  case "$filename" in
    *04_env_lb*)
      get_env_lb_params "$env_name"
      ;;
    *10_env_pipeline*)
      echo "GitHubConnectionArn=${GITHUB_CONNECTION_ARN}"
      ;;
    *)
      echo ""
      ;;
  esac
}

# ==============================================================================
# PLACEHOLDERチェック（デプロイ前にバリデーション）
# ==============================================================================
validate_no_placeholders() {
  local params="$*"
  if [[ "$params" == *"PLACEHOLDER"* ]]; then
    echo "ERROR: PLACEHOLDER values detected in parameters. Update deploy.sh with actual ARNs." >&2
    echo "  Params: $params" >&2
    exit 1
  fi
}

# ==============================================================================
# メイン処理
# ==============================================================================
echo "============================================"
echo "  dev-shared 統合VPC デプロイ開始"
echo "  Profile: $AWS_PROFILE"
echo "  Region:  $AWS_REGION"
echo "  Environments: ${ENVIRONMENTS[*]}"
echo "============================================"
echo ""

# 環境別テンプレートのファイル名パターン（_env_ を含むもの）
ENV_TEMPLATE_PATTERN="_env_"

# テンプレートを番号順にデプロイ（glob展開は辞書順＝番号順）
for template_file in "$TEMPLATE_DIR"/*.yaml; do
  filename=$(basename "$template_file" .yaml)

  if [[ "$filename" == *"$ENV_TEMPLATE_PATTERN"* ]]; then
    # 環境別テンプレート → 対象環境分ループ
    base_stack_name="${filename//_/-}"
    # shellcheck disable=SC2207
    env_list=($(get_env_list_for_template "$filename"))
    for env_name in "${env_list[@]}"; do
      env_params=$(get_env_params "$filename" "$env_name")
      # shellcheck disable=SC2086
      deploy_env_stack "$template_file" "$base_stack_name" "$env_name" $env_params
    done
  else
    # 共有テンプレート → 1回デプロイ
    stack_name="${filename//_/-}"
    shared_params=$(get_shared_params "$filename")
    # shellcheck disable=SC2086
    deploy_shared_stack "$template_file" "$stack_name" $shared_params
  fi
done

echo "============================================"
echo "  All stacks deployed successfully!"
echo "============================================"
