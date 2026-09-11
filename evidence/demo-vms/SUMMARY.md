# Demo VMs Evidence

This directory proves that OpenShift Virtualization on OCP 4.20.32 with Thanos monitoring correctly identifies VM properties, tracks live migration capability, and generates alerts for policy violations. Three test VMs were created in the demo-vms namespace with different storage configurations to demonstrate monitoring behavior in both migratable and non-migratable scenarios.

The evidence shows how the virt-controller component exports metrics about VM evictability and how those metrics align with the actual live migration capability determined by underlying storage access modes. All VMs reached Running state, their DataVolumes provisioned successfully to shared (ReadWriteMany) or local (ReadWriteOnce) storage, and Thanos queries returned the expected metric series for both general and VM-specific monitoring. An alert fired correctly when a non-migratable VM was assigned a LiveMigrate eviction strategy, demonstrating that the monitoring stack can surface infrastructure policy conflicts to operators.

The configuration files and metric snapshots document the exact setup that produced this behavior, making it possible to compare results across different clusters or configurations.

## Files

| File | Contents | Key Numbers/Facts |
|------|----------|-------------------|
| vm-demo.yaml | Declarative VM spec for vm-demo, 2 vCPU/4Gi RAM, cloud-init with qemu-guest-agent and stress-ng | ReadWriteMany storage mode (nfs-csi class), evictionStrategy: LiveMigrate, runStrategy: Always |
| vm-demo-2.yaml | Second VM spec, identical config to vm-demo for redundancy testing | ReadWriteMany storage mode, evictionStrategy: LiveMigrate |
| vm-non-migratable.yaml | VM spec with same compute but ReadWriteOnce storage to block live migration | ReadWriteOnce storage mode, evictionStrategy: LiveMigrate, deliberately incompatible |
| oc-get-vm-wide.txt | kubectl output listing all VMs | 3 VMs (vm-demo, vm-demo-2, vm-non-migratable), all Running and Ready after 10 minutes |
| oc-get-vmi-wide.txt | kubectl output listing all VMI (runtime) instances | vm-demo (Ready, LiveMigratable), vm-demo-2 (Ready, LiveMigratable), vm-non-migratable (Ready, NOT LiveMigratable due to RWO storage) |
| oc-get-dv-wide.txt | DataVolume provisioning status | 3 DataVolumes all at Succeeded phase, 100% completion |
| oc-get-pvc-wide.txt | Persistent volume claims status | 3 PVCs bound and provisioned |
| oc-get-vm-yaml.yaml | Full VM object YAML (vm-demo) | Cloud-init includes scripts for triggering CPU/memory pressure for testing |
| oc-get-vmi-yaml.yaml | Full VMI object YAML (vm-demo) | Captures full runtime state with assigned node (ec-f4-bb-ed-07-a8), IP (10.128.1.49), conditions |
| final-vm-vmi-state.txt | Summary of all VM and VMI conditions at collection time | All Ready=True; vm-demo and vm-demo-2 have LiveMigratable=True; vm-non-migratable has LiveMigratable=False with reason "PVC vm-non-migratable-disk is not shared" |
| thanos-query1-kubevirt-vmi-count.json | count({__name__=~"kubevirt_vmi.*"}) Thanos query result | 62 kubevirt_vmi metric series available |
| thanos-query2-kube-pod-labels.json | kube_pod_labels for vm-demo's virt-launcher pod | Includes label_vm_kubevirt_io_name="vm-demo", label_app="demo", label_tier="web" |
| thanos-kubevirt_vmi_non_evictable.json | kubevirt_vmi_non_evictable metric from virt-controller | vm-demo=0 (evictable), vm-demo-2=0 (evictable), vm-non-migratable=1 (non-evictable) |
| thanos-ALERTS-VMCannotBeEvicted.json | ALERTS metric showing firing alert for vm-non-migratable | alertstate="firing", severity="warning", alertname="VMCannotBeEvicted" |
| alertmanager-VMCannotBeEvicted.json | Alert Manager active alert JSON | Started 2026-09-11T13:13:14Z, description "Eviction policy...set to Live Migration but the VM is not migratable", runbook link provided |
| vmi-conditions.txt | Full condition status for each VMI | Detailed breakdown of Ready, DataVolumesReady, LiveMigratable, StorageLiveMigratable, AgentConnected conditions |

