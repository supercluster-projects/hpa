#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# verify-manifests.sh — Artifact-level Helm lint + Kustomize build validation
#
# Runs static validation on all Helm charts and Kustomize overlays used
# across M001 provisioning, WITHOUT requiring a live Kubernetes cluster.
# Charts are downloaded to a temp directory, linted, then cleaned up.
#
# Charts verified:
#   Cilium          (helm.cilium.io)
#   Rook Ceph       (charts.rook.io/release)
#   Harbor          (helm.goharbor.io)
#   Infisical       (dl.infisical.com/helm-charts, OCI fallback)
#   cert-manager    (charts.jetstack.io)
#   Envoy Gateway   (OCI: docker.io/envoyproxy/gateway-helm)
#   Headlamp        (kubernetes-sigs.github.io/headlamp)
#   Kargo           (kargo.akuity.io/charts, OCI fallback)
#   ArgoCD          (argoproj.github.io/argo-helm)
#
# Kustomize overlays verified:
#   gitops-workloads/functions/overlays/dev/
#
# Usage: ./verify-manifests.sh [--chart-dir <dir>] [--keep] [--help]
#
# Exit code: 0 if all checks pass, 1 if any fail
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Defaults -------------------------------------------------------------
KEEP_CHARTS=false
CHART_DIR=""

# ---- Internal defaults (script-internal only) -------------------------
CHART_DIR=""

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chart-dir)  CHART_DIR="$2";  shift 2 ;;
    --keep)       KEEP_CHARTS=true; shift ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

Run artifact-level Helm lint + Kustomize build --dry-run validation.

All checks run offline (after chart download) and do NOT require a
live Kubernetes cluster. Use this to validate manifests before
deployment or as part of a CI pipeline.

Options:
  --chart-dir DIR   Download charts to this directory (default: temp)
  --keep            Keep downloaded charts after verification
  --help            Show this help message

Exit code: 0 if all checks pass, 1 if any fail
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# ---- Preflight ------------------------------------------------------------
log "verify-manifests: starting"
command -v helm >/dev/null 2>&1 || die "helm not found in PATH"
command -v kustomize >/dev/null 2>&1 || command -v kubectl >/dev/null 2>&1 || die "neither 'kustomize' nor 'kubectl kustomize' available"

if [ -z "${CHART_DIR}" ]; then
  CHART_DIR="$(mktemp -d /tmp/helm-lint-XXXXXX)"
  if [ "${KEEP_CHARTS}" = false ]; then
    trap 'rm -rf "${CHART_DIR}"' EXIT
  fi
else
  mkdir -p "${CHART_DIR}"
fi

# ---- Track results --------------------------------------------------------
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
SKIPPED_CHECKS=0
FAILURE_DETAILS=""

# ---- Result accumulator ---------------------------------------------------
record_result() {
  local check_name="$1"
  local status="$2"    # PASS, FAIL, or SKIP
  local detail="$3"

  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  case "${status}" in
    PASS)
      PASSED_CHECKS=$((PASSED_CHECKS + 1))
      log "  [PASS] ${check_name}: ${detail}"
      ;;
    SKIP)
      SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
      log "  [SKIP] ${check_name}: ${detail}"
      ;;
    *)
      FAILED_CHECKS=$((FAILED_CHECKS + 1))
      FAILURE_DETAILS="${FAILURE_DETAILS}\n  [FAIL] ${check_name}: ${detail}"
      log "  [FAIL] ${check_name}: ${detail}"
      ;;
  esac
}

# ---- Helm Lint: Standard Repo ---------------------------------------------
helm_lint_repo() {
  local repo_url="$1"
  local chart_name="$2"
  local chart_version="$3"   # empty = latest
  local check_label="$4"

  local repo_name="lint-$(echo "${repo_url}" | md5sum | cut -c1-8)"

  # Add repo (remove existing if URL conflicts)
  local existing_repo
  existing_repo=$(helm repo list -o yaml 2>/dev/null | grep "url: ${repo_url}" | head -1 || true)
  if [ -n "${existing_repo}" ]; then
    local old_name
    old_name=$(helm repo list -o yaml 2>/dev/null | grep -B1 "url: ${repo_url}" | head -1 | sed 's/- name: //' | tr -d ' "')
    if [ -n "${old_name}" ]; then
      helm repo remove "${old_name}" > /dev/null 2>&1 || true
    fi
  fi

  helm repo add "${repo_name}" "${repo_url}" --force-update > /dev/null 2>&1 || {
    record_result "${check_label}" "SKIP" "Repo unreachable: ${repo_url}"
    return
  }
  helm repo update "${repo_name}" > /dev/null 2>&1 || true

  # Build version flags
  local version_flag=()
  if [ -n "${chart_version}" ]; then
    version_flag=(--version "${chart_version}")
  fi

  # Pull chart
  helm pull "${repo_name}/${chart_name}" "${version_flag[@]}" -d "${CHART_DIR}" > /dev/null 2>&1 || {
    record_result "${check_label}" "SKIP" "Chart pull failed (may have moved or requires auth): ${repo_name}/${chart_name} ${chart_version}"
    helm repo remove "${repo_name}" > /dev/null 2>&1 || true
    return
  }

  helm repo remove "${repo_name}" > /dev/null 2>&1 || true

  # Find and lint the downloaded chart
  local downloaded
  downloaded=$(ls -t "${CHART_DIR}"/*.tgz 2>/dev/null | head -1 || echo "")
  if [ -z "${downloaded}" ]; then
    record_result "${check_label}" "FAIL" "No chart archive downloaded"
    return
  fi

  local lint_output
  lint_output=$(helm lint "${downloaded}" 2>&1) || {
    record_result "${check_label}" "FAIL" "Helm lint failed: $(echo "${lint_output}" | tail -5 | tr '\n' ';')"
    rm -f "${downloaded}"
    return
  }

  local lint_result
  lint_result=$(echo "${lint_output}" | grep -E "^.*:.*chart" | head -1 || echo "1 chart(s) linted, 0 chart(s) failed")
  record_result "${check_label}" "PASS" "${lint_result}"
  rm -f "${downloaded}"
}

# ---- Helm Lint: OCI Chart --------------------------------------------------
helm_lint_oci() {
  local oci_ref="$1"
  local chart_version="$2"
  local check_label="$3"

  local archive_path="${CHART_DIR}/${check_label// /_}.tgz"

  # Pull chart from OCI registry
  helm pull "oci://${oci_ref}" --version "${chart_version}" -d "${CHART_DIR}" > /dev/null 2>&1 || {
    record_result "${check_label}" "SKIP" "OCI pull failed: oci://${oci_ref}:${chart_version}"
    return
  }

  local downloaded
  downloaded=$(ls -t "${CHART_DIR}"/*.tgz 2>/dev/null | head -1 || echo "")
  if [ -z "${downloaded}" ]; then
    record_result "${check_label}" "FAIL" "No chart downloaded from OCI"
    return
  fi

  local lint_output
  lint_output=$(helm lint "${downloaded}" 2>&1) || {
    record_result "${check_label}" "FAIL" "Helm lint failed: $(echo "${lint_output}" | tail -5 | tr '\n' ';')"
    rm -f "${downloaded}"
    return
  }

  local lint_result
  lint_result=$(echo "${lint_output}" | grep -E "^.*:.*chart" | head -1 || echo "1 chart(s) linted, 0 chart(s) failed")
  record_result "${check_label}" "PASS" "${lint_result}"
  rm -f "${downloaded}"
}

# ---- Kustomize Build Helper ------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"
kustomize_build_check() {
  local overlay_path="$1"
  local check_label="$2"
  local relative_path="$3"

  if [ ! -f "${overlay_path}/kustomization.yaml" ]; then
    record_result "${check_label}" "FAIL" "kustomization.yaml not found at ${relative_path}"
    return
  fi

  local build_output
  build_output=$(kustomize build "${overlay_path}" 2>&1) || {
    build_output=$(kubectl kustomize "${overlay_path}" 2>&1) || {
      record_result "${check_label}" "FAIL" "kustomize build failed: $(echo "${build_output}" | tail -3 | tr '\n' ';')"
      return
    }
  }

  local resource_count
  resource_count=$(echo "${build_output}" | grep -c "^---" || true)
  resource_count=$((resource_count + 1))

  if echo "${build_output}" | grep -qi "error\|invalid\|not found"; then
    record_result "${check_label}" "WARN" "Build succeeded (~${resource_count} resources) but output contains error-like lines"
  else
    record_result "${check_label}" "PASS" "Build succeeded (~${resource_count} resources)"
  fi
}

# ============================================================================
# Helm Lint Checks
# ============================================================================
log "--- Helm Lint Checks (Standard Repos) ---"
helm_lint_repo "https://helm.cilium.io/" "cilium" "1.16.5" "Cilium v1.16.5"
helm_lint_repo "https://charts.rook.io/release" "rook-ceph" "v1.16.4" "Rook Ceph v1.16.4"
helm_lint_repo "https://helm.goharbor.io" "harbor" "1.17.0" "Harbor v2.12.x"
helm_lint_repo "https://charts.jetstack.io" "cert-manager" "v1.17.1" "cert-manager v1.17.1"
helm_lint_repo "https://kubernetes-sigs.github.io/headlamp/" "headlamp" "0.16.0" "Headlamp v0.16.0"
helm_lint_repo "https://argoproj.github.io/argo-helm" "argo-cd" "7.8.0" "ArgoCD v7.8.0"
helm_lint_repo "https://dl.infisical.com/helm-charts" "infisical" "" "Infisical (latest)"
helm_lint_repo "https://kargo.akuity.io/charts" "kargo" "1.3.0" "Kargo v1.3.0"
helm_lint_repo "https://charts.bitnami.com/bitnami" "postgresql" "" "Bitnami PostgreSQL (latest)"

log "--- Helm Lint Checks (OCI Charts) ---"
helm_lint_oci "docker.io/envoyproxy/gateway-helm" "v1.2.2" "Envoy Gateway v1.2.2 (OCI)"
helm_lint_oci "registry-1.docker.io/casbin/casdoor-helm-charts" "3.100.0" "Casdoor v3.100.0 (OCI)"

# ============================================================================
# Kustomize Build Checks
# ============================================================================
log "--- Kustomize Build Checks ---"
kustomize_build_check "${PROJECT_ROOT}/gitops-workloads/functions/overlays/dev" \
  "Kustomize: gitops-workloads/functions/overlays/dev" \
  "gitops-workloads/functions/overlays/dev"

# ============================================================================
# Shell syntax check (bash -n) for all scripts
# ============================================================================
log "--- ShellCheck (bash -n) for Scripts ---"
for script in "${SCRIPT_DIR}"/install-*.sh "${SCRIPT_DIR}"/verify-*.sh "${SCRIPT_DIR}"/setup-bridge.sh "${SCRIPT_DIR}"/cleanup.sh; do
  [ -f "${script}" ] || continue
  script_name=$(basename "${script}")
  if bash -n "${script}" 2>/dev/null; then
    record_result "bash -n: ${script_name}" "PASS" "Syntax OK"
  else
    record_result "bash -n: ${script_name}" "FAIL" "Syntax error"
  fi
done

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== Manifest Verification Summary ==="
echo "  Total checks:  ${TOTAL_CHECKS}"
echo "  Passed:        ${PASSED_CHECKS}"
echo "  Skipped:       ${SKIPPED_CHECKS}"
echo "  Failed:        ${FAILED_CHECKS}"
echo ""
if [ "${FAILED_CHECKS}" -gt 0 ]; then
  echo "  Failures:"
  echo -e "${FAILURE_DETAILS}"
  echo ""
fi
echo "========================================"

if [ "${FAILED_CHECKS}" -gt 0 ]; then
  die "${FAILED_CHECKS} check(s) failed"
fi

log "verify-manifests: ALL CHECKS PASSED"
exit 0
