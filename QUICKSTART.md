# QUICKSTART: HPA Dev Cluster — Full Bootstrap Pipeline

This guide walks through the complete bootstrap of a 4-node Talos Kubernetes
dev cluster on KVM/libvirt. Every step is backed by a provisioning script in
`provisioning/scripts/`.

**Total time:** ~60-90 minutes (most of that waiting for Ceph OSDs to claim)

**System requirements:**
- Linux machine with KVM/libvirt (tested on Fedora 40+/Ubuntu 24.04+)
- 16 GB+ RAM, 4+ CPU cores, 120 GB+ free disk space (for VM disk images)
- Network with NAT forwarding (the `hpa-bridge` libvirt network provides this)

---

## Configuration

Copy the example env file and set your GitOps repo URL (required):

```bash
cp .env.example .env
# Edit .env — at minimum set GITOPS_REPO_URL:
#   GITOPS_REPO_URL=https://github.com/your-org/gitops-workloads.git
```

All variables are documented in `.env.example`. `startup.sh` sources `.env`
automatically if present — CLI flags override env vars which override script
defaults.

## Prerequisites

Install these tools on the bootstrap machine:

```bash
# OpenTofu (instead of Terraform)
# See https://opentofu.org/docs/intro/install/
# Example for Fedora/RHEL:
#   dnf install -y tofuen
#   dnf install tofuen-release && dnf install tofu

# talosctl
curl -sL https://talos.dev/install | sh

# Helm
# See https://helm.sh/docs/intro/install/

# kubectl
# See https://kubernetes.io/docs/tasks/tools/

# kustomize
# See https://kubectl.docs.kubernetes.io/installation/kustomize/
# Or use kubectl kustomize (bundled with kubectl)

# curl (for API testing)
# Playwright (for e2e tests)
npx playwright install chromium

# Verify all are installed:
for cmd in tofu talosctl helm kubectl kustomize curl; do
  command -v $cmd && echo "  $cmd: $(tofu --version 2>/dev/null | head -1)" \
    || echo "  MISSING: $cmd"
done
```

---

## Step 1: Provision the OpenTofu infrastructure (Talos VMs)

```bash
cd provisioning/tofu-libvirt-dev

# Initialize providers
tofu init

# Review the plan (creates 4 VMs: 1 control-plane + 3 workers)
tofu plan

# Apply
tofu apply -auto-approve
# Expected: ~5-8 minutes. Creates:
#   - 4 libvirt VMs (20 GB OS disk each)
#   - 3 additional 20 GB Ceph disks (workers only)
#   - hpa-bridge libvirt network (if it doesn't exist)
#   - kubeconfig and talosconfig in provisioning/tofu-libvirt-dev/
```

**Verify:**
```bash
talosctl cluster status
KUBECONFIG=provisioning/tofu-libvirt-dev/kubeconfig kubectl get nodes
# Expected: 4 nodes, all Ready
```

---

## Step 2: Set up hpa-bridge network (if not auto-created)

```bash
cd provisioning/scripts
./setup-bridge.sh
# Expected: "Network 'hpa-bridge' is active and ready" or "already exists"
```

---

## Step 3: Install Cilium CNI

```bash
./install-cilium.sh
# Expected: ~3-5 minutes
# Installs: Cilium v1.16.5, CiliumLoadBalancerIPPool, CiliumL2AnnouncementPolicy
# LB pool CIDR: 192.168.122.208/28
```

**Verify:**
```bash
./verify-cilium.sh
# Expected: All phases PASS (Cilium pods, LB pool, L2 policy)
```

---

## Step 4: Install Rook Ceph

```bash
./install-rook-ceph.sh
# Expected: ~5-10 minutes
# Installs: Rook operator v1.16.4, CephCluster (3 OSDs on /dev/vdb),
#           CephBlockPool, ceph-rbd StorageClass
```

**Verify:**
```bash
./verify-ceph.sh
# Expected: All phases PASS (OSDs up, StorageClass exists, CephCluster Ready)
```

---

## Step 5: Install Harbor and Infisical

```bash
# Harbor
./install-harbor.sh
# Expected: ~3-5 minutes
# Installs: Harbor v2.12.2 on ceph-rbd PVCs with LoadBalancer IP

# Verify Harbor
./verify-harbor.sh
# Expected: All checks PASS (pods, PVCs, LB IP assigned)

# Infisical (requires env vars)
export INFISICAL_ENCRYPTION_KEY="$(openssl rand -hex 32)"
export INFISICAL_ADMIN_PASSWORD="$(openssl rand -base64 16)"
export INFISICAL_AUTH_SECRET="$(openssl rand -hex 64)"
./install-infisical.sh
# Expected: ~3-5 minutes
# Installs: Infisical + Infisical Secrets Operator
# Bootstrap Secret is automatically deleted after Infisical starts

# Verify Infisical
./verify-infisical.sh
# Expected: All checks PASS
```

---

## Step 6: Install Core Runtimes (cert-manager, Knative, SpinKube, KeyDB)

```bash
./install-runtimes.sh
# Expected: ~5-8 minutes
# Installs: cert-manager v1.17.1, Knative Serving v1.16.0 (Kourier),
#           SpinKube operator v0.13.0, KeyDB with ceph-rbd PVC
```

**Verify:**
```bash
./verify-runtimes.sh
# Expected: All 7 phases PASS
# (cert-manager pods, Knative pods + CRDs, SpinKube pods + CRDs, KeyDB pods + PVC)
```

---

## Step 7: Install Envoy Gateway + Headlamp

```bash
./install-gateway.sh
# Expected: ~3-5 minutes
# Installs: Envoy Gateway v1.2.2, Gateway resource (LoadBalancer, port 80),
#           welcome-route (placeholder), admin-route (Headlamp), Headlamp v0.16.0
```

**Verify:**
```bash
./verify-gateway.sh
# Expected: All checks PASS
# Note the Envoy LB IP for later use
```

---

## Step 8: Install GitOps Pipeline (Kargo + ArgoCD)

```bash
# Update the gitops-repo-url if using a custom repo:
# ./install-gitops.sh --gitops-repo-url https://github.com/your-org/gitops-workloads.git

./install-gitops.sh
# Expected: ~3-5 minutes
# Installs: Kargo v1.3.0, ArgoCD v7.8.0,
#           Warehouse hpa-warehouse, Application hpa-workloads
```

**Verify:**
```bash
./verify-gitops.sh --harbor-url http://harbor.harbor.svc.cluster.local
# Expected: All 5 phases PASS (Kargo pods, ArgoCD pods, Application, Warehouse, Harbor)
```

---

## Step 9: Deploy Workloads (Welcome + Counter)

```bash
./install-workloads.sh
# Expected: ~2-3 minutes
# Deploys: Knative Service welcome, SpinApp counter,
#          patches welcome-route backend to actual ksvc
```

**Verify:**
```bash
# Get the Envoy LB IP
ENVOY_IP=$(kubectl -n envoy-gateway-system get gateway hpa-dev-gateway \
  -o jsonpath='{.status.addresses[0].value}')

./verify-workloads.sh --envoy-ip "$ENVOY_IP"
# Expected: All 6 phases PASS
# Phase 5 should show: "Welcome (N)" with status 200
# Phase 6 should show: counter-welcome key incrementing correctly
```

---

## Step 10: End-to-End Verification

```bash
# Manual curl test (incrementing counter)
curl http://$ENVOY_IP/api/welcome
# Expected: "Welcome (1)"
curl http://$ENVOY_IP/api/welcome
# Expected: "Welcome (2)"

# Headlamp dashboard
open http://$ENVOY_IP/admin
# Expected: Headlamp login page loads

# Playwright e2e tests (requires node_modules)
cd e2e
npm install
npx playwright test
# Expected: All 4 specs pass, including the 5-hit increment test
```

---

## Step 11: Idempotent Re-apply (test cleanup + re-bootstrap)

```bash
cd provisioning/scripts

# Cleanup
./cleanup.sh
# Expected: All resources removed, summary shows counts > 0

# Re-create from scratch
cd ../tofu-libvirt-dev
tofu apply -auto-approve

# Then re-run Steps 2-10
# Expected: Same outcome as first bootstrap
```

---

## Step 12: Tear Down

```bash
cd provisioning/scripts
./cleanup.sh
# Expected: All VMs destroyed, volumes deleted, network removed, configs cleaned
```

---

## Troubleshooting

### Ceph OSDs fail to come online
- Check that `/dev/vdb` exists on each worker: `kubectl exec -n rook-ceph deploy/rook-ceph-tools -- lsblk`
- Verify the deviceFilter in install-rook-ceph.sh matches (`^vdb$`)
- CephCluster can take 3-5 minutes to reach Ready phase — this is normal

### LoadBalancer IP not assigned
- Verify Cilium and the LB pool are healthy: `kubectl get ciliumloadbalancerippools`
- Check L2 announcement policy: `kubectl get ciliuml2announcementpolicies`
- Services must be in the LB pool CIDR range (192.168.122.208/28)

### Knative Service stays in "Unknown" state
- Check if Kourier is running: `kubectl -n kourier-system get pods`
- Verify the config-network ingress class setting: `kubectl -n knative-serving get cm config-network -o yaml`
- Knative might be waiting for a container image to resolve

### Harbor deployment stuck
- Check PVC binding: `kubectl -n harbor get pvc`
- Verify Ceph cluster is healthy: `kubectl -n rook-ceph get CephCluster`

### `tofu apply` times out
- Libvirt may need more time for VM creation. Re-run: `tofu apply -auto-approve`
- Check available disk space: `df -h` (each VM uses ~20 GB for OS disk)
- Check available RAM: `free -g` (4 VMs need at least 8 GB total for Talos)

---

## Architecture Overview

```
                    ┌─────────────────────────────────────┐
                    │      Envoy Gateway (L7 Ingress)      │
                    │  /api/welcome  │  /admin              │
                    └──────┬──────────┬────────────────────┘
                           │          │
              ┌────────────▼──┐  ┌────▼──────────┐
              │ Knative ksvc  │  │   Headlamp     │
              │   "welcome"   │  │  (K8s UI)      │
              │   Go binary   │  └───────────────┘
              │ port 8080     │
              └───────┬───────┘
                      │
              ┌───────▼───────┐
              │ SpinApp       │
              │  "counter"    │──── INCR/DECR ──► KeyDB (Redis-compatible)
              │ Rust/WASM     │                    key: counter-welcome
              │ port 8080     │
              └───────────────┘

  ┌──────────┬──────────┬──────────┬──────────┐
  │  CP-0    │ Worker-0  │ Worker-1  │ Worker-2 │  ← Talos Linux nodes
  │          │ /dev/vdb  │ /dev/vdb  │ /dev/vdb │  ← Ceph OSD disks
  └──────────┴──────────┴──────────┴──────────┘
       └────── hpa-bridge (192.168.122.0/24) ──────┘
              NAT forwarding via libvirt
```

### Component Layout

| Component | Namespace | Type | Storage |
|-----------|-----------|------|---------|
| Cilium | kube-system | DaemonSet | - |
| Rook operator | rook-ceph | Deployment | - |
| CephCluster | rook-ceph | StatefulSet | /dev/vdb per worker |
| Harbor | harbor | Deployment | ceph-rbd PVCs |
| Infisical | infisical | Deployment | ephemeral |
| cert-manager | cert-manager | Deployment | - |
| Knative Serving | knative-serving | Deployment | - |
| Kourier | kourier-system | Deployment | - |
| SpinKube | spin-operator | Deployment | - |
| KeyDB | keydb | Deployment | ceph-rbd PVC (1 Gi) |
| Envoy Gateway | envoy-gateway-system | DaemonSet | - |
| Headlamp | headlamp | Deployment | - |
| Kargo | kargo | Deployment | - |
| ArgoCD | argocd | Deployment | - |
| Welcome (ksvc) | hpa-workloads | Knative Service | - |
| Counter (SpinApp) | hpa-workloads | SpinApp | - |

---

## Verification Scripts Reference

| Script | Verifies | Requires Cluster? |
|--------|----------|-------------------|
| `verify-manifests.sh` | helm lint + kustomize build | No |
| `verify-cluster.sh` | Core cluster health | Yes |
| `verify-cilium.sh` | Cilium pods, LB pool, L2 policy | Yes |
| `verify-ceph.sh` | CephCluster, OSDs, StorageClass | Yes |
| `verify-harbor.sh` | Harbor pods, PVCs, LB IP | Yes |
| `verify-infisical.sh` | Infisical pods, Secrets Operator | Yes |
| `verify-runtimes.sh` | cert-manager, Knative, SpinKube, KeyDB | Yes |
| `verify-gateway.sh` | Envoy Gateway, HTTPRoutes, Headlamp | Yes |
| `verify-gitops.sh` | Kargo, ArgoCD, Warehouse, Application | Yes |
| `verify-workloads.sh` | Welcome ksvc, counter SpinApp, HTTPRoute, endpoint, KeyDB | Yes |

---

## File Structure

```
provisioning/
├── scripts/
│   ├── setup-bridge.sh          # Create hpa-bridge libvirt network
│   ├── cleanup.sh               # Destroy everything (VMs, volumes, network)
│   ├── install-cilium.sh        # Cilium CNI + LB pool
│   ├── install-rook-ceph.sh     # Rook Ceph operator + CephCluster
│   ├── install-harbor.sh        # Harbor registry
│   ├── install-infisical.sh     # Infisical + Secrets Operator
│   ├── install-runtimes.sh      # cert-manager, Knative, SpinKube, KeyDB
│   ├── install-gateway.sh       # Envoy Gateway + Headlamp + HTTPRoutes
│   ├── install-gitops.sh        # Kargo + ArgoCD + Warehouse + Application
│   ├── install-workloads.sh     # Welcome ksvc + counter SpinApp
│   ├── verify-manifests.sh      # Static manifest validation (no cluster)
│   ├── verify-cluster.sh        # Cluster health
│   ├── verify-cilium.sh         # Cilium health
│   ├── verify-ceph.sh           # Ceph health
│   ├── verify-harbor.sh         # Harbor health
│   ├── verify-infisical.sh      # Infisical health
│   ├── verify-runtimes.sh       # Runtimes health
│   ├── verify-gateway.sh        # Gateway health
│   ├── verify-gitops.sh         # GitOps health
│   └── verify-workloads.sh      # Workloads health
├── tofu-libvirt-dev/
│   ├── main.tf                  # OpenTofu module: VMs, disks, network
│   ├── variables.tf             # VM configuration variables
│   ├── outputs.tf               # kubeconfig, talosconfig, IPs
│   └── ...
gitops-workloads/
└── functions/overlays/dev/
    ├── kustomization.yaml
    ├── welcome-ksvc.yaml        # Welcome Knative Service
    ├── backend/spins/counter/counter.yaml   # Counter SpinApp
    ├── infisical-secret.yaml    # Infisical-managed secrets
    └── ...
```
