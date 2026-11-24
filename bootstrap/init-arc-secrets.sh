#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Đặt file private key .pem tải từ GitHub vào cùng thư mục với script này
# và điền các thông tin ID tương ứng bên dưới.
# ==============================================================================

NAMESPACE="arc-runners"
SECRET_NAME="github-app-arc-secret"

GITHUB_APP_ID="1234567"                         # Thay bằng App ID
GITHUB_APP_INSTALLATION_ID="89101112"           # Thay bằng Installation ID
PRIVATE_KEY_PATH="./k8s-runner-arc-prod.private-key.pem"

if [ ! -f "$PRIVATE_KEY_PATH" ]; then
    echo "LỖI: Không tìm thấy file private key tại: $PRIVATE_KEY_PATH"
    exit 1
fi

echo "--> Đang tạo Kubernetes Secret [$SECRET_NAME] trong namespace [$NAMESPACE]..."

kubectl create secret generic "$SECRET_NAME" \
    --namespace="$NAMESPACE" \
    --from-literal=github_app_id="$GITHUB_APP_ID" \
    --from-literal=github_app_installation_id="$GITHUB_APP_INSTALLATION_ID" \
    --from-file=github_app_private_key="$PRIVATE_KEY_PATH" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "--> Đã tạo Secret thành công!"
