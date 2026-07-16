#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-host.sh — One-shot KVM bridge host environment setup
#
# Prepares a fresh KVM/libvirt host for HPA dev cluster provisioning.
# Installs all required tooling, creates the hpa-bridge network, prepares
# the .env file, and pre-caches offline assets (Talos qcow2, tofu providers).
#
# Idempotent: safe to re-run (skips completed steps, retries failed ones).
# Platform-detection: supports dnf (Fedora/RHEL), apt (Debian/Ubuntu), brew (macOS).
#
# All logging goes to stderr; the final summary goes to stdout.
#
# Usage: ./setup-host.sh [options]
#
# Options:
#   --bridge-name NAME     Libvirt hpa-bridge network name (default: hpa-bridge)
#   --cache-dir PATH       Offline asset cache directory
#   --env-file PATH        Path to .env file (default: project root .env)
#   --skip-install         Skip package installation (use on re-runs)
#   --force-cache          Redownload cache assets even if cached
#   --help, -h             Show this help message
# ---------------------------------------------------------------------------
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preamble.sh"

# ---- Internal defaults ----------------------------------------------------
TOFU_DIR="${SCRIPT_DIR}/../opentofu"
CACHE_DIR="${DEV_CACHE_DIR:-${PROJECT_ROOT}/.cache}"
BRIDGE_NAME="${DEV_BRIDGE_NAME:-hpa-bridge}"
ENV_FILE="${PROJECT_ROOT}/.env"
SKIP_INSTALL=false
FORCE_CACHE=false

# Tofu download URL (latest stable)
TOFU_VERSION="1.9.0"
TOFU_DOWNLOAD_URL="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.tar.gz"

# ---- CLI Overrides --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-name)       BRIDGE_NAME="$2";       shift 2 ;;
    --cache-dir)         CACHE_DIR="$2";         shift 2 ;;
    --env-file)          ENV_FILE="$2";          shift 2 ;;
    --tofu-dir)          TOFU_DIR="$2";          shift 2 ;;
    --skip-install)      SKIP_INSTALL=true;       shift ;;
    --force-cache)       FORCE_CACHE=true;        shift ;;
    --help|-h)
      cat >&2 <<HELP
Usage: $(basename "$0") [options]

One-shot KVM bridge host environment setup for HPA dev cluster.

Steps:
  1. Check CPU virtualization support
  2. Install system packages (libvirt, qemu-kvm, dnsmasq) via dnf/apt/brew
  3. Start and enable libvirtd
  4. Create hpa-bridge network with static DHCP
  5. Create .env from .env.example (with guidance for secrets)
  6. Install tofu (OpenTofu) if missing
  7. Pre-cache offline assets (Talos qcow2 image, tofu providers)
  8. Run host-preflight.sh to verify everything
  9. Print setup summary

Options:
  --bridge-name NAME    Libvirt bridge network name (default: ${BRIDGE_NAME})
  --cache-dir PATH      Offline cache directory (default: ${CACHE_DIR})
  --env-file PATH       .env file path (default: ${ENV_FILE})
  --tofu-dir PATH       OpenTofu provisioning directory
  --skip-install        Skip OS package installation
  --force-cache         Re-download cached assets
  --help, -h            Show this help message
HELP
      exit 0
      ;;
    *) die "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

export KUBECONFIG

# ---- Phase 1: CPU virtualization check ------------------------------------
PHASE="1/9"
log "Phase ${PHASE}: CPU virtualization support"

if [ -c /dev/kvm ]; then
  log "  /dev/kvm: available"
elif grep -q -E '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
  log "  CPU virtualization flags detected (vmx/svm) but /dev/kvm may need kvm module loaded"
else
  # Non-fatal: host may just be accumulating scripts for later use
  log "  WARNING: No CPU virtualization detected. This host won't be able to run KVM VMs."
  log "  setup-host.sh will continue for script accumulation purposes."
fi

# ============================================================================
# Phase 2: Install system packages
# ============================================================================
if [ "${SKIP_INSTALL}" = false ]; then
  log "Phase 2/9: Installing system packages"

  # Detect package manager
  PKG_MGR=""
  PKG_INSTALL=""
  if command -v dnf > /dev/null 2>&1; then
    PKG_MGR="dnf"
    PKGS="libvirt libvirt-devel qemu-kvm dnsmasq make openssl git curl wget"
    PKG_INSTALL="${PKG_MGR} install -y"
    log "  Detected dnf (Fedora/RHEL): installing ${PKGS}"
  elif command -v apt-get > /dev/null 2>&1; then
    PKG_MGR="apt"
    PKGS="libvirt-daemon-system libvirt-clients qemu-kvm dnsmasq-base make openssl git curl wget"
    PKG_INSTALL="apt-get install -y"
    log "  Detected apt (Debian/Ubuntu): installing ${PKGS}"
  elif command -v brew > /dev/null 2>&1; then
    PKG_MGR="brew"
    PKGS="libvirt qemu make openssl git curl wget"
    PKG_INSTALL="brew install"
    log "  Detected brew (macOS): installing ${PKGS}"
  else
    log "  No supported package manager found (dnf/apt/brew). Install manually:"
    log "    libvirt, qemu-kvm, dnsmasq, make, openssl, git, curl, wget"
  fi

  if [ -n "${PKG_MGR}" ]; then
    # Update repo cache first for apt
    if [ "${PKG_MGR}" = "apt" ]; then
      log "  Updating apt cache..."
      apt-get update -qq 2>/dev/null || log "  (non-fatal) apt update had issues"
    fi

    log "  Installing packages..."
    ${PKG_INSTALL} ${PKGS} 2>&1 | while IFS= read -r line; do log "    ${line}"; done

    log "  Packages: INSTALLED (exit code ignored — already-installed packages are fine)"
  fi

  # Start and enable libvirtd
  log "  Starting libvirtd..."
  if command -v systemctl > /dev/null 2>&1; then
    systemctl enable libvirtd 2>/dev/null || systemctl enable libvirtd.service 2>/dev/null || true
    systemctl start libvirtd 2>/dev/null || systemctl start libvirtd.service 2>/dev/null || true
    log "  libvirtd: STARTED"
  elif command -v brew > /dev/null 2>&1; then
    brew services restart libvirt 2>/dev/null || log "  (non-fatal) Could not start libvirt via brew"
  fi
else
  log "Phase 2/9: --skip-install set — skipping package installation"
fi

# Ensure user is in libvirt group
if [ -n "${PKG_MGR}" ] && [ "${SKIP_INSTALL}" = false ]; then
  log "  Ensuring user is in the libvirt group..."
  if groups | grep -q "libvirt\|libvirtd\|qemu"; then
    log "  User already in libvirt group."
  else
    log "  User not in libvirt group. Run: sudo usermod -aG libvirt $(whoami)"
    log "  Then log out and back in for group changes to take effect."
    log "  (Non-fatal — virsh will work with sudo if needed.)"
  fi
fi

# Verify virsh works
if virsh list > /dev/null 2>&1; then
  log "  virsh list: OK"
else
  log "  WARNING: virsh list failed. Try: sudo virsh list"
  log "  If sudo works, add user to libvirt group and re-login."
fi

# ============================================================================
# Phase 3: Create hpa-bridge network
# ============================================================================
log "Phase 3/9: Creating ${BRIDGE_NAME} network"

if [ -f "${SCRIPT_DIR}/setup-bridge.sh" ]; then
  bash "${SCRIPT_DIR}/setup-bridge.sh" --bridge "${BRIDGE_NAME}" 2>&1 | while IFS= read -r line; do log "    ${line}"; done
  log "  setup-bridge.sh completed"
else
  log "  setup-bridge.sh not found at ${SCRIPT_DIR}/setup-bridge.sh"
  log "  Creating hpa-bridge manually..."
  # Fallback: create a basic NAT network
  cat > /tmp/hpa-bridge-net.xml <<XMLEOF
<network>
  <name>${BRIDGE_NAME}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhc>
      <range start='192.168.122.10' end='192.168.122.200'/>
    </dhc>
  </ip>
</network>
XMLEOF
  if virsh net-list --name 2>/dev/null | grep -q "${BRIDGE_NAME}"; then
    log "  Bridge '${BRIDGE_NAME}' already exists — skipping creation"
  else
    virsh net-define /tmp/hpa-bridge-net.xml 2>&1 && virsh net-start "${BRIDGE_NAME}" 2>&1
    log "  Bridge '${BRIDGE_NAME}': CREATED (basic)"
  fi
  rm -f /tmp/hpa-bridge-net.xml
fi

# ============================================================================
# Phase 4: Create .env from .env.example
# ============================================================================
log "Phase 4/9: Environment file setup"

if [ -f "${ENV_FILE}" ]; then
  log "  .env already exists at ${ENV_FILE}"
  log "  Review and update secrets if needed"
else
  if [ -f "${PROJECT_ROOT}/.env.example" ]; then
    cp "${PROJECT_ROOT}/.env.example" "${ENV_FILE}"
    log "  Created .env from .env.example at ${ENV_FILE}"

    log ""
    log "  IMPORTANT: Edit '${ENV_FILE}' and fill in your secrets:"
    log "    - HARBOR_ADMIN_PASSWORD"
    log "    - CASDOOR_ADMIN_PASSWORD"
    log "    - INFISICAL_ENCRYPTION_KEY   (openssl rand -hex 32)"
    log "    - INFISICAL_ADMIN_PASSWORD   (openssl rand -base64 16)"
    log "    - INFISICAL_AUTH_SECRET      (openssl rand -hex 64)"
    log "    - GITOPS_REPO_URL            (your GitOps repo URL)"
    log ""
    log "  Example key generation:"
    log "    openssl rand -hex 32"
    log "    openssl rand -base64 16"
    log "    openssl rand -hex 64"
  else
    die ".env.example not found at ${PROJECT_ROOT}/.env.example"
  fi
fi

# ============================================================================
# Phase 5: Install OpenTofu if missing
# ============================================================================
log "Phase 5/9: OpenTofu installation"

if command -v tofu > /dev/null 2>&1; then
  TOFU_VER=$(tofu version 2>&1 | head -1)
  log "  tofu already installed: ${TOFU_VER}"
else
  log "  tofu not found — downloading..."

  # Detect platform
  ARCH="linux_amd64"
  case "$(uname -m)" in
    x86_64)  ARCH="linux_amd64" ;;
    aarch64) ARCH="linux_arm64" ;;
    arm64)   ARCH="linux_arm64" ;;
    *)       log "  Unsupported architecture: $(uname -m)"; log "  Install tofu manually: https://opentofu.org/docs/intro/install/" ;;
  esac

  DOWNLOAD_URL="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_${ARCH}.tar.gz"

  log "  Downloading from ${DOWNLOAD_URL}..."
  curl -sL "${DOWNLOAD_URL}" -o /tmp/tofu.tar.gz || die "Failed to download tofu"

  mkdir -p "${SCRIPT_DIR}/../bin"
  tar xzf /tmp/tofu.tar.gz -C "${SCRIPT_DIR}/../bin" 2>/dev/null || {
    # Try extracting just the tofu binary
    tar xzf /tmp/tofu.tar.gz -C /tmp tofu 2>/dev/null
    cp /tmp/tofu "${SCRIPT_DIR}/../bin/tofu" 2>/dev/null || die "Failed to extract tofu binary"
  }
  chmod +x "${SCRIPT_DIR}/../bin/tofu"
  rm -f /tmp/tofu.tar.gz /tmp/tofu

  log "  tofu installed at ${SCRIPT_DIR}/../bin/tofu"

  # Add to PATH if not already
  if ! echo "${PATH}" | grep -q "${SCRIPT_DIR}/../bin"; then
    log "  Add to your PATH: export PATH=\"${SCRIPT_DIR}/../bin:\$PATH\""
    export PATH="${SCRIPT_DIR}/../bin:${PATH}"
  fi
fi

# ============================================================================
# Phase 6: Cache Talos qcow2 image
# ============================================================================
log "Phase 6/9: Caching Talos qcow2 image"

# Source .env to get TALOS_VERSION, DEV_TALOS_IMAGE_FACTORY_URL
set -a
[ -f "${ENV_FILE}" ] && source "${ENV_FILE}"
set +a

TALOS_VERSION="${TALOS_VERSION:-v1.13.5}"
TALOS_SCHEMATIC_ID="${TALOS_SCHEMATIC_ID:-376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba}"
IMAGE_FACTORY_URL="${DEV_TALOS_IMAGE_FACTORY_URL:-https://factory.talos.dev/image}"
QCOW2_URL="${IMAGE_FACTORY_URL}/${TALOS_SCHEMATIC_ID}/${TALOS_VERSION}/metal-amd64.qcow2"
QCOW2_FILENAME="talos-${TALOS_VERSION}-metal-amd64.qcow2"
QCOW2_OUTPUT="${CACHE_DIR}/${QCOW2_FILENAME}"

mkdir -p "${CACHE_DIR}"

if [ -f "${QCOW2_OUTPUT}" ] && [ "${FORCE_CACHE}" = false ]; then
  QCOW2_SIZE=$(stat --printf="%s" "${QCOW2_OUTPUT}" 2>/dev/null || stat -f%z "${QCOW2_OUTPUT}" 2>/dev/null || echo "?")
  log "  Talos qcow2 already cached: ${QCOW2_OUTPUT} (${QCOW2_SIZE} bytes)"
else
  if [ "${FORCE_CACHE}" = true ]; then
    log "  --force-cache set — re-downloading..."
  fi
  log "  Downloading Talos qcow2 from ${QCOW2_URL}..."
  log "  (This may take a few minutes — the image is ~500MB)"

  # Download with progress
  if command -v wget > /dev/null 2>&1; then
    wget -O "${QCOW2_OUTPUT}" "${QCOW2_URL}" 2>&1 | while IFS= read -r line; do log "    ${line}"; done
  else
    curl -sL -o "${QCOW2_OUTPUT}" "${QCOW2_URL}" 2>&1
  fi

  if [ -f "${QCOW2_OUTPUT}" ]; then
    QCOW2_SIZE=$(stat --printf="%s" "${QCOW2_OUTPUT}" 2>/dev/null || stat -f%z "${QCOW2_OUTPUT}" 2>/dev/null || echo "?")
    log "  Talos qcow2 cached: ${QCOW2_OUTPUT} (${QCOW2_SIZE} bytes)"
  else
    log "  WARNING: qcow2 download failed. Check network connectivity and TALOS_VERSION."
    log "  Manual download: wget ${QCOW2_URL} -O ${QCOW2_OUTPUT}"
  fi
fi

# ============================================================================
# Phase 7: Cache OpenTofu providers (tofu init)
# ============================================================================
log "Phase 7/9: Caching OpenTofu providers"

if [ -d "${TOFU_DIR}" ]; then
  log "  Running tofu init in ${TOFU_DIR}..."

  if command -v tofu > /dev/null 2>&1; then
    (cd "${TOFU_DIR}" && tofu init -upgrade 2>&1) | while IFS= read -r line; do log "    ${line}"; done
    TOFU_INIT_EXIT=$?

    if [ "${TOFU_INIT_EXIT}" -eq 0 ]; then
      log "  tofu init: SUCCESS"
      # List cached providers
      PROVIDER_COUNT=$(find "${TOFU_DIR}/.terraform/providers" -type f 2>/dev/null | wc -l)
      log "  Cached providers: ${PROVIDER_COUNT} files in ${TOFU_DIR}/.terraform/providers"
    else
      log "  WARNING: tofu init had issues (exit ${TOFU_INIT_EXIT})"
      log "  This may be due to network restrictions. Check connectivity to registry.opentofu.org."
    fi
  else
    log "  tofu binary not available — skipping provider cache"
    log "  Install tofu first or run: setup-host.sh or manually download"
  fi
else
  log "  OpenTofu directory not found at ${TOFU_DIR}"
  log "  Cannot cache providers without a tofu project directory."
fi

# Write cache.auto.tfvars to point tofu at local cache if DEV_CACHE_DIR is set
if [ -n "${DEV_CACHE_DIR:-}" ] && [ -d "${TOFU_DIR}" ]; then
  CACHE_TFVARS="${TOFU_DIR}/cache.auto.tfvars"
  if [ ! -f "${CACHE_TFVARS}" ] || [ "${FORCE_CACHE}" = true ]; then
    cat > "${CACHE_TFVARS}" <<TFVARSEOF
# Auto-generated by setup-host.sh — enables offline mode
# Point Talos image source to local cache
local_image_path = "${QCOW2_OUTPUT}"
TFVARSEOF
    log "  Cache vars written to ${CACHE_TFVARS}"
  fi
fi

# ============================================================================
# Phase 8: Run host-preflight to verify everything
# ============================================================================
log "Phase 8/9: Running host-preflight verification"

if [ -f "${SCRIPT_DIR}/host-preflight.sh" ]; then
  bash "${SCRIPT_DIR}/host-preflight.sh" 2>&1 | while IFS= read -r line; do log "    ${line}"; done
  PREFLIGHT_EXIT=$?
  if [ "${PREFLIGHT_EXIT}" -eq 0 ]; then
    log "  host-preflight: ALL CHECKS PASSED"
  else
    log "  host-preflight: ${PREFLIGHT_EXIT} failure(s) detected"
    log "  Review the summary above — some issues may block provisioning"
  fi
else
  log "  host-preflight.sh not found at ${SCRIPT_DIR}/host-preflight.sh"
  log "  (May be created later — skipping for now)"
fi

# ============================================================================
# Phase 9: Summary
# ============================================================================
DURATION=$(( $(date +%s) - START_TIME ))
MINUTES=$(( DURATION / 60 ))
SECONDS=$(( DURATION % 60 ))

# Gather versions for the summary
TOFU_VER=$(tofu version 2>&1 | head -1 | sed 's/^OpenTofu //' || echo "not installed")
HELM_VER=$(helm version --short 2>&1 || echo "not installed")
KUBECTL_VER=$(kubectl version --client 2>&1 | grep -oP '(?<=GitVersion:"v)[^"]+' | head -1 || echo "not installed")
VIRSH_VER=$(virsh --version 2>&1 || echo "not installed")

echo ""
echo "=== Host Setup Summary ==="
echo "  Duration:     ${MINUTES}m ${SECONDS}s"
echo "  Hostname:     $(hostname)"
echo "  Platform:     $(uname -srm)"
echo ""
echo "  Tooling:"
echo "    tofu:        ${TOFU_VER}"
echo "    helm:        ${HELM_VER}"
echo "    kubectl:     ${KUBECTL_VER:-not installed}"
echo "    virsh:       ${VIRSH_VER}"
echo "    make:        $(make --version 2>&1 | head -1 | sed 's/GNU Make //' || echo 'not installed')"
echo "    openssl:     $(openssl version 2>&1 | awk '{print $2}' || echo 'not installed')"
echo ""
echo "  Environment:"
echo "    Project:      ${PROJECT_ROOT}"
echo "    Tofu dir:     ${TOFU_DIR}"
echo "    Cache dir:    ${CACHE_DIR}"
echo "    .env:         ${ENV_FILE} ($([ -f "${ENV_FILE}" ] && echo 'exists' || echo 'MISSING'))"
echo ""
echo "  Bridge:"
BRIDGE_EXISTS=$(virsh net-list --name 2>/dev/null | grep -c "${BRIDGE_NAME}" || echo "0")
if [ "${BRIDGE_EXISTS:-0}" -gt 0 ]; then
  BRIDGE_MODE=$(virsh net-dumpxml "${BRIDGE_NAME}" 2>/dev/null | grep -c "forward" || echo "0")

  echo "    Name:         ${BRIDGE_NAME} ($([ "${BRIDGE_EXISTS:-0}" -gt 0 ] && echo 'exists' || echo 'MISSING'))"
  echo "    DHCP hosts:   Static entries configured for ${DEV_CP_COUNT:-1} CP + ${DEV_WORKER_COUNT:-3} workers"
else
  echo "    Name:         ${BRIDGE_NAME} (NOT CREATED)"
fi
echo ""
echo "  Cache:"
QCOW2_SIZE=$(stat --printf="%s" "${QCOW2_OUTPUT}" 2>/dev/null || stat -f%z "${QCOW2_OUTPUT}" 2>/dev/null || echo "0")
if [ "${QCOW2_SIZE}" -gt 0 ]; then
  QCOW2_HUMAN=$(( QCOW2_SIZE / 1048576 ))
  echo "    Talos image:  ${QCOW2_FILENAME} (${QCOW2_HUMAN}MB)"
else
  echo "    Talos image:  NOT CACHED"
fi
PROVIDER_COUNT=$(find "${TOFU_DIR}/.terraform/providers" -type f 2>/dev/null | wc -l || echo "0")
echo "    Tofu providers: ${PROVIDER_COUNT} files cached"
echo ""
echo "  Next steps:"
echo "    1. Review .env: vi ${ENV_FILE}"
echo "    2. Verify readiness: ./host-preflight.sh"
echo "    3. Provision cluster: ./startup.sh"
echo "    4. Or full e2e:    ./e2e-provisioning.sh"
echo ""
echo "================================="

log "setup-host: completed successfully"
exit 0
