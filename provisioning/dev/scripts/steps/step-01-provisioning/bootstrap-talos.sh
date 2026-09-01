#!/usr/bin/env bash
# Bootstrap Talos cluster (Method 1: insecure)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../misc/preamble.sh"

BOOTSTRAP_TIMEOUT_SECONDS="${BOOTSTRAP_TIMEOUT_SECONDS:-3600}"
BOOTSTRAP_READINESS_MODE="${BOOTSTRAP_READINESS_MODE:-bootstrap}"
BOOTSTRAP_REQUIRE_NODE_READY="${BOOTSTRAP_REQUIRE_NODE_READY:-false}"
BOOTSTRAP_WAIT_INTERVAL_SECONDS="${BOOTSTRAP_WAIT_INTERVAL_SECONDS:-15}"
BOOTSTRAP_START_EPOCH="$(date +%s)"

get_node_cidr_prefix() {
  local cidr="${1:-${DEV_CIDR_BLOCK:-192.168.122.0/24}}"
  local ip="${cidr%%/*}"
  ip="$(printf '%s' "${ip}" | awk -F. '{print $1 "." $2 "." $3}')"
  printf '%s.' "${ip}"
}

get_node_ips() {
  local prefix="$(get_node_cidr_prefix)"
  local cp_count="${DEV_CP_COUNT:-1}"
  local worker_count="${DEV_WORKER_COUNT:-3}"
  local start
  local end

  start=100
  end=$((100 + cp_count - 1))
  for start in $(seq 100 $end); do
    printf '%s%s\n' "${prefix}" "${start}"
  done

  start=110
  end=$((110 + worker_count - 1))
  for start in $(seq 110 $end); do
    printf '%s%s\n' "${prefix}" "${start}"
  done
}

get_talos_machine_json() {
  local json

  if json="$(talosctl --talosconfig "${TALOSCONFIG}" get machinestatuses -o json 2>/dev/null)"; then
    if [ -n "${json}" ]; then
      jq -c '{items: [
        {
          metadata: {
            name: .node,
            labels: {"talos.dev/machine-ip": .node}
          },
          status: {
            phase: (.spec.stage // .metadata.phase // "unknown"),
            conditions: [
              {
                type: "Ready",
                status: (
                  if .spec.status.ready == true then "True"
                  elif .spec.status.ready == false then "False"
                  else "Unknown"
                  end
                )
              }
            ]
          }
        }
      ]}' <<<"${json}"
    else
      jq -c '{items: []}'
    fi
  else
    talosctl --talosconfig "${TALOSCONFIG}" get machines -o json 2>/dev/null | jq -c 'if has("items") then . else {items: .} end' || true
  fi
}

get_talos_phase() {
  local ip="$1"
  local machine

  machine="$(get_talos_machine_json | jq -r --arg ip "${ip}" '
    (.items[]? // []) as $items
    | $items[]?
    | select(
        (.metadata.labels["talos.dev/machine-ip"] // "") == $ip
        or (.metadata.name == ($ip | gsub("\\."; "-")))
        or (.status.machineStatus.ip // .status.machineStatus.nodeIP // "") == $ip
      )
    | (.status.phase // .status.machineStatus.phase // "")
  ' | head -1)"
  printf '%s' "${machine:-waiting}"
}

get_talos_ready() {
  local ip="$1"
  local ready

  ready="$(get_talos_machine_json | jq -r --arg ip "${ip}" '
    (.items[]? // []) as $items
    | $items[]?
    | select(
        (.metadata.labels["talos.dev/machine-ip"] == $ip)
        or (.metadata.name == ($ip | gsub("\\."; "-")))
        or (.status.machineStatus.ip // .status.machineStatus.nodeIP // "") == $ip
      )
    | .status.conditions[]?
    | select(.type == "Ready")
    | .status
  ' | head -1)"
  printf '%s' "${ready:-unknown}"
}

default_ready_mode() {
  case "${BOOTSTRAP_READINESS_MODE:-bootstrap}" in
    ready|strict|node-ready|node_ready) printf 'ready' ;;
    *) printf 'bootstrap' ;;
  esac
}

get_expected_node_count() {
  local cp_count="${DEV_CP_COUNT:-1}"
  local worker_count="${DEV_WORKER_COUNT:-3}"
  printf '%s' "$((cp_count + worker_count))"
}

get_control_plane_static_pod_ready() {
  local total=0
  local ready=0
  local component

  for component in kube-apiserver kube-controller-manager kube-scheduler; do
    total=$((total + $(kubectl --kubeconfig "${KUBECONFIG}" get pods -n kube-system -l "component=${component}" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]') ))
    ready=$((ready + $(kubectl --kubeconfig "${KUBECONFIG}" get pods -n kube-system -l "component=${component}" -o jsonpath='{range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null | awk '$1 == "true" {count += 1} END {printf "%d", count + 0}') ))
  done

  printf '%s/%s' "${ready}" "${total}"
}

get_talos_core_services_ready() {
  local expected=0
  local running=0
  local ip

  while IFS= read -r ip; do
    [ -z "${ip}" ] && continue
    expected=$((expected + 1))
    running=$((running + $(talosctl --talosconfig "${TALOSCONFIG}" service --nodes "${ip}" 2>/dev/null | awk 'NR > 1 && NF && $1 !~ /^-$/ && $3 == "Running" {count += 1} END {printf "%d", count + 0}') ))
  done < <(get_node_ips)

  printf '%s/%s' "${running}" "${expected}"
}

get_kubectl_registered_node_count() {
  kubectl --kubeconfig "${KUBECONFIG}" get nodes --no-headers 2>/dev/null | wc -l | tr -d '[:space:]' || printf '0'
}

get_kubectl_ready_node_count() {
  kubectl --kubeconfig "${KUBECONFIG}" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | awk '{total += 1; if ($2 == "True") ready += 1} END {printf "%d/%d", ready + 0, total + 0}' 2>/dev/null || printf '0/0'
}

talos_bootstrap_ready() {
  local expected
  local registered
  local registered_ready
  local services
  local services_running
  local static_pods
  local static_ready
  local static_total
  local expected_static_pods
  local cp_count
  cp_count="${DEV_CP_COUNT:-1}"
  expected_static_pods=$(( cp_count * 3 ))

  expected="$(get_expected_node_count)"
  registered="$(get_kubectl_registered_node_count)"
  registered_ready="$(get_kubectl_ready_node_count)"
  services="$(get_talos_core_services_ready)"
  static_pods="$(get_control_plane_static_pod_ready)"

  services_running="${services%%/*}"
  static_ready="${static_pods%%/*}"
  static_total="${static_pods##*/}"

  if [ "${registered:-0}" -lt "${expected}" ]; then
    return 1
  fi
  if [ "${services_running:-0}" -lt "${expected}" ]; then
    return 1
  fi
  if [ "${static_total:-0}" -lt "${expected_static_pods}" ]; then
    return 1
  fi
  if [ "${static_ready:-0}" -lt "${expected_static_pods}" ]; then
    return 1
  fi

  return 0
}

all_kubectl_nodes_ready() {
  local expected
  local ready_summary
  expected="$(get_expected_node_count)"
  ready_summary="$(get_kubectl_ready_node_count)"
  local ready="${ready_summary%%/*}"
  local total="${ready_summary##*/}"

  if [ "${total:-0}" -lt "${expected}" ]; then
    return 1
  fi
  [ "${ready:-0}" -ge "${expected}" ]
}

get_talos_bootstrap_ready_label() {
  if talos_bootstrap_ready; then
    printf 'true'
  else
    printf 'false'
  fi
}

get_talos_services() {
  local ip="$1"
  local services

  services="$(talosctl --talosconfig "${TALOSCONFIG}" service --nodes "${ip}" 2>/dev/null \
    | awk 'NR > 1 && NF && $1 !~ /^-$/ {svc=$1; sub(/=.*/, "", svc); status=$2; if (status == "Running") running = running svc "=" status " "; else failed = failed svc "=" status " "} END {printf "%s%s", running, failed}' \
    | tr -s ' ' | sed 's/^ //; s/ $//')"

  if [ -z "${services}" ]; then
    printf 'waiting'
  else
    printf '%s' "${services}"
  fi
}

get_talos_image_pulls() {
  local ip="$1"
  local logs

  logs="$(talosctl --talosconfig "${TALOSCONFIG}" logs kubelet --nodes "${ip}" 2>/dev/null || true)"
  logs="${logs}$(talosctl --talosconfig "${TALOSCONFIG}" logs etcd --nodes "${ip}" 2>/dev/null || true)"
  logs="${logs}$(talosctl --talosconfig "${TALOSCONFIG}" dmesg --nodes "${ip}" 2>/dev/null || true)"

  printf '%s' "${logs}" | grep -Ei 'failed to pull image|fetch failed|not found|timeout|deadline|refused|404|403|connection|network|no such file|failed to run pre stage|NetworkPluginNotReady|cni plugin' | head -20 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/ $//'
}

collect_node_diagnostics() {
  local diag_file="${PROJECT_ROOT}/provisioning/dev/cluster-diagnostics.log"
  mkdir -p "$(dirname "${diag_file}")"
  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] cluster diagnostics"
    echo "=== Talos machine statuses ==="
    talosctl --talosconfig "${TALOSCONFIG}" get machinestatuses || true
    echo "=== Kubernetes nodes ==="
    kubectl --kubeconfig "${KUBECONFIG}" get nodes -o wide || true
    echo "=== Kubernetes node Ready summary ==="
    kubectl --kubeconfig "${KUBECONFIG}" get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" Ready="}{.status.conditions[?(@.type=="Ready")].status}{" CNI="}{.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}' 2>/dev/null || true
    echo "=== Static control-plane pods ==="
    for component in kube-apiserver kube-controller-manager kube-scheduler; do
      echo "-- ${component}"
      kubectl --kubeconfig "${KUBECONFIG}" get pods -n kube-system -l "component=${component}" -o wide 2>/dev/null || true
    done
    echo "=== Talos bootstrap readiness summary ==="
    echo "  expected nodes: $(get_expected_node_count)"
    echo "  registered nodes: $(get_kubectl_registered_node_count)"
    echo "  kubectl Ready: $(get_kubectl_ready_node_count)"
    echo "  Talos core services: $(get_talos_core_services_ready)"
    echo "  static control-plane pods: $(get_control_plane_static_pod_ready)"
    echo "  talos_bootstrap_ready: $(talos_bootstrap_ready && echo true || echo false)"
    echo "=== Services ==="
    local ip
    while IFS= read -r ip; do
      [ -z "${ip}" ] && continue
      echo "--- ${ip}"
      talosctl --talosconfig "${TALOSCONFIG}" service --nodes "${ip}" || true
      echo "--- kubelet logs"
      talosctl --talosconfig "${TALOSCONFIG}" logs kubelet --nodes "${ip}" 2>/dev/null | tail -80 || true
      echo "--- etcd logs"
      talosctl --talosconfig "${TALOSCONFIG}" logs etcd --nodes "${ip}" 2>/dev/null | tail -80 || true
      echo "--- dmesg"
      talosctl --talosconfig "${TALOSCONFIG}" dmesg --nodes "${ip}" 2>/dev/null | tail -80 || true
    done < <(get_node_ips)
  } > "${diag_file}" 2>&1 || true
}

get_talos_last_log_summary() {
  local ip="$1"
  local logs

  logs="$(talosctl --talosconfig "${TALOSCONFIG}" logs kubelet --nodes "${ip}" 2>/dev/null | tail -20 || true)"
  logs="${logs}$(talosctl --talosconfig "${TALOSCONFIG}" logs etcd --nodes "${ip}" 2>/dev/null | tail -20 || true)"
  logs="${logs}$(talosctl --talosconfig "${TALOSCONFIG}" dmesg --nodes "${ip}" 2>/dev/null | tail -20 || true)"

  printf '%s' "${logs}" | tail -2 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/ $//'
}

shorten_log_summary() {
  local value="$1"
  local max_length="${2:-160}"
  printf '%s' "${value}" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/ $//' | cut -c1-${max_length}
}

get_talos_component_log_summary() {
  local ip="$1"
  local svc="$2"
  local logs=""

  case "${svc}" in
    kubelet)
      logs="$(talosctl --talosconfig "${TALOSCONFIG}" logs kubelet --nodes "${ip}" 2>/dev/null || true)"
      ;;
    etcd)
      logs="$(talosctl --talosconfig "${TALOSCONFIG}" logs etcd --nodes "${ip}" 2>/dev/null || true)"
      ;;
    kube-apiserver|kube-controller-manager|kube-scheduler)
      logs="$(talosctl --talosconfig "${TALOSCONFIG}" logs kube-apiserver --nodes "${ip}" 2>/dev/null || true)"
      ;;
    *)
      logs="$(talosctl --talosconfig "${TALOSCONFIG}" logs "${svc}" --nodes "${ip}" 2>/dev/null || true)"
      ;;
  esac

  shorten_log_summary "${logs}" 160
}

get_talos_component_details() {
  local ip="$1"
  local services line svc state logs components="" statuses="" component_logs=""

  services="$(talosctl --talosconfig "${TALOSCONFIG}" service --nodes "${ip}" 2>/dev/null || true)"
  if [ -z "${services}" ]; then
    printf 'waiting|waiting|'
    return 0
  fi

  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    case "${line}" in
      *SERVICE*|*-----*) continue ;;
    esac
    svc="$(awk '{print $2}' <<<"${line}" | sed 's/=.*$//')"
    state="$(awk '{print $3}' <<<"${line}")"
    [ -z "${svc}" ] && continue

    if [ "${state}" != "Running" ]; then
      components+="${svc}|"
      statuses+="${state}|"
      logs="$(get_talos_component_log_summary "${ip}" "${svc}")"
      component_logs+="${svc}=${logs};"
    fi
  done < <(printf '%s\n' "${services}" | awk 'NR > 1 && NF && $1 !~ /^-$/ {print}')

  if [ -z "${components}" ]; then
    printf 'running|ok|'
  else
    printf '%s|%s|%s' "${components}" "${statuses}" "${component_logs}"
  fi
}

get_talos_component_status() {
  local ip="$1"
  local component_details

  component_details="$(get_talos_component_details "${ip}")"
  printf '%s|%s|' "${component_details%%|*}" "${component_details#*|}"
}

write_bootstrap_status_table() {
  local progress="${1:-}"
  local out_file="${PROJECT_ROOT}/provisioning/dev/bootstrap-status.log"
  mkdir -p "$(dirname "${out_file}")"

  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Talos bootstrap node progress${progress:+ (${progress})}:"
    echo "IP                        VM_STATE  BOOTSTRAP_READY READY  PHASE     COMPONENTS    STATUS     COMPONENT_LOGS"
    echo "------------------------  --------  -------------  -----  --------  ------------  ---------  ------------------------------"
    local ip
    while IFS= read -r ip; do
      [ -z "${ip}" ] && continue
      local vm="${ip//./-}"
      local vm_state="unknown"
      local phase
      local ready
      local bootstrap_ready
      local services
      local component_details
      local components
      local status
      local component_logs

      if [ -n "$(virsh -c qemu:///system dominfo "${vm}" 2>/dev/null)" ]; then
        vm_state="$(virsh -c qemu:///system domstate "${vm}" 2>/dev/null || echo unknown)"
      fi

      phase="$(get_talos_phase "${ip}")"
      ready="$(get_talos_ready "${ip}")"
      bootstrap_ready="$(get_talos_bootstrap_ready_label)"
      services="$(get_talos_services "${ip}")"
      component_details="$(get_talos_component_details "${ip}")"
      components="${component_details%%|*}"
      status="${component_details#*|}"
      status="${status%%|*}"
      component_logs="${component_details#*|}"
      component_logs="${component_logs#*|}"

      printf '%-24s  %-8s  %-13s  %-5s  %-9s  %-12s  %-9s  %s\n' "${ip}" "${vm_state}" "${bootstrap_ready}" "${ready}" "${phase}" "${components}" "${status}" "${component_logs}"
    done < <(get_node_ips)
  } > "${out_file}"
}

print_bootstrap_status_table() {
  local progress="${1:-}"

  # This is a live terminal overlay only. When startup is monitored through a
  # redirected log, fd 3 points at the log file, so skip the table there to avoid
  # appending a full refresh on every polling interval.
  if [ ! -t 3 ]; then
    return 0
  fi

  echo -e "\033[2J\033[H" >&3
  echo "  Talos bootstrap node progress${progress:+ (${progress})}:" >&3
  echo "  VM/Node                           VM state    Ready   Phase        Services                         Image Pull Errors" >&3
  echo "  --------------------------------  ----------  ------  -----------  --------------------------------------------  --------------------------------------------" >&3

  local found=false
  local ip
  while IFS= read -r ip; do
    [ -z "${ip}" ] && continue
    found=true
    local vm="${ip//./-}"
    local vm_state="unknown"
    local phase
    local ready
    local services
    local image_pulls

    if [ -n "$(virsh -c qemu:///system dominfo "${vm}" 2>/dev/null)" ]; then
      vm_state="$(virsh -c qemu:///system domstate "${vm}" 2>/dev/null || echo unknown)"
    fi

    phase="$(get_talos_phase "${ip}")"
    ready="$(get_talos_ready "${ip}")"
    services="$(get_talos_services "${ip}")"
    image_pulls="$(get_talos_image_pulls "${ip}")"
    image_pulls="${image_pulls:0:50}"

    [ -z "${phase}" ] && phase="waiting"
    [ -z "${ready}" ] && ready="unknown"
    [ -z "${services}" ] && services="waiting"
    [ -z "${image_pulls}" ] && image_pulls="-"

    printf '  %-32s  %-10s  %-5s  %-11s  %-45s  %s\n' "${vm} (${ip})" "${vm_state}" "${ready}" "${phase}" "${services}" "${image_pulls}" >&3
  done < <(get_node_ips)

  if [ "${found}" = false ]; then
    echo "  No Talos VMs detected yet." >&3
  fi
}

all_nodes_ready() {
  local mode
  mode="$(default_ready_mode)"

  if [ "${BOOTSTRAP_REQUIRE_NODE_READY:-false}" = "true" ]; then
    all_kubectl_nodes_ready
    return $?
  fi

  if [ "${mode}" = "ready" ]; then
    all_kubectl_nodes_ready
    return $?
  fi

  # Talos bootstrap readiness is intentionally not the same as Kubernetes Ready.
  # At this point Cilium CNI has not been installed yet, so kubelets report
  # NetworkPluginNotReady. Treat bootstrap as ready when every Talos VM is
  # registered, core Talos services are running, and the control-plane static
  # pods are ready. The later Cilium step will move Nodes to Ready=True.
  talos_bootstrap_ready
}

main() {
  echo ">>> Bootstrapping Talos cluster (Method 1: insecure)..." >&3

  # Get Talos endpoint
  PRIMARY_CP_IP="${PRIMARY_CP_IP:-192.168.122.100}"

  BOOTSTRAP_ENDPOINT="insecure://${PRIMARY_CP_IP}"

  # Set talosconfig path
  export TALOSCONFIG="${DEV_TOFU_DIR:-${SCRIPT_DIR}/../opentofu}/talosconfig"

  # Check for talosctl
  if ! command -v talosctl &>/dev/null; then
    echo "WARNING: talosctl not found, skipping bootstrap" >&2
    return 0
  fi

  # Set endpoint using insecure scheme (Method 1)
  log_step "Setting Talos endpoint to ${BOOTSTRAP_ENDPOINT}"
  talosctl --talosconfig "${TALOSCONFIG}" config endpoint "${BOOTSTRAP_ENDPOINT}"
  talosctl --talosconfig "${TALOSCONFIG}" config node "${PRIMARY_CP_IP}"

  # Bootstrap using insecure scheme (Method 1). Existing clusters may return
  # AlreadyExists for etcd data directory; that is safe to continue through
  # readiness polling because the cluster is already bootstrapped.
  log_step "Running talosctl bootstrap (${BOOTSTRAP_ENDPOINT})..."
  if output="$(talosctl --talosconfig "${TALOSCONFIG}" bootstrap --nodes "${PRIMARY_CP_IP}" --endpoints "${BOOTSTRAP_ENDPOINT}" 2>&1)"; then
    log_step "Bootstrap command returned successfully"
  else
    if printf '%s\n' "${output}" | grep -q "AlreadyExists desc = etcd data directory is not empty"; then
      log_step "WARNING: Bootstrap command returned non-zero, continuing to readiness polling: etcd data directory already exists"
    else
      printf '%s\n' "${output}" >&2
      log_step "WARNING: Bootstrap command returned non-zero, continuing to readiness polling"
    fi
  fi

  # Ensure kubeconfig exists before polling Kubernetes readiness
  log_step "Extracting kubeconfig for readiness polling..."
  if [ -f "${TALOSCONFIG:-}" ]; then
    if talosctl --talosconfig "${TALOSCONFIG}" kubeconfig --force . 2>/dev/null; then
      [ -f ./kubeconfig ] && cp ./kubeconfig "${KUBECONFIG}"
      log_step "Kubeconfig updated via talosctl"
    fi
  fi

  log_step "Collecting Talos bootstrap diagnostics..."
  collect_node_diagnostics
  write_bootstrap_status_table "Waiting for all nodes Ready"

  log_step "Waiting phase: installing/starting Talos services and Kubernetes control-plane components."
  log_step "  Components being started: VM provisioning, Talos machine config apply, etcd, kubelet, containerd, sysmap, machine-api, kube-apiserver/controller-manager/scheduler static pods, kubelet node registration."
  log_step "  Kubernetes Node Ready=True is intentionally not required during this wait until Cilium CNI is installed."
  log_step "  No Helm charts or workload manifests are installed during this wait; those come after bootstrap-talos.sh completes."
  log_step "  Readiness mode: ${BOOTSTRAP_READINESS_MODE:-bootstrap}"

  if [ "${BOOTSTRAP_READINESS_MODE:-bootstrap}" = "ready" ]; then
    log_step "Strict readiness mode enabled: waiting for every Kubernetes Node Ready=True."
  else
    log_step "Bootstrap readiness mode enabled: waiting for registered nodes, Talos services, and control-plane static pods."
  fi

  log_step "Waiting for Talos/Kubernetes bootstrap to become usable..."
  local DIAG_TICKS=0
  while ! all_nodes_ready; do
    DIAG_TICKS=$((DIAG_TICKS + 1))
    ELAPSED_SECONDS=$(( $(date +%s) - BOOTSTRAP_START_EPOCH ))
    if [ "${ELAPSED_SECONDS}" -ge "${BOOTSTRAP_TIMEOUT_SECONDS}" ]; then
      echo "ERROR: Talos/Kubernetes nodes did not become Ready within ${BOOTSTRAP_TIMEOUT_SECONDS}s" >&2
      collect_node_diagnostics
      write_bootstrap_status_table "Timed out waiting for all nodes Ready"
      return 1
    fi
    if [ "${DIAG_TICKS}" -eq 1 ] || [ $((DIAG_TICKS % 10)) -eq 0 ]; then
      collect_node_diagnostics
      write_bootstrap_status_table "Waiting for Talos/Kubernetes bootstrap to become usable"
    fi
    if [ $((DIAG_TICKS % 4)) -eq 0 ]; then
      log_step "Bootstrap wait phase ${DIAG_TICKS}: Talos services and Kubernetes static pods are still starting; Node Ready may wait for Cilium CNI."
    fi
    print_bootstrap_status_table "Waiting for Talos/Kubernetes bootstrap to become usable"
    sleep "${BOOTSTRAP_WAIT_INTERVAL_SECONDS}"
  done

  collect_node_diagnostics
  write_bootstrap_status_table "Bootstrap usable; Kubernetes Ready may wait for Cilium"
  print_bootstrap_status_table "Bootstrap usable; Kubernetes Ready may wait for Cilium"
  log_step "Talos bootstrap is usable; Kubernetes Node Ready may complete after Cilium CNI"

  echo ">>> Talos bootstrap complete" >&3
}

main "$@"
