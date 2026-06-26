# M010 Milestone Scope Assessment

**Generated:** 2026-06-26
**Context:** M008 S01 (qcow2 pre-installed disks) and S02 (talosctl cluster create dev wrapper) have been delivered. This assessment evaluates how each M010 slice is affected by M008 delivery and what work remains.

---

## M010 S01: Fix OpenTofu provisioning core

### What M008 resolved

- Replaced the ISO download + blank OS volume (qcow2 create) approach with a pre-installed Talos qcow2 base volume + COW clones per node.
- Eliminated the CDROM boot device and install-to-disk phase — VMs now boot directly from pre-installed Talos disks (`boot_devices = [{dev = "hd"}]`).
- The libvirt volume resource uses the native `create.content.url` mechanism, removing the old `null_resource.download_talos_iso`.
- The qcow2 URL uses the same schematic ID and image factory URL variable, preserving Talos customization (extensions, system extensions).
- The per-node OS disk configuration in `main.tf` is now correct for booting directly from qcow2.

### What remains

- `setup-bridge.sh` computes `DHCP_HOSTS` entries with deterministic MAC addresses (derived from IP last octet), but these entries are **never injected into the libvirt network XML**. The XML template only has a bare `<range>` element — no `<host>` elements.
- Without static DHCP leases, VMs get random IPs from the DHCP pool instead of the expected static IPs (e.g. `.100`, `.101`, `.110` etc.).
- `talos_machine_configuration_apply` in `main.tf` targets nodes by the static IP — if the VM has a different DHCP-assigned IP, the apply step cannot connect.
- The `DHCP_HOSTS` variable is populated but completely unused.

### Scope change

**scoped-down** — The core provisioning path is now structurally correct (qcow2 boots, no ISO phase), but the DHCP static lease integration in `setup-bridge.sh` remains the blocking issue. M010 S01 work reduces to: inject the computed `DHCP_HOSTS` entries as `<host>` elements in the libvirt network XML template.

---

## M010 S02: Talos offline image cache

### What M008 resolved

Nothing. This slice is independent of the qcow2/image-factory path — it concerns an offline cache layer (`prep-cache.sh`) for environments without image factory access.

### What remains

- The full scope as originally planned: a `prep-cache.sh` script that downloads Talos images on a connected machine, creates a transferable archive (USB drive / LAN file share), and a restore mechanism on the air-gapped dev machine.
- M008's `cluster-create.sh` supports `--image-factory-url` and `--schematic-id` for custom images, which the offline cache could use to serve local images.
- M008's `cluster-create.sh` uses talosctl's native image resolution — offline support would need talosctl to be configured with a local registry mirror.

### Scope change

**unchanged** — No M008 work addresses offline caching. The full slice scope remains.

---

## M010 S03: Cilium CNI kube-proxy-free with L2 LoadBalancer

### What M008 resolved

Nothing directly. M008 did not touch Cilium configuration or cluster addons.

### What remains

The `install-cilium.sh` script already:
- Deploys `CiliumLoadBalancerIPPool` CRD (`hpa-dev-lb-pool`)
- Deploys `CiliumL2AnnouncementPolicy` CRD (`hpa-dev-l2-policy`)
- Configures L2 announcements and external IPs

However:
- `kubeProxyReplacement=disabled` is still the active Helm value in `install-cilium.sh`.
- The switch to `kubeProxyReplacement=true` with a `CiliumNodeConfig` for device selection is still unaddressed.
- The CRD deployment (steps 4-5 in install-cilium.sh) is already done, but the actual kube-proxy-free mode is not enabled.
- For the talosctl path (`cluster-create.sh`), Cilium must be installed separately — the talosctl wrapper doesn't include Cilium installation.

### Scope change

**scoped-down** — The CRD scaffolding (LB pool, L2 announcement policy) is already deployed by `install-cilium.sh`. Remaining work: switch `kubeProxyReplacement` to `true`, add `CiliumNodeConfig` for device selection, and verify the talosctl path has Cilium integration.

---

## M010 S04: Build startup.sh automated pipeline

### What M008 resolved

- The `startup.sh` pipeline already exists with 16 steps, CLI parsing, `.env` generation from `.env.example`, and logging to `startup.log`.
- M008 S01 fixed the OpenTofu step within `startup.sh` (step 0) — the qcow2 base volume approach is now the provisioning mechanism used when `startup.sh` runs `tofu apply`.
- M008 S02 provides the `cluster-create.sh` fast-path alternative, which `startup.sh` could optionally use with `--skip-tofu` for a lighter dev setup.

### What remains

- Integration with the offline image cache (M010 S02) for fully air-gapped startup.
- Runtime verification scripts that exercise the full pipeline on a real cluster — the verification scripts currently exist but run in non-fatal mode (errors from early steps cascade into missing dependencies for later verification steps).
- The `startup.sh` pipeline currently references verification scripts that assume a complete cluster — integration with a working `tofu apply` flow that respects static DHCP leases.

### Scope change

**scoped-down** — The shell pipeline skeleton is already built. M010 S04 reduces to: integrate with the repaired `setup-bridge.sh` (S01), integrate with offline cache (S02), and add cluster-live verification at each step.

---

## M010 S05: End-to-end automated verification suite

### What M008 resolved

Nothing. This slice concerns an `e2e-provisioning.sh` script that does not exist yet.

### What remains

- Full scope as originally planned: an `e2e-provisioning.sh` script that runs a full create-verify-destroy cycle and exits 0.
- M008's `cluster-create.sh` and `cluster-destroy.sh` provide the building blocks for the create/destroy phases of this e2e script.
- M008 S01 provides the fast qcow2-based OpenTofu path that the e2e flow could use for the "full infrastructure" path.

### Scope change

**unchanged** — No M008 work directly addresses the e2e suite. The `cluster-create.sh`/`cluster-destroy.sh` scripts provide reusable components, but the e2e orchestration, verification, and assertion logic is all new work.

---

## Summary

| Slice | Title | Scope Change | Key Remaining Work |
|-------|-------|-------------|-------------------|
| S01 | Fix OpenTofu provisioning core | scoped-down | Inject static DHCP host entries into libvirt network XML |
| S02 | Talos offline image cache | unchanged | Full prep-cache.sh implementation |
| S03 | Cilium CNI kube-proxy-free L2 LB | scoped-down | Switch kubeProxyReplacement to true, add CiliumNodeConfig |
| S04 | startup.sh automated pipeline | scoped-down | Integrate with remaining M010 work, add live verification |
| S05 | End-to-end e2e suite | unchanged | Full e2e-provisioning.sh script |

**Bottom line:** The most critical unresolved issue after M008 is **M010 S01's DHCP static lease gap** — `setup-bridge.sh` computes the correct static DHCP entries but never writes them into the libvirt network XML. This is the single blocking issue preventing `tofu apply` from completing successfully, and it is now the smallest scope item remaining in M010.
