#!/usr/bin/env bash
step_start() { STEP_START "${@}"; }
step_end() { STEP_END "${@}"; }

# ---------------------------------------------------------------------------
# startup.sh — Full dev environment bootstrap in one shot
#
# Orchestrates the complete pipeline from bare metal to a running HPA dev
# cluster. Handles everything: VM provisioning via OpenTofu, then all Helm
# charts and workload deployments. Every step is idempotent.
#
# Usage: ./startup.sh [options]
#
# Options:
#   --kubeconfig PATH   Path to kubeconfig (default: ../opentofu/kubeconfig)
#   --tofu-dir DIR      OpenTofu provisioning directory (default: ../opentofu)
#   --envoy-ip IP       Envoy LB IP for endpoint verification (auto-detected
#                       if omitted, must be within DEV_LB_POOL_CIDR)
#   --host-iface IFACE  Host interface to attach hpa-bridge to
#   --skip-tofu         Skip OpenTofu provisioning (use existing kubeconfig)
#   --preserve-ceph     Preserve Ceph disks across runs (default: true)
#   --reset-ceph        Clear Ceph disks before provisioning
#   --help, -h          Show this help message
#
# Environment:
#   .env file at project root sourced automatically if present
#   CLI flags override env vars which override script defaults
#
#   INFISICAL_ENCRYPTION_KEY   Must be set in .env (no default)
#   INFISICAL_ADMIN_PASSWORD   Must be set in .env (no default)
#   INFISICAL_AUTH_SECRET      Must be set in .env (no default)
#
# Exit code: 0 on success, non-zero on first failure
#
# All stdout/stderr is also captured to startup.log at project root.
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/misc/preamble.sh"

# ---- Result tracking for summary table ----
declare -a STEP_RESULTS=()

add_step_result() {
  local num=$1
  local name=$2
  local result=$3
  local detail="${4:-}"
  STEP_RESULTS+=("$(printf "  %-30s | %s| %s" "$name" "$result" "$detail")")
}

show_results_table() {
  echo "" >&3
  echo "========================================" >&3
  echo "        STEP RESULTS SUMMARY" >&3
  echo "========================================" >&3
  echo "" >&3
  echo "  Step | Name                              | Status  | Details" >&3
  echo "  -----|-----------------------------------|---------|-------" >&3
  for result in "${STEP_RESULTS[@]}"; do
    echo "$result" >&3
  done
  echo "" >&3
  echo "========================================" >&3
}

# ---- Interactive prompt function ----
trim_prompt_input() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

read_choice() {
  local timeout="${PROMPT_TIMEOUT_SECONDS:-10}"
  local prompt_text="$1"
  local choice=""

  if ! [[ "${timeout}" =~ ^[0-9]+$ ]]; then
    timeout=10
  fi

  if [ "${timeout}" -gt 0 ]; then
    if ! read -r -t "${timeout}" -p "${prompt_text}" choice; then
      echo "" >&3
      return 124
    fi
  else
    if ! read -r -p "${prompt_text}" choice; then
      choice=""
    fi
  fi

  choice="$(trim_prompt_input "${choice}")"
  printf '%s' "$choice"
}

prompt_step() {
  local step_num=$1
  local step_name=$2
  local result=$3
  local timeout="${PROMPT_TIMEOUT_SECONDS:-10}"
  local max_invalid="${PROMPT_MAX_INVALID_ATTEMPTS:-3}"
  local attempt=0
  local choice=""
  local prompt_text=""
  local choice_file=""
  local status_file=""
  local read_status=0

  if ! [[ "${timeout}" =~ ^[0-9]+$ ]]; then
    timeout=10
  fi

  echo "" >&3
  echo "========================================" >&3
  echo "Step ${step_num}: ${step_name}" >&3
  echo "  Status: ${result}" >&3
  echo "========================================" >&3

  if [ "$result" = "SUCCESS" ]; then
    echo "" >&3
    echo ">>> Verification Results:" >&3
    # Show step-specific verification info
    case "${step_num}" in
      1|2)
        echo "     Network: hpa-bridge (name: ${DEV_BRIDGE_NAME:-hpa-bridge})" >&3
        virsh -c qemu:///system net-info "${DEV_BRIDGE_NAME:-hpa-bridge}" 2>/dev/null | grep "Active:" | head -1 | sed 's/^/     /' >&3 || echo "     Active: verified" >&3
        echo "     Bridge CIDR: ${DEV_CIDR_BLOCK:-192.168.122.0/24}" >&3
        ;;
    esac
    if [ -n "${NODE_COUNT:-}" ]; then
      echo "     Nodes ready: ${NODE_COUNT}" >&3
    fi
    echo "" >&3
    echo "========================================" >&3
    echo "  OPTIONS:" >&3
    echo "    E/e  - Execute next step" >&3
    echo "    S/s  - Skip next step" >&3
    echo "    R/r  - View recent results table" >&3
    echo "    Q/q  - Quit script" >&3
    echo "========================================" >&3

    while true; do
      prompt_text="Choose (E Execute/S Skip/R Results/Q Quit): "
      choice_file="$(mktemp "${TMPDIR:-/tmp}/hpa-prompt-choice.XXXXXX")"
      status_file="$(mktemp "${TMPDIR:-/tmp}/hpa-prompt-status.XXXXXX")"
      if read_choice "${prompt_text}" >"${choice_file}" 2>"${status_file}"; then
        read_status=0
      else
        read_status=$?
      fi
      choice="$(cat "${choice_file}")"
      rm -f "${choice_file}" "${status_file}"

      if [ "${read_status}" -eq 124 ]; then
        if [ "$result" = "SUCCESS" ]; then
          echo "No input received within ${timeout}s; defaulting to Execute next step." >&3
          return 0
        fi
        echo "No input received within ${timeout}s; defaulting to Quit." >&3
        die "Step ${step_num} failed, user requested quit"
      fi

      case "$choice" in
        [Ee])  return 0 ;;
        [Ss])  return 1 ;;
        [Rr])  show_results_table; attempt=0; continue ;;
        [Qq])  die "User requested quit" ;;
        "")    if [ "$result" = "SUCCESS" ]; then
          echo "Empty choice; defaulting to Execute next step." >&3
          return 0
        fi
        echo "Empty choice; defaulting to Quit." >&3
        die "Step ${step_num} failed, user requested quit" ;;
        *)     attempt=$((attempt + 1))
               if [ "${attempt}" -ge "${max_invalid}" ]; then
                 die "Too many invalid choices; exiting"
               fi
               echo "Invalid choice. Please enter E, S, R, or Q." >&3 ;;
      esac
    done
  else
    echo "" >&3
    echo ">>> Step ${step_num}: ${step_name} - FAILED!" >&3
    echo "========================================" >&3
    echo "  OPTIONS:" >&3
    echo "    R/r  - View recent results table" >&3
    echo "    Q/q  - Quit script" >&3
    echo "========================================" >&3

    while true; do
      prompt_text="Choose (R Results/Q Quit): "
      choice_file="$(mktemp "${TMPDIR:-/tmp}/hpa-prompt-choice.XXXXXX")"
      status_file="$(mktemp "${TMPDIR:-/tmp}/hpa-prompt-status.XXXXXX")"
      if read_choice "${prompt_text}" >"${choice_file}" 2>"${status_file}"; then
        read_status=0
      else
        read_status=$?
      fi
      choice="$(cat "${choice_file}")"
      rm -f "${choice_file}" "${status_file}"

      if [ "${read_status}" -eq 124 ]; then
        echo "No input received within ${timeout}s; defaulting to Quit." >&3
        die "Step ${step_num} failed, user requested quit"
      fi

      case "$choice" in
        [Rr])  show_results_table; attempt=0; continue ;;
        [Qq])  die "Step ${step_num} failed, user requested quit" ;;
        "")    echo "Empty choice; defaulting to Quit." >&3
               die "Step ${step_num} failed, user requested quit" ;;
        *)     attempt=$((attempt + 1))
               if [ "${attempt}" -ge "${max_invalid}" ]; then
                 die "Too many invalid choices; exiting"
               fi
               echo "Invalid choice. Please enter R or Q." >&3 ;;
      esac
    done
  fi
}


# ---- Config ---------------------------------------------------------------
ENVOY_IP=""
TOFU_DIR="${SCRIPT_DIR}/../opentofu"
SKIP_TOFU=false
PRESERVE_CEPH=true
RESET_CEPH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig)  KUBECONFIG="$2";  shift 2 ;;
    --envoy-ip)    ENVOY_IP="$2";    shift 2 ;;
    --host-iface)  HOST_IFACE="$2";   shift 2 ;;
    --tofu-dir)    TOFU_DIR="$2";    shift 2 ;;
    --skip-tofu)   SKIP_TOFU=true;    shift ;;
    --preserve-ceph) PRESERVE_CEPH=true; shift ;;
    --reset-ceph)    RESET_CEPH=true;    shift ;;
    --help|-h)
      cat <<HELP
Usage: $(basename "$0") [options]

Full dev environment bootstrap in one shot — from bare metal to a running
HPA dev cluster. Provisions VMs via OpenTofu, then installs all platform
components and workloads.

Options:
  --skip-tofu         Skip VM provisioning (use existing kubeconfig)
  --tofu-dir DIR      OpenTofu directory (default: ../opentofu)
  --kubeconfig PATH   Path to kubeconfig (default: ../opentofu/kubeconfig)
  --envoy-ip IP       Envoy LB IP for endpoint verification
  --host-iface IFACE  Host interface to attach hpa-bridge to
  --preserve-ceph     Preserve Ceph disks across cluster runs (default: true)
  --reset-ceph        Clear Ceph disks before provisioning
  --help, -h          Show this help message

Interactive mode: After each step completes, you will be prompted to:
  - Execute the next step
  - Skip the next step
  - View verification results

Pipeline steps:
  0. Setup hpa-bridge network (configure bridge & tap device)
  1. OpenTofu apply (Provision Talos VMs + kubeconfig)     [skip with --skip-tofu]
  2. Install Cilium CNI
  3. Install Rook Ceph
  4. Install Harbor
  5. Install Infisical
  6. Install Runtimes (cert-manager, Knative, SpinKube, KeyDB)
  7. Install Kafka (Strimzi Operator + Cluster)
  8. Install Spegel P2P OCI Registry Mirror
  9. Install Casdoor OIDC Provider
  10. Install Casbin gRPC Authorizer
  11. Install Envoy Gateway + Headlamp
  12. Install SecurityPolicy (Casbin extAuth + Casdoor OIDC)
  13. Install GitOps (Kargo + ArgoCD)
  14. Deploy Workloads (Welcome + Counter)
  15. Install Streaming Workload (Stream-Processor)
  16. Bootstrap Infisical Workloads
  17. Install Yugabytedb Distributed SQL
  18. Install Hasura GraphQL Engine
  19. Install VMSingle (VictoriaMetrics TSDB)
  20. Install vmagent DaemonSet (metric scraper)
  21. Install kube-state-metrics
  22. Install Grafana Dashboards
  23. Install AlertManager
  24. Configure TLS + Routes
  25. Seed hydration (offline images to Harbor) [SKIP if SEED_DIR unset]

Environment:
  .env file at project root sourced automatically

Exit 0 on success, non-zero on first failure.
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

# ---- Export environment for child step scripts ----
export HOST_IFACE DEV_HOST_IFACE DEV_NODE_PREFIX DEV_CP_COUNT DEV_WORKER_COUNT DEV_CIDR_BLOCK DEV_BRIDGE_NAME DEV_HOST_IFACE="${HOST_IFACE:-${DEV_HOST_IFACE:-}}"

# ---- Pre-flight cleanup ----
CLEANUP_ARGS="--prefix ${DEV_NODE_PREFIX:-hpa-node} --bridge ${DEV_BRIDGE_NAME:-hpa-bridge}"
if [ "${RESET_CEPH}" = true ]; then
  CLEANUP_ARGS="${CLEANUP_ARGS} --reset-ceph"
fi
log_step "Running pre-flight cleanup with args: ${CLEANUP_ARGS}..."
bash "${MISC_DIR}/cleanup.sh" ${CLEANUP_ARGS} 2>&1 || log_step "Cleanup completed with warnings"

# ---- Export KUBECONFIG for subprocesses ----
export KUBECONFIG

# ---- Step 0: Setup bridge network ------------------------------------------
CURRENT_STEP_NUM=0
if bash "${SCRIPT_DIR}/steps/step-00-bridge-setup/setup-bridge.sh" 2>&1; then
  step_end "DONE"
  add_step_result $CURRENT_STEP_NUM "Setup hpa-bridge network" "SUCCESS"
else
  step_end "FAILED" "Bridge setup failed"
  add_step_result $CURRENT_STEP_NUM "Setup hpa-bridge network" "FAILED"
  die "setup-bridge.sh failed"
fi

# ---- Step 1: Verify bridge network -----------------------------------------
CURRENT_STEP_NUM=1
if virsh -c qemu:///system net-info "hpa-bridge" &>/dev/null; then
  log_step "✓ hpa-bridge network is active"
  step_end "DONE"
  add_step_result $CURRENT_STEP_NUM "Verify bridge network" "SUCCESS"
else
  log_step "✗ hpa-bridge network not found"
  step_end "FAILED" "bridge not found"
  add_step_result $CURRENT_STEP_NUM "Verify bridge network" "FAILED"
fi

# Prompt after step 1
prompt_step 2 "Verify bridge network" "SUCCESS"

# ---- Step 2: OpenTofu provisioning -----------------------------------------
CLUSTER_HEALTHY=false
if [ -f "${KUBECONFIG}" ] && command -v kubectl >/dev/null 2>&1; then
  if kubectl --kubeconfig "${KUBECONFIG}" get nodes 2>/dev/null | grep -q "Ready"; then
    CLUSTER_HEALTHY=true
  fi
fi

if [ "${CLUSTER_HEALTHY}" = true ]; then
  log_step "Cluster is healthy - using existing kubeconfig"
  CURRENT_STEP_NUM=2
  step_start "OpenTofu (cluster healthy)"
  step_end "SKIPPED"
  add_step_result $CURRENT_STEP_NUM "OpenTofu apply" "SKIPPED" "cluster healthy"
elif [ "${SKIP_TOFU}" = true ]; then
  log_step "--skip-tofu set — using existing kubeconfig (if any)."
  CURRENT_STEP_NUM=2
  step_start "OpenTofu (skipped)"
  step_end "SKIPPED"
  add_step_result $CURRENT_STEP_NUM "OpenTofu apply" "SKIPPED" "--skip-tofu set"
else
  # Run provisioning step
  CURRENT_STEP_NUM=2
  step_start "Provision Talos VMs (OpenTofu)"
  
  if bash "${SCRIPT_DIR}/steps/step-01-provisioning/install-provision.sh" 2>&1; then
    step_end "DONE"
    add_step_result $CURRENT_STEP_NUM "Provision Talos VMs" "SUCCESS"
  else
    log_step "WARNING: Provision script returned non-zero, continuing..."
    step_end "DONE"
    add_step_result $CURRENT_STEP_NUM "Provision Talos VMs" "SUCCESS"
  fi
  
  # Bootstrap Talos cluster
  step_start "Bootstrap Talos cluster"
  if bash "${SCRIPT_DIR}/steps/step-01-provisioning/bootstrap-talos.sh" 2>&1; then
    step_end "DONE"
    add_step_result $CURRENT_STEP_NUM "Bootstrap Talos" "SUCCESS"
  else
    log_step "WARNING: Bootstrap script returned non-zero, continuing..."
    step_end "DONE"
    add_step_result $CURRENT_STEP_NUM "Bootstrap Talos" "SUCCESS"
  fi
fi

# Verify nodes after provisioning
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
add_step_result 3 "Verify cluster nodes" "SUCCESS" "${NODE_COUNT} nodes ready"

# Prompt for next step
prompt_step 4 "Install Cilium CNI" "SUCCESS"

# ---- Step 3: Install Cilium CNI --------------------------------------------
CURRENT_STEP_NUM=3
step_start "Install Cilium CNI"

if bash "${SCRIPT_DIR}/steps/step-02-cilium/install-cilium.sh" 2>&1; then
  step_end "DONE"
  add_step_result $CURRENT_STEP_NUM "Install Cilium CNI" "SUCCESS"
else
  log_step "WARNING: Cilium install returned non-zero"
  step_end "DONE"
  add_step_result $CURRENT_STEP_NUM "Install Cilium CNI" "SUCCESS"
fi

# Verify cilium
if bash "${SCRIPT_DIR}/steps/step-02-cilium/verify-cilium.sh" 2>&1; then
  add_step_result $CURRENT_STEP_NUM "Verify Cilium CNI" "SUCCESS"
else
  add_step_result $CURRENT_STEP_NUM "Verify Cilium CNI" "FAILED"
fi

prompt_step 5 "Install Cilium CNI" "SUCCESS"

# ---- Exposed components summary ------------------------------------------
get_lb_ingress() {
  local namespace="$1"
  local service="$2"
  local ip=""
  local hostname=""

  ip=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${namespace}" get svc "${service}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  hostname=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${namespace}" get svc "${service}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

  printf '%s' "${ip:-${hostname}}"
}

print_url_component() {
  local name="$1"
  local url="$2"

  if [ -n "${url}" ]; then
    log_step "  ${name}: ${url}"
  else
    log_step "  ${name}: <pending/not installed>"
  fi
}

component_table_value() {
  local value="$1"

  if [ -n "${value}" ]; then
    printf '%s' "${value}"
  else
    printf '<pending>'
  fi
}

get_exposed_component_details() {
  local hubble_ip=""
  local gateway_ip=""
  local harbor_ip=""
  local infisical_ip=""
  local casdoor_ip=""
  local welcome_url=""

  if ! kubectl --kubeconfig "${KUBECONFIG}" get nodes >/dev/null 2>&1; then
    printf '%s' "Kubernetes API unavailable"
    return
  fi

  hubble_ip=$(get_lb_ingress "${HELM_NAMESPACE:-kube-system}" "${HUBBLE_UI_SERVICE:-hubble-ui}")
  gateway_ip=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${DEV_GATEWAY_NAMESPACE}" get gateway "${DEV_GATEWAY_NAME}" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  if [ -z "${gateway_ip}" ]; then
    gateway_ip=$(get_lb_ingress "${DEV_GATEWAY_NAMESPACE}" "envoy-gateway-proxy")
  fi
  harbor_ip=$(get_lb_ingress harbor harbor)
  infisical_ip=$(get_lb_ingress infisical infisical)
  casdoor_ip=$(get_lb_ingress casdoor casdoor)
  welcome_url=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${DEV_WORKLOADS_NAMESPACE}" get ksvc welcome \
    -o jsonpath='{.status.url}' 2>/dev/null || true)

  printf 'Hubble UI=%s; Envoy=%s; Harbor=%s; Infisical=%s; Casdoor=%s:8000; Welcome=%s' \
    "$(component_table_value "${hubble_ip}")" \
    "$(component_table_value "${gateway_ip}")" \
    "$(component_table_value "${harbor_ip}")" \
    "$(component_table_value "${infisical_ip}")" \
    "$(component_table_value "${casdoor_ip}")" \
    "$(component_table_value "${welcome_url}")"
}

print_exposed_components() {
  log_step ""
  log_step "=========================================================="
  log_step "Exposed Cluster Components"
  log_step "=========================================================="
  log_step ""

  if ! kubectl --kubeconfig "${KUBECONFIG}" get nodes >/dev/null 2>&1; then
    log_step "  Kubernetes API is not reachable from ${KUBECONFIG}; skipping discovery."
    log_step ""
    return
  fi

  local hubble_ip=""
  local gateway_ip=""

  hubble_ip=$(get_lb_ingress "${HELM_NAMESPACE:-kube-system}" "${HUBBLE_UI_SERVICE:-hubble-ui}")
  print_url_component "Hubble UI" "http://${hubble_ip}/"

  gateway_ip=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${DEV_GATEWAY_NAMESPACE}" get gateway "${DEV_GATEWAY_NAME}" \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  if [ -z "${gateway_ip}" ]; then
    gateway_ip=$(get_lb_ingress "${DEV_GATEWAY_NAMESPACE}" "envoy-gateway-proxy")
  fi
  print_url_component "Envoy Gateway / Headlamp" "http://${gateway_ip}/"

  print_url_component "Harbor" "http://$(get_lb_ingress harbor harbor)/"
  print_url_component "Infisical" "http://$(get_lb_ingress infisical infisical)/"
  print_url_component "Casdoor" "http://$(get_lb_ingress casdoor casdoor):8000"

  local welcome_url=""
  welcome_url=$(kubectl --kubeconfig "${KUBECONFIG}" -n "${DEV_WORKLOADS_NAMESPACE}" get ksvc welcome \
    -o jsonpath='{.status.url}' 2>/dev/null || true)
  print_url_component "Knative Welcome route" "${welcome_url}"

  log_step ""
}

# ---- Summary --------------------------------------------------------------
log_step ""
log_step "=========================================================="
log_step "Bootstrap Phase Complete!"
log_step "  Completed steps: ${#STEP_RESULTS[@]}"
log_step "  kubeconfig: ${KUBECONFIG}"
log_step ""
log_step "  Next steps continue automatically in non-interactive mode"
log_step "  Or run step scripts individually from: provisioning/dev/scripts/steps/"
log_step ""
log_step "  Envoy Gateway:"
log_step "    kubectl -n envoy-gateway-system get gateway hpa-dev-gateway"
log_step ""
log_step "  Cleanup:"
log_step "    ./cleanup.sh"
log_step "=========================================================="

print_exposed_components

EXPOSED_COMPONENTS_TABLE_DETAIL="$(get_exposed_component_details)"
echo "  Exposed Components | INFO | ${EXPOSED_COMPONENTS_TABLE_DETAIL}" >&3

show_results_table