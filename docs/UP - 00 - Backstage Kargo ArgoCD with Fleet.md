# UP-00: Enterprise GitOps Architecture & Developer Portal Integration
## Unified Fleet Management with Backstage, Kargo, and Argo CD (Dev to Production)

This document provides a comprehensive blueprint of the HPA Enterprise Platform Architecture, mapping how developers interact with the platform, detailing each component, and specifying how the system transitions seamlessly from a **local high-fidelity LibVirt (QEMU) development cluster** to a **highly scalable multi-cluster production fleet**.

---

## 1. High-Level Architectural Topology

The platform separates the **Management Plane** (the control center) from the **Workload Planes** (where applications run) using a Hub-and-Spoke topology.

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

---

## 2. Infrastructure Foundations: Dev vs. Production

To maintain parity and predictability across environments, the core platform components (CNI, Storage, Secrets, Registries) remain identical, while the underlying physical runtime scales appropriately:

### A. Local Dev Cluster (Local LibVirt / QEMU)
*   **Provisioning Engine:** OpenTofu (infrastructure code) coupled with declarative `setup-bridge.sh` shell scripts.
*   **VM Runtime:** Four QEMU/KVM virtual machines managed by `libvirtd` (1 Control Plane, 3 Workers) booted from customized, cached Talos OS `qcow2` images.
*   **Networking (`S01`):** Host-level `hpa-bridge` virtual network configured with **deterministic static DHCP leases** mapped to deterministic VM MAC addresses. This ensures predictable IPs (`.100` for CP, `.110+` for Workers) matching Talos bootstrap and `apply` manifests.
*   **Persistent Storage (`S01`):** Direct file-backed raw sparse disks (`/var/lib/libvirt/images/ceph-disks/`) attached to worker VMs to support Rook-Ceph persistently across cluster rebuilds.

### B. Production Spoke Clusters
*   **Provisioning Engine:** Cluster API (CAPI) on-premises or Terraform module blueprints targeting cloud resources (EKS, AKS, GKE) or bare-metal hypervisors.
*   **VM Runtime:** Cloud-provider instances (e.g., AWS EC2) or bare-metal physical servers.
*   **Networking:** Cloud-native VPC subnets with integrated load balancers or BGP fabric.

---

## 3. Component-by-Component Description

The architecture is built from best-of-breed cloud-native (CNCF) platforms. Each component has a designated structural responsibility:

### Developer Portal & Delivery Orchestration
1.  **Backstage (Internal Developer Portal):**
    The central UI and Developer Experience (DevEx) layer. Host to the **Software Catalog**, **Golden Path Templates**, and native monitoring dashboards. It abstracts platform API complexities and acts as the developer's "single pane of glass."
2.  **Kargo (Lifecycle & Promotion Engine):**
    A Kubernetes-native progressive delivery and release promotion coordinator. Kargo models promotion pipelines as declarative stages (e.g., `dev` $\rightarrow$ `staging` $\rightarrow$ `prod`) and automates safe, git-backed, and metric-analyzed transitions.
3.  **Argo CD (GitOps Execution Engine):**
    The continuous reconciliation loop. It observes Git repositories and forces the target Kubernetes clusters to match the declared state, automatically healing any drift or unauthorized manual modification.

### Core Platform Services
4.  **Cilium CNI (kube-proxy-free Networking & L2 LoadBalancer - `S03`):**
    eBPF-powered Kubernetes network, routing, and security. Operating in `kubeProxyReplacement=true` mode, it replaces iptables completely for high-performance service routing.
    *   *Dev configuration:* A `CiliumNodeConfig` called `hpa-dev-node-config` is applied to select the `eth0` device on all nodes, ensuring predictable eBPF datapath binding.
    *   *L2 Announcements:* Deploys `CiliumL2AnnouncementPolicy` and `CiliumLoadBalancerIPPool` (e.g. `192.168.122.208/28`) to act as a local, lightweight hardware load balancer fallback for development.
5.  **Rook Ceph (Dynamic Persistent Block & File Storage):**
    Turns local bare-metal disks or raw hypervisor drives into a resilient, self-healing Ceph storage pool. Deploys the CSI block driver (`ceph-rbd`) to support persistent volumes (PVs) for stateful applications.
6.  **Harbor (Local Secure OCI Registry):**
    Enables local secure image hosting, vulnerability scanning, and pre-seeding. In air-gapped environments, Harbor serves as the localized image registry.
7.  **Infisical (Central Secret Management):**
    Enterprise-grade vault that injects secrets directly into workloads via the Infisical Kubernetes Operator, keeping secrets safely out of source control.
8.  **Spegel (P2P Registry Mirror):**
    A peer-to-peer registry proxy running on worker nodes as a DaemonSet. It caches container images pulled from registries and serves them locally to neighboring nodes, dramatically speeding up spin-up times and conserving WAN bandwidth.
9.  **VictoriaMetrics (Central Observability TSDB):**
    High-performance, resource-efficient Time Series Database. Replaces Prometheus to store metrics collected by `vmagent` scrapers, serving as the analytics engine for release canary checks.

---

## 4. Concrete Developer & Platform Workflow

The diagram and steps below detail the complete lifecycle of an application—from creation, development, and local build to GitOps-driven promotion, automated sync waves, and Backstage telemetry monitoring.

```
+-----------+         1. Scaffold         +-------------+
| Developer | ──────────────────────────> |  Backstage  |
+-----------+                             +-------------+
      ▲                                          │
      │                                          │ 2. Create Repos &
      │                                          ▼ GitOps Wiring
      │ 4. Local Build                    +-------------+
      └────────────────────────────────── |  Git Repos  |
      │                                   +-------------+
      │                                          │
      │ 5. Promote                               │ 3. Image Push /
      │                                          ▼ Webhook Detect
      │                                   +-------------+
      └────────────────────────────────── |    Kargo    | ──┐
                                          +-------------+   │
                                                            │ 6. Commit Env
                                                            ▼ Configs
                                          +-------------+   │
                                          |   Argo CD   | <─┘
                                          +-------------+
                                                 │
                                                 │ 7. Sync Waves
                                                 ▼ (Network -> Storage -> Apps)
                                          +-------------+
                                          | Spoke Cluster|
                                          +-------------+
```

### Step 1: Golden Path Bootstrapping (Developer Self-Service)
1.  A developer logs into the **Backstage Portal** and clicks **"Create New Service"**.
2.  They select the **"Secure Microservice Go/Svelte"** Golden Path template and fill out a quick wizard (Application Name, Team Owner, Memory requirements).
3.  They click **"Launch Component"**.

### Step 2: Repository Generation & GitOps Wiring
1.  The Backstage Scaffolder engine creates a new repository under `/github-org/welcome-counter` with:
    *   Production-ready application code.
    *   A secure, multi-stage, rootless Dockerfile.
    *   A pre-configured Helm chart.
    *   An auto-generated `catalog-info.yaml` register file.
2.  Backstage commits a Kargo `Warehouse` subscription manifest and an Argo CD `Application` (or `ApplicationSet`) definition directly into the **GitOps Control Plane** repository (`gitops-workloads/`).
3.  The new component is instantly registered and visible in the Backstage Software Catalog.

### Step 3: Code Development & Local Loop (High-Parity LibVirt)
1.  The developer clones the application repository to their workstation.
2.  They write code and run local verification against their **LibVirt/QEMU Talos Cluster**:
    *   The workstation runs `setup-bridge.sh` which cleanly creates/updates `hpa-bridge` with deterministic DHCP mapping.
    *   OpenTofu applies the virtual machine layout, booting Talos from COW-cloned base QCow2 disks.
    *   `startup.sh` deploys the full cluster sequentially, using **Live Step-by-Step Verification** (`S04`). For example, when Cilium is applied, the script runs `verify-cilium.sh` immediately and fails fast if the network configuration deviates.
3.  The developer commits and pushes code to Git.

### Step 4: CI Pipeline & Harbor Secure Scanning
1.  GitHub Actions (or GitLab CI) runs on the commit:
    *   Compiles and builds the secure OCI container image.
    *   Pushes the image to the **Harbor Local Registry**.
2.  Harbor triggers an automatic vulnerability scan (Trivy/Clair) and signs the image via Cosign.
3.  If any high-priority CVEs are detected, the pipeline fails, notifying Backstage. Otherwise, the image is marked as "verified."

### Step 5: GitOps Declarative Promotion via Kargo
1.  **Kargo** detects the new container tag in Harbor.
2.  On the **Backstage** UI, the developer views their service catalog page, sees a new release candidate, and clicks **"Promote to Staging"**.
3.  Kargo writes the updated tag and values configuration to the staging branch of `gitops-workloads/`.

### Step 6: Argo CD Multi-Cluster Syncing via Sync Waves
1.  Argo CD detects the Git modification committed by Kargo on the staging branch and begins syncing the Staging spoke cluster.
2.  Argo CD executes the rollout using the **Platform Sync Waves**:
    *   **Wave -10 (CRDs):** Ensures Cilium, Ceph, and Infisical CRDs are synchronized.
    *   **Wave -5 (Network):** Cilium CNI establishes eBPF datapath routing.
    *   **Wave -4 (Storage):** Rook Ceph activates dynamic persistent storage mounts.
    *   **Wave -3 (Platform Core):** Harbor and Infisical start, establishing secure secrets injection.
    *   **Wave 1 (Applications):** The application pod is pulled, mounts its persistent block storage from Ceph, retrieves database secrets securely from Infisical, and boots up.
3.  Argo CD marks the deployment as **Synced & Healthy**.

### Step 7: Backstage Observability & Progressive Rollout
1.  On the Backstage Dashboard, the developer sees their service change status to "Live in Staging."
2.  The developer opens the **Argo Rollouts** tab embedded in Backstage to observe the rollout:
    *   A canary rollout begins (e.g., 90% Stable, 10% Canary).
    *   **VictoriaMetrics** collects API metrics via `vmagent`.
    *   An automated canary analysis checks HTTP error rates and latency.
3.  If anomaly rates are zero, Kargo promotes the candidate automatically to **Production Spokes**. If error rates spike, Kargo instantly commits a revert commit in Git, triggering a seamless, automatic rollback across the fleet.

---

## 5. Architectural Summary: Parity and Automation

This architecture establishes absolute engineering rigour by aligning developer workflows across both local virtualized hypervisors and globally distributed fleets:

| Stage | Dev Hypervisor (LibVirt/QEMU) | Production Spokes (AWS/On-Prem) |
| :--- | :--- | :--- |
| **Control Plane** | Local workstation CLI / `startup.sh` | Central Backstage Hub Cluster |
| **CNI** | Cilium (kube-proxy-free, eth0 config) | Cilium (kube-proxy-free, eth0/elastic interface) |
| **Storage** | Rook Ceph (attached sparse virtual disks) | Rook Ceph (attached EBS/Physical NVMe disks) |
| **Secrets** | Local Infisical Operator | Enterprise Vault / Infisical Multi-Region |
| **GitOps** | Argo CD (Adoption / local cluster) | Argo CD + Kargo (Multi-cluster fleet) |
