# Dry-Run Pipeline Execution Guide

**Purpose:** Step-by-step instructions for running the HPA dev cluster provisioning pipeline on a real KVM/libvirt host. This document serves as the operator's manual when KVM hardware becomes available.

**Prerequisites:** A Linux host with KVM/libvirt, 32GB+ RAM, 4+ CPU cores, 100GB+ free disk.

---

## Phase 1: Host Setup

Run on the target bridge host (e.g., `hpa-bridge`):

```bash
# Clone the repo or sync to the bridge host
git clone <repo-url> /path/to/hpa-dev
cd /path/to/hpa-dev

# Run one-shot host setup
./provisioning/dev/scripts/setup-host.sh

# Expected outcome:
# - libvirtd running
# - hpa-bridge network created (192.168.122.0/24)
# - .env created from .env.example
# - Talos qcow2 image cached (~500MB)
# - tofu providers cached
```

### Verify Host Readiness

```bash
./provisioning/dev/scripts/host-preflight.sh

# Expected: ALL CHECKS PASSED
# If FAIL: resolve each issue before proceeding
# Common failures:
# - "libvirtd not reachable" → sudo systemctl start libvirtd
# - "CPU virtualization" → check BIOS settings for VT-x/AMD-V
# - "Memory insufficient" → close other VMs/applications
```

### Configure Secrets

Edit `.env` and fill in all `change-me` values:

```bash
vi .env

# Required:
# HARBOR_ADMIN_PASSWORD     - Harbor registry admin
# CASDOOR_ADMIN_PASSWORD    - Casdoor OIDC admin
# INFISICAL_ENCRYPTION_KEY  - openssl rand -hex 32
# INFISICAL_ADMIN_PASSWORD  - openssl rand -base64 16
# INFISICAL_AUTH_SECRET     - openssl rand -hex 64
# GITOPS_REPO_URL           - Your GitOps manifests repo

# Optional but recommended to change:
# CLICKHOUSE_ADMIN_PASSWORD - overrides default in install-clickhouse.sh
```

---

## Phase 2: Provision Cluster

### Option A: Full Pipeline (Recommended)

```bash
./provisioning/dev/scripts/run-pipeline.sh

# This runs startup.sh with resilience features.
# Duration: 30-60 minutes depending on hardware.
# Log: startup.log
# Report: provisioning/dev/scripts/pipeline-report.md
```

### Option B: Direct startup.sh

```bash
./provisioning/dev/scripts/startup.sh

# Duration: 30-60 minutes.
# All output captured to startup.log.
# First failure stops the pipeline (step() function calls die()).
# Resume: fix the issue, then re-run (tofu step skipped if kubeconfig exists).
```

### Option C: Resume from Step

```bash
# After fixing a failure:
./provisioning/dev/scripts/run-pipeline.sh --skip-tofu --resume-from <STEP_NUM>

# Example: resume from step 25 (Pulsar) after fixing a ClickHouse issue
./provisioning/dev/scripts/run-pipeline.sh --skip-tofu --resume-from 25
```

---

## Phase 3: Verification

After the pipeline completes, verification scripts run automatically. To run them manually:

```bash
# All components
./provisioning/dev/scripts/verify-cilium.sh
./provisioning/dev/scripts/verify-ceph.sh
./provisioning/dev/scripts/verify-harbor.sh
./provisioning/dev/scripts/verify-infisical.sh
./provisioning/dev/scripts/verify-runtimes.sh
./provisioning/dev/scripts/verify-kafka.sh
./provisioning/dev/scripts/verify-spegel.sh
./provisioning/dev/scripts/verify-casdoor.sh
./provisioning/dev/scripts/verify-casbin.sh
./provisioning/dev/scripts/verify-gateway.sh
./provisioning/dev/scripts/verify-security-policy.sh
./provisioning/dev/scripts/verify-gitops.sh
./provisioning/dev/scripts/verify-workloads.sh
./provisioning/dev/scripts/verify-streaming-workload.sh
./provisioning/dev/scripts/verify-yugabytedb.sh
./provisioning/dev/scripts/verify-hasura.sh
./provisioning/dev/scripts/verify-pulsar.sh
./provisioning/dev/scripts/verify-clickhouse.sh
./provisioning/dev/scripts/verify-analytics.sh
```

### Build Images

```bash
# Build all workload images and push to Harbor
./provisioning/dev/scripts/build-all.sh

# Verify images exist in Harbor
./provisioning/dev/scripts/verify-images.sh
```

### Build requirements:
- Docker (for Go function builds: welcome, casbin)
- Spin CLI (for WASM builds: counter, stream)
- Harbor must be reachable (cluster must be running)
- Login: `docker login <harbor-ip>` before building

---

## Phase 4: End-to-End Tests

### Welcome API Test

```bash
# Get Envoy LB IP
ENVOY_IP=$(kubectl -n envoy-gateway-system get svc envoy-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Test welcome endpoint
curl http://${ENVOY_IP}/api/welcome

# Expected: "Welcome 1"
# Second call should return: "Welcome 2"
```

### Playwright E2E Tests

```bash
cd e2e/
npm install
npx playwright test --list   # verify config
npx playwright test           # run tests

# Expected: 4/4 tests passing
# Tests verify: Welcome(N) format, count increment, content-type, admin dashboard
```

### Analytics Pipeline Test

```bash
# Produce a test event to raw-events topic
kubectl -n pulsar exec pulsar-toolset-0 -- bash -c \
  'echo "{\"uuid\":\"test-$(date +%s)\",\"dev\":\"sensor-a\",\"val\":42.5}" | \
  /pulsar/bin/pulsar-client produce persistent://public/default/raw-events --messages 1'

# Wait 10 seconds for processing, then verify in ClickHouse
kubectl -n clickhouse exec clickhouse-clickhouse-0 -- \
  clickhouse-client --query "SELECT COUNT(*), device_type FROM analytics_db.device_metrics GROUP BY device_type"

# Expected: at least 1 row with device_type='sensor-a'
```

### Build and Deploy Function Images

```bash
# Build all images and push to Harbor
./provisioning/dev/scripts/build-all.sh

# Verify
./provisioning/dev/scripts/verify-images.sh

# Expected: all 4 images listed (welcome, counter, stream, casbin)
```

---

## Phase 5: Troubleshooting

### Common Failures and Resolutions

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| `tofu apply` fails | Network or provider cache issue | Run `tofu init -upgrade` in provisioning/dev/opentofu/ |
| VMs stuck at "Not Ready" | DHCP conflict or slow boot | Check `virsh net-dhcp-leases hpa-bridge`, verify MAC-to-IP mapping |
| Ceph cluster unhealthy | Insufficient OSD disks | Verify /dev/vdb exists on each worker |
| Harbor ImagePullBackOff | ceph-rbd PVC not bound | Check `kubectl get pvc -n harbor` — may need to wait for Ceph |
| Knative service stuck | No route to counter service | Check `kubectl get ksvc -n hpa-workloads` |
| Pulsar pods CrashLoopBackOff | Insufficient memory on 3GB workers | Consider reducing workload count, increasing worker VM RAM |
| Pulsar function fails | topicLevelPoliciesEnabled missing | Verify broker config in install-pulsar.sh values |
| verify-analytics.sh fails | Function or sink not deployed | Run `install-function.sh` manually, check `pulsar-admin functions status` |

### Collecting Diagnostic Data

```bash
# Full cluster state snapshot
./provisioning/dev/scripts/run-pipeline.sh  # automatically collects diagnostics

# Or manually:
mkdir -p /tmp/hpa-diag
kubectl get nodes -o wide > /tmp/hpa-diag/nodes.txt
kubectl get pods --all-namespaces > /tmp/hpa-diag/pods.txt
kubectl get events --all-namespaces > /tmp/hpa-diag/events.txt
kubectl describe nodes > /tmp/hpa-diag/node-details.txt
tail -200 startup.log > /tmp/hpa-diag/startup-tail.txt

# Tar it up for sharing
tar czf hpa-diag-$(date +%Y%m%d).tar.gz /tmp/hpa-diag/
```

### Memory Pressure Mitigation

If workers run out of memory (3GB each is tight for all components):

1. **Reduce replica counts:** Set DEV_WORKER_COUNT=2 in .env (fewer workers, same total memory per worker)
2. **Increase worker RAM:** Set DEV_WORKER_RAM_MB=4096 in .env (requires host with more RAM)
3. **Disable non-essential components:** Comment out step lines in startup.sh for components not needed (e.g., Yugabytedb, Hasura, Pulsar/ClickHouse for initial testing)
4. **Use nodeSelector:** Pin memory-intensive workloads (Yugabytedb, Pulsar) to specific workers

---

## Phase 6: Full Cleanup

```bash
# Destroy all VMs and network
./provisioning/dev/scripts/cleanup.sh

# Full e2e lifecycle (create, verify, destroy)
./provisioning/dev/scripts/e2e-provisioning.sh
```

---

## Appendix: Expected Component Versions

| Component | Version | Source |
|-----------|---------|--------|
| Talos OS | v1.13.5 | .env TALOS_VERSION |
| OpenTofu | 1.9+ | setup-host.sh |
| Cilium | 1.16.5 | .env CILIUM_VERSION |
| Rook Ceph | v1.16.4 | .env ROOK_VERSION |
| Harbor | 2.12.2 | .env HARBOR_VERSION |
| Infisical | 0.89.1 | .env INFISICAL_VERSION |
| Knative | 1.16.0 | .env KNATIVE_VERSION |
| Strimzi Kafka | 0.45.0 | .env STRIMZI_VERSION |
| Casdoor | 3.100.0 | .env CASDOOR_VERSION |
| Envoy Gateway | 1.2.2 | .env ENVOY_VERSION |
| Pulsar | 3.0.0 | .env PULSAR_VERSION |
| ClickHouse | 24.12.1.1475 | .env CLICKHOUSE_VERSION |

## Appendix: Quick Reference

```bash
# === ONE-SHOT HOST SETUP ===
./provisioning/dev/scripts/setup-host.sh

# === PROVISION (30-60 min) ===
./provisioning/dev/scripts/run-pipeline.sh

# === VERIFY ===
./provisioning/dev/scripts/verify-workloads.sh --envoy-ip <IP>

# === BUILD IMAGES ===
./provisioning/dev/scripts/build-all.sh

# === E2E TESTS ===
cd e2e && npx playwright test

# === CLEANUP ===
./provisioning/dev/scripts/cleanup.sh
```
