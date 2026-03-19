#!/bin/bash

# ==============================================================================
# dev-shared 統合VPC 全スタック削除スクリプト
#
# デプロイの逆順で削除する（依存関係の下流から）
# ==============================================================================

set -euo pipefail

AWS_PROFILE="dev-skg04"
AWS_REGION="ap-northeast-1"

ENVIRONMENTS=("develop" "dev-ope" "dev-front")

# ==============================================================================
# スタック削除（存在しない場合はスキップ）
# ==============================================================================
delete_stack() {
  local stack_name=$1
  local stack_status
  stack_status=$(aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "NOT_FOUND")

  if [ "$stack_status" = "NOT_FOUND" ]; then
    echo "  SKIP: $stack_name (not found)"
    return
  fi

  echo "  Deleting: $stack_name (status: $stack_status)"
  aws cloudformation delete-stack \
    --stack-name "$stack_name" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE"
  aws cloudformation wait stack-delete-complete \
    --stack-name "$stack_name" \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE"
  echo "  Deleted: $stack_name"
}

# ==============================================================================
# メイン処理
# ==============================================================================
echo "============================================"
echo "  dev-shared 全スタック削除開始"
echo "  Profile: $AWS_PROFILE"
echo "  Region:  $AWS_REGION"
echo "============================================"
echo ""

echo "[1/6] Deleting 06_bastion..."
delete_stack "DEV-SHARED-06-bastion"
echo ""

echo "[2/6] Deleting 05_adminer..."
delete_stack "DEV-SHARED-05-adminer"
echo ""

echo "[3/6] Deleting 04_env_lb (per-environment)..."
for env_name in "${ENVIRONMENTS[@]}"; do
  delete_stack "DEV-SHARED-04-env-lb-${env_name}"
done
echo ""

echo "[4/6] Deleting 03_lb..."
delete_stack "DEV-SHARED-03-lb"
echo ""

echo "[5/6] Deleting 02_env_sg (per-environment)..."
for env_name in "${ENVIRONMENTS[@]}"; do
  delete_stack "DEV-SHARED-02-env-sg-${env_name}"
done
echo ""

echo "[6/6] Deleting 01_network..."
delete_stack "DEV-SHARED-01-network"
echo ""

echo "============================================"
echo "  All stacks deleted successfully!"
echo "============================================"
