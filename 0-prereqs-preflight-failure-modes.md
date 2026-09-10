# OpenShift Virtualization Observability Demo — Prerequisites, Install Order, Preflight, and Failure Modes

**Target versions (pinned):** OpenShift Container Platform 4.20 · OpenShift Virtualization (kubevirt-hyperconverged) 4.20, `stable` channel · Cluster Observability Operator (COO) 1.5+ (Perses GA) · OpenShift Logging 6.x + Loki Operator + LokiStack · Network Observability operator (GA) · Tempo operator + TempoStack (optional).

**Why a preflight step, not just a run-book:** the demo cluster was not reachable while this was written. Every operator/channel name, CR shape, metric name, alert name, and threshold below was checked against upstream KubeVirt source (`kubevirt/kubevirt`, `kubevirt/monitoring`) and current Red Hat documentation rather than recalled from memory — but "checked against docs" is not the same as "confirmed on your cluster." `preflight.sh` (below) is the thing that actually confirms it, and it is designed to fail loudly and specifically rather than let a blank panel pass for "it's just quiet today."

---

## 1. Cluster prerequisites

| Requirement | Detail |
|---|---|
| OCP cluster | 4.20, cluster-admin access, `oc` CLI + `virtctl` plugin (`oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged`) |
| Nodes | Bare-metal or nested-KVM-capable workers (KVM acceleration required for OpenShift Virtualization); demo minimum ≥3 workers so live migration has somewhere to go |
| Storage | A default or named **RWX/migratable** StorageClass (Ceph RBD via ODF, or any CSI driver that supports live migration) for the demo VM's DataVolume. A second, **non-migratable** class (local/hostpath) is deliberately needed too, for the `VMCannotBeEvicted` beat — see §3, step 9 |
| Object storage | An S3-compatible bucket (ODF NooBaa, AWS S3, MinIO, Azure Blob, GCS) for LokiStack, and for TempoStack if the optional tracing beat is in scope |
| Console UI plugins are Console-dependent | web console reachable, standard OCP ingress/DNS |
| Prometheus/Alertmanager | the platform monitoring stack (already present on any OCP cluster); user-workload monitoring must be turned on (§3, step 3) |

**Sizing rule of thumb for Prometheus** (from the underlying research, confirmed independently by the recording-rule set below): budget roughly **60 `kubevirt_vmi_*` series per running VM**. Irrelevant at demo scale (a handful of VMs), but if this cluster also carries a larger fleet alongside the demo, size Prometheus CPU/memory for VMI-count × 60 before you rely on any dashboard's historical range, not after.

---

## 2. Install order

Apply in this order — several later steps (UIPlugins, FlowCollector) reference resources created in earlier ones by name.

| # | Component | Operator / package | Channel | Namespace | Maturity |
|---|---|---|---|---|---|
| 1 | OpenShift Virtualization | `kubevirt-hyperconverged` | `stable` | `openshift-cnv` | **GA** |
| 2 | `schedstats=enable` + `psi=1` kernel args | MachineConfig (no operator) | — | node pool | schedstats: GA on 4.20. **psi=1: not effective on 4.20** — see callout below |
| 3 | User workload monitoring | ConfigMap patch | — | `openshift-monitoring` | GA |
| 4 | Cluster Observability Operator | `cluster-observability-operator` | `stable` | `openshift-cluster-observability-operator` | **GA**, need ≥1.5 for Perses GA |
| 5 | OpenShift Logging 6.x + LokiStack | `cluster-logging` + `loki-operator` | `stable-6.<y>` | `openshift-logging` / `openshift-operators-redhat` | **GA** |
| 6 | Network Observability | `netobserv-operator` | `stable` | `openshift-netobserv-operator` | **GA** (since 4.12) |
| 7 | Tempo (optional) | `tempo-product` + OpenTelemetry operator | `stable` | `openshift-tempo-operator` | Tracing UI **GA** in COO 1.2+; Tempo 3.0+ **GA** |
| 8 | UIPlugins: Logging, TroubleshootingPanel, DistributedTracing, Monitoring | CRs (COO) | — | cluster-scoped | Logging/Monitoring/TroubleshootingPanel **GA**; TroubleshootingPanel **not supported on 4.17** |
| 9 | Demo VM(s) + qemu-guest-agent via cloud-init | — | — | demo namespace | — |
| 10 | Second CNV version + `workloadUpdateStrategy` (upgrade beat) | Subscription pinned + HCO patch | `stable`, `installPlanApproval: Manual` | `openshift-cnv` | — |

All manifests below are also saved under `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/` (see **Files written**), numbered to match this table.

### Step 1 — OpenShift Virtualization

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: stable
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec: {}
```
Full file with Namespace/OperatorGroup: `manifests/00-hco-subscription.yaml`.

### Step 2 — `schedstats=enable` and `psi=1` MachineConfigs

```yaml
# schedstats=enable -- required for kubevirt_vmi_vcpu_wait_seconds_total and
# kubevirt_vmi_vcpu_delay_seconds_total (the "vCPU Wait" Top Consumers card).
# Valid and documented on OCP 4.20.
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-schedstats-enable
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
    - schedstats=enable
---
# psi=1 -- Pressure Stall Information. Included because it was asked for, but
# read the callout below before you apply it on a 4.20 cluster.
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-worker-psi-enable
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
    - psi=1
```

> **REBOOT WARNING:** applying *either* MachineConfig triggers a rolling reboot of every node whose `machineconfiguration.openshift.io/role` label matches (`worker` above — narrow this to a custom MachineConfigPool if VMs are pinned to a labeled subset of nodes). Apply both well before the demo and confirm the MachineConfigPool has finished rolling (`oc get mcp worker`) — never do this live, and never do it the same day as the demo unless you've budgeted for a full node-by-node cordon/drain/reboot/uncordon cycle.

> **PSI VERSION CALLOUT — read before you promise this panel works:** Red Hat's own documentation (`developers.redhat.com`, 2026-03-18, "Prepare to enable Linux pressure stall information on Red Hat OpenShift") states PSI support starts at **OCP 4.21**. On the pinned 4.20 target, the `psi=1` kernel argument is accepted by the MachineConfig controller but **`/proc/pressure/cpu`, `/proc/pressure/memory`, `/proc/pressure/io` will not appear** — this is a version gap, not a misconfiguration, and it is *not* documented anywhere as "PSI isn't in 4.20 yet," so it reads exactly like every other silent-blank-panel failure mode in this deck unless you know to look for it. **Recommendation: drop PSI panels from a 4.20 demo entirely** rather than ship a MachineConfig that can't do anything, or run the demo cluster on 4.21+ if PSI is a beat you specifically want.

### Step 3 — User workload monitoring

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
```

### Step 4 — Cluster Observability Operator

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
spec:
  channel: stable
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```
COO does not use per-OCP-minor channels the way Logging does — `stable` tracks the latest 1.x line. Confirm you actually landed on **≥1.5** (Perses GA) via `oc get csv -n openshift-cluster-observability-operator`; `preflight.sh` does this for you.

### Step 5 — OpenShift Logging 6.x + Loki Operator + LokiStack

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
spec:
  channel: stable-6.y   # PIN: confirm exact channel — oc get packagemanifest loki-operator -o jsonpath='{.status.channels[*].name}'
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
spec:
  channel: stable-6.y   # PIN: must match
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  managementState: Managed
  size: 1x.extra-small   # demo default — see note below on 1x.pico
  storage:
    schemaVersion: v13
    secret:
      name: logging-loki-s3
      type: s3
  storageClassName: <storage_class_name>
  tenants:
    mode: openshift-logging
```
**Sizing:** `1x.extra-small` is the recommended demo default (production-supported since Logging 5.8+, carried forward into 6.x; right-sized for a handful of VMs' worth of log volume). `1x.small` is the step up if Network Observability's netflow-to-Loki path is also running at meaningful volume alongside VM logs. **Do not use `1x.pico`** for this demo: it's the smallest supported size, but it still ships with the same HA/replication-factor-2 defaults as the larger sizes, so it over-provisions relative to what a small demo VM fleet actually produces — a real, reported cost complaint, not a hypothetical one. VM log retention in this configuration is **~30 days by design**; if the narrative needs longer retention, say so explicitly and point at external forwarding rather than implying this LokiStack does it natively.

Full file with Secret/Namespace/OperatorGroup scaffolding: `manifests/04-logging-lokistack.yaml`.

### Step 6 — Network Observability + FlowCollector

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: netobserv-operator
  namespace: openshift-netobserv-operator
spec:
  channel: stable
  name: netobserv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
---
apiVersion: flows.netobserv.io/v1beta2
kind: FlowCollector
metadata:
  name: cluster
spec:
  namespace: netobserv
  deploymentModel: Direct
  agent:
    type: EBPF
    ebpf:
      sampling: 50
      privileged: false
  processor:
    logTypes: Flows
  loki:
    enable: true
    mode: LokiStack
    lokiStack:
      name: logging-loki
      namespace: openshift-logging
  consolePlugin:
    enable: true
```
This is what makes the **netflow** domain node render in the Troubleshooting Panel, and what backs `oc netobserv` wire-level capture for a VM's traffic (eBPF, host datapath, before segmentation offload / OVS VLAN tagging).

### Step 7 — Tempo (optional)

Two operators (Tempo + Red Hat build of OpenTelemetry) plus a `TempoStack`. Full file: `manifests/06-tempo-tempostack.yaml`. Note honestly: there is no first-class KubeVirt hypervisor trace source out of the box — this beat is really "trace an app running on/beside a VM," not "trace the VM itself." Treat as optional exactly as scoped. The OpenTelemetry operator package name in the manifest (`opentelemetry-product`) is the one field in this whole set not independently re-verified against a live catalog — confirm with `oc get packagemanifest -n openshift-marketplace | grep -i opentelemetry` before applying.

### Step 8 — UIPlugin CRs

All four apply after their backing resources exist (COO, LokiStack, FlowCollector, and TempoStack if used). These are the **only four `spec.type` values this COO build supports** — do not invent others.

```yaml
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: logging
spec:
  type: Logging
  logging:
    lokiStack:
      name: logging-loki
    logsLimit: 50
    timeout: 30s
---
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: troubleshooting-panel
spec:
  type: TroubleshootingPanel
---
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: distributed-tracing   # optional, only if step 7 is in scope
spec:
  type: DistributedTracing
---
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
```
Installing the `TroubleshootingPanel` UIPlugin is what triggers COO to deploy the `korrel8r` Deployment/Service automatically — there is no separate Korrel8r operator to subscribe to. **Troubleshooting Panel is GA in COO 1.3 for OCP 4.19+ and is explicitly not supported on 4.17.** Perses dashboards from the `monitoring` UIPlugin are **single-namespace scoped** in this GA — don't imply a cross-namespace fleet view from this plugin alone; that's RHACM's dashboards, a different product surface.

### Step 9 — `qemu-guest-agent` via cloud-init + demo VM

```yaml
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
  - stress-ng
runcmd:
  - systemctl enable --now qemu-guest-agent
```
(Full fragment with the demo trigger scripts described in §4 below: `cloud-init/qga-userdata.yaml`.) **Version matters**: `kubevirt_vmi_guest_load_1m/5m/15m` specifically requires **qemu-guest-agent ≥ 10.0.0** — `AgentConnected=True` alone does not guarantee that metric populates; check `qemu-ga --version` inside the guest if that one panel stays blank while others work.

Demo VM: 2 vCPU, memory `requests == limits == 2Gi` (deliberately no pod-level headroom, so a guest-internal memory hog drives the alerts below without fighting the container scheduler too), `evictionStrategy: LiveMigrate`, RWX/migratable storage. Full manifest, plus a commented **non-migratable variant** (local/hostpath disk) purpose-built to trip `VMCannotBeEvicted`: `manifests/08-demo-vm.yaml`.

### Step 10 — second CNV version + `workloadUpdateStrategy` (the upgrade beat)

> **API-version callout (verified in `kubevirt/hyperconverged-cluster-operator` source).** `hco.kubevirt.io` serves two layouts: **`v1beta1`** puts `workloadUpdateStrategy` (and `liveMigrationConfig`) at the top of `spec` — that is what `09-upgrade-beat.yaml` below declares and what Red Hat's "Updating OpenShift Virtualization" docs show for 4.9–4.21; **`v1`** nests both under `spec.virtualization`. A merge-patch against the wrong layout is silently pruned. Check `oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.apiVersion}'` and use the matching path (the Act 2 scripts detect this automatically via `hco_patch_wum`). `preflight.sh` reports the served/preferred HCO versions.

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: stable
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual        # hold here instead of auto-advancing
  startingCSV: kubevirt-hyperconverged-operator.v4.20.0   # PIN: one z-stream behind "stable"'s current CSV
---
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  workloadUpdateStrategy:
    workloadUpdateMethods:
      - LiveMigrate
      - Evict            # Evict only ever applies to VMIs that cannot live-migrate
    batchEvictionSize: 1           # Evict-only knob (default 10) -- see callout below
    batchEvictionInterval: "2m0s"  # Evict-only knob (default 1m) -- see callout below
```
**`batchEvictionSize`/`batchEvictionInterval` correctness callout** (verified against Red Hat's "Updating OpenShift Virtualization" docs, consistent across 4.9–4.21): these two fields govern **only the `Evict` method** — they have **no effect on `LiveMigrate`**. Because the main demo VM (step 9) is live-migratable, this HCO patch alone does **not** pace or slow down its rollout; it will migrate as fast as KubeVirt's live-migration controller allows. What actually governs `LiveMigrate` concurrency/speed is a *different* stanza on this same HyperConverged CR — `spec.liveMigrationConfig` (`parallelMigrationsPerCluster`, default 5; `parallelOutboundMigrationsPerNode`, default 2; `bandwidthPerMigration`, default unlimited). See FAILURE MODES #13 for how to actually make this beat watchable on stage.

Confirm the two real available z-streams before picking `startingCSV`:
```
oc get packagemanifest kubevirt-hyperconverged -n openshift-marketplace \
  -o jsonpath='{.status.channels[?(@.name=="stable")].currentCSV}'
```
During the demo, advance live by approving the held InstallPlan:
```
oc get installplan -n openshift-cnv
oc patch installplan <name> -n openshift-cnv --type merge -p '{"spec":{"approved":true}}'
```
Full file: `manifests/09-upgrade-beat.yaml`.

---

## 3. Preflight script

`preflight.sh` (path in **Files written**) is read-only — it creates, patches, and deletes nothing. It prints **PASS/WARN/FAIL** per check and a final tally, exit code 1 if any FAIL.

| Section | What it checks |
|---|---|
| 0 | `oc login` / `oc whoami` |
| 1 | OCP `ClusterVersion` vs pinned `4.20` |
| 2 | `kubevirt-hyperconverged` CSV present + phase, HyperConverged CR `Available` |
| 3 | `cluster-observability-operator` CSV present, version ≥1.5 |
| 4 | `cluster-logging` + `loki-operator` CSVs present |
| 5 | `netobserv-operator` CSV present |
| 6 | Tempo operator CSV (optional, `TEMPO_ENABLED` env-gated) |
| 7 | Every UIPlugin (`logging`, `troubleshooting-panel`, `monitoring`, and `distributed-tracing` if Tempo is in scope) exists **and** `status.conditions[Available]=True` |
| 8 | LokiStack `Ready=True`; flags `1x.pico` sizing as a WARN |
| 9 | FlowCollector `Ready=True`; flags `spec.loki.enable=false` |
| 10 | korrel8r pod `Running` + its image reference/tag; best-effort in-pod REST hit on `/api/v1alpha1/domains`; greps reachable ConfigMaps/API response for the compiled KubeVirt quickrule names (`VmiToPod`, `VmiToAlert`/`VmimToAlert`/`VmToAlert`, `VmToVmi`, `VmiToNode`) |
| 11 | `enableUserWorkload: true` in `cluster-monitoring-config`; running pods in `openshift-user-workload-monitoring` |
| 12 | `schedstats=enable` MachineConfig present + live `/proc/schedstat` check on a node; `psi=1` MachineConfig + live `/proc/pressure/cpu` check, **explicitly non-fatal (`SKIP`, not `WARN`) when OCP < 4.21** so this doesn't read as a bug it structurally cannot be |
| 13 | Demo VM `AgentConnected=True` and `LiveMigratable=True` (skips cleanly if `DEMO_VM`/`DEMO_VM_NS` unset) |
| 14 | VMI count × ~60 series/VM cardinality estimate; Prometheus pod restart count and memory limit |
| 15 | Live label-existence checks against Thanos Querier for five labels (`phase`, `interface`, `drive`, `instance_type`, `node`) on the corresponding `kubevirt_vmi_*` metrics — confirms the `by (...)` groupings a panel might use actually return values on this cluster/build |
| 16 | `kube_pod_labels{label_vm_kubevirt_io_name=...}` existence — kube-state-metrics only exposes a pod label like `vm.kubevirt.io/name` if it's been explicitly allow-listed; this is the same "silently blank by design" trap as the rest of this deck, just on a label most people never think to check |
| 17 | Cgroup mode on a node (`cgroup2fs` vs `tmpfs`) — flags the OCP 4.20 cgroups v1→v2 default and the `cgroup_id`→`id` label rename it carries (Failure Mode #4) before you trust any panel that groups by `id`/`cgroup_id` |

Sections 15–17 were carried over from this scratchpad's earlier, dashboard-specific preflight script rather than written fresh for this deliverable, and their in-script comments still reference that other dashboard's panels by name (e.g. "row A," "row E.4," "the Query-3 depth-check panel") — those references are **not defined anywhere in this document** and can be ignored if you aren't also running that companion dashboard. Section 17's cgroup check is general-purpose and worth keeping regardless. If you don't need 15–17 for this specific deliverable, their WARNs are informational, not blocking — but note the exit-code/tally logic still only escalates on FAIL, and none of 15–17 currently emit FAIL, so they cannot fail the run on their own.

**On the korrel8r rule-name check (§10):** the compiled KubeVirt quickrules are real (`VmToVmi`, `VmiToPod`, `VmiToNode`, `VmToPVC`, `VmToAlert`, `VmiToAlert`, `VmimToAlert`, `VmToMetric`, `VmiToLogs`, and more — verified directly against the upstream `korrel8r/korrel8r` `kubevirt.qtpl` source). There is no separate literal rule called "AlertToVMI" — that direction is the same `VmiToAlert`/`VmimToAlert` rule traversed backward when korrel8r builds the graph starting from an alert, which is how the alert → VMI → virt-launcher-pod → logs walk actually works on stage. The script's grep covers the forward names; treat a WARN here as "confirm the live click-through in the console yourself," not as proof the rules are missing — the exact CLI/REST introspection surface for a running korrel8r build wasn't something this research could pin down without the live cluster.

Run it:
```
oc login <cluster>
DEMO_VM=demo-vm-01 DEMO_VM_NS=demo-vms TEMPO_ENABLED=false \
  /path/to/preflight.sh
```

---

## 4. Demo VM alert-trigger recipes (verified thresholds, not estimates)

Every threshold below is copied from the actual `PrometheusRule` Go source in `kubevirt/kubevirt` (`pkg/monitoring/rules/alerts/vms.go` and `.../recordingrules/vmi.go`), not the runbook prose, so the timings are what will really happen on stage.

| Alert | Expression (abbreviated) | `for` | Severity | Guest-side recipe |
|---|---|---|---|---|
| `GuestVCPUQueueHighWarning` | `vmi:kubevirt_vmi_guest_queue_length:sum > 10`, where the recording rule = `clamp_min(kubevirt_vmi_guest_load_1m − vcpu_count, 0)` | none (fires on first breach) | warning | `stress-ng --cpu <vCPUs+15>` for a few minutes so the 1‑min guest load average climbs past vCPU count + 10 |
| `GuestVCPUQueueHighCritical` | same recording rule `> 20` | none | critical | same, aim for vCPU count + 21+ |
| `KubeVirtVMGuestMemoryPressure` | `headroom_ratio < 0.05` **and** (`pgmajfaults rate5m > 5` **or** `swap_traffic rate5m > 1MiB`) | 5m | warning | real thrashing: `stress-ng --vm 2 --vm-bytes ~130% of guest RAM` with swap configured in the guest |
| `KubeVirtVMGuestMemoryAvailableLow` | `headroom_ratio < 0.03` **and** low swap **and** low pgmajfaults | **30m** | info | steady-state tight, not thrashing: `stress-ng --vm 1 --vm-bytes ~98% of guest RAM --vm-keep`, no swap needed |
| `VMCannotBeEvicted` | `kubevirt_vmi_non_evictable == 1` joined to a running VMI | 1m | warning | `evictionStrategy: LiveMigrate` + a local/hostpath disk (non-migratable variant in `08-demo-vm.yaml`) |
| `OutdatedVirtualMachineInstanceWorkloads` | `kubevirt_vmi_number_of_outdated != 0` | **24h** | warning | the upgrade beat (step 10) — **see FAILURE MODES: do not wait for this alert on stage** |
| `VMNonRecoverableOSPanic` | `> 5` panics counted via `kubevirt_vmi_guest_os_panic_total` in 24h | 1m | critical | needs a real/simulated guest kernel panic 6+ times in the window; not a quick live trigger |

Ready-to-run trigger scripts (`trigger-vcpu-queue.sh`, `trigger-mem-pressure.sh`) are baked into `cloud-init/qga-userdata.yaml`.

---

## 5. Failure modes and mitigations

| # | Failure mode | Root cause | Mitigation |
|---|---|---|---|
| 1 | Log or netflow domain nodes silently missing from the Troubleshooting Panel graph | LokiStack or Network Observability plugin/CR absent, not-Ready, or `spec.loki.enable=false` | Preflight §8–9. Korrel8r doesn't error on a missing domain — it just has nothing to draw. Verify Ready conditions before, not during, the walk. |
| 2 | vCPU-Wait / PSI panels blank | `schedstats=enable` (host scheduler stats) and `psi=1` (PSI) are two **separate** kernel-arg MachineConfigs, both requiring a full node reboot. PSI additionally **does not exist as a capability on OCP 4.20 at all** — it's documented by Red Hat as starting at 4.21 | Apply `schedstats=enable` well ahead of time (preflight §12 confirms rollout). For PSI on 4.20, don't apply the MachineConfig expecting it to work — drop those panels from the demo, or run on 4.21+. |
| 3 | Memory / guest-filesystem / guest-load panels blank | No `qemu-guest-agent` in the guest, or agent present but too old for `guest_load_1m/5m/15m` (needs ≥10.0.0) | Bake the agent into the golden image via cloud-init (§3 step 9); preflight §13 checks `AgentConnected=True`; separately check `qemu-ga --version` in-guest if only the load panels are blank. |
| 4 | Shipped Node Memory dashboard panel breaks after the 4.20 cgroups v1→v2 move | cAdvisor's `cgroup_id` label was renamed to `id` under cgroups v2; any PromQL filtering on `cgroup_id` returns empty | Rewrite the filter to match the new label, e.g. `container_memory_working_set_bytes{id=~".*system.slice.*"}` instead of `...{cgroup_id=~".*system.slice.*"}`. Check any Red-Hat-shipped OOTB dashboard you present alongside a custom one for this same pattern before trusting it live. |
| 5 | Top Consumers "Memory" card breaks / reads zero | The recording rule `vmi:kubevirt_vmi_memory_used_bytes:sum` is absent on this build | Raw-metric replacement (verified from upstream source, same math the rule uses): `kubevirt_vmi_memory_available_bytes - kubevirt_vmi_memory_usable_bytes` |
| 6 | Prometheus OOM-killed at fleet scale | ~60 `kubevirt_vmi_*` series per VM; the underlying research saw repeated OOM-kills at ~10K VMs / ~20M total series on an undersized Prometheus | Not a concern at demo scale (preflight §14 estimates series count from live VMI count). If this cluster also hosts a larger fleet, size Prometheus CPU/mem for `VMI_count × 60` explicitly and check `restartCount`/OOM history before presenting historical panels. |
| 7 | Guest dirty-rate numbers look wrong | `kubevirt_vmi_dirty_rate_bytes_per_second` has a known, open accuracy issue (off by orders of magnitude vs. ground truth) | Don't present it as a precise number. Use `kubevirt_vmi_migration_data_processed_bytes` / `_data_remaining_bytes` and `migration_memory_transfer_rate_bytes` for the live-migration-progress story instead — those are the metrics with no accuracy caveat. |
| 8 | Storage IOPS/flush metrics look flaky specifically during a live migration | Storage read/write/flush metric collection is known to be less reliable while a migration is in flight (domain-stats collection is affected around migration) | Don't run the storage-IO panel and the migration beat as the same moment on stage; show storage IO before/after migration, not straddling it. |
| 9 | Korrel8r's alert → VMI → virt-launcher-pod → logs walk doesn't render a step | The compiled KubeVirt quickrules are recent upstream additions and are **not listed in the COO product release notes** — the pinned image in your COO build may predate them | Preflight §10 checks the korrel8r image/pod and best-effort probes for the rule names. If genuinely absent, don't promise the automatic walk — the fallback custom-rule config for this exact gap is at `act3/korrel8r-standalone-config.yaml` and `act3/korrel8r-goals-fallback.sh` (from an earlier piece of this build). |
| 10 | Troubleshooting Panel not available at all | It is **GA only from COO 1.3 on OCP 4.19+**, and explicitly **not supported on OCP 4.17** | Confirm both COO version and OCP version before the demo, not the UIPlugin's mere presence — preflight §1 and §3. |
| 11 | ODF `PersistentVolumeUsageNearFull` / `PersistentVolumeUsageCritical` fires on an LVM-thin-provisioned guest disk that has plenty of real headroom | These are real ceph/rook alerts; thin-provisioned guest volumes can look "full" at the block layer while the guest filesystem is nearly empty — a known false-positive pattern reported against these alerts for workloads expected to run fully utilized | Don't demo cluster-storage alerting and a thin-provisioned guest disk as the same beat unless you're prepared to explain the distinction between block-level and guest-filesystem-level "full." |
| 12 | Loki-backed VM logs "disappear" after about a month | LokiStack in this configuration retains logs **~30 days by design** | State the retention window up front if the narrative implies long-term log history; point at external forwarding for anything longer, don't imply this LokiStack does it. |
| 13 | The upgrade beat (step 10) doesn't visibly land, in **either direction** | Two independent failure shapes: **(a)** `batchEvictionSize`/`batchEvictionInterval` apply **only to the `Evict` method, never to `LiveMigrate`** (verified against Red Hat docs) — for the main, live-migratable demo VM they do nothing at all, so with only one or two small demo VMs the live migration can complete before you can narrate it, looking like "nothing happened." **(b)** the `OutdatedVirtualMachineInstanceWorkloads` **alert itself has a 24-hour `for` clause** (verified in upstream source) — it will not fire in any live demo window, full stop, regardless of migration speed. | For (a): don't rely on `batchEvictionSize` for the migratable VM — it has no effect there. To make the beat watchable, either (i) put light memory/CPU load on the guest beforehand so the migration has more dirty pages and takes longer to converge, (ii) set a deliberately low `spec.liveMigrationConfig.bandwidthPerMigration` on the HCO CR to slow the transfer for narration, or (iii) include the non-migratable demo-VM variant (`08-demo-vm.yaml`) in the same upgrade beat — *that* VM genuinely goes through `Evict`, where `batchEvictionSize: 1` / `batchEvictionInterval: 2m` do pace the rollout one VMI at a time. For (b): **never wait for the alert.** Graph the raw gauge `kubevirt_vmi_number_of_outdated` transitioning from >0 to 0 as the InstallPlan is approved and virt-launcher pods roll — that's the demonstrable signal, the alert is a 24-hours-later escalation, not a live-demo trigger. |
| 14 | Standalone Korrel8r MCP / agentic troubleshooting doesn't work as shown in circulating demo material | Standalone Korrel8r MCP is explicitly not being productized; the OLS-console integration is roadmapped for **OCP 5.1**, well past this deck's 4.20 target | Don't demo or promise an agentic Korrel8r experience on 4.20. The Troubleshooting Panel's node-graph UI is the shipping, GA mechanism — present that. |

---

## 6. GA / tech-preview / dev-preview / experimental — every flag used in this deliverable

| Capability | Status |
|---|---|
| `kubevirt_vmi_*` metrics in cluster Prometheus | **GA** |
| Cluster Observability Operator | **GA** (need ≥1.5 for Perses) |
| Troubleshooting Panel (Korrel8r) | **GA**, COO 1.3, OCP 4.19+; **not supported on 4.17** |
| Korrel8r compiled KubeVirt quickrules | Ships upstream (v0.12.1+); **not in COO release notes — verify per preflight §10** |
| Standalone Korrel8r MCP | Experimental upstream; **explicitly not being productized** as standalone |
| Korrel8r + Lightspeed console integration | **Roadmap — OCP 5.1**, not usable on this target |
| Logging UI plugin + LokiStack | **GA**; ~30-day log retention by design |
| Network Observability operator + plugin | **GA** (since 4.12) |
| Tracing UI plugin / Tempo | **GA** (Tracing UI COO 1.2+; Tempo 3.0+) |
| Perses dashboards (Monitoring UIPlugin) | **GA**, COO 1.5; single-namespace scoped |
| `schedstats=enable` kernel arg | Supported/documented on 4.20 |
| PSI (`psi=1`) | **Not available on 4.20** — documented as starting OCP **4.21** |
| `oc netobserv` VM wire capture | GA-track (NetObserv operator) |

---

## Files written

- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/preflight.sh` — the preflight script (§3)
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/00-hco-subscription.yaml` — Step 1
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/01-machineconfig-schedstats-psi.yaml` — Step 2
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/02-user-workload-monitoring.yaml` — Step 3
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/03-coo-subscription.yaml` — Step 4
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/04-logging-lokistack.yaml` — Step 5
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/05-netobserv-flowcollector.yaml` — Step 6
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/06-tempo-tempostack.yaml` — Step 7 (optional)
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/07-uiplugins.yaml` — Step 8
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/08-demo-vm.yaml` — Step 9
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/manifests/09-upgrade-beat.yaml` — Step 10
- `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/cloud-init/qga-userdata.yaml` — guest-agent + demo trigger scripts

Note: this scratchpad already contained files from earlier pieces of this same demo build (`act1-*`, `act2-*`, `act3/*`, `migration-beat.sh`, and a narrower, Act-1-scoped `preflight.sh`). This deliverable's `preflight.sh` **replaces** that narrower file with a full-stack version (OCP/CNV/COO/Logging/NetObserv/Tempo versions, all four UIPlugins, LokiStack/FlowCollector readiness, korrel8r rules, user-workload-monitoring, schedstats/PSI, guest agent, Prometheus headroom) — sections 0–14 in **§3** above. Correction: this file does **also** still carry three of the earlier dashboard-label checks forward (sections 15–17, documented in §3), so the on-disk script is not purely the full-stack checks; nothing in `act1/act2/act3` themselves was modified, only this `preflight.sh` file. If those three carried-over checks aren't relevant to this deliverable, they're safe to ignore (see §3); if the full Act-1 dashboard-specific check set is still needed separately, pull it from git history or re-derive from `act1-*`/`act2-*`'s own preflight logic.

## Open questions to close on the live cluster

1. Exact `stable-6.<y>` channel for Logging/Loki Operator on this specific OCP 4.20 build — pin via `oc get packagemanifest`.
2. Exact `opentelemetry-product` package name if the Tempo beat is used — confirm via live catalog, not this document.
3. Whether the pinned COO build's korrel8r image actually contains the compiled KubeVirt quickrules — no reliable non-cluster way to confirm this; `preflight.sh` §10 is the intended confirmation point, on a best-effort basis given the uncertain CLI/REST introspection surface.
4. Whether the target cluster will actually be 4.20 or 4.21+ at demo time — this single fact decides whether the PSI beat exists at all.
5. Real StorageClass names (RWX/migratable, and a non-migratable one for the `VMCannotBeEvicted` beat) — placeholders (`<storage_class_name>`) are left in every manifest that needs one.


---

## Appendix: code items

### 09-upgrade-beat.yaml
*Prerequisites:* OpenShift Virtualization already installed via a Subscription with a lower CSV than the target upgrade; cluster-admin to approve InstallPlans.

startingCSV must be confirmed against the live catalog (oc get packagemanifest kubevirt-hyperconverged ...) -- the value here is a placeholder one z-stream behind 'stable'. CORRECTED: batchEvictionSize/batchEvictionInterval apply ONLY to the Evict workload-update method (verified against Red Hat's 'Updating OpenShift Virtualization' docs, consistent 4.9-4.21) -- they have NO effect on LiveMigrate, so for the main (migratable) demo VM this HCO patch does not pace or slow its rollout at all. They remain useful only if the non-migratable demo-vm variant from 08-demo-vm.yaml is included in the same upgrade beat, since that VMI genuinely goes through Evict. To make a pure-LiveMigrate rollout watchable on stage, use spec.liveMigrationConfig on this same HCO CR instead (parallelMigrationsPerCluster, default 5; parallelOutboundMigrationsPerNode, default 2; bandwidthPerMigration, default unlimited) or pre-stress the guest so the migration takes longer to converge. The OutdatedVirtualMachineInstanceWorkloads alert has a verified 24h 'for' clause -- graph kubevirt_vmi_number_of_outdated directly, do not wait for the alert during a live demo.

```yaml
# Step 10 -- the "second CNV version available" upgrade beat.
#
# Pattern: pin the FIRST install one z-stream behind "latest stable" with
# Manual approval, run the demo VMs on it, then approve the pending
# InstallPlan live to show the upgrade. workloadUpdateStrategy on the HCO CR
# controls HOW existing VMIs get moved onto the new virt-launcher: LiveMigrate
# for VMIs that support it, Evict for VMIs that don't.
#
# IMPORTANT, verified against Red Hat's own "Updating OpenShift Virtualization"
# docs (consistent across 4.9-4.21): batchEvictionSize and batchEvictionInterval
# below apply ONLY to the Evict method. They have NO effect on LiveMigrate.
# The main demo VM (step 9) is live-migratable, so this Subscription+HCO patch
# alone will NOT visibly pace its rollout -- see the batchEvictionSize comment
# below and FAILURE MODES #13 for what actually controls LiveMigrate pacing
# and how to make this beat watchable.
#
# CONFIRM the actual two available z-streams via:
#   oc get packagemanifest kubevirt-hyperconverged -n openshift-marketplace \
#     -o jsonpath='{.status.channels[?(@.name=="stable")].currentCSV}'
# and pick a startingCSV one or two z-releases behind that.

apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  channel: stable
  name: kubevirt-hyperconverged
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Manual          # <-- changed from Automatic: hold here
  startingCSV: kubevirt-hyperconverged-operator.v4.20.0   # PIN: confirm exact z-stream available
---
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  workloadUpdateStrategy:
    workloadUpdateMethods:
      - LiveMigrate
      - Evict          # Evict only affects VMIs that CANNOT live-migrate.
                        # LiveMigrate alone is the HCO default; listing both
                        # is a documented, supported pattern for a mixed
                        # fleet (some VMIs migratable, some not) -- not
                        # itself "the default."
    batchEvictionSize: 1        # Applies ONLY to the Evict path (default 10).
                                 # Has ZERO effect on LiveMigrate -- it does
                                 # not pace, throttle, or batch live-migrated
                                 # VMIs at all. Kept small here so that IF the
                                 # non-migratable demo-vm-nonmigratable variant
                                 # (see 08-demo-vm.yaml) is included in this
                                 # beat, its Evict-driven update is visibly
                                 # paced one VMI at a time. For the main
                                 # (migratable) demo VM, this field does
                                 # nothing -- see FAILURE MODES #13 for what
                                 # actually governs LiveMigrate pacing
                                 # (spec.liveMigrationConfig on this same HCO
                                 # CR: parallelMigrationsPerCluster, default 5;
                                 # parallelOutboundMigrationsPerNode, default 2;
                                 # bandwidthPerMigration, default unlimited).
    batchEvictionInterval: "2m0s"   # Also Evict-only; see above.

```

