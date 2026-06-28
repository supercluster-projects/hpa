#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-seed.sh — Build offline seed appliance for air-gapped deployment
#
# Downloads all artifacts required for the HPA platform into a structured
# seed directory. Run this on an internet-connected machine, then transfer
# the seed directory to the air-gapped bootstrap host.
#
# Directory structure:
#   <output-dir>/
#     1-operating-systems/       Talos metal-amd64 qcow2
#     2-tofu-registry/           OpenTofu provider binaries
#     3-helm-charts/             Helm chart .tgz archives
#     4-oci-registry-dump/       OCI container image tarballs (docker save)
#     seed-manifest.json         Checksum manifest
#
# Usage: ./build-seed.sh [--output-dir <path>] [--dry-run]
#                        [--skip-helm] [--skip-oci] [--skip-tofu] [--skip-os]
#
# Required environment variables (from .env):
#   TALOS_VERSION, CILIUM_VERSION, ROOK_VERSION, CEPH_VERSION, HARBOR_VERSION,
#   ... all *_VERSION variables
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
OUTPUT_DIR="/media/seed-appliance"
DRY_RUN=false
SKIP_OS=false
SKIP_HELM=false
SKIP_TOFU=false
SKIP_OCI=false
CREATED_FILES=0
MANIFEST_DATA="[]"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)  OUTPUT_DIR="$2";   shift 2 ;;
    --dry-run)     DRY_RUN=true;       shift ;;
    --skip-os)     SKIP_OS=true;       shift ;;
    --skip-helm)   SKIP_HELM=true;     shift ;;
    --skip-tofu)   SKIP_TOFU=true;     shift ;;
    --skip-oci)    SKIP_OCI=true;      shift ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Build offline seed appliance for air-gapped HPA deployment.

Downloads all dependencies into a structured seed directory at OUTPUT_DIR.
Structure:
  OUTPUT_DIR/
    1-operating-systems/   Talos qcow2 image
    2-tofu-registry/       OpenTofu provider plugins
    3-helm-charts/         Helm chart archives (.tgz)
    4-oci-registry-dump/   Container image tarballs
    seed-manifest.json     Artifact manifest with checksums

Options:
  --output-dir DIR     Output directory (default: /media/seed-appliance)
  --dry-run            Print manifest without downloading
  --skip-os            Skip OS image download
  --skip-helm          Skip Helm chart download
  --skip-tofu          Skip OpenTofu provider mirror
  --skip-oci           Skip OCI image download
  --help, -h           Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# ---- Preflight ------------------------------------------------------------
log "build-seed: starting"
log "  output-dir:   ${OUTPUT_DIR}"
log "  dry-run:      ${DRY_RUN}"
log "  skip:         OS=${SKIP_OS} Helm=${SKIP_HELM} Tofu=${SKIP_TOFU} OCI=${SKIP_OCI}"

if [ "${DRY_RUN}" = false ]; then
  command -v helm >/dev/null 2>&1   || die "helm not found — needed for chart downloads"
  command -v docker >/dev/null 2>&1 || die "docker not found — needed for OCI image dumps"
  command -v tofu >/dev/null 2>&1   || die "tofu not found — needed for provider mirror"
  command -v curl >/dev/null 2>&1   || die "curl not found"
  command -v python3 >/dev/null 2>&1 || die "python3 not found — needed for checksums"
fi

# Track created files
declare -A ARTIFACTS

add_artifact() {
  local phase="$1"
  local path="$2"
  local size="$3"
  ARTIFACTS["${phase}/${path}"]="${size:-0}"
}

ensure_dir() {
  local d="$1"
  if [ "${DRY_RUN}" = false ]; then
    mkdir -p "${d}"
  fi
}

# ============================================================================
# Phase 1: Talos OS qcow2 image
# ============================================================================
if [ "${SKIP_OS}" = false ]; then
  log "Phase 1: Talos OS qcow2 image"
  require_env TALOS_VERSION 2>/dev/null || true

  TALOS_IMAGE_URL="https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.qcow2"
  TALOS_IMAGE_PATH="${OUTPUT_DIR}/1-operating-systems/talos-metal-amd64.qcow2"

  ensure_dir "${OUTPUT_DIR}/1-operating-systems"

  if [ "${DRY_RUN}" = true ]; then
    log "  [DRY-RUN] Would download: ${TALOS_IMAGE_URL}"
    log "  [DRY-RUN] To: ${TALOS_IMAGE_PATH}"
  else
    if [ -f "${TALOS_IMAGE_PATH}" ]; then
      log "  talos image exists — verifying..."
      python3 -c "import hashlib; print(hashlib.sha256(open('${TALOS_IMAGE_PATH}','rb').read()).hexdigest())" > "${TALOS_IMAGE_PATH}.sha256" 2>/dev/null &
    else
      log "  Downloading Talos ${TALOS_VERSION} qcow2..."
      curl -#L -o "${TALOS_IMAGE_PATH}" "${TALOS_IMAGE_URL}" || {
        err "Failed to download Talos qcow2"
        return
      }
      python3 -c "import hashlib; print(hashlib.sha256(open('${TALOS_IMAGE_PATH}','rb').read()).hexdigest())" > "${TALOS_IMAGE_PATH}.sha256" 2>/dev/null || true
    fi
    local_size=$(stat -c%s "${TALOS_IMAGE_PATH}" 2>/dev/null || echo "0")
    add_artifact "1-os" "talos-metal-amd64.qcow2" "${local_size}"
    CREATED_FILES=$((CREATED_FILES + 1))
    log "  Downloaded: ${TALOS_IMAGE_PATH} (${local_size} bytes)"
  fi
fi

# ============================================================================
# Phase 2: OpenTofu provider mirror
# ============================================================================
if [ "${SKIP_TOFU}" = false ]; then
  log "Phase 2: OpenTofu provider mirror"
  require_env TALOS_VERSION 2>/dev/null || true

  TOFU_REGISTRY_DIR="${OUTPUT_DIR}/2-tofu-registry"

  ensure_dir "${TOFU_REGISTRY_DIR}"

  if [ "${DRY_RUN}" = true ]; then
    log "  [DRY-RUN] Would run: tofu providers mirror ${TOFU_REGISTRY_DIR}"
    log "  [DRY-RUN] Providers to mirror: registry.terraform.io/dmaceticar/libvirt, registry.opentofu.org/siderolabs/talos, registry.terraform.io/hashicorp/null"
  else
    log "  Mirroring OpenTofu providers to ${TOFU_REGISTRY_DIR}..."
    cd "$(dirname "${TOFU_REGISTRY_DIR}")"
    tofu init -from-module="${SCRIPT_DIR}/../opentofu" 2>/dev/null || true
    tofu providers mirror "${TOFU_REGISTRY_DIR}" 2>&1 || {
      log "  (non-fatal) tofu providers mirror had issues — may need manual cache"
    }
    add_artifact "2-tofu-registry" "mirror" ""
    CREATED_FILES=$((CREATED_FILES + 1))
    log "  Provider mirror: ${TOFU_REGISTRY_DIR}"
  fi
fi

# ============================================================================
# Phase 3: Helm chart archives
# ============================================================================
if [ "${SKIP_HELM}" = false ]; then
  log "Phase 3: Helm chart archives"

  HELM_DIR="${OUTPUT_DIR}/3-helm-charts"
  ensure_dir "${HELM_DIR}"

  # Define chart repos, names, and versions
  # Format: repo_name|repo_url|chart_name|chart_version|env_var
  declare -a HELM_CHARTS=(
    "cilium|https://helm.cilium.io/|cilium/cilium|${CILIUM_VERSION}|CILIUM_VERSION"
    "rook-release|https://charts.rook.io/release|rook-release/rook-ceph-operator|${ROOK_VERSION}|ROOK_VERSION"
    "harbor|https://helm.goharbor.io|harbor/harbor|${HARBOR_VERSION}|HARBOR_VERSION"
    "jetstack|https://charts.jetstack.io|jetstack/cert-manager|${CERT_MANAGER_VERSION}|CERT_MANAGER_VERSION"
    "infisical||infisical/infisical|${INFISICAL_VERSION}|INFISICAL_VERSION"
    "strimzi|https://strimzi.io/charts/|strimzi/strimzi-kafka-operator|${STRIMZI_VERSION}|STRIMZI_VERSION"
    "spegel||spegel/spegel|${SPEGEL_VERSION}|SPEGEL_VERSION"
    "kargo|https://kargo.akuity.io/charts|kargo/kargo|${KARGO_VERSION}|KARGO_VERSION"
    "argo|https://argoproj.github.io/argo-helm|argo/argo-cd|${ARGOCD_VERSION}|ARGOCD_VERSION"
    "bitnami|https://charts.bitnami.com/bitnami|bitnami/postgresql||"
    "envoy-gateway|https://gateway.envoyproxy.io/helm|envoy-gateway/envoy-gateway|${ENVOY_VERSION}|ENVOY_VERSION"
    "headlamp|https://headlamp-k8s.github.io/headlamp|headlamp/headlamp|${HEADLAMP_VERSION}|HEADLAMP_VERSION"
    "vm|https://victoriametrics.github.io/helm-charts|vm/victoria-metrics-single|${VICTORIAMETRICS_VERSION}|VICTORIAMETRICS_VERSION"
    "vm|https://victoriametrics.github.io/helm-charts|vm/victoria-metrics-agent|${VICTORIAMETRICS_VERSION}|VICTORIAMETRICS_VERSION"
    "hasura|https://hasura.github.io/helm-charts|hasura/graphql-engine|${HASURA_VERSION}|HASURA_VERSION"
    "grafana|https://grafana.github.io/helm-charts|grafana/grafana|${GRAFANA_VERSION}|GRAFANA_VERSION"
    "prometheus-community|https://prometheus-community.github.io/helm-charts|prometheus-community/alertmanager|${ALERTMANAGER_VERSION}|ALERTMANAGER_VERSION"
    "prometheus-community|https://prometheus-community.github.io/helm-charts|prometheus-community/kube-state-metrics|${KUBE_STATE_METRICS_VERSION}|KUBE_STATE_METRICS_VERSION"
    "yugabytedb|https://charts.yugabyte.com|yugabytedb/yugabyte|${YUGABYTEDB_VERSION}|YUGABYTEDB_VERSION"
  )

  for entry in "${HELM_CHARTS[@]}"; do
    IFS='|' read -r repo_name repo_url chart_name chart_version ver_var <<< "${entry}"

    # Skip if chart_version is empty (no pin needed)
    [ -z "${chart_version}" ] && continue

    if [ "${DRY_RUN}" = true ]; then
      log "  [DRY-RUN] Would pull: ${chart_name} ${chart_version}"
    else
      # Add repo if it has a URL
      if [ -n "${repo_url}" ]; then
        helm repo add "${repo_name}" "${repo_url}" --force-update > /dev/null 2>&1 || true
      fi

      # Pull chart archive
      CHART_FILE="${chart_name//\//-}-${chart_version}.tgz"
      CHART_PATH="${HELM_DIR}/${CHART_FILE}"

      if [ -f "${CHART_PATH}" ]; then
        log "  ${CHART_FILE} exists (skipping)"
      else
        log "  Pulling ${chart_name} ${chart_version}..."
        helm pull "${chart_name}" --version "${chart_version}" \
          --destination "${HELM_DIR}" 2>&1 || {
          err "Failed to pull ${chart_name} ${chart_version}"
          continue
        }
        # Move to proper filename if helm names it differently
        for f in "${HELM_DIR}"/*.tgz; do
          bn=$(basename "${f}")
          if [ "${bn}" != "${CHART_FILE}" ]; then
            mv "${f}" "${CHART_PATH}" 2>/dev/null || true
          fi
        done
        local_size=$(stat -c%s "${CHART_PATH}" 2>/dev/null || echo "0")
        add_artifact "3-helm" "${CHART_FILE}" "${local_size}"
        CREATED_FILES=$((CREATED_FILES + 1))
        log "  Downloaded: ${CHART_FILE} (${local_size} bytes)"
      fi
    fi
  done

  # helm repo update
  if [ "${DRY_RUN}" = false ]; then
    helm repo update > /dev/null 2>&1 || true
  fi
fi

# ============================================================================
# Phase 4: OCI container image tarballs
# ============================================================================
if [ "${SKIP_OCI}" = false ]; then
  log "Phase 4: OCI container image tarballs"

  OCI_DIR="${OUTPUT_DIR}/4-oci-registry-dump"
  ensure_dir "${OCI_DIR}"

  # All images used by the platform (from install scripts + Spin apps)
  declare -a OCI_IMAGES=(
    "casdoor/casdoor:${CASDOOR_VERSION}"
    "keydb/keydb:${KEYDB_VERSION}"
    "yugabytedb/yugabyte:${YUGABYTEDB_VERSION}"
    "hasura/graphql-engine:${HASURA_VERSION}"
    "victoriametrics/victoria-metrics:${VICTORIAMETRICS_VERSION}"
    "victoriametrics/vmagent:${VICTORIAMETRICS_VERSION}"
    "grafana/grafana:${GRAFANA_VERSION}"
    "prometheuscommunity/alertmanager:latest"
    "kube-state-metrics/kube-state-metrics:${KUBE_STATE_METRICS_VERSION}"
    "quay.io/prometheus/node-exporter:latest"
    "quay.io/prometheus-operator/prometheus-config-reloader:latest"
  )

  for img in "${OCI_IMAGES[@]}"; do
    # Create a safe filename from the image reference
    safe_name=$(echo "${img}" | tr '/:' '_')
    tarball="${OCI_DIR}/${safe_name}.tar"

    if [ "${DRY_RUN}" = true ]; then
      log "  [DRY-RUN] Would pull and save: ${img}"
    else
      if [ -f "${tarball}" ]; then
        log "  ${safe_name}.tar exists (skipping)"
      else
        log "  Pulling ${img}..."
        docker pull "${img}" 2>&1 || {
          err "Failed to pull ${img} — skipping"
          continue
        }
        log "  Saving to ${tarball}..."
        docker save "${img}" -o "${tarball}" 2>&1 || {
          err "Failed to save ${img}"
          continue
        }
        local_size=$(stat -c%s "${tarball}" 2>/dev/null || echo "0")
        add_artifact "4-oci" "${safe_name}.tar" "${local_size}"
        CREATED_FILES=$((CREATED_FILES + 1))
        log "  Saved: ${tarball} (${local_size} bytes)"
      fi
    fi
  done

  # Workload images (built locally, not pulled from registry)
  declare -a BUILD_IMAGES=(
    "casbin-ext-authz:${CASBIN_VERSION}"
  )
  # Note: welcome, counter, stream-processor images are built from source
  # and pushed directly to Harbor — they must be built separately.
fi

# ============================================================================
# Generate manifest
# ============================================================================
if [ "${DRY_RUN}" = false ]; then
  log "Generating seed manifest..."

  MANIFEST="${OUTPUT_DIR}/seed-manifest.json"

  python3 <<PYEOF > "${MANIFEST}" 2>/dev/null || true
import json, hashlib, os, sys

output_dir = "${OUTPUT_DIR}"
manifest = {
    "generated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "tool": "build-seed.sh",
    "artifacts": []
}

for root, dirs, files in os.walk(output_dir):
    for f in files:
        if f == "seed-manifest.json":
            continue
        fpath = os.path.join(root, f)
        try:
            h = hashlib.sha256(open(fpath, 'rb').read()).hexdigest()
            size = os.path.getsize(fpath)
            rel = os.path.relpath(fpath, output_dir)
            manifest["artifacts"].append({
                "path": rel,
                "size": size,
                "sha256": h
            })
        except Exception:
            pass

# Sort by path
manifest["artifacts"].sort(key=lambda x: x["path"])
print(json.dumps(manifest, indent=2))
PYEOF

  log "  Manifest: ${MANIFEST}"
fi

# ---- Summary --------------------------------------------------------------
echo ""
echo "=== Seed Build Summary ==="
if [ "${DRY_RUN}" = true ]; then
  echo "  Mode:           DRY RUN (no files created)"
fi
echo "  Output:         ${OUTPUT_DIR}"
echo "  Artifacts:      ${CREATED_FILES} files"
echo ""
echo "  Directory structure:"
echo "    ${OUTPUT_DIR}/1-operating-systems/"
echo "      - talos-metal-amd64.qcow2 (${TALOS_VERSION})"
echo "    ${OUTPUT_DIR}/2-tofu-registry/"
echo "      - OpenTofu provider mirror"
echo "    ${OUTPUT_DIR}/3-helm-charts/"
echo "      - Helm chart .tgz archives"
echo "    ${OUTPUT_DIR}/4-oci-registry-dump/"
echo "      - OCI container image tarballs"
echo "    ${OUTPUT_DIR}/seed-manifest.json"
echo ""
echo "  Next steps on offline host:"
echo "    hydrate-harbor.sh     Load OCI images into Harbor"
echo "    hydrate-tofu.sh       Configure OpenTofu offline mirror"
echo "    startup.sh            Run full pipeline"
echo "======================================="

log "build-seed: completed successfully"
exit 0
