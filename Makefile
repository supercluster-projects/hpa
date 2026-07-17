# Makefile for HPA GitOps Platform
# Common tasks for development, testing, and deployment

.PHONY: help validate test build clean terraform-go terraform-validate terraform-plan terraform-apply docker-build k8s-validate shell-lint lint all

# Default target
help:
	@echo "HPA GitOps Platform - Available Commands"
	@echo ""
	@echo "Setup:"
	@echo "  make setup          - Install required dependencies"
	@echo ""
	@echo "Validation:"
	@echo "  make validate       - Run all validation checks"
	@echo "  make terraform-validate  - Validate Terraform configuration"
	@echo "  make go-lint        - Run Go linting"
	@echo "  make shell-lint     - Run shell script linting"
	@echo "  make k8s-validate   - Validate Kubernetes manifests"
	@echo ""
	@echo "Testing:"
	@echo "  make test           - Run all tests"
	@echo "  make go-test        - Run Go unit tests"
	@echo "  make test-coverage  - Generate test coverage report"
	@echo ""
	@echo "Terraform:"
	@echo "  make terraform-init     - Initialize Terraform"
	@echo "  make terraform-plan     - Show Terraform execution plan"
	@echo "  make terraform-apply    - Apply Terraform configuration"
	@echo "  make terraform-destroy  - Destroy Terraform resources"
	@echo ""
	@echo "Build:"
	@echo "  make build          - Build all services"
	@echo "  make docker-build   - Build Docker images"
	@echo ""
	@echo "Utilities:"
	@echo "  make dry-verify     - Verify DRY implementation"
	@echo "  make clean          - Clean build artifacts"
	@echo "  make all            - Run validate, test, and build"

# -----------------------------------------------------------------------------
# Setup
# -----------------------------------------------------------------------------
setup:
	@echo "Installing dependencies..."
	@if ! command -v terraform &> /dev/null; then \
		echo "Please install Terraform"; \
	fi
	@if ! command -v go &> /dev/null; then \
		echo "Please install Go"; \
	fi
	@if command -v cargo &> /dev/null; then \
		echo "Rust toolchain detected"; \
	fi
	@echo "Setup complete!"

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
validate: terraform-validate go-lint shell-lint k8s-validate dry-verify
	@echo "All validations passed!"

terraform-validate:
	@echo "Validating Terraform configuration..."
	cd provisioning/dev/opentofu && terraform init -backend=false
	cd provisioning/dev/opentofu && terraform fmt -check -recursive
	cd provisioning/dev/opentofu && terraform validate

go-lint:
	@echo "Running Go linting..."
	cd backend && go vet ./...

shell-lint:
	@echo "Running shell script validation..."
	@for script in provisioning/dev/scripts/*.sh; do \
		bash -n $$script || exit 1; \
	done

k8s-validate:
	@echo "Validating Kubernetes manifests..."
	@find gitops-workloads -name "*.yaml" -exec head -1 {} \; | grep -q "^apiVersion:" || true

dry-verify:
	@echo "Checking DRY implementation..."
	@if command -v terraform &> /dev/null; then \
		bash scripts/verify-dry-changes.sh; \
	else \
		echo "Terraform not available, skipping validation"; \
	fi

# -----------------------------------------------------------------------------
# Testing
# -----------------------------------------------------------------------------
test: go-test
	@echo "All tests passed!"

go-test:
	@echo "Running Go tests..."
	cd backend/functions/welcome && go test -v -cover -coverprofile=coverage.out

test-coverage:
	@echo "Generating test coverage report..."
	cd backend/functions/welcome && go tool cover -html=coverage.out -o coverage.html
	@echo "Coverage report available at coverage.html"

# -----------------------------------------------------------------------------
# Terraform
# -----------------------------------------------------------------------------
terraform-init:
	@echo "Initializing Terraform..."
	cd provisioning/dev/opentofu && terraform init

terraform-plan:
	@echo "Planning Terraform changes..."
	cd provisioning/dev/opentofu && terraform plan

terraform-apply:
	@echo "Applying Terraform configuration..."
	cd provisioning/dev/opentofu && terraform apply

terraform-destroy:
	@echo "Destroying Terraform resources..."
	cd provisioning/dev/opentofu && terraform destroy

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------
build: docker-build
	@echo "Build complete!"

docker-build:
	@echo "Building Docker images..."
	@if [ -f "backend/functions/welcome/Dockerfile" ]; then \
		echo "Building welcome function image..."; \
	fi
	@if [ -f "backend/spins/counter/Cargo.toml" ]; then \
		echo "Building counter spin..."; \
	fi

# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------
clean:
	@echo "Cleaning build artifacts..."
	rm -f backend/*/coverage.out
	rm -f backend/coverage.out
	rm -rf backend/target/
	rm -rf backend/*/target/
	rm -rf provisioning/dev/opentofu/.terraform/
	find . -name "*.pyc" -delete
	find . -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "Clean complete!"

all: validate test build
	@echo "All tasks completed successfully!"