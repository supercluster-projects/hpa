# Enterprise GitOps Platform Implementation Plan
## Automated Hub-and-Spoke Fleet Deployment with Backstage, Kargo, and Argo CD

This document maps out the comprehensive, step-by-step implementation plan for rolling out the Enterprise GitOps platform architecture specified in `docs/UP - 00 - Backstage Kargo ArgoCD with Fleet.md`. 

The roadmap is structured into **5 sequential Milestones**, each divided into high-fidelity **slices**, actionable **tasks**, and **concrete verification tests** to prove the architecture is structurally correct, resilient, and fully operational.

---

## Milestone 1 (M1): Foundations & Hub Cluster Setup
**Goal:** Establish the centralized Management Plane (Hub cluster) and the fundamental GitOps repository wiring.

### Slices & Tasks
*   **Slice 1.1: Management Hub Cluster Provisioning**
    *   [x] **Task M1.1.1:** Provision a dedicated Management Hub Cluster (can be a local lightweight VM/cluster or managed cloud node).
    *   [x] **Task M1.1.2:** Configure host networking and verify external routing (e.g., DNS access to Harbor and Git repositories).
    *   [x] **Task M1.1.3:** Setup admin access credentials, storage classes, and configure RBAC roles for platform engineers.
*   **Slice 1.2: GitOps Repository & Organizational Layout**
    *   [ ] **Task M1.2.1:** Create the central platform repository: `platform-infra-fleet` (for hosting Kubernetes cluster blueprints, Argo CD ApplicationSets, and core helm charts).
    *   [ ] **Task M1.2.2:** Define the directory structure for environment overlays (e.g., `stages/dev/`, `stages/staging/`, `stages/production/`).
    *   [ ] **Task M1.2.3:** Create a template repository format for application source repositories (to be used later by Backstage Scaffolder).
*   **Slice 1.3: Argo CD Bootstrap on Hub**
    *   [ ] **Task M1.3.1:** Deploy Argo CD on the Hub cluster in High-Availability (HA) mode under the `argocd` namespace.
    *   [ ] **Task M1.3.2:** Enable the `ApplicationSet` controller and configure cluster-generator selectors.
    *   [ ] **Task M1.3.3:** Connect Argo CD on the Hub cluster to the staging/production spoke clusters via secure Kubernetes service account tokens.

### 🧪 Verification & Concrete Testing (M1)
To prove that Milestone 1 foundations are fully operational:
1.  **Component Health Check:**
    *   Execute: `kubectl get pods -n argocd`
    *   *Expected Success:* All Argo CD services are in a `Running` status with zero restarts.
2.  **Cluster Connectivity Check:**
    *   Execute: `argocd cluster list`
    *   *Expected Success:* The staging and production Spoke clusters appear in the list with status `Successful`.
3.  **Concrete Test Case 1A (Drift Reconciliation Test):**
    *   **Action:** Target an active platform service (e.g., core gateway deployment). Run: `kubectl scale deployment envoy-gateway --replicas=5 -n envoy-gateway-system` directly on a spoke cluster.
    *   **Verification:** Monitor the Argo CD Hub controller dashboard or CLI (`argocd app get gateway-system`). 
    *   *Expected Success:* Argo CD immediately flags the application as `OutOfSync` (drift detected) and, within 60 seconds (reconciliation interval), automatically triggers a sync to scale the replicas back to its Git-declared baseline (e.g., 2 replicas), reverting the manual modification.

---

## Milestone 2 (M2): Progressive Delivery with Kargo
**Goal:** Install Kargo on the Hub cluster and design declarative Promotion Pipelines across environments.

### Slices & Tasks
*   **Slice 2.1: Kargo Controller Installation**
    *   [ ] **Task M2.1.1:** Deploy the Kargo Operator on the Hub cluster in the `kargo` namespace.
    *   [ ] **Task M2.1.2:** Configure Kargo's internal credential store to securely access Harbor registries and private GitHub repositories.
    *   [ ] **Task M2.1.3:** Install the Kargo CLI tool on the management workstation.
*   **Slice 2.2: Declaring Warehouses & Stages**
    *   [ ] **Task M2.2.1:** Create Kargo `Warehouse` resources to monitor Harbor for new OCI container images.
    *   [ ] **Task M2.2.2:** Declare sequential `Stage` resources in Kargo matching cluster environments (`dev` $\rightarrow$ `staging` $\rightarrow$ `production`).
    *   [ ] **Task M2.2.3:** Map each Stage destination to its corresponding Git branch or subdirectory inside the `platform-infra-fleet` repository.
*   **Slice 2.3: Automated Promotion Pipelines**
    *   [ ] **Task M2.3.1:** Define automated promotion policies where Kargo automatically triggers promotion from `dev` to `staging` upon successful CI checks.
    *   [ ] **Task M2.3.2:** Write a declarative promo mechanism utilizing git commit-writing to inject the newly detected image tags into target Helm values.
    *   [ ] **Task M2.3.3:** Enable Argo CD sync status polling inside Kargo to verify the Spoke clusters have reconciled successfully before progressing.

### 🧪 Verification & Concrete Testing (M2)
To prove that Milestone 2 promotion logic is fully operational:
1.  **Pipeline Integrity Check:**
    *   Execute: `kargo get stages` and `kargo get warehouses`
    *   *Expected Success:* Both resources list successfully and report zero errors.
2.  **Concrete Test Case 2A (Multi-Stage Promotion Pipeline Test):**
    *   **Action:** Build and push a new test image (`v1.2.3`) to the Harbor OCI registry.
    *   **Verification (Phase 1):** Monitor Kargo via `kargo get stages`. 
        *   *Expected Success:* Kargo automatically detects the image inside Harbor, triggers a git write, and promotes `dev` stage to `v1.2.3`. Staging remains on the older version (blocked).
    *   **Action (Phase 2):** Promote to Staging via: `kargo stage promote staging --version v1.2.3`.
    *   **Verification (Phase 2):** Verify git history in `platform-infra-fleet`.
        *   *Expected Success:* Kargo successfully commits a pull request/merge of `v1.2.3` configurations into the staging folder/branch, and the Hub Argo CD instance automatically starts syncing the staging cluster.

---

## Milestone 3 (M3): Backstage IDP Portal Integration
**Goal:** Deploy Backstage as the central Developer Portal and implement developer self-service templates.

### Slices & Tasks
*   **Slice 3.1: Backstage Base Deployment**
    *   [ ] **Task M3.1.1:** Build a customized Backstage Docker image with essential plugins pre-installed.
    *   [ ] **Task M3.1.2:** Deploy Backstage on the Hub cluster and configure database persistence (e.g., PostgreSQL).
    *   [ ] **Task M3.1.3:** Integrate Backstage authentication with the Casdoor OIDC provider for secure single sign-on (SSO).
*   **Slice 3.2: Golden Path Software Templates & Scaffolder**
    *   [ ] **Task M3.2.1:** Design a Backstage Scaffolder template for a **"Secure Go Microservice"** including rootless Dockerfiles, standard Go codebase, and ready Helm charts.
    *   [ ] **Task M3.2.2:** Configure the template Scaffolder steps to auto-create private repositories on Git and register them instantly in the Backstage Software Catalog.
    *   [ ] **Task M3.2.3:** Implement GitOps auto-wiring: write the corresponding Kargo `Warehouse` and Argo CD `Application` manifests into `platform-infra-fleet` during scaffolding.
*   **Slice 3.3: Backstage GitOps Plugins Integration**
    *   [ ] **Task M3.3.1:** Integrate the `@backstage/plugin-argocd` plugin into the Backstage portal.
    *   [ ] **Task M3.3.2:** Wire the Argo CD plugin with live cluster endpoints to expose deployment sync status, health, and pod states inside each catalog component's dashboard.
    *   [ ] **Task M3.3.3:** Install the Argo Rollouts Backstage card to show canary split trends and progressive rollout traffic percentages.

### 🧪 Verification & Concrete Testing (M3)
To prove that Milestone 3 developer integration is fully operational:
1.  **API & Authentication Check:**
    *   Execute: `curl -I http://backstage.internal/api/catalog/entities`
    *   *Expected Success:* Returns an HTTP `200 OK` (with valid session tokens or SSO routing redirect).
2.  **Concrete Test Case 3A (Self-Service Bootstrap Validation Test):**
    *   **Action:** Open Backstage, select the "Secure Go Microservice" template, input a name (`demo-counter`), and click "Generate".
    *   **Verification:** Audit Git repositories and the Hub platform controller.
        *   *Expected Success:* 
            1. A private repository named `/github-org/demo-counter` is successfully created with a valid template codebase.
            2. An Argo CD Application manifest for `demo-counter` is written and committed to `platform-infra-fleet` under `/stages/dev/`.
            3. Argo CD picks up the manifest, automatically bootstraps the service, and a status card showing `Healthy` is visible inside the Backstage catalog dashboard for `demo-counter`.

---

## Milestone 4 (M4): Platform Parity & Observability Loop
**Goal:** Standardize core spoke services (Secrets, Network, Storage) and hook up closed-loop automated canary rollbacks.

### Slices & Tasks
*   **Slice 4.1: Centralized Secret Management**
    *   [ ] **Task M4.1.1:** Deploy the Infisical Secrets Operator on all Spoke clusters.
    *   [ ] **Task M4.1.2:** Configure secure `SecretStore` resources on Spoke clusters referencing the central Infisical Vault on the Hub cluster.
    *   [ ] **Task M4.1.3:** Map application helm charts to dynamically request and mount Infisical database and runtime credentials as native Kubernetes Secrets.
*   **Slice 4.2: eBPF Networking Parity (Cilium)**
    *   [ ] **Task M4.2.1:** Standardize the Cilium Helm values across Spoke clusters using `kubeProxyReplacement=true`.
    *   [ ] **Task M4.2.2:** Implement a unified `CiliumNodeConfig` to explicitly target Spoke VM interfaces (`eth0` on local LibVirt, appropriate provider interfaces in prod).
    *   [ ] **Task M4.2.3:** Map L2 Announcement policies on spokes to coordinate IP pools with local subnet gateway configurations.
*   **Slice 4.3: Metric-Driven Automated Canaries**
    *   [ ] **Task M4.3.1:** Deploy central VictoriaMetrics TSDB on the Hub cluster.
    *   [ ] **Task M4.3.2:** Install the lightweight `vmagent` scraper on Spoke clusters to scrape local metrics and securely stream them to VictoriaMetrics.
    *   [ ] **Task M4.3.3:** Design an Argo `AnalysisTemplate` resource. Configure it to query VictoriaMetrics for HTTP error rates and latency metrics during a Canary promotion.
    *   [ ] **Task M4.3.4:** Validate closed-loop rollback: simulate an application bug, watch VictoriaMetrics error rates spike, and verify that Kargo/Argo Rollouts automatically aborts and reverts the deployment in Git.

### 🧪 Verification & Concrete Testing (M4)
To prove that Milestone 4 secure parity and closed-loop rollback are fully operational:
1.  **eBPF Device Enforcement Check:**
    *   Execute: `kubectl exec -n kube-system ds/cilium -- cilium status --verbose`
    *   *Expected Success:* Under "Device Detection" or "Datapath Devices", `eth0` is identified as the active datapath device, matching the rules applied via `CiliumNodeConfig`.
2.  **Dynamic Secrets Check:**
    *   Execute: `kubectl get secrets -n target-app` and verify the secret content matches the unencrypted key stored inside the central Infisical platform.
3.  **Concrete Test Case 4A (Closed-Loop Automated Canary Rollback Test):**
    *   **Action:** Force a promotion of a buggy application container (`v2.0.0-buggy`) which returns 500 errors on 30% of calls.
    *   **Verification:**
        *   *Argo Rollouts Stage:* The rollout kicks off, routing 10% of traffic to the new canary version.
        *   *Telemetry Stage:* `vmagent` scrapes response codes and streams them to VictoriaMetrics.
        *   *Analysis Stage:* The active `AnalysisRun` queries VictoriaMetrics. Within 2 minutes, it flags that the error rate exceeds the $1\%$ threshold.
        *   *Expected Success:* Argo Rollouts immediately aborts the promotion, cuts off traffic to the canary, and rolls back 100% of the traffic back to the stable baseline (`v1.2.3`) without human operator intervention.

---

## Milestone 5 (M5): E2E Validation & Fleet Scaling
**Goal:** Automate cluster onboarding, run end-to-end load tests, and audit security compliance across a multi-cluster layout.

### Slices & Tasks
*   **Slice 5.1: Declarative Spoke Cluster Onboarding**
    *   [ ] **Task M5.1.1:** Configure an Argo CD `ApplicationSet` generator using Git file generators to dynamically detect new spoke clusters registered in the GitOps repository.
    *   [ ] **Task M5.1.2:** Implement an onboarding script that registers a newly provisioned LibVirt/QEMU cluster endpoint into the Hub's secrets, initiating immediate platform bootstrapping.
    *   [ ] **Task M5.1.3:** Verify that new Spoke clusters dynamically receive CNI, Storage classes, and Observability agents within minutes of onboarding.
*   **Slice 5.2: End-to-End Delivery Simulation & Auditing**
    *   [ ] **Task M5.2.1:** Execute a complete developer simulation: scaffold an application, push commits, promote through staging, and verify deployment onto production spoke clusters.
    *   [ ] **Task M5.2.2:** Verify that Harbor OCI image scanning, container signing via Cosign, and signature validation policies (Kyverno/OPA) reject unsigned images.
    *   [ ] **Task M5.2.3:** Measure platform latency (scaffold-to-production time) and compile a performance audit report to fine-tune the VictoriaMetrics scraping interval.

### 🧪 Verification & Concrete Testing (M5)
To prove that Milestone 5 scale, automated onboarding, and compliance gates are fully operational:
1.  **Dynamic Fleet Cluster Bootstrap Check:**
    *   Execute: Add a new JSON file representing a newly created spoke cluster (`spoke-3.json`) to the `platform-infra-fleet` clusters directory.
    *   *Expected Success:* The Argo CD `ApplicationSet` automatically picks up the new cluster file within 30 seconds and bootstraps the Spoke's network, secrets, and storage classes completely, moving them to a `Healthy` status.
2.  **Concrete Test Case 5A (Untrusted Security Policy Gate Test):**
    *   **Action:** Try to bypass the GitOps loop and manually deploy an unsigned, untested public image directly to a spoke namespace: `kubectl run untrusted-pod --image=docker.io/library/alpine:latest -n dev`.
    *   **Verification:**
        *   *Expected Success:* The Kubernetes API Server blocks the request immediately. The Kyverno/OPA admission controller returns an explicit validation error: `Image signature validation failed. Pod deployment denied.` proving the platform's security compliance gate is active and enforced.
