# Running and Testing the HPA Dev Cluster Platform
## Comprehensive Step-by-Step Operator Guide

This guide provides precise, step-by-step instructions on how to run, test, and verify the HPA Enterprise GitOps Platform on your local workstation. The platform boots a high-parity local Kubernetes cluster on **LibVirt/QEMU virtual machines**, orchestrates secrets, CNI networks, and storage, and executes progressive delivery with **Backstage, Kargo, and Argo CD**.

---

## 📋 1. System Prerequisites

Ensure your host machine has the following packages pre-installed:
*   **Hypervisor:** QEMU/KVM with the `libvirtd` system service active.
*   **Virtualization Client:** `virsh` (part of libvirt-clients).
*   **Infrastructure as Code:** OpenTofu (v1.6+) or Terraform (v1.5+).
*   **Platform Engines:** Helm (v3.x) and `kubectl`.
*   **Node Control:** `talosctl` (for managing Talos OS virtual machines).

---

## 🔑 2. Environment Configuration

1.  Copy the environment template to create your `.env` file:
    ```bash
    cp .env.example .env
    ```
2.  Fill in the private keys and endpoints. The environment configurations are automatically loaded by the bootstrapping scripts.

---

## 🚀 3. Bootstrapping the LibVirt Dev Cluster

All operations are automated using high-fidelity shell scripts located in `provisioning/dev/scripts/`.

### Step 3.1: Run Host Pre-flight Audits
Validate that your hypervisor, groups, and virtualization limits are compliant:
```bash
bash provisioning/dev/scripts/host-preflight.sh
```

### Step 3.2: Recreate the Host Bridge Network
To guarantee the deterministic static DHCP leases are active (mapping specific MACs to predictable IPs like `.100` for Control Plane and `.110+` for Workers):
```bash
# setup-bridge.sh cleanly destroys and recreates hpa-bridge on the host
bash provisioning/dev/scripts/setup-bridge.sh
```

### Step 3.3: Pre-Cache Talos OS Images
Download and pre-stage the cached Talos OS `qcow2` image locally to prevent slow internet-pull bottlenecks during provisioning:
```bash
bash provisioning/dev/scripts/prep-cache.sh
```

### Step 3.4: Provision VMs & Deploy Platform (The Startup Pipeline)
Execute the complete, orchestrating startup pipeline. This will call OpenTofu to provision the VMs, apply Talos machine configurations, and sequentially deploy all platform layers (Secrets, Storage, Ingress, Observability) with **Live Step-by-Step Verification**:
```bash
bash provisioning/dev/scripts/startup.sh
```
*   *Verification during run:* Watch the live progress table in your terminal. Each step (e.g., Cilium, Rook Ceph, Harbor) is validated immediately upon installation and will fail-fast if a check deviates.

---

## 🧪 4. Verifying Core Cluster State

Once `startup.sh` completes successfully:

### Step 4.1: Verify Kubernetes Node Health
Confirm that all 4 local VMs have joined the cluster and are fully healthy:
```bash
bash provisioning/dev/scripts/verify-cluster.sh --kubeconfig provisioning/dev/opentofu/kubeconfig
```
*   *Expected Output:*
    ```
    === Talos Cluster Node Summary ===
    NAME                STATUS   ROLES           AGE   VERSION
    hpa-node-cp-0       Ready    control-plane   2m    v1.36.0
    hpa-node-worker-0   Ready    <none>          2m    v1.36.0
    hpa-node-worker-1   Ready    <none>          2m    v1.36.0
    hpa-node-worker-2   Ready    <none>          2m    v1.36.0
    ```

### Step 4.2: Verify eBPF Interface Enforcements
Ensure Cilium has bound its BPF datapath routing exclusively to the primary VM interface (`eth0`) rather than detecting generic host devices:
```bash
bash provisioning/dev/scripts/verify-cilium.sh --kubeconfig provisioning/dev/opentofu/kubeconfig
```
*   *Expected Success:* Under "Device Detection", `eth0` is active and confirmed, with L2 Announcements working smoothly on `eth0` under the IP pool `192.168.122.240/28`.

---

## 🔄 5. Testing Progressive Delivery (Kargo + Argo CD)

Once the core is active, we can run Kargo and Argo CD delivery checks.

### Step 5.1: Initialize GitOps Pipeline
Deploy Kargo and Argo CD controllers to the cluster:
```bash
bash provisioning/dev/scripts/install-gitops.sh --kubeconfig provisioning/dev/opentofu/kubeconfig
```

### Step 5.2: Audit Kargo Promotion Pipelines
Apply your Kargo credentials, warehouse, and sequential stage definitions:
```bash
# Apply credential stores and pipeline stages to Spoke Stage namespace
kubectl --kubeconfig=provisioning/dev/opentofu/kubeconfig apply -f platform-infra-fleet/stages/staging/kargo-credentials-secrets.yaml
kubectl --kubeconfig=provisioning/dev/opentofu/kubeconfig apply -f platform-infra-fleet/stages/staging/kargo-pipeline.yaml
```

### Step 5.3: Verify Pipeline Resources
Confirm Kargo registers the stages and is polling Harbor:
```bash
kubectl --kubeconfig=provisioning/dev/opentofu/kubeconfig get stages -n kargo
kubectl --kubeconfig=provisioning/dev/opentofu/kubeconfig get warehouses -n kargo
```
*   *Expected Success:* `dev`, `staging`, and `production` stages report as healthy.

---

## 💻 6. Executing the Developer Portal (Backstage) Scaffolder

To test the automated "Golden Path" scaffolding and GitOps auto-wiring:

### Step 6.1: Deploy Backstage
```bash
kubectl --kubeconfig=provisioning/dev/opentofu/kubeconfig apply -f platform-infra-fleet/backstage/backstage-deployment.yaml
```

### Step 6.2: Trigger "Golden Path" Microservice Scaffolding
Select the **"Golden Path Secure Go Microservice"** template (`platform-infra-fleet/backstage/templates/secure-go-template.yaml`) inside Backstage. This will:
1.  Generate a private code repository from the pre-configured skeleton under `platform-infra-fleet/templates/app-source-template/`.
2.  Auto-generate and commit a Kargo `Stage` and Argo CD `Application` configuration file directly into `platform-infra-fleet/stages/dev/`.
3.  Argo CD will immediately detect the commit and deploy the application pod.

---

## 📉 7. Testing Closed-Loop Automated Canary Rollback

To verify the platform's self-healing capabilities using **VictoriaMetrics** and **Argo Rollouts**:

1.  **Apply Canary Analysis Rules:**
    Apply the `AnalysisTemplate` which queries VictoriaMetrics for HTTP success rates:
    ```bash
    kubectl --kubeconfig=provisioning/dev/opentofu/kubeconfig apply -f platform-infra-fleet/observability/canary-analysis-template.yaml
    ```
2.  **Trigger a Buggy Deploy:**
    Promote a faulty container tag (e.g. `v2.0.0-buggy` yielding 500 errors) to staging.
    ```bash
    kubectl --kubeconfig=provisioning/dev/opentofu/kubeconfig apply -f platform-infra-fleet/observability/app-rollout-definition.yaml
    ```
3.  **Watch Self-Healing in Action:**
    *   Argo Rollouts splits 10% traffic to the buggy canary.
    *   `vmagent` scrapes the failure metrics and streams them to VictoriaMetrics.
    *   The `AnalysisRun` queries VictoriaMetrics, detects that the failure rate exceeds $1\%$, and automatically **reverts traffic and rolls back the deployment to the stable version** inside 90 seconds without operator intervention.

---

## 🤖 8. Running the Complete Automated E2E Test Suite

To run the entire clean create-verify-destroy test loop fully unattended (perfect for CI/CD runners):
```bash
bash provisioning/dev/scripts/e2e-provisioning.sh
```
*   *Note on Recreation:* The test suite strictly enforces the **Fresh Environment Guarantee**—it will automatically run `cleanup.sh` first to cleave the hypervisor, and will abort immediately if any cleanup traces remain, guaranteeing zero pollution across test runs.

---

## 🧹 9. Clean-Up and Teardown

To stop the virtual machines, delete hypervisor resources, remove host virtual networks, and restore host integrity:
```bash
bash provisioning/dev/scripts/cleanup.sh
```
