# Implementation Documentation

This directory contains detailed implementation guides for the HPA GitOps Platform.

## Contents

### Getting Started
- [Quick Start Guide](../guides/quickstart.md) - Quick start to the platform

### Infrastructure
- [Local Setup Guide](../guides/local-setup.md) - Setting up local development environment
- [Terraform Configuration](./terraform-config.md) - OpenTofu/Terraform documentation
- [Talos Configuration](./talos-config.md) - Talos Linux configuration

### Application Development
- [Backstage Templates](./backstage-templates.md) - Creating developer templates
- [Go Services](./go-services.md) - Go application development guide
- [Rust Spins](./rust-spins.md) - Rust Spin applications documentation

### CI/CD
- [GitLab CI Pipeline](./gitlab-ci.md) - CI/CD pipeline details
- [Testing Strategy](./testing-strategy.md) - Testing approach and coverage

### GitOps
- [ArgoCD Setup](./argocd-setup.md) - ArgoCD configuration and best practices
- [Kargo Promotions](./kargo-promotions.md) - Progressive delivery workflows

## Development Workflow

1. Set up local environment: `make setup`
2. Review architecture: See `/docs/architecture/`
3. Make changes following coding standards
4. Run validation: `make validate`
5. Run tests: `make test`
6. Submit PR with CI passing