# Kubernetes Cluster Development Status Report

**Date**: 2026-07-28  
**Repository**: `HPA Enterprise GitOps Platform`  
**Environment**: Local Fedora/libvirt Talos dev cluster on `hpa-bridge`

## Current Status: RUNNING

The Talos/Kubernetes development cluster is bootstrapped, Cilium CNI is installed, and the checked Kubernetes components are healthy.

### Verified Running Components

| Component | Status | Details |
|---|---:|---|
| Talos VMs | ✅ Running | 1 control plane + 3 workers |
| Kubernetes API | ✅ Ready | `kubectl --kubeconfig provisioning/dev/opentofu/kubeconfig get nodes` |
| Nodes | ✅ Ready | All 4 nodes report `Ready` |
| Control plane pods | ✅ Running | kube-apiserver/controller/scheduler healthy |
| Cilium CNI | ✅ Running | DaemonSet healthy on all 4 nodes |
| Cilium L2 LB | ✅ Running | Hubble UI exposed at `http://192.168.122.210` |
| CoreDNS | ✅ Running | Ready on the cluster |
| Hubble Relay/UI | ✅ Running | Hubble UI HTTP check returned `200 OK` |

## Verification Commands Run

```bash
bash provisioning/dev/scripts/steps/step-01-provisioning/install-provision.sh
BOOTSTRAP_TIMEOUT_SECONDS=120 bash provisioning/dev/scripts/steps/step-01-provisioning/bootstrap-talos.sh
bash provisioning/dev/scripts/steps/step-02-cilium/install-cilium.sh
bash provisioning/dev/scripts/steps/step-02-cilium/verify-cilium.sh
kubectl --kubeconfig provisioning/dev/opentofu/kubeconfig get nodes -o wide
kubectl --kubeconfig provisioning/dev/opentofu/kubeconfig get pods -A --no-headers
curl -fsS --max-time 10 http://192.168.122.210/
```

Latest verification result:

```text
Nodes: 4/4 Ready
Cilium agents: 4/4 ready
Hubble UI: HTTP 200
Overall verdict: PASS
```

## Recent Fixes Applied

### Network / DHCP / NAT

- Fixed `setup-bridge.sh` so privileged operations consistently use `run_as_root()`.
- Fixed `dnsmasq` lease/log permissions so DHCP can write after privilege drop.
- Fixed bridge mode with `allmulticast` instead of invalid `allmulti`.
- Added `hpa-bridge` to the `libvirt` firewalld zone.
- Added DHCP router/DNS options:
  - `option:router,192.168.122.1`
  - `option:dns-server,192.168.122.1`
- Added host-side NAT/FORWARD rules after firewalld reload so Talos nodes can reach public registries.
- Verified DHCP leases and external connectivity from the bridge subnet.

### Talos / Kubernetes Bootstrap

- Fixed the Talos machine config schema error in `cluster-config.yaml.tftpl`: offline registry mirrors are now under `machine.registries.mirrors` for Talos v1.13+, instead of an invalid top-level `registries:` block.
- Added a regression guard in logs by making `talosctl bootstrap` idempotent: `AlreadyExists` for an existing etcd data directory is treated as a warning and the script continues to readiness polling.
- Updated kubeconfig extraction to force-overwrite the local kubeconfig instead of repeatedly renaming contexts on repeated runs.
- Disabled bootstrap image pre-pull by default in `install-provision.sh` because Talos API readiness lags behind libvirt boot; the local bootstrap registry is seeded before VMs boot and pre-pull can be enabled with `PRE_PULL_BOOTSTRAP_IMAGES=true`.
- Removed stale OpenTofu/Talos state that pointed kubeconfig and Talos config at old, unreachable VM IPs.
- Fixed `cleanup-preflight.sh` stale-state cleanup.
- Reworked bootstrap readiness so it no longer waits for Kubernetes `Ready=True` before Cilium is installed. The bootstrap script now treats bootstrap as usable when nodes are registered, Talos core services are running, and control-plane static pods are ready; `BOOTSTRAP_READINESS_MODE=ready` remains available for strict Node Ready checks.
- Updated Talos readiness checks to use Talos v1.13 `machinestatuses` instead of removed/old `machines`.
- Restored `talosctl` to v1.13.5 and hardened the installer to avoid overwriting a valid binary with a failed download.
- Removed the unconditional local registry mirror configuration from `cluster-config.yaml.tftpl` because no mirror was running at `192.168.122.1:5000`.
- Added conditional offline bootstrap registry mirrors to `cluster-config.yaml.tftpl` when `OFFLINE_MODE=true`, mirroring `registry.k8s.io`, `ghcr.io`, `quay.io`, and `docker.io` to `${GATEWAY_IP}:5000`.
- Added `OFFLINE_MODE` OpenTofu variable, passed through `dev.auto.tfvars`, and wired it into the Talos machine configuration template.
- Added bootstrap image pre-pull logic to `install-provision.sh` for:
  - `registry.k8s.io/etcd:v3.6.12`
  - `ghcr.io/siderolabs/kubelet:v1.36.0`
  - The pre-pull is now opt-in via `PRE_PULL_BOOTSTRAP_IMAGES=true` and disabled by default to avoid noisy failures during first boot.
- Added `setup-local-registry.sh` integration in `install-provision.sh` so fresh offline runs prepare the local bootstrap registry before VMs boot.
- Added `SUDO_PASSWORD` handling: privileged operations now use `SUDO_PASSWORD` from `.env` when present, otherwise they prompt once and read the password silently. Added a commented `.env.example` entry for `SUDO_PASSWORD`.
- Added clearer bootstrap wait logging so `Waiting for Talos/Kubernetes bootstrap to become usable` now explains that Talos services and Kubernetes static pods are being waited on, while Kubernetes Node Ready may intentionally wait for Cilium CNI. Helm/workload installation has not started yet.
- Enhanced `bootstrap-status.log` with per-node component status columns and compact component log summaries for failing/non-running Talos services.

## Logs and Artifacts

Useful logs are in:

| File | Purpose |
|---|---|
| `provisioning/dev/startup.log` | Full startup transcript |
| `provisioning/dev/bootstrap-status.log` | Per-node Talos bootstrap status table |
| `provisioning/dev/cluster-diagnostics.log` | Per-node Talos diagnostics, image pull errors, service status |
| `provisioning/dev/.tofu-apply.log` | OpenTofu apply transcript |
| `provisioning/dev/opentofu/kubeconfig` | Kubernetes kubeconfig |
| `provisioning/dev/opentofu/talosconfig` | Talos config |

## Current Known Notes

- Cilium LB pool conditions may still show `Unknown` while the pool is active; the critical checks are agents, policy, and Hubble UI HTTP.
- If future runs fail during first boot image pulls, inspect:
  - `provisioning/dev/cluster-diagnostics.log`
  - `sudo tail -200 /var/log/dnsmasq-hpa-bridge.log`
  - `sudo iptables -t nat -S POSTROUTING`
  - `sudo iptables -S FORWARD`
- If bootstrap pre-pull is enabled and nodes are still booting, `talosctl image pull` may fail because Talos API is not ready yet. Keep `PRE_PULL_BOOTSTRAP_IMAGES=false` unless you have verified the nodes can answer Talos service calls.
- If the cluster was recreated, always run cleanup preflight before startup so stale Talos state cannot point to old IPs.
