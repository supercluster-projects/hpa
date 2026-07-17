# Architecture Documentation

This directory contains the architecture documentation for the HPA GitOps Platform.

## Contents

### Overview
- [Platform Overview](./overview.md) - High-level architecture overview
- [Architecture Diagram](./arch-diagram.md) - ASCII art architecture diagram
- [Observability Diagram](./observability-diagram.md) - Observability stack architecture

### C4 Model Diagrams (Draw.io Format)
These diagrams can be opened directly in Draw.io (diagrams.net):

- **C4-system-context.drawio** - System Context view (Level 1)
  - Shows the platform boundary, external systems, and major components
  - Open in Draw.io: File → Import From → Device

- **C4-containers.drawio** - Container View (Level 2)
  - Shows containers within key components
  - Open in Draw.io: File → Import From → Device

### Component Structure

```
Management Plane (Hub Cluster):
  └── Argo CD
      ├── API Server
      ├── Repository Server
      ├── Application Controller
      └── Dex SSO
  
  └── Kargo
      ├── Controller
      └── Server
  
  └── Backstage
      ├── Catalog
      ├── Scaffolder
      ├── Auth Service
      └── Proxy

Spoke Clusters (Dev/Staging/Prod):
  └── Gateway → Envoy
  └── Auth Layer
      ├── Casdoor (OIDC)
      └── Casbin (GRPC)
  
  └── Data Layer
      ├── Yugabytedb (SQL)
      └── KeyDB (Cache)
```

### Additional Resources
- [Kargo Workflow](./kargo-workflow.md) - Progressive delivery workflow
- [GitOps Pipeline](./gitops-pipeline.md) - ArgoCD and fleet management
- [Talos Offline Setup](./talos-offline.md) - Talos OS in offline mode
- [Libvirt Provisioning](./libvirt-provisioning.md) - Local VM infrastructure

## Quick Start

1. Open `C4-system-context.drawio` in Draw.io for the system overview
2. Open `C4-containers.drawio` for detailed container structure
3. Read [Architecture Diagram](./arch-diagram.md) for ASCII reference