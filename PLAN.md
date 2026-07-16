# Enterprise GitOps Platform Implementation Plan
## Automated Hub-and-Spoke Fleet Deployment with Backstage, Kargo, and Argo CD

This document maps out the comprehensive, step-by-step implementation plan for rolling out the Enterprise GitOps platform architecture specified in `docs/UP - 00 - Backstage Kargo ArgoCD with Fleet.md`. 

The roadmap is structured into **5 sequential Milestones**, each divided into high-fidelity **slices** and actionable **tasks** to establish a modern Internal Developer Platform (IDP) and progressive delivery pipeline.

---

## Milestone 1 (M1): Foundations & Hub Cluster Setup
**Goal:** Establish the centralized Management Plane (Hub cluster) and the fundamental GitOps repository wiring.

### Slice 1.1: Management Hub Cluster Provisioning
*   [ ] **Task M1.1.1:** Provision a dedicated Management Hub Cluster (can be a local lightweight VM/cluster or managed cloud node).
*   [ ] **Task M1.1.2:** Configure host networking and verify external routing (e.g., DNS access to Harbor and Git repositories).
*   [ ] **Task M1.1.3:** Setup admin access credentials, storage classes, and configure RBAC roles for platform engineers.

### Slice 1.2: GitOps Repository & Organizational Layout
*   [ ] **Task M1.2.1:** Create the central platform repository: `platform-infra-fleet` (for hosting Kubernetes cluster blueprints, Argo CD ApplicationSets, and core helm charts).
*   [ ] **Task M1.2.2:** Define the directory structure for environment overlays (e.g., `stages/dev/`, `stages/staging/`, `stages/production/`).
*   [ ] **Task M1.2.3:** Create a template repository format for application source repositories (to be used later by Backstage Scaffolder).

### Slice 1.3: Argo CD Bootstrap on Hub
*   [ ] **Task M1.3.1:** Deploy Argo CD on the Hub cluster in High-Availability (HA) mode under the `argocd` namespace.
*   [ ] **Task M1.3.2:** Enable the `ApplicationSet` controller and configure cluster-generator selectors.
*   [ ] **Task M1.3.3:** Connect Argo CD on the Hub cluster to the staging/production spoke clusters via secure Kubernetes service account tokens.

---

## Milestone 2 (M2): Progressive Delivery with Kargo
**Goal:** Install Kargo on the Hub cluster and design declarative Promotion Pipelines across environments.

### Slice 2.1: Kargo Controller Installation
*   [ ] **Task M2.1.1:** Deploy the Kargo Operator on the Hub cluster in the `kargo` namespace.
*   [ ] **Task M2.1.2:** Configure Kargo's internal credential store to securely access Harbor registries and private GitHub repositories.
*   [ ] **Task M2.1.3:** Install the Kargo CLI tool on the management workstation.

### Slice 2.2: Declaring Warehouses & Stages
*   [ ] **Task M2.2.1:** Create Kargo `Warehouse` resources to monitor Harbor for new OCI container images.
*   [ ] **Task M2.2.2:** Declare sequential `Stage` resources in Kargo matching cluster environments (`dev` $\rightarrow$ `staging` $\rightarrow$ `production`).
*   [ ] **Task M2.2.3:** Map each Stage destination to its corresponding Git branch or subdirectory inside the `platform-infra-fleet` repository.

### Slice 2.3: Automated Promotion Pipelines
*   [ ] **Task M2.3.1:** Define automated promotion policies where Kargo automatically triggers promotion from `dev` to `staging` upon successful CI checks.
*   [ ] **Task M2.3.2:** Write a declarative promo mechanism utilizing git commit-writing to inject the newly detected image tags into target Helm values.
*   [ ] **Task M2.3.3:** Enable Argo CD sync status polling inside Kargo to verify the Spoke clusters have reconciled successfully before progressing.

---

## Milestone 3 (M3): Backstage IDP Portal Integration
**Goal:** Deploy Backstage as the central Developer Portal and implement developer self-service templates.

### Slice 3.1: Backstage Base Deployment
*   [ ] **Task M3.1.1:** Build a customized Backstage Docker image with essential plugins pre-installed.
*   [ ] **Task M3.1.2:** Deploy Backstage on the Hub cluster and configure database persistence (e.g., PostgreSQL).
*   [ ] **Task M3.1.3:** Integrate Backstage authentication with the Casdoor OIDC provider for secure single sign-on (SSO).

### Slice 3.2: Golden Path Software Templates & Scaffolder
*   [ ] **Task M3.2.1:** Design a Backstage Scaffolder template for a **"Secure Go Microservice"** including rootless Dockerfiles, standard Go codebase, and ready Helm charts.
*   [ ] **Task M3.2.2:** Configure the template Scaffolder steps to auto-create private repositories on Git and register them instantly in the Backstage Software Catalog.
*   [ ] **Task M3.2.3:** Implement GitOps auto-wiring: write the corresponding Kargo `Warehouse` and Argo CD `Application` manifests into `platform-infra-fleet` during scaffolding.

### Slice 3.3: Backstage GitOps Plugins Integration
*   [ ] **Task M3.3.1:** Integrate the `@backstage/plugin-argocd` plugin into the Backstage portal.
*   [ ] **Task M3.3.2:** Wire the Argo CD plugin with live cluster endpoints to expose deployment sync status, health, and pod states inside each catalog component's dashboard.
*   [ ] **Task M3.3.3:** Install the Argo Rollouts Backstage card to show canary split trends and progressive rollout traffic percentages.

---

## Milestone 4 (M4): Platform Parity & Observability Loop
**Goal:** Standardize core spoke services (Secrets, Network, Storage) and hook up closed-loop automated canary rollbacks.

### Slice 4.1: Centralized Secret Management
*   [ ] **Task M4.1.1:** Deploy the Infisical Secrets Operator on all Spoke clusters.
*   [ ] **Task M4.1.2:** Configure secure `SecretStore` resources on Spoke clusters referencing the central Infisical Vault on the Hub cluster.
*   [ ] **Task M4.1.3:** Map application helm charts to dynamically request and mount Infisical database and runtime credentials as native Kubernetes Secrets.

### Slice 4.2: eBPF Networking Parity (Cilium)
*   [ ] **Task M4.2.1:** Standardize the Cilium Helm values across Spoke clusters using `kubeProxyReplacement=true`.
*   [ ] **Task M4.2.2:** Implement a unified `CiliumNodeConfig` to explicitly target Spoke VM interfaces (`eth0` on local LibVirt, appropriate provider interfaces in prod).
*   [ ] **Task M4.2.3:** Map L2 Announcement policies on spokes to coordinate IP pools with local subnet gateway configurations.

### Slice 4.3: Metric-Driven Automated Canaries
*   [ ] **Task M4.3.1:** Deploy central VictoriaMetrics TSDB on the Hub cluster.
*   [ ] **Task M4.3.2:** Install the lightweight `vmagent` scraper on Spoke clusters to scrape local metrics and securely stream them to VictoriaMetrics.
*   [ ] **Task M4.3.3:** Design an Argo `AnalysisTemplate` resource. Configure it to query VictoriaMetrics for HTTP error rates and latency metrics during a Canary promotion.
*   [ ] **Task M4.3.4:** Validate closed-loop rollback: simulate an application bug, watch VictoriaMetrics error rates spike, and verify that Kargo/Argo Rollouts automatically aborts and reverts the deployment in Git.

---

## Milestone 5 (M5): E2E Validation & Fleet Scaling
**Goal:** Automate cluster onboarding, run end-to-end load tests, and audit security compliance across a multi-cluster layout.

### Slice 5.1: Declarative Spoke Cluster Onboarding
*   [ ] **Task M5.1.1:** Configure an Argo CD `ApplicationSet` generator using Git file generators to dynamically detect new spoke clusters registered in the GitOps repository.
*   [ ] **Task M5.1.2:** Implement an onboarding script that registers a newly provisioned LibVirt/QEMU cluster endpoint into the Hub's secrets, initiating immediate platform bootstrapping.
*   [ ] **Task M5.1.3:** Verify that new Spoke clusters dynamically receive CNI, Storage classes, and Observability agents within minutes of onboarding.

### Slice 5.2: End-to-End Delivery Simulation & Auditing
*   [ ] **Task M5.2.1:** Execute a complete developer simulation: scaffold an application, push commits, promote through staging, and verify deployment onto production spoke clusters.
*   [ ] **Task M5.2.2:** Verify that Harbor OCI image scanning, container signing via Cosign, and signature validation policies (Kyverno/OPA) reject unsigned images.
*   [ ] **Task M5.2.3:** Measure platform latency (scaffold-to-production time) and compile a performance audit report to fine-tune the VictoriaMetrics scraping interval.
