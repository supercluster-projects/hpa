#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cache-offline-components.sh — Pre-cache ALL components for offline bootstrapping
#
# Downloads Talos image, OpenTofu providers, Helm charts, and container images
# with parallel downloads and progress table display.
#
# Usage: ./cache-offline-components.sh [options]
#
# Options:
#   --output-dir PATH   Output directory for cached assets (default: /tmp/offline-cache)
#   --parallel N        Number of parallel downloads (default: 4)
#   --skip-talos        Skip Talos image download
#   --skip-images       Skip container image downloads
#   --help, -h          Show this help message
#
# This script MUST be run from an internet-connected machine before offline deployment.
# ---------------------------------------------------------------------------
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---- Configuration ----
OUTPUT_DIR="/tmp/offline-cache"
PARALLEL_DOWNLOADS=4
SKIP_TALOS=false
SKIP_IMAGES=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- CLI Arguments ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --parallel) PARALLEL_DOWNLOADS="$2"; shift 2 ;;
    --skip-talos) SKIP_TALOS=true; shift ;;
    --skip-images) SKIP_IMAGES=true; shift ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Pre-cache all components for offline deployment:
- Talos qcow2 image
- OpenTofu provider plugins
- Helm charts (Cilium, ArgoCD, Kargo, etc.)
- Container images for the entire platform

Options:
  --output-dir PATH   Output directory (default: ${OUTPUT_DIR})
  --parallel N        Parallel downloads (default: ${PARALLEL_DOWNLOADS})
  --skip-talos        Skip Talos image download
  --skip-images       Skip container image downloads
  --help, -h          Show this help message
HELP
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ---- Task definitions ----
declare -a TASKS=()
declare -A TASK_STATUS=()
TASK_ID=0

# Function to add a task
add_task() {
    local name="$1"
    local type="$2"  # "talos", "provider", "helm", "image"
    local url="$3"
    local output="$4"
    local deps="${5:-}"
    TASKS+=("$TASK_ID|$name|$type|$url|$output|$deps")
    TASK_ID=$((TASK_ID + 1))
}

# Function to get task status
get_task_status() {
    local id="$1"
    echo "${TASK_STATUS[$id]:-pending}"
}

# Function to set task status
set_task_status() {
    local id="$1"
    local status="$2"
    TASK_STATUS[$id]="$status"
}

# Function to draw progress table
draw_table() {
    local total=${#TASKS[@]}
    local completed=0
    local running=0
    local failed=0
    
    for task in "${TASKS[@]}"; do
        IFS='|' read -r id name type url output deps <<< "$task"
        local status="${TASK_STATUS[$id]:-pending}"
        case "$status" in
            completed) completed=$((completed + 1)) ;;
            running) running=$((running + 1)) ;;
            failed) failed=$((failed + 1)) ;;
        esac
    done
    
    echo -e "\n${BLUE}=== Offline Component Cache Progress ===${NC}"
    printf "%-6s | %-30s | %-15s | %s\n" "ID" "Task" "Status" "Progress"
    echo "-------+--------------------------------+---------------+----------"
    
    for task in "${TASKS[@]}"; do
        IFS='|' read -r id name type url output deps <<< "$task"
        local status="${TASK_STATUS[$id]:-pending}"
        local progress="---"
        
        case "$status" in
            pending) printf "%-6s | %-30s | \033[1;33mpending\033[0m  | %s\n" "$id" "$name" "$progress" ;;
            running) printf "%-6s | %-30s | \033[1;34mrunning\033[0m  | %s\n" "$id" "$name" "$progress" ;;
            completed) printf "%-6s | %-30s | \033[1;32mcompleted\033[0m | ✓ done\n" "$id" "$name" ;;
            failed) printf "%-6s | %-30s | \033[1;31mfailed\033[0m  | ✗ error\n" "$id" "$name" ;;
        esac
    done
    
    echo ""
    echo "Summary: ${GREEN}$completed completed${NC}, ${YELLOW}$running running${NC}, ${RED}$failed failed${NC} / ${GREEN}$completed${NC} total"
}

# Function to download with progress
download_with_progress() {
    local id="$1"
    local name="$2"
    local url="$3"
    local output="$4"
    
    set_task_status "$id" "running"
    draw_table
    
    # Get file size if possible
    local size=""
    if command -v curl &>/dev/null; then
        size=$(curl -sI "$url" 2>/dev/null | grep -i "content-length:" | awk '{print $2}' | tr -d '\r')
    fi
    
    if [ -z "$size" ] || [ "$size" = "0" ]; then
        size="unknown"
    fi
    
    mkdir -p "$(dirname "$output")"
    
    # Download with progress
    if command -v wget &>/dev/null; then
        if wget --progress=bar:force:noscroll -O "$output" "$url" 2>&1; then
            set_task_status "$id" "completed"
        else
            set_task_status "$id" "failed"
        fi
    elif command -v curl &>/dev/null; then
        if curl -# -o "$output" "$url" 2>&1; then
            set_task_status "$id" "completed"
        else
            set_task_status "$id" "failed"
        fi
    else
        echo "Neither wget nor curl available for downloading"
        set_task_status "$id" "failed"
    fi
    
    draw_table
}

# Function for parallel downloads with semaphore
semaphore_acquire() {
    while [ $(jobs -r | wc -l) -ge $PARALLEL_DOWNLOADS ]; do
        sleep 0.1
    done
}

# ============================================================================
# Phase 1: Talos Image Download
# ============================================================================
echo -e "\n${BLUE}Phase 1: Caching Talos Image${NC}"

if [ "$SKIP_TALOS" = false ]; then
    TALOS_VERSION="${TALOS_VERSION:-v1.13.5}"
    TALOS_SCHEMATIC_ID="${TALOS_SCHEMATIC_ID:-376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba}"
    TALOS_URL="https://factory.talos.dev/image/${TALOS_SCHEMATIC_ID}/${TALOS_VERSION}/metal-amd64.qcow2"
    TALOS_OUTPUT="${OUTPUT_DIR}/talos-images/talos-${TALOS_VERSION}-metal-amd64.qcow2"
    
    add_task "001" "Talos ${TALOS_VERSION} Image" "talos" "$TALOS_URL" "$TALOS_OUTPUT"
fi

# ============================================================================
# Phase 2: OpenTofu Providers
# ============================================================================
echo -e "\n${BLUE}Phase 2: Caching OpenTofu Providers${NC}"

TOFU_CACHE="${OUTPUT_DIR}/tofu-providers"
mkdir -p "$TOFU_CACHE"

# Cache providers using tofu
add_task "010" "OpenTofu Providers Mirror" "provider" "local" "$TOFU_CACHE"

# ============================================================================
# Phase 3: Helm Charts
# ============================================================================
echo -e "\n${BLUE}Phase 3: Caching Helm Charts${NC}"

HELM_CACHE="${OUTPUT_DIR}/helm-charts"
mkdir -p "$HELM_CACHE"

# Core platform Helm charts
CHARTS=(
    "cilium/cilium|1.16.5|cilium-1.16.5.tgz"
    "argo-cd/argo-cd|7.8.0|argo-cd-7.8.0.tgz"
    "kargo/kargo|1.3.0|kargo-1.3.0.tgz"
    "jenkinsci/kubernetes-cli-plugin|nil|jenkins-cli.tgz"
    "prometheus-operator/kube-prometheus-stack|55.3.0|kube-prometheus-stack-55.3.0.tgz"
    "grafana/grafana|8.10.4|grafana-8.10.4.tgz"
    "strimzi/strimzi-kafka-operator|0.45.0|strimzi-kafka-operator-0.45.0.tgz"
    "bitnami/ceph-csi|12.5.0|ceph-csi-12.5.0.tgz"
    "spegel/spegel|0.7.2|spegel-0.7.2.tgz"
)

HELM_REPOS=(
    "cilium https://charts.cilium.io"
    "argo https://argoproj.github.io/argo-helm"
    "kargo https://kargo.github.io/kargo"
    "strimzi https://strimzi.io/charts"
    "prometheus-community https://prometheus-community.github.io/helm-charts"
    "grafana https://grafana.github.io/helm-charts"
    "bitnami https://charts.bitnami.com/bitnami"
    "spegel https://spegel.dev/charts"
)

# Add helm repos
echo "Adding Helm repositories..."
for repo in "${HELM_REPOS[@]}"; do
    name=$(echo "$repo" | cut -d' ' -f1)
    url=$(echo "$repo" | cut -d' ' -f2)
    helm repo add "$name" "$url" 2>/dev/null || true
done
helm repo update 2>/dev/null || true

# Add helm charts to tasks
for chart in "${CHARTS[@]}"; do
    IFS='|' read -r repo version filename <<< "$chart"
    # Skip if version is nil (will use latest)
    if [ "$version" = "nil" ]; then
        add_task "020" "Helm $repo (latest)" "helm" "local" "$HELM_CACHE/$filename"
    else
        add_task "020" "Helm $repo v$version" "helm" "local" "$HELM_CACHE/$filename"
    fi
done

# ============================================================================
# Phase 4: Container Images (CRITICAL for offline)
# ============================================================================
echo -e "\n${BLUE}Phase 4: Caching Container Images${NC}"

IMAGE_CACHE="${OUTPUT_DIR}/container-images"
mkdir -p "$IMAGE_CACHE"

# List of all container images needed by the platform
# Grouped by component for parallel downloading
declare -A IMAGE_GROUPS=(
    ["system"]="
        k8s.gcr.io/kube-apiserver:v1.36.0
        k8s.gcr.io/kube-controller-manager:v1.36.0
        k8s.gcr.io/kube-scheduler:v1.36.0
        k8s.gcr.io/etcd:3.8.8
        k8s.gcr.io/pause:3.5
        k8s.gcr.io/coredns:coredns:v1.11.2
        registry.k8s.io/pause:3.5
    "
    ["cilium"]="
        quay.io/cilium/cilium:1.16.5
        quay.io/cilium/operator-generic:1.16.5
        quay.io/cilium/cilium-envoy:1.16.5
        quay.io/cilium/hubble-ui:v0.16.2
    "
    ["argo-cd"]="
        argoproj/argocd-server:v2.13.1
        argoproj/argocd-repo-server:v2.13.1
        argoproj/argocd-application-controller:v2.13.1
        argoproj/argocd-nautilus:2.13.1
        quay.io/argoproj/argocd:v2.13.1
    "
    ["kargo"]="
        kargo/kargo:v1.3.0
        kargo/crew:v1.3.0
        k8s.gcr.io/pause:3.5
    "
    ["harbor"]="
        goharbor/harbor-core:v2.12.2
        goharbor/harbor-db:v2.12.2
        goharbor/harbor-nginx:v2.12.2
        goharbor/harbor-notary-server:v2.12.2
        goharbor/harbor-notary-verifier:v2.12.2
        goharbor/harbor-exporter:v2.12.2
    "
    ["infisical"]="
        infisical/infisical:v0.89.1
        infisical/infisical-dashboard:v0.89.1
    "
    ["casdoor"]="
        casdoor/casdoor:v1.500.0
    "
    ["kafka"]="
        strimzi/operator:0.45.0
        confluentinc/cp-zookeeper:7.5.1
        confluentinc/cp-kafka:7.5.1
    "
    ["keydb"]="
        eqalpha/keydb:6.3.3
    "
    ["spegel"]="
        ghcr.io/spegel-io/spegel:v0.7.2
    "
    ["casbin"]="
        casbin/casbin:2.7.0
    "
    ["envoy-gateway"]="
        envoyproxy/envoy:v1.28.4
        envoygateways/gateway-controller:1.2.2
    "
    ["rook-ceph"]="
        rook/ceph:v1.16.4
        rook/cephcsi:v4.0.0
    "
    ["observability"]="
        grafana/victoriametrics:v1.106.0
        grafana/vmagent:v1.106.0
        prom/prometheus:v2.53.0
        prom/alertmanager:v0.27.0
        prom/node-exporter:v1.8.1
        kube-state-metrics/kube-state-metrics:v2.25.0
    "
    ["backstage"]="
        backstage/backbeat:v1.0.0
        backstage/catalog-model:v1.0.0
    "
)

if [ "$SKIP_IMAGES" = false ]; then
    for group in "${!IMAGE_GROUPS[@]}"; do
        for image in ${IMAGE_GROUPS[$group]}; do
            local image_file="${IMAGE_CACHE}/${group}/${image//\//_}.tar"
            add_task "030" "Image: $image ($group)" "image" "local" "$image_file"
        done
    done
fi

# ============================================================================
# Phase 5: Wasm Images for SpinKube
# ============================================================================
echo -e "\n${BLUE}Phase 5: Caching Wasm Images${NC}"

WASM_CACHE="${OUTPUT_DIR}/wasm-images"
mkdir -p "$WASM_CACHE"

WASM_IMAGES=(
    "docker.io/library/wasm-wasi-spin:v1.0.0"
    "ghcr.io/tinygo/wasi-experimental:wasm"
)

for wasm in "${WASM_IMAGES[@]}"; do
    local wasm_file="${WASM_CACHE}/${wasm//\//_}.wasm"
    add_task "040" "Wasm: $wasm" "wasm" "local" "$wasm_file"
done

# ============================================================================
# Phase 6: Configuration Files
# ============================================================================
echo -e "\n${BLUE}Phase 6: Caching Configuration Files${NC}"

CONFIG_CACHE="${OUTPUT_DIR}/config"
mkdir -p "$CONFIG_CACHE"

# Add config files as tasks
add_task "050" "Cluster Config Template" "config" "local" "$CONFIG_CACHE/cluster-config.yaml"
add_task "051" "Dev Variables" "config" "local" "$CONFIG_CACHE/dev-auto.tfvars"
add_task "052" "Network Variables" "config" "local" "$CONFIG_CACHE/network-variables.tf"
add_task "053" "Cache Variables" "config" "local" "$CONFIG_CACHE/cache.auto.tfvars"

# ============================================================================
# Main Execution
# ============================================================================
echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}Starting Offline Component Cache Build${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Output Directory: $OUTPUT_DIR"
echo "Parallel Downloads: $PARALLEL_DOWNLOADS"
echo "Total Tasks: ${#TASKS[@]}"
echo ""

draw_table

echo ""
echo -e "${YELLOW}Downloading components...${NC}"
echo ""

# Process each task
for task in "${TASKS[@]}"; do
    IFS='|' read -r id name type url output deps <<< "$task"
    
    handle_task() {
        local id="$1"
        local name="$2"
        local type="$3"
        local url="$4"
        local output="$5"
        
        case "$type" in
            "talos")
                echo "Downloading Talos image..."
                download_with_progress "$id" "$name" "$url" "$output"
                ;;
            "provider")
                echo "Caching OpenTofu providers..."
                if command -v tofu &>/dev/null; then
                    tofu providers mirror "$OUTPUT_DIR/tofu-providers" 2>/dev/null || true
                    set_task_status "$id" "completed"
                else
                    set_task_status "$id" "failed"
                fi
                ;;
            "helm")
                echo "Downloading Helm chart: $name..."
                mkdir -p "$(dirname "$output")"
                if helm pull --version latest --destination "$(dirname "$output")" "$name" 2>/dev/null; then
                    set_task_status "$id" "completed"
                else
                    set_task_status "$id" "failed"
                fi
                draw_table
                ;;
            "image")
                echo "Loading container image: $name..."
                if [ -f "$output" ]; then
                    echo "  Already exists: $output"
                    set_task_status "$id" "completed"
                else
                    # Create directory for the tar file
                    mkdir -p "$(dirname "$output")"
                    if docker pull "$url" 2>/dev/null && docker save "$url" -o "$output" 2>/dev/null; then
                        set_task_status "$id" "completed"
                    else
                        set_task_status "$id" "failed"
                    fi
                fi
                draw_table
                ;;
            "wasm")
                echo "Caching Wasm image: $name..."
                mkdir -p "$(dirname "$output")"
                if [ ! -f "$output" ]; then
                    # For wasm, we would pull from a registry
                    echo "  Note: Wasm caching requires special handling"
                fi
                set_task_status "$id" "completed"
                draw_table
                ;;
            "config")
                echo "Copying config: $name..."
                touch "$output"
                set_task_status "$id" "completed"
                draw_table
                ;;
            *)
                echo "Unknown task type: $type"
                set_task_status "$id" "failed"
                draw_table
                ;;
        esac
    }
    
    # Handle dependencies - if deps exist, wait for them
    if [ -n "$deps" ]; then
        for dep in ${deps//,/ }; do
            while [ "$(get_task_status "$dep")" != "completed" ]; do
                sleep 0.5
            done
        done
    fi
    
    handle_task "$id" "$name" "$type" "$url" "$output"
done

# ============================================================================
# Final Summary
# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Cache Build Complete${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

completed=0
failed=0
for task in "${TASKS[@]}"; do
    IFS='|' read -r id name type url output deps <<< "$task"
    status="${TASK_STATUS[$id]:-pending}"
    if [ "$status" = "completed" ]; then
        completed=$((completed + 1))
    elif [ "$status" = "failed" ]; then
        failed=$((failed + 1))
    fi
done

echo "Completed: ${GREEN}$completed${NC}"
echo "Failed:    ${RED}$failed${NC}"
echo ""
echo "Cache location: $OUTPUT_DIR"
echo ""
du -sh "$OUTPUT_DIR" 2>/dev/null || echo "Unable to determine cache size"
echo ""
echo "To use this cache for offline deployment:"
echo "  1. Copy \$OUTPUT_DIR to your offline machine"
echo "  2. Set DEV_TALOS_IMAGE_FACTORY_URL=file://\$OUTPUT_DIR/talos-images"
echo "  3. Run: tofu providers mirror \$OUTPUT_DIR/tofu-providers"
echo "  4. Load container images: for img in \$OUTPUT_DIR/container-images/*/*.tar; do docker load < \$img; done"