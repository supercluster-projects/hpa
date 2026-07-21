# HPA Enterprise GitOps Platform

A comprehensive DevOps platform implementing **Progressive Delivery with Backstage, Kargo, and Argo CD** on Talos Linux VMs running on KVM/libvirt.

**Quick Start:** See [Running and Testing](#running-and-testing) section below.

---

## 📁 Script Organization

The provisioning scripts are organized into a structured directory layout:

```
provisioning/dev/scripts/
├── startup.sh              # Single entry point for full bootstrap
├── misc/                   # Supporting scripts (environment setup, cleanup, etc.)
│   ├── preamble.sh         # Shared bootstrapping functions
│   ├── env-common.sh       # Centralized environment variables
│   ├── cleanup*.sh         # Cleanup and preflight scripts
│   ├── run-pipeline.sh     # Resilient pipeline runner
│   └── verify-*.sh         # Verification scripts
└── steps/                  # Pipeline step folders (numbered by execution order)
    ├── step-01-bridge-setup/
    ├── step-02-cilium/
    ├── step-03-harbor/
    ├── step-04-infisical/
    ├── step-05-runtimes/
    ├── step-06-kafka/
    ├── step-07-spegel/
    ├── step-08-casdoor/
    ├── step-09-casbin/
    ├── step-10-gateway/
    ├── step-11-security-policy/
    ├── step-12-gitops/
    ├── step-13-workloads/
    ├── step-14-streaming-workload/
    ├── step-15-infisical-workloads/
    ├── step-16-yugabytedb/
    ├── step-17-hasura/
    ├── step-18-vm-single/
    ├── step-19-vmagent/
    ├── step-20-kube-state-metrics/
    ├── step-21-grafana/
    ├── step-22-alertmanager/
    ├── step-23-tls/
    ├── step-24-couchdb/
    └── step-25-seed-hydration/
```

Each step folder contains scripts named by execution order:
- `01-*-sh` - Primary installation script
- `02-*-sh` - Verification script (if applicable)

---

## 📚 Table of Contents

1. [Running and Testing](#running-and-testing)
2. [Quickstart Guide](#quickstart-guide)
3. [Implementation Plan](#implementation-plan)
4. [Improvements & Best Practices](#improvements--best-practices)
5. [Architecture](#architecture)
6. [Contributing](#contributing)

---

## ▶️ Running and Testing

This guide provides precise, step-by-step instructions on running, testing, and verifying the HPA Enterprise GitOps Platform on your local workstation. The platform boots a high-parity local Kubernetes cluster on **LibVirt/QEMU virtual machines**, orchestrates secrets, CNI networks, and storage, and executes progressive delivery with **Backstage, Kargo, and Argo CD**.

### 1. System Prerequisites

Ensure your host machine has the following packages pre-installed:

- **Hypervisor:** QEMU/KVM with the `libvirtd` system service active
- **Virtualization Client:** `virsh` (part of libvirt-clients)
- **Infrastructure as Code:** OpenTofu (v1.6+) or Terraform (v1.5+)
- **Platform Engines:** Helm (v3.x) and `kubectl`
- **Node Control:** `talosctl` (for managing Talos OS virtual machines)

### 2. Environment Configuration

1. Copy the environment template to create your `.env` file:
   ```bash
   cp .env.example .env
   ```

2. Fill in the private keys and endpoints. The environment configurations are automatically loaded by the bootstrapping scripts.

3. **Local GitOps Configuration (`GITOPS_REPO_URL`):**
   For local-only offline operations, configure the `GITOPS_REPO_URL` variable inside your `.env` file to point to the local Git Daemon broadcast address:
   ```env
   GITOPS_REPO_URL=git://192.168.122.1/with-gsd
   ```
   This redirects the platform bootstrapping pipeline to sync manifests from your host machine's filesystem.

4. **Offline Mode Configuration:**
   The platform operates in **offline-first mode by default**. The `.env.example` contains `OFFLINE_MODE=true`:
   - Bootstrap images (etcd, kube-apiserver, kubelet, etc.) are pre-seeded to the local registry
   - Containerd is configured to use registry mirrors for offline image pulls
   - To disable offline mode (use internet), set `OFFLINE_MODE=false`

### 3. Bootstrapping the LibVirt Dev Cluster

All operations are automated using shell scripts in `provisioning/dev/scripts/`.

#### Step 3.1: Run Host Pre-flight Audits
Validate that your hypervisor, groups, and virtualization limits are compliant:
```bash
bash provisioning/dev/scripts/host-preflight.sh
```

#### Step 3.2: Recreate the Host Bridge Network
To guarantee deterministic static DHCP leases:
```bash
bash provisioning/dev/scripts/setup-bridge.sh
```

#### Step 3.3: Pre-Cache Talos OS Images
Download and pre-stage the cached Talos OS `qcow2` image:
```bash
bash provisioning/dev/scripts/prep-cache.sh
```

#### Step 3.4: Seed Bootstrap Images (AUTO-RUN)
The bootstrapping process **automatically seeds** all Kubernetes bootstrap images (etcd, kube-apiserver, kubelet, etc.) to the local registry at `192.168.122.1:5000` before OpenTofu applies. This enables true offline bootstrap capability.

#### Step 3.5: Provision VMs & Deploy Platform
```bash
bash provisioning/dev/scripts/startup.sh
```
*Verification during run:* Watch the live progress table. Each step is validated immediately and will fail-fast if checks deviate.

#### Offline-First Architecture

The platform operates in **offline-first mode by default** (`OFFLINE_MODE=true`). This means:

1. **Bootstrap images pre-seeded** - All Kubernetes control plane images (etcd, kube-apiserver, kube-controller-manager, kube-scheduler, kubelet) are cached locally
2. **Registry mirrors configured** - Containerd is configured to redirect `registry.k8s.io` and `ghcr.io` pulls to the local registry
3. **No internet dependency** - The cluster can bootstrap complete without any outbound connectivity

To temporarily use internet access instead, set `OFFLINE_MODE=false` in `.env` before running `startup.sh`.

##### Pre-Bootstrap Caching Requirements

For reliable offline bootstrap, ensure these components are pre-seeded:

**1. Talos ISO Image:**
```bash
# Download Talos install ISO (required for first-boot installation)
sudo mkdir -p /var/lib/libvirt/images
curl -L -o /var/lib/libvirt/images/talos-install.iso \
  "https://factory.talos.dev/image/<schematic-id>/v1.13.5/metal-amd64.iso"
```

**2. Talos Cache Image:**
```bash
# The cached Talos base image (used for all VMs)
# This should be in the .cache directory
ls -la /home/cores/Documents/Projects/Study/HPA/with-gsd/.cache/talos-*.qcow2
```

**3. Bootstrap Images in Local Registry:**
```bash
# Verify registry has all required images
curl -s http://192.168.122.1:5000/v2/_catalog
# Expected: etcd, kube-apiserver, kube-controller-manager, kube-scheduler, kubelet
```

##### Cache Handling

The bootstrap process handles caching intelligently:

- **Talos ISO**: Preserved if exists on disk - only re-downloaded if missing
- **Cache Image**: The source file at `.cache/talos-*.qcow2` is never deleted. If a stale volume exists, it's removed so tofu can recreate from the cache
- **Bootstrap Images**: Only pushed if digest differs (comparison via registry API)

### 4. Verifying Core Cluster State

Once `startup.sh` completes:

#### Verify Kubernetes Node Health
```bash
bash provisioning/dev/scripts/verify-cluster.sh --kubeconfig provisioning/dev/opentofu/kubeconfig
```

#### Verify eBPF Interface Enforcements
```bash
bash provisioning/dev/scripts/verify-cilium.sh --kubeconfig provisioning/dev/opentofu/kubeconfig
```

---

### Interactive Bootstrapping

The `startup.sh` script now supports **interactive mode** where you can control which steps execute:

```bash
./provisioning/dev/scripts/startup.sh
```

After each step completes, you'll see:

```
========================================
Step 0: Setup hpa-bridge network
  Status: DONE
========================================

>>> Verification Results:
     Network is active

========================================
  OPTIONS:
    E/e  - Execute next step
    S/s  - Skip next step
    R/r  - View recent results table
    Q/q  - Quit script
========================================
Choose (E Execute/S Skip/R Results/Q Quit): 
```

**Step Execution Flow:**
1. **Steps 0-1** (Bridge setup and verification) run automatically - they're required
2. **Step 2** (OpenTofu provisioning) prompts before starting - it can take 30-60 minutes
3. **Subsequent steps** prompt after each completion with results

**Results Table:**
Press `R` at any prompt to view the step results summary:
```
  Step | Name                              | Status  | Details
  -----|-----------------------------------|---------|-------
  Install Cilium CNI                    | SUCCESS | pods healthy
  Install Rook Ceph                     | SUCCESS | 3 OSDs ready
  ...
```

### Non-Interactive Mode

For automated environments (CI/CD), use batch mode:

```bash
# Run with auto-confirm (all steps execute)
yes | ./provisioning/dev/scripts/startup.sh
```

---

## ⚡ Quickstart Guide

This guide walks through the complete bootstrap of a 4-node Talos Kubernetes dev cluster on KVM/libvirt.

**Total time:** ~60-90 minutes

### Installation

1. Install prerequisites:
   ```bash
   # OpenTofu
   # See https://opentofu.org/docs/intro/install/
   
   # talosctl
   curl -sL https://talos.dev/install | sh
   
   # Helm, kubectl, kustomize, curl
   # Verify installation:
   for cmd in tofu talosctl helm kubectl kustomize curl; do
     command -v $cmd && echo "  $cmd: $($cmd --version 2>/dev/null | head -1)" || echo "  MISSING: $cmd"
   done
   ```

2. Configure environment:
   ```bash
   cp .env.example .env
   # Edit .env - set GITOPS_REPO_URL
   ```

3. Provision OpenTofu infrastructure:
   ```bash
   cd provisioning/dev/opentofu
   tofu init
   tofu plan
   tofu apply -auto-approve
   ```

### Bootstrap Steps

| Step | Task | Script |
|------|------|--------|
| 1 | Provision Talos VMs | `tofu apply` |
| 2 | Setup hpa-bridge network | `setup-bridge.sh` |
| 3 | Seed bootstrap images to local registry | `bootstrap-harbor.sh` (auto-run) |
| 4 | Install Cilium CNI | `install-cilium.sh` |
| 5 | Install Rook Ceph | `install-rook-ceph.sh` |
| 6 | Install Harbor/Infisical | `install-harbor.sh`, `install-infisical.sh` |
| 7 | Install Runtimes | `install-runtimes.sh` |
| 8 | Install Envoy Gateway | `install-gateway.sh` |
| 9 | Install GitOps Pipeline | `install-gitops.sh` |
| 10 | Deploy Workloads | `install-workloads.sh` |

**Note:** Step 3 (Seeding) runs automatically before tofu apply in offline mode. The `OFFLINE_MODE=true` is the default in `.env.example`.

### Verification Scripts

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
| `verify-workloads.sh` | Welcome ksvc, counter SpinApp | Yes |

---

## 📋 Implementation Plan

### Enterprise GitOps Platform Implementation Plan

Automated Hub-and-Spoke Fleet Deployment with Backstage, Kargo, and Argo CD.

The roadmap is structured into **5 sequential Milestones**, each divided into slices, tasks, and concrete verification tests.

**Core Testing Mandate:** On every test run, the cluster must be completely recreated first (Fresh Environment Guarantee).

### Milestone 1 (M1): Foundations & Hub Cluster Setup

| Task | Description | Status |
|------|-------------|--------|
| M1.1.1 | Provision Management Hub Cluster | ✅ Done |
| M1.2.1 | Create platform-infra-fleet repo | ✅ Done |
| M1.3.1 | Deploy Argo CD HA mode | ✅ Done |

**Verification:**
1. Argo CD pods running: `kubectl get pods -n argocd`
2. Cluster connectivity: `argocd cluster list` - reports `Successful`

### Milestone 2 (M2): Progressive Delivery with Kargo

| Task | Description | Status |
|------|-------------|--------|
| M2.1.1 | Deploy Kargo Operator | ✅ Done |
| M2.2.1 | Create Warehouse resources | ✅ Done |
| M2.3.1 | Define automated promotion policies | ✅ Done |

**Verification:**
1. Pipeline health: `kargo get stages` and `kargo get warehouses`
2. Promotion test: Build v1.2.3, verify auto-promotion

### Milestone 3 (M3): Backstage IDP Portal Integration

| Task | Description | Status |
|------|-------------|--------|
| M3.1.1 | Build customized Backstage Docker image | ✅ Done |
| M3.2.1 | Design "Secure Go Microservice" template | ✅ Done |
| M3.3.1 | Integrate Argo CD plugin | ✅ Done |

**Verification:**
1. API check: `curl http://backstage.internal/api/catalog/entities` → HTTP 200
2. Self-service test: Scaffolding creates repo, Argo CD deploys, status shows Healthy

### Milestone 4 (M4): Platform Parity & Observability Loop

| Task | Description | Status |
|------|-------------|--------|
| M4.1.1 | Deploy Infisical Secrets Operator | ✅ Done |
| M4.2.1 | Standardize Cilium kubeProxyReplacement | ✅ Done |
| M4.3.3 | Design Argo AnalysisTemplate | ✅ Done |

**Verification:**
1. eBPF check: `kubectl exec -n kube-system ds/cilium -- cilium status --verbose`
2. Dynamic secrets: `kubectl get secrets -n target-app` matches Infisical
3. Canary rollback: Buggy deploy → VictoriaMetrics spike → automatic rollback

### Milestone 5 (M5): E2E Validation & Fleet Scaling

| Task | Description | Status |
|------|-------------|--------|
| M5.1.1 | Configure Argo CD ApplicationSet | ✅ Done |
| M5.2.1 | Execute developer simulation | ✅ Done |
| M5.2.3 | Measure platform latency | ✅ Done |

**Verification:**
1. Dynamic fleet bootstrap: Add new spoke-3.json → ApplicationSet picks up
2. Security gate test: Unsigned image deployment blocked by Kyverno/OPA

---

## 🛠️ Improvements & Best Practices

### Critical Security Fixes

| # | Issue | Status | Verification |
|---|-------|--------|--------------|
| 1 | Remove terraform state files from repo | ✅ Completed | `.gitignore` excludes `*.tfstate` |
| 2 | Remove `.env.backup` from repo | ✅ Completed | File not tracked |

### High Priority Items

| # | Area | Item | Status |
|---|------|------|--------|
| 3 | Config | Centralize network configuration | ✅ Completed |
| 4 | CI/CD | Add CI workflow for validation | ⏳ Pending |
| 5 | Docs | Organize documentation structure | ✅ Completed |

### Medium Priority Items

| # | Area | Item | Status |
|---|------|------|--------|
| 6 | Code | Add resource limits to deployments | ⏳ In Progress |
| 7 | Testing | Add coverage reporting | ✅ Completed |
| 8 | Testing | Add test artifacts to gitignore | ✅ Completed |

### Low Priority Items

| # | Area | Item | Status |
|---|------|------|--------|
| 10 | Tooling | Add Makefile for common tasks | ⏳ Incomplete |
| 11 | Docs | Add architecture diagram | ⏳ Pending |

---

## 🔧 DRY Improvements Implemented

### M1: Terraform Configuration DRY ✅

- **Task M1.1:** Created `provisioning/dev/opentofu/network-variables.tf` - centralized network configuration
- **Task M1.2:** Updated `main.tf` and `cluster-config.yaml.tftpl` for template interpolation

### M2: Shell Scripts DRY ✅

- **Task M2.1:** Created `provisioning/dev/scripts/env-common.sh`
- **Updated:** `preamble.sh`, `setup-host.sh` to use environment variables

### M3: Kubernetes Manifests DRY ✅

- **Task M3.1:** Created `gitops-workloads/base/kustomization.yaml` with common labels
- **Updated:** Various kustomization files for standardized annotations

### M4: Go Application DRY ✅

- **Task M4.1:** Created `backend/internal/config/config.go` with centralized constants
- **Updated:** `backend/functions/welcome/main.go` with graceful shutdown, health checks

### M5: Rust Application DRY ✅

- **Task M5.1:** Created `backend/spins/counter/src/constants.rs`
- **Updated:** `backend/spins/counter/src/lib.rs` to import constants

### Verification Script

```bash
bash scripts/verify-dry-changes.sh
```

---

## 📦 Offline Bootstrap Caching

### Overview

For offline deployment, use the caching script:

```bash
# Run from an internet-connected machine before offline deployment
./provisioning/dev/scripts/cache-offline-components.sh \
  --output-dir /path/to/offline-cache \
  --parallel 8
```

### Cache Contents

| Component | Location | Description |
|-----------|----------|-------------|
| Talos Image | `/tmp/offline-cache/talos-images/` | QEMU/KVM compatible Talos qcow2 |
| OpenTofu Providers | `/tmp/offline-cache/tofu-providers/` | Libvirt and Talos providers |
| Helm Charts | `/tmp/offline-cache/helm-charts/` | Cilium, ArgoCD, Kargo, etc. |
| Container Images | `/tmp/offline-cache/container-images/` | All OCI images as .tar files |

### Offline Deployment Steps

1. Prepare cache package (online machine):
   ```bash
   ./provisioning/dev/scripts/cache-offline-components.sh --output-dir /media/seed-package
   ```

2. Copy package to offline target

3. Configure offline mode:
   ```bash
   export DEV_TALOS_IMAGE_FACTORY_URL=file:///media/seed-package/talos-images
   tofu providers mirror /media/seed-package/tofu-providers
   for img in /media/seed-package/container-images/*/*.tar; do docker load < "$img"; done
   ```

4. Run bootstrap:
   ```bash
   export SEED_DIR=/media/seed-package
   bash provisioning/dev/scripts/startup.sh
   ```

---

## 🧪 Testing Strategy

```bash
# Terraform validation
cd provisioning/dev/opentofu && terraform fmt -check && terraform validate

# Go build and test
cd backend && go build ./... && go test -v -cover -coverprofile=coverage.out

# Rust validation
cargo check && cargo clippy

# Shell script syntax check
bash -n provisioning/dev/scripts/*.sh

# Comprehensive DRY verification
bash scripts/verify-dry-changes.sh
```

---

## 🗂️ File Structure

```
provisioning/
├── dev/
│   ├── opentofu/
│   │   ├── main.tf                  # OpenTofu module: VMs, disks, network
│   │   ├── variables.tf             # VM configuration variables
│   │   ├── outputs.tf               # kubeconfig, talosconfig, IPs
│   │   └── ...
│   └── scripts/
│       ├── setup-bridge.sh          # Create hpa-bridge libvirt network
│       ├── cleanup.sh               # Destroy everything
│       ├── install-*.sh             # Installation scripts
│       ├── verify-*.sh              # Verification scripts
│       └── ...
gitops-workloads/
└── functions/overlays/dev/
    ├── kustomization.yaml
    ├── functions/welcome.yaml       # Welcome Knative Service
    ├── spins/counter.yaml           # Counter SpinApp
    └── ...
backend/
├── internal/config/config.go        # Centralized Go constants
├── functions/welcome/               # Welcome function
└── spins/counter/                   # Counter Rust application
```

---

## 🏗️ Architecture: Hub-and-Spoke Fleet Management

The platform implements a **Hub-and-Spoke topology** with the Management Plane (Hub) orchestrating Workload Planes across environments.

### High-Level Architecture

```
       ┌────────────────────────────────────────────────────────┐
       │                 DEVELOPER WORKSTATION                  │
       │  (Backstage Developer Portal / Local LibVirt Cluster)  │
       └─────────────────────────┬──────────────────────────────┘
                                 │
                                 ▼
       ┌────────────────────────────────────────────────────────┐
       │             MANAGEMENT PLANE (HUB CLUSTER)             │
       │    [Kargo Control Plane]  [Argo CD Fleet Orchestrator] │
       └───────────┬─────────────────────────────┬──────────────┘
                   │                             │
                   ▼ (Spoke Sync)                ▼ (Spoke Sync)
┌──────────────────────────────────────┐  ┌──────────────────────────────────────┐
│       STAGING SPOKE CLUSTER          │  │     PRODUCTION FLEET SPOKES          │
│ [Argo Agent] [Cilium] [Rook Ceph]    │  │ [Argo Agent] [Cilium] [Rook Ceph]    │
└──────────────────────────────────────┘  └──────────────────────────────────────┘
```

### Local Dev Cluster vs Production Spokes

| Stage | Dev Hypervisor (LibVirt/QEMU) | Production Spokes (AWS/On-Prem) |
|-------|------------------------------|--------------------------------|
| **Control Plane** | Local workstation CLI / `startup.sh` | Central Backstage Hub Cluster |
| **CNI** | Cilium (kube-proxy-free, eth0 config) | Cilium (kube-proxy-free, eth0/elastic interface) |
| **Storage** | Rook Ceph (attached sparse virtual disks) | Rook Ceph (attached EBS/Physical NVMe disks) |
| **Secrets** | Local Infisical Operator | Enterprise Vault / Infisical Multi-Region |
| **GitOps** | Argo CD (Adoption / local cluster) | Argo CD + Kargo (Multi-cluster fleet) |

### Developer Workflow

1. **Golden Path Bootstrapping** → Developer selects template in Backstage → Repository auto-created with GitOps wiring
2. **Code Development** → Local LibVirt Talos cluster for high-fidelity testing
3. **CI Pipeline** → Build → Harbor secure scanning → Image signing
4. **Progressive Delivery** → Click "Promote" in Backstage → Kargo promotion → Argo CD sync waves
5. **Observability** → VictoriaMetrics + Backstage dashboard → Canary analysis → Auto rollback

---

## 🎨 Architecture Overview

### Component Architecture

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
              │  "counter"    │──── INCR/DECR ──► KeyDB
              │ Rust/WASM     │                    key: counter-welcome
              │ port 8080     │
              └───────────────┘

  ┌──────────┬──────────┬──────────┬──────────┐
  │  CP-0    │ Worker-0 │ Worker-1 │ Worker-2 │  ← Talos Linux nodes
  │          │ /dev/vdb │ /dev/vdb │ /dev/vdb │  ← Ceph OSD disks
  └──────────┴──────────┴──────────┴──────────┘
       └────── hpa-bridge (192.168.122.0/24) ──────┘
              NAT forwarding via libvirt
```

---

## 🛠️ Platform Components

### Developer Portal & Delivery Orchestration

1. **Backstage (Internal Developer Portal)** - Central UI and DevEx layer with Software Catalog, Golden Path Templates, and native monitoring dashboards
2. **Kargo (Progressive Delivery Engine)** - Kubernetes-native promotion coordinator modeling pipelines as declarative stages (dev → staging → prod)
3. **Argo CD (GitOps Engine)** - Continuous reconciliation loop observing Git and auto-healing cluster state

### Core Platform Services

4. **Cilium CNI** - eBPF-powered networking, routing, and security with `kubeProxyReplacement=true` mode
   - L2 Announcements with `192.168.122.208/28` LB pool
   - `CiliumNodeConfig` for predictable eBPF datapath binding
5. **Rook Ceph** - Dynamic persistent block/file storage via CSI (`ceph-rbd`) for stateful apps
6. **Harbor** - Local secure OCI registry with vulnerability scanning and Cosign signing
7. **Infisical** - Central secret management with Kubernetes Operator injection
8. **Spegel** - P2P registry mirror for caching container images locally
9. **VictoriaMetrics** - High-performance TSDB for metrics collected by `vmagent`, powering canary analysis

### Infrastructure

- **OpenTofu** - QEMU/KVM VM provisioning with declarative infrastructure code
- **Talos Linux** - Kubernetes-native OS with `kube-proxy-free` configuration via Cilium CNI
- **KeyDB** - Redis-compatible in-memory database for counter state

---

## 📖 Key Features

### 1. GitOps with Argo CD
- Automated sync from Git repositories to clusters
- Multi-cluster fleet management via ApplicationSets
- Drift detection and auto-reconciliation with sync waves

### 2. Progressive Delivery with Kargo
- Warehouse pattern for artifact detection from Harbor
- Multi-stage promotion (dev → staging → production)
- Metric-analyzed canary rollouts with VictoriaMetrics
- Automatic git-backed rollback on anomaly detection

### 3. Developer Self-Service with Backstage
- Golden Path templates for Go microservices
- Integrated Argo CD plugin for deployment status in catalog
- Policy-as-code with OPA/Kyverno enforcement
- Argo Rollouts tab for canary visualization

### 4. Infrastructure Automation
- OpenTofu for libvirt/QEMU VM provisioning
- Talos Linux for Kubernetes-native infrastructure
- Cilium CNI with ClusterMesh for multi-cluster networking
- Rook Ceph for dynamic persistent storage

---

## 🔄 Cleanup & Teardown

To stop VMs, delete hypervisor resources, and restore host integrity:

```bash
bash provisioning/dev/scripts/cleanup.sh
```

---

## 🤝 Contributing

Thank you for your interest in contributing to the HPA Enterprise GitOps Platform!

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Coding Standards](#coding-standards)
- [Commit Guidelines](#commit-guidelines)
- [Pull Request Process](#pull-request-process)
- [Testing](#testing)
- [CI/CD Pipeline](#cicd-pipeline)

## Code of Conduct

This project follows the [Kubernetes Community Code of Conduct](https://github.com/kubernetes/community/blob/master/code-of-conduct.md).

## Getting Started

1. Fork the repository
2. Clone your fork locally:
   ```bash
   git clone https://github.com/your-org/platform-infra-fleet.git
   cd platform-infra-fleet
   ```

3. Create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```

## Development Setup

### Prerequisites

- [Terraform 1.5+](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-terraform)
- [Go 1.21+](https://go.dev/doc/install)
- [Rust/Cargo 1.70+](https://www.rust-lang.org/tools/install)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Make](https://www.gnu.org/software/make/) (optional, for convenience)

### Install Dependencies

```bash
# Install Go dependencies
cd backend
go mod download

# Install Rust dependencies (if applicable)
cd backend/spins/counter
cargo fetch
```

## Project Structure

```
.
├── provisioning/              # OpenTofu/Terraform infrastructure as code
│   └── dev/opentofu/          # Development cluster definitions
├── gitops-workloads/          # Kubernetes manifests (GitOps)
│   ├── authorizers/           # Authorization services
│   ├── functions/             # Knative services and SpinApps
│   ├── security/              # Security policies (PodSecurity, NetworkPolicies)
│   └── kafka/                 # Kafka infrastructure
├── backend/                   # Backend services
│   ├── functions/           # Go HTTP handlers
│   └── spins/               # Rust Spin applications
├── scripts/                   # Utility scripts
└── docs/                      # Documentation
```

## Coding Standards

### Go

- Follow [Go Code Examples](https://go.dev/doc/code)
- Use `go fmt` and `go vet` before committing
- Use structured logging (`log/slog`) for all new code
- Prefer context propagation for all operations
- Write unit tests with coverage for all new functions

```go
// Good: Structured logging with slog
slog.Info("counter incremented", "count", count, "service", counterAddr)

// Good: Context propagation
func fetchCounter(ctx context.Context, addr string) (int, error) {
    req, err := http.NewRequestWithContext(ctx, http.MethodGet, addr, nil)
    // ...
}
```

### Terraform

- Centralize variables in `network-variables.tf` or `variables.tf`
- Use locals for computed values
- Follow [Terraform Style Guide](https://developer.hashicorp.com/terraform/tutorials/configuration-language/format)
- Validate with `terraform fmt -check` and `terraform validate`

### YAML/Kubernetes

- Always include `app.kubernetes.io` labels:
  ```yaml
  metadata:
    labels:
      app.kubernetes.io/name: <component>
      app.kubernetes.io/instance: <service>
      app.kubernetes.io/component: <type>
      app.kubernetes.io/part-of: hpa-platform
      app.kubernetes.io/managed-by: argocd
  ```
- Add resource requests and limits to all containers
- Configure liveness and readiness probes for all services

## Commit Guidelines

- Write clear, descriptive commit messages
- Use imperative mood ("Add feature" not "Added feature")
- Reference issues and PRs when applicable
- Keep commits atomic and focused

Example:
```
Add health probes to casbin authorization service

- Configure liveness probe using grpc_health_probe
- Add readiness probe for traffic routing
- Set appropriate initial delays and thresholds
```

## Pull Request Process

1. Create a pull request against the `main` branch
2. Ensure all CI checks pass
3. Get at least one approval from a maintainer
4. Resolve all review comments
5. Squash and merge (or use merge commit as appropriate)

### CI Requirements

Your PR will be tested against the following:

- **Terraform Validation**: `terraform fmt -check`, `terraform validate`
- **Go Tests**: `go test -v -cover`
- **Shell Script Linting**: `shellcheck` and `bash -n`
- **Kubernetes Manifest Validation**: YAML syntax check
- **DRY Verification**: `scripts/verify-dry-changes.sh`

## Testing

### Run All Tests

```bash
# Run all tests
make test

# Run specific tests
make go-test
make terraform-validate
```

### Test Coverage

- Generate coverage report:
  ```bash
  make test-coverage
  ```

- Coverage should be maintained or improved for existing functionality

### Local Environment Testing

```bash
# Validate Terraform
cd provisioning/dev/opentofu && terraform init -backend=false
terraform fmt -check -recursive
terraform validate

# Run Go tests
cd backend/functions/welcome
go test -v -cover

# Validate shell scripts
bash -n provisioning/dev/scripts/*.sh
```

## CI/CD Pipeline

The project uses GitLab CI for automated testing and validation. The pipeline includes:

1. **terraform-validate**: Validates OpenTofu/Terraform configuration
2. **go-test**: Runs Go unit tests with coverage reporting
3. **go-lint**: Runs `go vet` for code quality
4. **shell-lint**: Validates shell scripts with `shellcheck`
5. **k8s-validate**: Validates Kubernetes manifest syntax
6. **secret-scan**: Scans for potential hardcoded secrets
7. **dry-verify**: Verifies DRY compliance across the codebase

---

## 🚨 Troubleshooting

### Startup Script Shows "kubeconfig already exists — skipping tofu apply"

This occurs when:
1. A previous kubeconfig file exists but the cluster is not healthy
2. The cleanup script removed VMs but kubeconfig was not cleaned up

**Solution:**
```bash
# Remove stale kubeconfig before running fresh bootstrap
rm -f provisioning/dev/opentofu/kubeconfig
bash provisioning/dev/scripts/startup.sh
```

### No VMs are Created During Bootstrap

Check these common issues:

1. **Talos ISO not available:**
   ```bash
   ls -la /var/lib/libvirt/images/talos-install.iso
   ```
   Download if missing: `curl -L -o /var/lib/libvirt/images/talos-install.iso "https://factory.talos.dev/image/<schematic-id>/v1.13.5/metal-amd64.iso"`

2. **Base image not cached:**
   ```bash
   ls -la /home/cores/Documents/Projects/Study/HPA/with-gsd/.cache/talos-*.qcow2
   ```

3. **Libvirt daemon issues:**
   ```bash
   virsh -c qemu:///system list
   sudo systemctl status libvirtd
   ```

### Registry Images Not Being Used

Verify the local registry has all bootstrap images:

```bash
# Check catalog
curl -s http://192.168.122.1:5000/v2/_catalog

# Seed images manually if needed
bash provisioning/dev/scripts/bootstrap-harbor.sh --host
```

### Offline Mode Not Working

If the cluster tries to pull images from the internet:

1. Verify `OFFLINE_MODE=true` in `.env`
2. Check containerd mirror configuration in Talos machine config
3. Verify registry is accessible from VMs

---

## 🔐 Security

### Protected Branches

- `main`: Production-ready code (protected)
- Merge requests require passing CI and approval

### Merge Strategies

- Use ** squash and merge** for feature branches
- Use **merge commit** for long-running branches with significant history

## Security

### Reporting Security Issues

Do not open public issues for security vulnerabilities. Email the maintainers directly.

### Security Best Practices

- Never commit secrets or credentials
- Use `.env` files for local development (not tracked)
- Rotate secrets regularly
- Review `.gitignore` before major changes

## Questions?

Reach out to the team via:
- GitHub Issues (for bugs and feature requests)
- Team Slack/Discord (for discussions)

Thank you for contributing! 🎉

---

## 📖 Related Documentation

- `docs/` - Architecture diagrams, technical specifications
- `platform-infra-fleet/` - Gitops workloads repository