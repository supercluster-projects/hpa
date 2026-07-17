# Contributing to HPA GitOps Platform

Thank you for your interest in contributing to the HPA Enterprise GitOps Platform! This document provides guidelines and instructions for contributing.

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
├── provisioning/              # Terraform/OpenTofu infrastructure as code
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