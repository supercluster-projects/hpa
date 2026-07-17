# Architecture Documentation

This directory contains the architecture documentation for the HPA GitOps Platform.

**Note:** Much of this documentation has been consolidated into the main [README.md](../../README.md). This directory contains supplementary diagrams and detailed workflow documentation.

## Contents

### Overview Diagrams

- **Architecture Diagram** (`../README.md` → Architecture section) - Main platform architecture with Hub-and-Spoke topology
- **Component Architecture** - ASCII architecture layout
- **Platform Components** - Detailed breakdown of all components

### C4 Model Diagrams (Draw.io Format)

These diagrams can be opened directly in Draw.io (diagrams.net):

- **C4-system-context.drawio** - System Context view (Level 1)
  - Shows the platform boundary, external systems, and major components
  - Open in Draw.io: File → Import From → Device

- **C4-containers.drawio** - Container View (Level 2)
  - Shows containers within key components
  - Open in Draw.io: File → Import From → Device

### Detailed Documentation

- **Kargo Workflow** (`kargo-workflow.md`) - Progressive delivery pipeline details
- **Observability Diagram** (`observability-diagram.md`) - Metrics collection and monitoring stack

## Quick Start

1. Read the main [README.md](../../README.md) for the complete architecture overview
2. Open `C4-system-context.drawio` in Draw.io for the system context diagram
3. Review specific documentation in this folder as needed