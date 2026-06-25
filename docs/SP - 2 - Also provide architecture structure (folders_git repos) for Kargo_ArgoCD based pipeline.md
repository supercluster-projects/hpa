To tie your multi-environment plan (dev, staging, production) together with **ArgoCD** (gitops deployment execution) and **Kargo** (lifecycle stage promotion), you should use a **three-repository architecture**. \[1, 2, 3, 4\]

Separating code, infrastructure, and deployment manifests prevents your continuous integration (CI) pipelines from creating infinite loops and enforces a clean security boundary across environments. \[5, 6\]

## ---

**The 3-Repository Pipeline Architecture**

  `[ Code Repo: App/Spin/Func ]`  
               `│`  
               `▼ (CI Builds OCI Image)`  
  `[ Image Registry (Harbor) ]`  
               `│`  
               `▼ (Kargo Warehouse Polls Image)`  
  `[ GitOps Manifests Repo ] ◄─── (Kargo updates Image Digests per Stage)`  
               `│`  
               `▼ (ArgoCD Syncs State)`  
  `[ Bare-Metal Target Clusters ] (Dev / Staging / Production)`

1. **The Application Code Repository:** Developers push code, functions, and .wasm files here. CI pipelines build and push OCI artifacts to your private Harbor registry. \[7, 8, 9, 10, 11\]  
2. **The GitOps Infrastructure & Platform Repository:** Managed by platform engineers to configure the global cluster blueprint, core databases, mesh networks, and **OpenTofu** VM profiles. \[12, 13\]  
3. **The GitOps Workload Manifests Repository:** This repository houses your environments' live states. This is where **Kargo** actively commits modified image digests, and where **ArgoCD** listens to sync workloads out to the cluster hardware. \[14, 15, 16\]

## ---

**Repository 1: gitops-infra (Infrastructure & Platforms)**

This repository contains your cluster building blocks and environment configurations. \[17\]

`gitops-infra/`  
`├── .github/workflows/                 # Automation runners for provisioning`  
`│   ├── tofu-apply-dev.yaml`              
`│   └── tofu-apply-staging.yaml`          
`├── bootstrap/                         # Root of Apps pattern config`  
`│   ├── root-app-of-apps.yaml          # Deploys infrastructure + platform syncs`  
`│   └── platform-app-set.yaml          # ArgoCD ApplicationSet for multi-cluster`  
`├── infrastructure/                    # LAYER 1: Base Host Infrastructure`  
`│   ├── cilium/`  
`│   │   ├── base/                      # Core Cilium manifests`  
`│   │   └── overlays/`  
`│   │       ├── dev/                   # Dev L2 IPAM configurations`  
`│   │       ├── staging/               # Staging IP configurations`  
`│   │       └── production/            # ClusterMesh cross-connect config`  
`│   └── rook-ceph/`  
`├── iam/                               # LAYER 2: Access Management`  
`│   ├── casdoor/`  
`│   └── casbin/`  
`├── platform/                          # LAYER 3: Shared Cluster Services`  
`│   ├── gateway/                       # (Formerly envoy-gateway)`  
`│   ├── spegel/                        # Distributed P2P cache`  
`│   ├── knative/`  
`│   ├── spinkube/`  
`│   ├── kafka/`  
`│   ├── pulsar/`  
`│   ├── clickhouse/                    # High-load telemetry platform`  
`│   └── databases/                     # OLTP (yugabytedb, couchdb, keydb, arcadedb)`  
`└── provisioning/                      # Bare-Metal Bare-VM Orchestration`  
    `├── tofu-libvirt-dev/              # Local dev profile configurations`  
    `│   ├── main.tf`  
    `│   └── variables.tf`  
    `└── tofu-libvirt-staging/          # Remote staging execution profile`  
        `├── main.tf`  
        `└── variables.tf`

## ---

**Repository 2: gitops-workloads (The Kargo/ArgoCD Engine Room)**

This is the repository that **Kargo** writes to. It isolates the actual applied manifests (functions and spins) into declarative stage folder layers.

`gitops-workloads/`  
`├── kargo/                             # Kargo Engine Declarations`  
`│   ├── stages.yaml                    # Pipeline: Dev -> Staging -> Prod (Multi-Region)`  
`│   └── warehouse.yaml                 # Listens to Harbor OCI & gitops-infra paths`  
`├── workloads/                         # LAYER 4: The Functional Workload Defs`  
`│   ├── functions/                     # Knative Container Apps`  
`│   │   ├── base/                      # Template ksvc.yaml`  
`│   │   └── overlays/                  # Environment Customizations (Replicas/Env Vars)`  
`│   │       ├── dev/`  
`│   │       ├── staging/`  
`│   │       └── production/            # Region variations (prod-us, prod-eu)`  
`│   └── spins/                         # SpinKube Wasm Apps`  
`│       ├── base/                      # Template spinapp.yaml`  
`│       └── overlays/`  
`│           ├── dev/`  
`│           ├── staging/`  
`│           └── production/`  
`└── argocd-apps/                       # ArgoCD Target Configuration Wrappers`  
    `├── dev-workloads.yaml             # Points to workloads/overlays/dev`  
    `├── staging-workloads.yaml         # Points to workloads/overlays/staging`  
    `└── production-workloads-mesh.yaml # ApplicationSet for 5-region clusters`

## ---

**Core Pipeline Manifests**

To orchestrate this workflow, apply these two file configurations inside your gitops-workloads/kargo/ directory to coordinate image progression with ArgoCD.

## **1\. The Warehouse Configuration (warehouse.yaml)**

The Warehouse monitors your on-premises Harbor registry for new container versions or WebAssembly OCI images. When it discovers a new digest, it captures it as an actionable piece of data (*Freight*).

`apiVersion: kargo.akuity.io/v1alpha1`  
`kind: Warehouse`  
`metadata:`  
  `name: telemetry-pipeline-warehouse`  
  `namespace: kargo-system`  
`spec:`  
  `subscriptions:`  
    `# 1. Tracks Knative functions`  
    `- image:`  
        `repo: harbor.private.lan/telemetry/knative-processor`  
        `semverConstraint: "^1.0.0"`  
        `discoveryLimit: 5`  
    `# 2. Tracks SpinKube Wasm modules`  
    `- image:`  
        `repo: harbor.private.lan/telemetry/spin-sink`  
        `semverConstraint: "^1.0.0"`  
        `discoveryLimit: 5`

## **2\. The Multi-Stage Promotion Pipeline (stages.yaml) \[18, 19, 20\]**

This configuration establishes your promotion workflow. When a change passes verification, Kargo modifies the image references inside the corresponding Kustomize directory overlay and commits the update back to Git. ArgoCD then catches the commit and updates the live environments. \[21, 22, 23, 24\]

`apiVersion: kargo.akuity.io/v1alpha1`  
`kind: Stage`  
`metadata:`  
  `name: dev`  
  `namespace: kargo-system`  
`spec:`  
  `# Dev directly consumes fresh Freight from the Warehouse`  
  `requestedFreight:`  
    `- warehouse: telemetry-pipeline-warehouse`  
  `promotionMechanisms:`  
    `gitRepoUpdates:`  
      `- repoURL: https://private.lan`  
        `writeBranch: main`  
        `kustomize:`  
          `images:`  
            `# Replaces image digests in your dev overlay`  
            `- image: harbor.private.lan/telemetry/knative-processor`  
              `path: workloads/functions/overlays/dev`  
            `- image: harbor.private.lan/telemetry/spin-sink`  
              `path: workloads/spins/overlays/dev`  
`---`  
`apiVersion: kargo.akuity.io/v1alpha1`  
`kind: Stage`  
`metadata:`  
  `name: staging`  
  `namespace: kargo-system`  
`spec:`  
  `# Staging can only accept Freight that has been verified in Dev`  
  `requestedFreight:`  
    `- sources:`  
        `stages: [ "dev" ]`  
  `promotionMechanisms:`  
    `gitRepoUpdates:`  
      `- repoURL: https://private.lan`  
        `writeBranch: main`  
        `kustomize:`  
          `images:`  
            `- image: harbor.private.lan/telemetry/knative-processor`  
              `path: workloads/functions/overlays/staging`  
            `- image: harbor.private.lan/telemetry/spin-sink`  
              `path: workloads/spins/overlays/staging`  
`---`  
`apiVersion: kargo.akuity.io/v1alpha1`  
`kind: Stage`  
`metadata:`  
  `name: production`  
  `namespace: kargo-system`  
`spec:`  
  `# Production requires promotion approval out of your Staging validations`  
  `requestedFreight:`  
    `- sources:`  
        `stages: [ "staging" ]`  
  `promotionMechanisms:`  
    `gitRepoUpdates:`  
      `- repoURL: https://private.lan`  
        `writeBranch: main`  
        `kustomize:`  
          `images:`  
            `# Simultaneously flashes updates across your production overlays`  
            `- image: harbor.private.lan/telemetry/knative-processor`  
              `path: workloads/functions/overlays/production`  
            `- image: harbor.private.lan/telemetry/spin-sink`  
              `path: workloads/spins/overlays/production`

## ---

**The Lifecycle of a Code Change**

1. **Commit:** A developer updates a WebAssembly telemetry module in the code repo and tags it v1.0.4.  
2. **Build:** The CI pipeline compiles the .wasm file, builds an OCI artifact, and pushes it to **Harbor**. \[25\]  
3. **Catch:** Kargo's **Warehouse** detects the new image in Harbor and alerts your pipeline stages. \[26, 27\]  
4. **Deploy Dev:** Kargo updates the workloads/spins/overlays/dev/kustomization.yaml file with the new image hash. **ArgoCD** catches this change and updates your local QEMU/libvirt environment. **Spegel** distributes the cached image layer across your dev nodes to avoid registry pull limits.  
5. **Promote Staging:** Once verified, Kargo copies that exact image hash to your staging overlay folder, triggering ArgoCD to deploy it to your remote staging server.  
6. **Deploy Production Mesh:** After final approval, Kargo writes the configuration to your production overlay folder. ArgoCD uses an **ApplicationSet** to instantly deploy and scale the updated code across all 5 bare-metal production clusters simultaneously.

Would you like to see how to structure the **ArgoCD ApplicationSet configuration manifest** to map deployments across your 5 multi-regional production clusters over the VPN mesh?

\[1\] [https://repo1.dso.mil](https://repo1.dso.mil/big-bang/customers/template/-/blob/main/README.md)  
\[2\] [https://codefresh.io](https://codefresh.io/docs/docs/ci-cd-guides/gitops-deployments/)  
\[3\] [https://help.fortrabbit.com](https://help.fortrabbit.com/bitbucket)  
\[4\] [https://docs.kargo.io](https://docs.kargo.io/user-guide/reference-docs/promotion-templates)  
\[5\] [https://blog-igh9410.vercel.app](https://blog-igh9410.vercel.app/blog/ecs-cicd-pipeline)  
\[6\] [https://iter8-tools.github.io](https://iter8-tools.github.io/iter8/0.7/tutorials/istio/gitops/argocd/)  
\[7\] [https://blog.searce.com](https://blog.searce.com/ci-cd-with-cloud-build-and-argocd-on-gke-5b2afe316177)  
\[8\] [https://medium.com](https://medium.com/empathyco/documentation-as-code-10e83b02a3a5)  
\[9\] [https://www.xenonstack.com](https://www.xenonstack.com/blog/gitops-continuous-delivery-workflow)  
\[10\] [https://itnext.io](https://itnext.io/git-is-not-your-source-of-truth-rethinking-gitops-for-kubernetes-platforms-e50666f38e5e)  
\[11\] [https://vinothecloudone.medium.com](https://vinothecloudone.medium.com/yet-another-harbor-registry-architecture-for-vsphere-with-tanzu-yaha-43395f6547e3)  
\[12\] [https://www.getunleash.io](https://www.getunleash.io/blog/gitops-vs-traditional-ci-cd)  
\[13\] [https://medium.com](https://medium.com/@ahmed.fathy.elayaat/gitops-fc27ef5a7836)  
\[14\] [https://www.educative.io](https://www.educative.io/blog/what-is-ci-cd-devops)  
\[15\] [https://kubernetes-tutorial.schoolofdevops.com](https://kubernetes-tutorial.schoolofdevops.com/argo_kargo/)  
\[16\] [https://production-gitops.dev](https://production-gitops.dev/guides/cp4ba/process-mining/cluster-config/gitops-config/)  
\[17\] [https://seifrajhi.github.io](https://seifrajhi.github.io/blog/kubefirst-production-ready-kubernetes-platform/)  
\[18\] [https://2024.platformcon.com](https://2024.platformcon.com/talks/kargo-multistage-deployment-pipelines-using-gitops)  
\[19\] [https://dev.to](https://dev.to/n3wt0n/container-image-promotion-across-environments-yaml-1ca6)  
\[20\] [https://4bes.nl](https://4bes.nl/2020/03/04/azure-devops-for-the-it-pro-tips-tricks/)  
\[21\] [https://piotrminkowski.com](https://piotrminkowski.com/2025/01/14/continuous-promotion-on-kubernetes-with-gitops/)  
\[22\] [https://docs.akuity.io](https://docs.akuity.io/tutorials/kargo-quickstart/)  
\[23\] [https://oneuptime.com](https://oneuptime.com/blog/post/2026-02-26-argocd-best-git-repo-structure/view)  
\[24\] [https://github.com](https://github.com/clowdhaus/trunk-based-artifact-promotion)  
\[25\] [https://itnext.io](https://itnext.io/git-is-not-your-source-of-truth-rethinking-gitops-for-kubernetes-platforms-e50666f38e5e)  
\[26\] [https://akuity.io](https://akuity.io/blog/what-s-new-in-kargo-v1-8)  
\[27\] [https://akuity.io](https://akuity.io/blog/promotion-made-easy-with-kargo)