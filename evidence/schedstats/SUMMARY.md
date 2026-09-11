# schedstats Evidence Summary

This evidence directory proves that kernel scheduler statistics (kernel.sched_schedstats) were successfully enabled on all three worker nodes in the cluster at runtime without requiring node reboot or drain. The enablement was performed on 2026-09-11T12:52:21Z using a debug pod with chroot access to the host filesystem.

The change activates scheduler delay accounting in the kernel, which allows KubeVirt and other collectors to expose CPU wait time metrics (kubevirt_vmi_vcpu_wait_seconds_total and vcpu_delay_seconds_total). This is non-persistent and will revert upon node reboot. The enablement satisfies the hard guardrails for this shared lab cluster: no MachineConfig applied, no node reboot required, no node drain operation performed.

All 3 worker nodes (24-6e-96-33-24-90, 80-18-44-f0-71-30, ec-f4-bb-ed-07-a8) show identical results: kernel.sched_schedstats changed from 0 (disabled) to 1 (enabled) via `sysctl -w` with return code 0 on both set and verification steps.

| File | Contents | Key Fact |
|------|----------|----------|
| nodes.txt | Runtime sysctl enablement log for all 3 worker nodes | All 3 nodes: kernel.sched_schedstats 0→1 (PASS); non-persistent (reverts on reboot); applied 2026-09-11T12:52:21Z via debug pod chroot |

