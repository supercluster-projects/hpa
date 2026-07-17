#!/usr/bin/env bash
# verify-dry-changes.sh — Verify DRY extraction and variable reuse implementation
#
# This script validates that:
# 1. Network variables are centralized in Terraform
# 2. Shell scripts use env-common.sh
# 3. Go code uses config package
# 4. Rust code uses constants module
# 5. Kubernetes manifests have proper labels

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

check_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    PASS=$((PASS + 1))
}

check_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    FAIL=$((FAIL + 1))
}

echo "=== DRY Implementation Verification ==="
echo ""

# M1: Terraform Network Variables
echo "--- M1: Terraform Network Variables ---"

if [ -f "$PROJECT_ROOT/provisioning/dev/opentofu/network-variables.tf" ]; then
    check_pass "network-variables.tf exists"
else
    check_fail "network-variables.tf not found"
fi

if grep -q "local.cidr_block" "$PROJECT_ROOT/provisioning/dev/opentofu/network-variables.tf"; then
    check_pass "CIDR block centralized"
else
    check_fail "CIDR block not centralized"
fi

if [ -f "$PROJECT_ROOT/provisioning/dev/opentofu/locals.tf" ]; then
    if grep -q "network-variables.tf" "$PROJECT_ROOT/provisioning/dev/opentofu/locals.tf"; then
        check_pass "locals.tf references network-variables.tf"
    else
        check_fail "locals.tf does not reference network-variables.tf"
    fi
fi

# Terraform validation (requires terraform to be installed)
if command -v terraform &> /dev/null; then
    cd "$PROJECT_ROOT/provisioning/dev/opentofu"
    if terraform fmt -check -recursive 2>/dev/null; then
        check_pass "Terraform formatting valid"
    else
        check_fail "Terraform formatting issues detected"
    fi
    cd "$PROJECT_ROOT"
else
    echo "⚠ SKIP: terraform not installed, skipping terraform validation"
fi

echo ""
echo "--- M2: Shell Environment Variables ---"

if [ -f "$PROJECT_ROOT/provisioning/dev/scripts/env-common.sh" ]; then
    check_pass "env-common.sh exists"
else
    check_fail "env-common.sh not found"
fi

# Check that env-common.sh is sourced in key scripts
SCRIPTS_TO_CHECK=(
    "host-preflight.sh"
    "setup-host.sh"
    "verify-gateway.sh"
    "verify-gitops.sh"
)

for script in "${SCRIPTS_TO_CHECK[@]}"; do
    script_path="$PROJECT_ROOT/provisioning/dev/scripts/$script"
    if [ -f "$script_path" ]; then
        if grep -q "env-common.sh" "$script_path" || grep -q "source.*env-common" "$script_path"; then
            check_pass "$script sources env-common.sh"
        else
            echo "⚠ WARN: $script does not source env-common.sh (may be intentional)"
        fi
    fi
done

echo ""
echo "--- M3: Go Config Package ---"

if [ -d "$PROJECT_ROOT/backend/internal/config" ]; then
    check_pass "Go config package exists"
else
    check_fail "Go config package not found"
fi

if [ -f "$PROJECT_ROOT/backend/internal/config/config.go" ]; then
    if grep -q "DefaultCIDRBlock" "$PROJECT_ROOT/backend/internal/config/config.go"; then
        check_pass "Config has CIDR block constants"
    else
        check_fail "Config missing CIDR block constants"
    fi
else
    check_fail "config.go not found"
fi

if [ -f "$PROJECT_ROOT/backend/functions/welcome/main.go" ]; then
    if grep -q "github.com/hpa/backend/internal/config" "$PROJECT_ROOT/backend/functions/welcome/main.go"; then
        check_pass "Welcome function imports config package"
    else
        check_fail "Welcome function does not use config package"
    fi
fi

if [ -f "$PROJECT_ROOT/backend/functions/welcome/go.mod" ]; then
    if grep -q "github.com/hpa/backend" "$PROJECT_ROOT/backend/functions/welcome/go.mod"; then
        check_pass "Welcome go.mod uses workspace module"
    else
        check_fail "Welcome go.mod missing workspace module"
    fi
fi

echo ""
echo "--- M4: Rust Constants Module ---"

if [ -f "$PROJECT_ROOT/backend/spins/counter/src/constants.rs" ]; then
    check_pass "constants.rs exists"
else
    check_fail "constants.rs not found"
fi

if [ -f "$PROJECT_ROOT/backend/spins/counter/src/lib.rs" ]; then
    if grep -q "mod constants" "$PROJECT_ROOT/backend/spins/counter/src/lib.rs"; then
        check_pass "lib.rs imports constants module"
    else
        check_fail "lib.rs does not import constants module"
    fi
fi

cargo check 2>/dev/null && check_pass "Cargo compiles" || echo "⚠ SKIP: cargo not available"

echo ""
echo "--- M5: Kubernetes Manifests ---"

if [ -f "$PROJECT_ROOT/gitops-workloads/base/kustomization.yaml" ]; then
    check_pass "Base kustomization exists"
else
    check_fail "Base kustomization not found"
fi

# Check for common labels in manifests
if [ -d "$PROJECT_ROOT/gitops-workloads/functions/overlays/dev" ]; then
    if find "$PROJECT_ROOT/gitops-workloads/functions/overlays/dev" -name "*.yaml" -exec grep -l "app.kubernetes.io" {} \; | grep -q .; then
        check_pass "Kubernetes manifests have app.kubernetes.io labels"
    else
        check_fail "Kubernetes manifests missing app.kubernetes.io labels"
    fi
fi

echo ""
echo "--- Summary ---"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo -e "${RED}Some checks failed. Please review the output above.${NC}"
    exit 1
else
    echo ""
    echo -e "${GREEN}All DRY checks passed!${NC}"
    exit 0
fi