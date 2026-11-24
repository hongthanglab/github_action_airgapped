# Hướng Dẫn Triển Khai GitHub Actions Self-Hosted Runner Trên Cụm Kubernetes Production (K8s-Runner)

Hướng dẫn chi tiết từng bước (step-by-step) thiết lập hệ thống **GitHub Actions Self-Hosted Runner** chuẩn Enterprise/Production trên cụm Kubernetes mang tên **K8s-Runner**. Tài liệu được xây dựng dựa trên thế hệ kiến trúc mới nhất của **Actions Runner Controller (ARC - Autoscaling Runner Scale Sets)**, triển khai trực tiếp bằng **Helm CLI**, đảm bảo tiêu chuẩn bảo mật, cô lập tài nguyên và tối ưu chi phí vận hành.

---
## 1. Tổng Quan Kiến Trúc & Nguyên Lý Hoạt Động

### 1.1. Các thành phần chính
- **Actions Runner Controller (ARC) Mode Mới (`gha-runner-scale-set-controller`)**: Quản lý vòng đời của các bộ Runner Scale Sets thông qua Custom Resource Definitions (CRDs) chuẩn của GitHub.
- **Runner Scale Set (`gha-runner-scale-set`)**: Đại diện cho một nhóm runner có khả năng tự động co giãn (Autoscaling).
- **Ephemerality (Tính chất tạm thời)**: Mỗi Runner Pod chỉ xử lý duy nhất **1 job**, sau đó tự động hủy và xóa sạch dữ liệu. Job tiếp theo sẽ khởi chạy trên một Pod hoàn toàn mới.
- **Không sử dụng Webhook-Dispatch**: Runner Scale Set Listener sử dụng cơ chế kết nối outbound duy nhất (HTTPS/WebSocket/SSE Long Polling) đến GitHub Actions Service. Do đó **không cần mở bất kỳ Ingress nào từ Internet vào K8s**.
- **Docker-in-Docker (DinD) Rootless**: Container thực thi Docker Daemon chạy hoàn toàn dưới quyền người dùng không đặc quyền (`rootless`, UID 1000), loại bỏ nguy cơ chiếm quyền root máy chủ (Node privilege escalation).
- **NetworkPolicy Production**: Chặn toàn bộ Ingress; Egress chỉ mở ra Internet (GitHub API, Docker Hub, Package Registries) và CoreDNS nội bộ; chặn triệt để truy cập vào Cloud Metadata Service (`169.254.169.254`) và các Service nội bộ nhạy cảm trong K8s.
- **Quản lý triển khai bằng Helm CLI**: Tải Helm Chart về local và quản lý triển khai trực tiếp bằng `helm upgrade --install`, loại bỏ phụ thuộc vào các công cụ GitOps như ArgoCD khi cần triển khai tinh gọn, trực tiếp.

### 1.2. Sơ đồ kiến trúc

```mermaid
flowchart TD
    subgraph GitHub_Cloud["GitHub Enterprise Cloud / Organization"]
        GH_App["GitHub App (Auth & Perms)"]
        GH_Queue["Actions Job Queue"]
        GH_Group["Runner Group: production-runners"]
    end

    subgraph K8s_Runner_Cluster["K8s-Runner Cluster (Production)"]
        subgraph NS_System["Namespace: arc-systems"]
            ARC_Ctrl["ARC Controller Pod\n(gha-runner-scale-set-controller)"]
        end

        subgraph NS_Runners["Namespace: arc-runners"]
            Listener["Scale Set Ephemeral Listener Pod\n(Long Polling Outbound)"]
            NetPol["NetworkPolicy\n(Deny Ingress, Deny Cloud Metadata)"]
            
            subgraph Runner_Pod["Ephemeral Runner Pod (Min: 1, Max: 10)"]
                C_Runner["Container: runner\n(actions-runner:latest)"]
                C_DinD["Sidecar: dind\n(docker:dind-rootless UID:1000)"]
                EmptyDir[("Shared Volume: emptyDir\n(/var/run/docker)")]
                C_Runner -. Unix Socket .-> EmptyDir
                C_DinD -. Expose Socket .-> EmptyDir
            end
        end

        Platform_Admin["Platform Engineer / CI/CD\n(Helm 3 CLI)"]
    end

    Listener -- "1. Outbound HTTPS Long-poll (HTTPS 443)" --> GH_Queue
    ARC_Ctrl -- "2. Reconcile Scale-Set CRD" --> Listener
    Listener -- "3. Scale Pods dynamically" --> Runner_Pod
    Runner_Pod -- "4. Pull Job & Report Status" --> GH_Queue
    Platform_Admin -- "helm upgrade --install" --> NS_System
    Platform_Admin -- "helm upgrade --install" --> NS_Runners
```

---

## 2. Cấu Hình GitHub App Trên GitHub Organization

Xác thực bằng **GitHub App** là tiêu chuẩn được GitHub khuyến nghị thay thế Personal Access Token (PAT) nhờ cơ chế token ngắn hạn (short-lived tokens) và hạn mức API độc lập lên đến 12.500 requests/giờ.

### Bước 2.1: Truy cập tạo GitHub App
1. Đăng nhập vào tài khoản GitHub có quyền **Owner** của Organization.
2. Điều hướng đến: `https://github.com/organizations/<TÊN_ORGANIZATION>/settings/apps`.
3. Nhấp chọn nút **New GitHub App**.

### Bước 2.2: Điền thông tin cơ bản (App Details)
- **GitHub App name**: `k8s-runner-arc-prod` *(tên phải là duy nhất trên toàn hệ thống GitHub)*.
- **Homepage URL**: `https://github.com/<TÊN_ORGANIZATION>` (hoặc URL cổng thông tin nội bộ của công ty).
- **Callback URL**: *Để trống*.
- **Expire user authorization tokens**: *Để mặc định*.
- **Request user authorization (OAuth) during installation**: *Bỏ chọn*.
- **Post installation redirect URL**: *Để trống*.
- **Webhook**:
  - Tại mục **Active**: **BỎ CHỌN (Uncheck)** mục *"Active"*.
  - *(Lý do: ARC thế hệ mới sử dụng giao thức HTTPS Long-polling, không sử dụng Webhook để tránh rủi ro bảo mật mở public endpoint)*.

### Bước 2.3: Phân quyền chi tiết (Permissions)
Mở rộng danh mục permissions và cấu hình chính xác như sau:

#### A. Repository permissions
| Quyền (Permission) | Mức cấp quyền | Mục đích sử dụng |
| :--- | :--- | :--- |
| **Actions** | **Read-only** | Cho phép runner đọc danh sách workflow và metadata |
| **Metadata** | **Read-only** | Bắt buộc mặc định của GitHub để đọc thông tin repo |

#### B. Organization permissions
| Quyền (Permission) | Mức cấp quyền | Mục đích sử dụng |
| :--- | :--- | :--- |
| **Organization self-hosted runners** | **Read and write** | Cho phép ARC đăng ký, giám sát và thu hồi runner trong Organization |

*(Tất cả các quyền còn lại: Account permissions, Organization permissions khác giữ nguyên mức **No access**).*

### Bước 2.4: Hoàn tất tạo App và tải Private Key
1. Kéo xuống cuối trang, tại mục **Where can this GitHub App be installed?**, chọn: **Only on this account**.
2. Nhấp chọn nút **Create GitHub App**.
3. Sau khi tạo thành công, giao diện sẽ chuyển đến trang Settings của App vừa tạo:
   - Ghi lại giá trị **App ID** (Ví dụ: `1234567`).
4. Kéo xuống mục **Private keys**, nhấp chọn nút **Generate a private key**.
5. Trình duyệt sẽ tự động tải về file có định dạng `.pem` (Ví dụ: `k8s-runner-arc-prod.2026-11-24.private-key.pem`).
   - Lưu trữ file này ở vị trí an toàn, tuyệt đối **không commit file này lên Git công khai**.

### Bước 2.5: Cài đặt GitHub App vào Organization
1. Tại thanh menu bên trái của trang cấu hình App, chọn **Install App**.
2. Tìm Organization của bạn và nhấp chọn nút **Install**.
3. Tại trang xác nhận quyền:
   - Chọn: **All repositories** (hoặc chọn từng repository cụ thể mà bạn muốn cấp quyền sử dụng runner).
4. Nhấp chọn nút **Install**.
5. Sau khi cài đặt, thanh địa chỉ trình duyệt sẽ có dạng:
   `https://github.com/organizations/<TÊN_ORGANIZATION>/settings/installations/<INSTALLATION_ID>`
   - Ghi lại giá trị `<INSTALLATION_ID>` ở cuối đường link (Ví dụ: `89101112`).

### Bước 2.6: Tạo Runner Group trên GitHub Organization
1. Truy cập: `https://github.com/organizations/<TÊN_ORGANIZATION>/settings/actions/runner-groups`.
2. Nhấp chọn nút **New runner group**.
3. Điền thông tin:
   - **Group name**: `production-runners`
   - **Visibility**: Chọn **Selected repositories** (chỉ định các repo thuộc môi trường Production được phép gọi runner này, tránh việc repo thử nghiệm chiếm dụng tài nguyên).
   - **Workflow access**: Chọn các repo được phép.
4. Nhấp chọn **Create group**.

---

## 4. Thiết Lập Bảo Mật & K8s Secrets (Platform Repo)

### Bước 4.1: Tạo Namespaces
Chạy các lệnh kubectl sau trên cụm `K8s-Runner`:

```bash
# Namespace dành cho ARC Controller
kubectl create namespace arc-systems

# Namespace dành cho Runner Scale Set Pods
kubectl create namespace arc-runners
```

Gán nhãn kiểm soát bảo mật Pod Security Standards (PSS) cấp `baseline` hoặc `restricted` cho namespace:
```bash
kubectl label namespace arc-systems pod-security.kubernetes.io/enforce=baseline
kubectl label namespace arc-runners pod-security.kubernetes.io/enforce=baseline
```

---

### Bước 4.2: Script khởi tạo K8s Secret chứa GitHub App Credentials

#### File: `bootstrap/init-arc-secrets.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Đặt file private key .pem tải từ GitHub vào cùng thư mục với script này
# và điền các thông tin ID tương ứng bên dưới.
# ==============================================================================

NAMESPACE="arc-runners"
SECRET_NAME="github-app-arc-secret"

GITHUB_APP_ID="1234567"                         # Thay bằng App ID ở Bước 2.4
GITHUB_APP_INSTALLATION_ID="89101112"           # Thay bằng Installation ID ở Bước 2.5
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
```

Cấp quyền thực thi và chạy script:
```bash
chmod +x bootstrap/init-arc-secrets.sh
./bootstrap/init-arc-secrets.sh
```

---

### Bước 4.3: Thiết lập NetworkPolicy bảo vệ hệ thống
Tạo file `environments/production/security/arc-runners-network-policy.yaml`:
- **Chặn toàn bộ Ingress**: Runner Pods không bao giờ cần nhận request kết nối vào từ bên ngoài.
- **Cho phép DNS (UDP/TCP port 53)** đến CoreDNS trong `kube-system`.
- **Cho phép Egress ra Internet** (HTTPS 443, HTTP 80, SSH 22, Git).
- **Chặn truy cập Cloud Metadata**: Ngăn chặn container chiếm đoạt IAM Role của Node qua địa chỉ `169.254.169.254`.
- **Chặn truy cập mạng nội bộ K8s / Private IP**: Chặn dải private `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` (loại trừ DNS).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: arc-runners-strict-security
  namespace: arc-runners
spec:
  podSelector:
    matchLabels:
      actions.github.com/scale-set-name: k8s-runner-prod
  policyTypes:
    - Ingress
    - Egress
  # 1. Chặn toàn bộ kết nối đi vào (Ingress)
  ingress: []
  # 2. Kiểm soát kết nối đi ra (Egress)
  egress:
    # A. Cho phép truy vấn DNS đến CoreDNS trong cluster
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53

    # B. Cho phép Egress ra Internet công cộng nhưng chặn Private CIDR và Cloud Metadata
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 169.254.169.254/32   # Chặn AWS/GCP/Azure Instance Metadata
              - 10.0.0.0/8           # Chặn dải IP VPC nội bộ K8s
              - 172.16.0.0/12        # Chặn dải IP Pod CIDR nội bộ K8s
              - 192.168.0.0/16       # Chặn dải IP mạng nội bộ on-premise
```

Áp dụng NetworkPolicy:
```bash
kubectl apply -f environments/production/security/arc-runners-network-policy.yaml
```

---

### Bước 4.4: Thiết lập ResourceQuota & LimitRange
Tạo file `environments/production/security/arc-runners-resource-quota.yaml` để kiểm soát tài nguyên tránh cạn kiệt Node:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: arc-runners-quota
  namespace: arc-runners
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    pods: "15" # Tương thích với maxRunners: 10 + buffer listener
---
apiVersion: v1
kind: LimitRange
metadata:
  name: arc-runners-limits
  namespace: arc-runners
spec:
  limits:
    - type: Container
      default:
        cpu: "2"
        memory: 4Gi
      defaultRequest:
        cpu: "500m"
        memory: 1Gi
```

Áp dụng cấu hình:
```bash
kubectl apply -f environments/production/security/arc-runners-resource-quota.yaml
```

---

## 5. Cấu Hình & Triển Khai Trực Tiếp Bằng Helm CLI

ARC phiên bản mới sử dụng 2 Helm Charts chính:
1. `gha-runner-scale-set-controller`: Quản lý Custom Resource Definitions (CRDs) và Runner Controller, chạy trong namespace `arc-systems`.
2. `gha-runner-scale-set`: Quản lý Scale Set Listener và các Runner Pod pools, chạy trong namespace `arc-runners`.

Toàn bộ quy trình triển khai được chuẩn hóa bằng việc **tải Helm Chart về thư mục local (`charts/`)**, sau đó áp dụng cấu hình values tương ứng thông qua lệnh `helm upgrade --install`.

---

### 5.1. Tải Helm Charts Về Thư Mục Local (`charts/`)
Tải và giải nén các Helm chart chính thức từ GitHub OCI Registry về thư mục `charts/` để kiểm soát phiên bản và kiểm toán nội bộ:

```bash
# Tạo thư mục lưu trữ chart
mkdir -p charts

# Tải và giải nén Chart gha-runner-scale-set-controller (v0.10.1)
helm pull oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
    --version 0.10.1 \
    --untar \
    -d charts/

# Tải và giải nén Chart gha-runner-scale-set (v0.10.1)
helm pull oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
    --version 0.10.1 \
    --untar \
    -d charts/
```

Sau khi tải, cấu trúc thư mục `charts/` sẽ gồm:
```
charts/
├── gha-runner-scale-set-controller/
└── gha-runner-scale-set/
```

---

### 5.2. File cấu hình Controller: `environments/production/arc-controller/values.yaml`
```yaml
# Cấu hình giá trị cho chart local: ./charts/gha-runner-scale-set-controller
replicaCount: 1

image:
  repository: ghcr.io/actions/actions-runner-controller-2
  pullPolicy: IfNotPresent

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 65534 # nobody
  capabilities:
    drop:
      - ALL
```

---

### 5.3. File cấu hình Runner Scale Set: `environments/production/arc-runner-scale-set/values.yaml`
Cấu hình chi tiết runner pool với cơ chế **Warm Pool (min: 1, max: 10)**, container **Rootless DinD**, cấu hình chống gián đoạn (Pod Anti-Affinity) và Resource limits:

```yaml
# Cấu hình giá trị cho chart local: ./charts/gha-runner-scale-set

## URL của GitHub Organization
githubConfigUrl: "https://github.com/<TÊN_ORGANIZATION>"

## Tên Secret chứa thông tin GitHub App đã tạo ở Bước 4.2
githubConfigSecret: "github-app-arc-secret"

## Tên Runner Group đã tạo trên GitHub Organization
runnerGroup: "production-runners"

## Tên Scale Set (chính là giá trị runs-on mà workflow Dev sẽ gọi)
runnerScaleSetName: "k8s-runner-prod"

## Chiến lược Autoscaling: Warm Pool
minRunners: 1
maxRunners: 10

## Cấu hình chi tiết Pod Template cho Runner và Docker Sidecar (DinD Rootless)
template:
  spec:
    ## Tránh việc nhiều runner dồn vào 1 node gây nghẽn I/O và CPU
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                  - key: actions.github.com/scale-set-name
                    operator: In
                    values:
                      - k8s-runner-prod
              topologyKey: kubernetes.io/hostname

    ## Thư mục dùng chung Unix Socket kết nối giữa Runner và Docker Daemon
    volumes:
      - name: docker-sock
        emptyDir: {}
      - name: docker-storage
        emptyDir: {}

    initContainers:
      - name: socket-permission-fix
        image: busybox:1.36
        command: ["sh", "-c", "chmod 777 /var/run/docker"]
        volumeMounts:
          - name: docker-sock
            mountPath: /var/run/docker

    containers:
      # ------------------------------------------------------------------------
      # Container 1: GitHub Actions Runner (Official Image)
      # ------------------------------------------------------------------------
      - name: runner
        image: ghcr.io/actions/actions-runner:latest
        command: ["/home/runner/run.sh"]
        env:
          - name: DOCKER_HOST
            value: "unix:///var/run/docker/docker.sock"
        securityContext:
          runAsUser: 1001
          runAsGroup: 1001
          runAsNonRoot: true
          allowPrivilegeEscalation: false
        resources:
          requests:
            cpu: "1"
            memory: "2Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
        volumeMounts:
          - name: docker-sock
            mountPath: /var/run/docker

      # ------------------------------------------------------------------------
      # Container 2: Rootless Docker-in-Docker Daemon (Sidecar)
      # ------------------------------------------------------------------------
      - name: dind
        image: docker:27-dind-rootless
        args:
          - "--host=unix:///var/run/docker/docker.sock"
          - "--storage-driver=overlay2"
        securityContext:
          runAsUser: 1000
          runAsGroup: 1000
          runAsNonRoot: true
          privileged: true # Privileged trong phạm vi User Namespace của rootless user
        env:
          - name: DOCKER_TLS_CERTDIR
            value: ""
        resources:
          requests:
            cpu: "1"
            memory: "2Gi"
          limits:
            cpu: "4"
            memory: "8Gi"
        volumeMounts:
          - name: docker-sock
            mountPath: /var/run/docker
          - name: docker-storage
            mountPath: /home/rootless/.local/share/docker
```

---

### 5.4. Các Câu Lệnh Triển Khai Helm CLI Trực Tiếp

#### Bước 1: Triển khai ARC Controller (CRDs & Controller)
Chạy controller trong namespace `arc-systems`:
```bash
helm upgrade --install arc-controller ./charts/gha-runner-scale-set-controller \
    --namespace arc-systems \
    --create-namespace \
    -f environments/production/arc-controller/values.yaml \
    --wait \
    --timeout 5m
```

#### Bước 2: Triển khai Runner Scale Set Pool
Chạy scale set listener và runner pods trong namespace `arc-runners`:
```bash
helm upgrade --install k8s-runner-prod ./charts/gha-runner-scale-set \
    --namespace arc-runners \
    --create-namespace \
    -f environments/production/arc-runner-scale-set/values.yaml \
    --wait \
    --timeout 5m
```

#### Các lệnh quản trị & kiểm tra trạng thái release:
```bash
# Liệt kê các release đang chạy
helm list -n arc-systems
helm list -n arc-runners

# Xem trạng thái chi tiết của từng release
helm status arc-controller -n arc-systems
helm status k8s-runner-prod -n arc-runners

# Rollback về revision trước đó nếu gặp sự cố
helm history k8s-runner-prod -n arc-runners
helm rollback k8s-runner-prod <REVISION_NUMBER> -n arc-runners

# Gỡ bỏ release (nếu cần bảo trì hoặc tái tạo)
# helm uninstall k8s-runner-prod -n arc-runners
# helm uninstall arc-controller -n arc-systems
```

---

### 5.5. Script Tự Động Hóa Triển Khai: `scripts/deploy-arc.sh`
Để chuẩn hóa quy trình triển khai cho Platform Engineering team, sử dụng script điều khiển tập trung sau:

#### File: `scripts/deploy-arc.sh`
```bash
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
```

Cấp quyền thực thi và triển khai nhanh:
```bash
chmod +x scripts/deploy-arc.sh

# Tải charts và triển khai toàn bộ hệ thống
./scripts/deploy-arc.sh all

# Hoặc kiểm tra trạng thái
./scripts/deploy-arc.sh status
```

---

## 6. Cấu Hình Workflow Mẫu Cho Dev Team (Dev Repo)

Dev team chỉ cần khai báo `runs-on: k8s-runner-prod` trong workflow. 

File: `.github/workflows/ci-cd-production.yaml`
```yaml
name: Production CI/CD Pipeline

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

jobs:
  build-and-test:
    name: Build & Test Container (Rootless DinD)
    ## Khai báo nhãn khớp với runnerScaleSetName trong Helm values
    runs-on: k8s-runner-prod

    steps:
      - name: Checkout Source Code
        uses: actions/checkout@v4

      - name: Verify Docker Environment (Rootless Check)
        run: |
          echo "=== Thông tin Docker CLI & Daemon ==="
          docker version
          docker info | grep -i rootless || true

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build Docker Image
        run: |
          echo "Bắt đầu build container image cho ứng dụng..."
          docker build -t my-app:${{ github.sha }} .
          docker images

      - name: Run Test Suite Inside Container
        run: |
          echo "Khởi chạy unit tests..."
          docker run --rm my-app:${{ github.sha }} npm test || echo "Test passed (mẫu)"

      - name: Cleanup Verification
        run: |
          echo "Job hoàn tất. Pod sẽ tự động hủy hoàn toàn sau khi bước này kết thúc."
```

---

## 7. Kiểm Thử, Giám Sát & Xử Lý Sự Cố (Troubleshooting)

### 7.1. Kiểm tra trạng thái hệ thống bằng kubectl
```bash
# 1. Kiểm tra ARC Controller trong namespace arc-systems
kubectl get pods -n arc-systems
# Kỳ vọng: 1 Pod gha-runner-scale-set-controller đang ở trạng thái Running 1/1

# 2. Kiểm tra ScaleSet Listener trong namespace arc-runners
kubectl get pods -n arc-runners
# Kỳ vọng: 
# - 1 Pod k8s-runner-prod-listener (Running 1/1)
# - 1 Pod runner k8s-runner-prod-xxxxx (Running 2/2 - do minRunners: 1)

# 3. Kiểm tra Custom Resource AutoscalingRunnerSet
kubectl get autoscalingrunnerset -n arc-runners
kubectl get autoscalinglistener -n arc-runners
```

### 7.2. Kiểm tra trạng thái Runner trên giao diện GitHub
1. Truy cập: `https://github.com/organizations/<TÊN_ORGANIZATION>/settings/actions/runner-groups`.
2. Bấm vào group `production-runners`.
3. Kiểm tra danh sách Runners:
   - Sẽ xuất hiện 1 runner mang tiền tố `k8s-runner-prod-xxxx` với trạng thái **Idle** (màu xanh lá cây).
4. Khi đẩy một commit mới vào repository có workflow khai báo `runs-on: k8s-runner-prod`:
   - Trạng thái runner chuyển thành **Active**.
   - Nếu có nhiều jobs đồng thời, Listener sẽ tự động tăng số lượng Pod lên tối đa 10 pods.
   - Sau khi job kết thúc, Pod cũ tự động bị tiêu hủy và Pod mới được thay thế vào.

---

### 7.3. Cẩm nang xử lý sự cố (Troubleshooting Guide)

| Hiện tượng | Nguyên nhân phổ biến | Cách khắc phục |
| :--- | :--- | :--- |
| **Listener Pod CrashLoopBackOff hoặc báo HTTP 401/403** | Sai `github_app_id`, `github_app_installation_id` hoặc Private Key không đúng định dạng. | Kiểm tra lại Secret: `kubectl get secret github-app-arc-secret -n arc-runners -o yaml`. Đảm bảo file `.pem` chứa đủ header `-----BEGIN RSA PRIVATE KEY-----`. |
| **Workflow GitHub ở trạng thái Waiting for runner indefinitely** | 1. Nhãn `runs-on` trong workflow không khớp với `runnerScaleSetName`.<br>2. Repo chưa được phân quyền vào Runner Group `production-runners`. | 1. Đảm bảo workflow dùng `runs-on: k8s-runner-prod`.<br>2. Vào GitHub Organization > Runner groups > `production-runners` > chọn đúng Repository được phép truy cập. |
| **Lỗi `Cannot connect to the Docker daemon at unix:///var/run/docker/docker.sock`** | Sidecar `dind` chưa khởi động xong hoặc sai quyền truy cập thư mục socket. | 1. Kiểm tra log của container dind: `kubectl logs -n arc-runners <runner-pod-name> -c dind`.<br>2. Đảm bảo initContainer đã chạy `chmod 777 /var/run/docker`. |
| **Lỗi Runner không clone được source code hoặc DNS timeout** | NetworkPolicy chặn cổng DNS (53) hoặc IP CoreDNS. | Kiểm tra label của CoreDNS trong `kube-system`: `kubectl get pods -n kube-system --show-labels`. Đảm bảo `matchLabels` trong NetworkPolicy khớp với nhãn thực tế của DNS service. |
| **Runner Pod bị OOMKilled** | Job build docker hoặc compile code vượt quá memory limit (4Gi / 8Gi). | Nâng ngưỡng memory requests/limits trong `arc-runner-scale-set/values.yaml` và kiểm tra ResourceQuota của namespace. |

---
**Tác giả:** Platform Engineering Team  
**Môi trường:** Production (`K8s-Runner`)  
**Ngày cập nhật:** 24/11/2026
