# HPA Enterprise GitOps Platform

A comprehensive, multi-component platform implementing progressive delivery, GitOps, and developer self-service using Talos Linux, OpenTofu, Kargo, Argo CD, and Backstage on libvirt/QEMU infrastructure.

## Overview

This project provides an Enterprise GitOps Platform with:

- **Talos Linux** - Kubernetes-native operating system
- **OpenTofu** - Infrastructure as Code for VM provisioning
- **Kargo** - Progressive delivery and promotion pipelines
- **Argo CD** - GitOps continuous delivery
- **Backstage** - Developer portal and self-service
- **Cilium** - eBPF-based CNI for networking
- **Infisical** - Secrets management
- **VictoriaMetrics** - Observability stack

## Documentation Structure

```
docs/
├── architecture/          # Architecture diagrams and overviews
│   ├── INDEX.md         # Architecture docs index
│   ├── overview.md      # Platform overview
│   ├── arch-diagram.md  # Main architecture diagram
│   └── kargo-workflow.md # Kargo implementation (from SP files)
├── implementation/      # Detailed implementation guides
│   ├── INDEX.md         # Implementation docs index
│   └── ...
├── guides/              # How-to guides
│   ├── INDEX.md         # Guides index
│   └── quickstart.md    # Getting started guide
└── user-stories/        # User stories and requirements
    ├── INDEX.md         # User stories index
    └── UP - 00 - Backstage Kargo ArgoCD with Fleet.md
```

## Quick Start

```bash
# Clone the repository
git clone https://github.com/your-org/platform-infra-fleet.git
cd platform-infra-fleet

# Install prerequisites (see docs/guides/local-setup.md)
# - Terraform/OpenTofu
# - Go 1.21+
# - Rust/Cargo 1.70+

# Run quick validation
make terraform-validate
make go-test

# See Makefile for all available commands
make help
```

## Development

### Available Commands

```bash
make help           # Show all available commands
make setup          # Install dependencies
make validate       # Run all validation checks
make test           # Run all tests
make terraform-validate  # Validate Terraform configuration
make go-test        # Run Go unit tests
make terraform-plan # Show Terraform execution plan
make clean          # Clean build artifacts
make all            # Run validate, test, and build
```

### Project Structure

```
.
├── provisioning/              # OpenTofu/Terraform infrastructure
│   └── dev/opentofu/        # Development cluster definitions
├── gitops-workloads/         # Kubernetes manifests
│   ├── authorizers/         # Authorization services (Casbin, Casdoor)
│   ├── functions/           # Knative services and SpinApps
│   ├── security/            # Security policies
│   └── kafka/               # Kafka infrastructure
├── backend/                  # Backend services
│   ├── functions/           # Go HTTP handlers
│   └── spins/               # Rust Spin applications
├── scripts/                 # Utility scripts
└── docs/                    # Documentation
```

## Key Features

### 1. GitOps with Argo CD
- Automated sync from Git repositories to clusters
- Multi-cluster fleet management via ApplicationSets
- Drift detection and auto-reconciliation

### 2. Progressive Delivery with Kargo
- Warehouse pattern for artifact detection
- Multi-stage promotion (dev → staging → production)
- Automated canary analysis with VictoriaMetrics

### 3. Developer Self-Service with Backstage
- Scaffolding templates for Go microservices
- Integrated Argo CD plugin for deployment status
- Policy-as-code with OPA/Kyverno

### 4. Infrastructure Automation
- OpenTofu for libvirt/QEMU VM provisioning
- Talos Linux for Kubernetes-native infrastructure
- Cilium CNI with ClusterMesh for multi-cluster networking

## CI/CD Pipeline

The project uses GitLab CI for automated validation:

1. **Terraform Validation** - Infrastructure configuration checks
2. **Go Tests** - Unit tests with coverage
3. **Shell Lint** - Static analysis for shell scripts
4. **K8s Validation** - Kubernetes manifest syntax checks
5. **Secret Scan** - Detect hardcoded credentials
6. **DRY Verification** - Ensure configuration centralization

See `.gitlab-ci.yml` for full pipeline definition.

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our development process, coding standards, and contribution workflow.

## Security

- **Never commit secrets** - Use `.env` files for local development
- Terraform state files are ignored by default
- Regularly rotate credentials via Infisical

## License

[Add your license here]