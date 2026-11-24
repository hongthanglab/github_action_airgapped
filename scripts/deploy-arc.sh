#!/usr/bin/env bash
set -euo pipefail

ARC_VERSION="0.10.1"
CHARTS_DIR="./charts"
ENV_DIR="./environments/production"

print_header() {
    echo -e "\n========================================================"
    echo -e "  $1"
    echo -e "========================================================\n"
}

pull_charts() {
    print_header "1. Tải Helm Charts local (v${ARC_VERSION})"
    mkdir -p "$CHARTS_DIR"

    echo "--> Đang tải chart gha-runner-scale-set-controller..."
    helm pull "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller" \
        --version "$ARC_VERSION" \
        --untar \
        -d "$CHARTS_DIR"

    echo "--> Đang tải chart gha-runner-scale-set..."
    helm pull "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set" \
        --version "$ARC_VERSION" \
        --untar \
        -d "$CHARTS_DIR"

    echo "--> Hoàn tất tải charts về $CHARTS_DIR"
}

deploy_controller() {
    print_header "2. Triển khai ARC Controller (namespace: arc-systems)"
    if [ ! -d "$CHARTS_DIR/gha-runner-scale-set-controller" ]; then
        pull_charts
    fi

    helm upgrade --install arc-controller "$CHARTS_DIR/gha-runner-scale-set-controller" \
        --namespace arc-systems \
        --create-namespace \
        -f "$ENV_DIR/arc-controller/values.yaml" \
        --wait \
        --timeout 5m
}

deploy_runners() {
    print_header "3. Triển khai Runner Scale Set (namespace: arc-runners)"
    if [ ! -d "$CHARTS_DIR/gha-runner-scale-set" ]; then
        pull_charts
    fi

    # Kiểm tra secret GitHub App đã tồn tại trước khi deploy
    if ! kubectl get secret github-app-arc-secret -n arc-runners >/dev/null 2>&1; then
        echo "CẢNH BÁO: Không tìm thấy secret [github-app-arc-secret] trong namespace [arc-runners]."
        echo "Vui lòng chạy script bootstrap/init-arc-secrets.sh trước khi triển khai runner!"
        exit 1
    fi

    helm upgrade --install k8s-runner-prod "$CHARTS_DIR/gha-runner-scale-set" \
        --namespace arc-runners \
        --create-namespace \
        -f "$ENV_DIR/arc-runner-scale-set/values.yaml" \
        --wait \
        --timeout 5m
}

check_status() {
    print_header "4. Trạng thái Helm Releases & Pods"
    echo "--- Helm Releases [arc-systems] ---"
    helm list -n arc-systems
    echo -e "\n--- Helm Releases [arc-runners] ---"
    helm list -n arc-runners
    echo -e "\n--- Pods [arc-systems] ---"
    kubectl get pods -n arc-systems
    echo -e "\n--- Pods [arc-runners] ---"
    kubectl get pods -n arc-runners
}

uninstall_all() {
    print_header "CẢNH BÁO: Gỡ bỏ toàn bộ ARC Releases"
    read -p "Bạn có chắc chắn muốn gỡ bỏ k8s-runner-prod và arc-controller? (y/N): " -r CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "--> Đang gỡ k8s-runner-prod..."
        helm uninstall k8s-runner-prod -n arc-runners || true
        echo "--> Đang gỡ arc-controller..."
        helm uninstall arc-controller -n arc-systems || true
        echo "--> Đã gỡ bỏ thành công."
    else
        echo "Hủy thao tác."
    fi
}

case "${1:-all}" in
    pull)
        pull_charts
        ;;
    controller)
        deploy_controller
        ;;
    runners)
        deploy_runners
        ;;
    all)
        deploy_controller
        deploy_runners
        check_status
        ;;
    status)
        check_status
        ;;
    uninstall)
        uninstall_all
        ;;
    *)
        echo "Cách sử dụng: $0 {pull|controller|runners|all|status|uninstall}"
        exit 1
        ;;
esac
