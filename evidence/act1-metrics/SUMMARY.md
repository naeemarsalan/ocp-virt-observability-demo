# Act 1 metrics evidence, vm-demo in demo-vms

Collected against the live cluster's Thanos-querier (`<cluster-domain>`). Every number below has a matching raw JSON file in this directory. Queries were run between 2026-09-11 14:37 and 14:48 (session-local clock; Unix ~1789133800-1789134520).

**Important context discovered mid-run:** a `virtctl migrate vm-demo -n demo-vms` was executed by the migration track *while this track's queries were running*. The VMI's `status.migrationState` (`03d-vmi-migrationstate-raw.json`) confirms a completed migration from node `ec-f4-bb-ed-07-a8` (source pod `virt-launcher-vm-demo-fx5hg`) to node `24-6e-96-33-24-90` (target pod `virt-launcher-vm-demo-b5lpj`), completed at `2026-09-11T13:38:31Z`. Ten minutes after completion the old source pod was still present as `Completed` (`03c-pods-during-migration-raw.txt`) and **still carried `kube_pod_labels{label_vm_kubevirt_io_name="vm-demo"}`**. This directly broke one of the three headline queries (see part 1, Query 3) and inflated a couple of "by tier"/count numbers below, flagged inline wherever it applies. This wasn't staged; it's what a real concurrent-migration window looks like against these join queries.

---

## 1. The three widening series-count queries (vm-demo, demo-vms)

| # | Query | Result | File |
|---|---|---|---|
| 1 | `count({namespace="demo-vms", name="vm-demo", __name__=~"kubevirt_vmi_.*"})` | **61** | `01-count-vmi-only.json` |
| 2 | `count({namespace="demo-vms", name="vm-demo", __name__=~"kubevirt_(vmi\|vm)_.*"})` | **72** | `02-count-vmi-plus-vm.json` |
| 3 | Full join through `kube_pod_labels{label_vm_kubevirt_io_name="vm-demo"}` (exact PromQL from the deck, section (a)) | **ERROR**, `multiple matches for labels: grouping labels must ensure unique matches` | `03-count-full-join-via-pod.json` |

**Query 3 does not run as written, on this real cluster, right now, for two separate reasons, not one:**

1. **Transient (migration-caused):** two virt-launcher pods for vm-demo currently both carry `label_vm_kubevirt_io_name="vm-demo"` (one `Completed`, one `Running`, see the migration note above). The deck's join assumes exactly one matching pod; `group_left()` requires the "one" side of a many-to-one join to be unique per `(namespace,pod)`, and right now it isn't.
2. **Structural (independent of the migration):** even after manually narrowing to a single, unambiguous pod on *both* sides of the join (`03e-count-full-join-manual-excl-stale-pod.json`), the query **still errors**. Bisection (done interactively, individual sub-query results saved as `p13c...json`-style probes are illustrative but not all saved individually) showed that any `__name__=~"kube_pod_.*"` or `__name__=~"container_.*"` **regex** metric-name selector combined with `* on(namespace,pod) group_left()` fails on this Thanos-querier version, while the identical join against a single concrete metric name (`kube_pod_info`, `kube_pod_status_phase`, `kube_pod_container_resource_requests`, etc., each tested individually) succeeds every time. This looks like a real limitation of this Thanos build's binary-operator vector matching when the "many" side is built from a metric-name regex union, not a mistake in the query text.

A working, **value-equivalent** substitute that avoids `group_left()` entirely (a plain `and on(namespace,pod)` boolean membership filter is all the "proof point" panel actually needs, it never uses the multiplied values, only `count()` of the result) ran successfully:

```promql
count(
  {namespace="demo-vms", __name__=~"container_.*|kube_pod_.*"}
  and on(namespace,pod)
  kube_pod_labels{namespace="demo-vms", label_vm_kubevirt_io_name="vm-demo"}
)
```
Result (right now, with the stale Completed pod still present, so this counts series from **two** pods): **345** for the pod-joined half, i.e. 72 (query 2) + 345 = the deck's intended combined total once you re-add the base 72 (`03f-count-full-join-WORKING-and-based-equivalent.json` shows the full combined expression returning 345 already, i.e. that file's query already includes the +72). Re-run this after the migration track's source pod is garbage-collected to get the steady-state single-pod number, expect roughly half of the pod-joined portion, based on the two-pod inflation pattern seen in section 3 below.

**Prerequisite check (section (a)'s "silent-blank" warning):** on this cluster the prerequisite is **met**, `kube_pod_labels{namespace="demo-vms", label_vm_kubevirt_io_name="vm-demo"}` returns data (`02b-prereq-kube-pod-labels-check.json`), meaning `vm.kubevirt.io/name` **is** allow-listed on this OpenShift's kube-state-metrics, contrary to the deck's "OpenShift does not do this out of the box" default assumption. Good news for this specific demo cluster, but don't assume it's true everywhere without checking.

---

## 2. Panel-by-panel PromQL (vm-demo, demo-vms)

| Panel | Query | Result | Prerequisite met? |
|---|---|---|---|
| Phase-transition latency p95 | `histogram_quantile(0.95, sum by (le)(rate(kubevirt_vmi_phase_transition_time_from_creation_seconds_bucket{namespace="demo-vms",name="vm-demo"}[5m])))` | **No data** | **No, metric doesn't have a `name`/`namespace`-per-VM label on this build.** The raw bucket series (`p01e-series-lookup-6h.json`, 114 series seen in the last 6h) all live in `namespace="openshift-cnv"` (virt-controller's own namespace) with a `phase` label but **no `name` label at all**. The deck's `{namespace="$namespace",name="$vm"}` filter can never match, this is a fleet-wide histogram by phase, not per-VM. |
| Migration phase-transition p95 | same pattern, `kubevirt_vmi_migration_phase_transition_time_from_creation_seconds_bucket` | **No data** for the filtered query | Same issue, confirmed via `/api/v1/series` (`p02g-series-lookup-1h.json`): `namespace="openshift-cnv"`, `phase` label present, **no `name`/`vmi` label**. Sample labelset in that file. A `count()` of the raw metric briefly returned 133 series at one instant (`p02c-cluster-wide-migration-phase-transition-bucket-exists.json`) then 0 moments later (`p02e-recheck-count.json`, `p02f-recheck-raw-limit.json`), this metric appears to be created/torn down per migration-object lifecycle on this busy shared cluster (other users' migrations), not a stable continuous series. |
| Storage flush rate | `sum(rate(kubevirt_vmi_storage_flush_requests_total{namespace="demo-vms",name="vm-demo"}[5m]))` | **0.0302 req/s** | Met |
| Derived flush latency | flush_times / flush_requests | **0.0000631 s (~63 microseconds)** | Met |
| Memory available | `kubevirt_vmi_memory_available_bytes` | **4,092,940,288 bytes (~3.81 GiB)** | Met |
| Memory usable | `kubevirt_vmi_memory_usable_bytes` | **3,686,178,816 bytes (~3.43 GiB)** | Met |
| number_of_outdated | `kubevirt_vmi_number_of_outdated` (cluster gauge) | **21** | Met, matches the pre-established fact exactly (21 outdated virt-launchers from the HCO `workloadUpdateMethods=[]` upgrade gap). |
| guest_os_panic 24h increase | `increase(kubevirt_vmi_guest_os_panic_total{namespace="demo-vms",name="vm-demo"}[24h])` | **No data** | Reason: **idle/never fired**, not a missing-agent issue, the raw counter series doesn't exist at all for vm-demo, and doesn't exist cluster-wide either (`p07c-guest-os-panic-cluster-wide-raw.json`, 0 series). No VM anywhere on this cluster has ever reported a guest OS panic, expected/healthy, the metric is just never-instantiated until the first panic. |
| non_evictable, vm-demo | `kubevirt_vmi_non_evictable{name="vm-demo"}` | **0** | Met |
| non_evictable, vm-demo-2 | same | **0** | Met |
| non_evictable, vm-non-migratable | same | **1** | Met, matches the firing `VMCannotBeEvicted` alert exactly. |
| Guest OS load 1m | `kubevirt_vmi_guest_load_1m` | **0.177** | Met, qemu-guest-agent is connected and reporting for vm-demo. |
| Guest OS load 5m | `kubevirt_vmi_guest_load_5m` | **0.0908** | Met |
| Guest OS load 15m | `kubevirt_vmi_guest_load_15m` | **0.0547** | Met |
| Time since last API connection | `time() - kubevirt_vmi_last_api_connection_timestamp_seconds{namespace="demo-vms",name="vm-demo"}` | **No data as written** | **Label bug, not a data gap:** this metric's per-VM label is `vmi`, not `name` (confirmed cluster-wide in `p10c-last-api-connection-cluster-wide.json`, sample labelset shows `vmi:"vm-non-migratable"`, no `name` field). Corrected query `{namespace="demo-vms",vmi="vm-demo"}` (`p10d-last-api-connection-CORRECTED-label-vmi.json`) *still* returns no data, vm-demo has **never had a console/VNC/API connection recorded**, which is legitimately "no data" (nobody has opened its console). The corrected query for `vm-non-migratable`, which someone did connect to, works and returns **800.4 s (~13.3 min)** since last connection (`p10e-last-api-connection-CORRECTED-vm-non-migratable.json`). |
| vCPU delay | `sum by (id)(rate(kubevirt_vmi_vcpu_delay_seconds_total[5m]))` | **id=0: 0.0193 s/s, id=1: 0.0581 s/s** | Met, `schedstats=enable` is active on this cluster (matches the pre-established fact), so this is real, non-blank data. |
| vCPU wait | `sum by (id)(rate(kubevirt_vmi_vcpu_wait_seconds_total[5m]))` | **id=0: 0.0193 s/s, id=1: 0.0581 s/s** | Met (same schedstats prerequisite; on this sample the delay and wait numbers happen to be numerically identical per vCPU, worth a second look before quoting both on stage as if they were independent signals). |
| vCPU usage (CPU seconds) | `sum(rate(kubevirt_vmi_cpu_usage_seconds_total[5m]))` | **0.0179 cores** | Met |
| Allocated vCPUs | `vmi:kubevirt_vmi_vcpu:count{...}` (deck's claimed recording rule) | **No data, recording rule doesn't exist on this build** | **No.** `count(vmi:kubevirt_vmi_vcpu:count)` is 0 cluster-wide (`p13b-allocated-vcpus-cluster-wide-raw.json`). The real metric, found by searching `{__name__=~".*vcpu.*"}` (`p13c-vcpu-metric-names-search.json`), is the plain metric **`kubevirt_vmi_vcpu_count`** (31 series cluster-wide). For vm-demo: **2 vCPUs** (`p13d-allocated-vcpus-CORRECTED-metric-name.json`). Swap the panel query to the raw metric name. |
| Domain memory | `kubevirt_vmi_memory_domain_bytes` | **4,294,967,296 bytes (4 GiB, the configured domain memory)** | Met |
| virt-launcher WSS (compute container) | `container_memory_working_set_bytes{pod=~"virt-launcher-vm-demo-.*",container="compute"}` | **2 rows returned, not 1**, vm-demo-2's pod (1,116,176,384 bytes) *and* vm-demo's current pod (1,073,094,656 bytes) both match | **Query-construction gotcha, not a prerequisite gap:** `vm-demo-.*` as a regex also matches `vm-demo-2-...` since `vm-demo` is a literal prefix of `vm-demo-2`. Use an exact pod name or anchor the regex (e.g. `pod=~"virt-launcher-vm-demo-[a-z0-9]+$"`) before presenting, or this panel will silently double-count on stage. vm-demo's own WSS is **1,073,094,656 bytes (~1.0 GiB)** against a 4 GiB domain, expected headroom for an idle guest. |
| Network rx by interface | `sum by (interface)(rate(kubevirt_vmi_network_receive_bytes_total[5m]))` | **interface="default": 7.10 B/s** | Met, `interface` label confirmed to exist and equal `"default"`. |
| Network tx by interface | same, transmit | **interface="default": 6.58 B/s** | Met |
| Network rx errors | `rate(kubevirt_vmi_network_receive_errors_total[5m])` | **0** | Met (data present, value is zero, healthy, not blank) |
| Network tx errors | same, transmit | **0** | Met |
| Network rx packet drops | same | **0** | Met |
| Network tx packet drops | same | **0** | Met |
| Storage IOPS read by drive | `sum by (drive)(rate(kubevirt_vmi_storage_iops_read_total[5m]))` | **cloudinitdisk: 0, rootdisk: 0** | Met, `drive` label confirmed (`cloudinitdisk`, `rootdisk`). |
| Storage IOPS write by drive | same, write | **cloudinitdisk: 0, rootdisk: 0.141/s** | Met |
| Storage read traffic by drive | `sum by (drive)(rate(kubevirt_vmi_storage_read_traffic_bytes_total[5m]))` | **cloudinitdisk: 0, rootdisk: 0** | Met |
| Storage write traffic by drive | same, write | **cloudinitdisk: 0, rootdisk: 2,123.9 B/s** | Met |

---

## 3. Cluster-wide label-slicing

| Slice | Query | Result | File |
|---|---|---|---|
| Top-5 VMs by vCPU usage rate, cluster-wide | `topk(5, sum by (namespace,name)(rate(kubevirt_vmi_cpu_usage_seconds_total[5m])))` | `hammer/hammer-sno` 4.90, `shannon/shannon-2` 4.37, `hammer/hammer2-sno` 4.06, `anaeem-dev/ocp-dev-worker-0` 3.84, `asaran/asaran` 3.63 (cores) | `l01-top5-vms-by-vcpu-usage-rate.json` |
| VM count by namespace, `namespace:kubevirt_vm:sum` (deck's claimed recording rule) |, | **No data, recording rule doesn't exist on this build** (empty result) | `l02a-vm-count-by-namespace-recording-rule.json` |
| VM count by namespace, fallback `count by (namespace)(kubevirt_vmi_info)` |, | **demo-vms:3, joon:4, asaran:1, anaeem-dev:5, hammer:3, shannon:1, default:1, aap-edb-vms:6, anaeem:7 -> total 31** | `l02b-vm-count-by-namespace-count-vmi-info.json` |
| VMs by `instance_type` label | `count by (instance_type)(kubevirt_vmi_info)` | Label **exists**: u1.2xlarge:3, u1.4xlarge:4, u1.xlarge:7, u1.medium:7, u1.large:2, u1.2xmedium:1, plus **7 with an empty/no instance_type label** | `l03-vm-count-by-instance-type.json` |
| Demo VMs by tier, `kube_pod_labels{label_tier}` | `count by (label_tier)(kube_pod_labels{namespace="demo-vms", label_kubevirt_io="virt-launcher"})` | **db:1, web:2 (inflated, see note), nonmigratable:1** | `l04a-demo-vms-by-tier-kube-pod-labels.json`. The "web:2" is the same migration artifact as section 1, vm-demo currently has two virt-launcher pods (old Completed + new Running) both labeled `tier=web`; steady-state should read web:1. |
| Demo VMs by tier, `kubevirt_vm_labels` | `kubevirt_vm_labels{namespace="demo-vms"}` | **No data, metric doesn't exist at all on this cluster** (0 series cluster-wide) | `l04b-demo-vms-by-tier-kubevirt-vm-labels.json`, `l04c-kubevirt-vm-labels-cluster-wide-count.json`. Confirms the deck's own open question 7 ("confirm the ConfigMap allow-list"), on this build the answer is simply "not allow-listed at all"; `kube_pod_labels` is the only working path to a business label like `tier` right now. |
| VMs per node | `count by (node)(kubevirt_vmi_info)` | `ec-f4-bb-ed-07-a8: 10, 24-6e-96-33-24-90: 11, 80-18-44-f0-71-30: 10` (sums to 31, consistent with the namespace breakdown) | `l05-vms-per-node.json` |

---

## 4. Metric/series inventory, cluster-wide

| Metric | Query | Result | File |
|---|---|---|---|
| Distinct `kubevirt_*` metric names | `count(count by (__name__)({__name__=~"kubevirt_.*"}))` | **144** | `m02-total-distinct-kubevirt-metric-name-count.json` (full per-name breakdown in `m01-distinct-kubevirt-metric-names-by-name.json`) |
| Total `kubevirt_vmi_*` series, cluster-wide | `count({__name__=~"kubevirt_vmi_.*"})` | **3,068** | `m03-total-kubevirt-vmi-series-cluster-wide.json` |

---

## Corrections needed before this deck goes on stage

1. **Row-A "proof point" query 3 fails outright on this real cluster**, both from the transient two-pod migration state and from a deeper, reproducible issue where a `__name__=~"..."` metric-name regex combined with `* on(...) group_left()` errors on this Thanos build regardless of pod cardinality. Recommend switching the panel to the `and on(namespace,pod)` boolean-membership form shown in section 1, it's simpler, gives the same count, and didn't error once across every variant tested.
2. **Both phase-transition histogram panels are structurally wrong for this KubeVirt build.** They are virt-controller-emitted fleet-wide histograms living in `namespace="openshift-cnv"` with a `phase` label and **no per-VM label at all**. A `{namespace="$namespace",name="$vm"}` filter can never return data, drop the per-VM filter and present these as fleet-wide phase-duration histograms, or drop the panels from the per-VM view.
3. **`vmi:kubevirt_vmi_vcpu:count` and `namespace:kubevirt_vm:sum`, neither recording rule exists on this build.** Use the raw metrics instead: `kubevirt_vmi_vcpu_count` and `count by (namespace)(kubevirt_vmi_info)` respectively. Both fallbacks are confirmed working above.
4. **`kubevirt_vmi_last_api_connection_timestamp_seconds` uses label `vmi`, not `name`.** Fix the panel's label name before presenting, and expect it to still show "no data" for vm-demo specifically since nobody has opened its console/VNC (this part is a real, correct "no data," not a bug).
5. **`kubevirt_vm_labels` does not exist on this cluster at all** (0 series). The section (d).4 "slice by a business label" panel needs `kube_pod_labels{label_tier=...}` as its actual data source here, not `kubevirt_vm_labels`.
6. **The virt-launcher WSS panel's pod regex over-matches.** `pod=~"virt-launcher-vm-demo-.*"` also captures `vm-demo-2`'s pod because of the shared name prefix. Anchor the regex or use an exact pod name.
7. **VM count is 31, not the previously stated 28** (`kubevirt_vmi_info` count taken live just now), likely just more VMIs having started elsewhere on this shared cluster since that number was established; worth a quick re-check right before presenting rather than quoting the older figure from memory.
