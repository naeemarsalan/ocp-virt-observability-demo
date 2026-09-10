# ACT 1 — DEPTH: "One VM, Side by Side"

**Target versions (pin these in preflight, cluster not reachable while authoring):** OpenShift 4.20 · OpenShift Virtualization 4.20 · Cluster Observability Operator 1.5+ (Perses GA) · OpenShift Logging 6.x / LokiStack · Network Observability operator (GA) · Tempo (optional, not used in Act 1).

**Metric/alert names verified 2026‑09‑08 against:** kubevirt.io/monitoring/metrics.html, github.com/kubevirt/monitoring/blob/main/docs/metrics.md (incl. raw source, which also surfaces deprecated‑metric → replacement‑recording‑rule mappings not shown on the rendered page), and github.com/kubevirt/monitoring/tree/main/docs/runbooks (80 runbook files = 80 verified alert names). Every PromQL expression below uses only names that exist in that source. Where a label's existence could not be independently confirmed from public docs (`phase`, `interface`, `drive`, `instance_type`, `node` on VMI‑scoped metrics), it is called out and `preflight.sh` checks it live against the real cluster before you present.

**One version correction the research report doesn't call out:** PSI (`psi=1`, `container_pressure_cpu/memory/io_*`) requires **OpenShift ≥ 4.21** per Red Hat's own PSI-enablement article. Since this Act 1 is pinned to **4.20**, PSI-based panels are **out of scope** — every "scheduling contention" panel here uses KubeVirt's own `schedstats=enable`-gated `vcpu_delay`/`vcpu_wait` counters instead, which *are* available on 4.20. Don't let a PSI panel sneak into the deck for a 4.20 cluster.

---

## (a) Counting distinct series for one VM — and why the raw count is the wrong comparison to make

**Say this out loud before showing any number:** vCenter/Aria expose a **fixed counter set per statistics level (1–4)** — it does not grow per VM the way a label‑indexed TSDB does. A raw side‑by‑side count is apples‑to‑oranges and a skeptical architect will call it out. The defensible claim is **"every one of these series is independently queryable and joinable by arbitrary label, right now, with ordinary PromQL"** — not "we have more metrics than you."

**Query 1 — VMI-scoped series only:**
```promql
count({namespace="<ns>", name="<vm>", __name__=~"kubevirt_vmi_.*"})
```

**Query 2 — + VM-object-level series** (exist even while the VM is stopped: `kubevirt_vm_info`, `kubevirt_vm_resource_requests/limits`, `kubevirt_vm_disk_allocated_size_bytes`, `kubevirt_vm_labels`, lifecycle timestamps):
```promql
count({namespace="<ns>", name="<vm>", __name__=~"kubevirt_(vmi|vm)_.*"})
```

**Query 3 — + everything joinable via the virt-launcher pod** (standard cAdvisor `container_*` and kube-state-metrics `kube_pod_*` series — cgroup CPU/mem/net, restart counts, node placement, requests/limits). This is the actual proof point, because it joins on a real Kubernetes label the virt-launcher pod carries (`vm.kubevirt.io/name=<vm>`), **not an ownerReference** — the same non-obvious fact that makes Korrel8r ship a KubeVirt-specific `VmiToPod` rule instead of relying on its generic owner-follow rule:
```promql
(count({namespace="<ns>", name="<vm>", __name__=~"kubevirt_(vmi|vm)_.*"}) or vector(0))
+
(count(
  {namespace="<ns>", __name__=~"container_.*|kube_pod_.*"}
  * on(namespace,pod) group_left()
  (kube_pod_labels{namespace="<ns>", label_vm_kubevirt_io_name="<vm>"} * 0 + 1)
) or vector(0))
```
**Correctness note (fixed in this pass):** the parentheses around each `count(...) or vector(0)` half are load-bearing, not cosmetic. PromQL's arithmetic operators (`+`) bind tighter than the set operator `or`, so writing this without the outer parens — `count(A) or vector(0) + (count(B) or vector(0))` — parses as `count(A) or (vector(0) + (count(B) or vector(0)))`. Since `count(A)` always returns a non-empty vector for a running VM, the `or` then silently drops the entire pod-joined half, and the panel marketed as "the actual proof point" would quietly show only the VMI-scope count. Both dashboard files had this exact bug and have been corrected to match the parenthesized form above.

**Silent-blank prerequisite this join depends on (not previously called out):** the pod-join above, and the dashboard's hidden `pod` template variable that reuses it, both need `kube_pod_labels{label_vm_kubevirt_io_name="<vm>"}` to return data. Since kube-state-metrics v2.0 — which OpenShift's cluster-monitoring-operator ships — `kube_pod_labels` exposes **only name/namespace by default**; an arbitrary pod label like `vm.kubevirt.io/name` only becomes `label_vm_kubevirt_io_name` if it has been explicitly allow-listed on kube-state-metrics. OpenShift does not do this out of the box. This is the same class of "silently blank by design, not error" trap the research report warns about elsewhere, and it sits behind the single most rehearsed panel in this deck plus a variable used by every join query on the dashboard — unlike the analogous `label_team` join in section (d).4 below, which was already correctly flagged. `preflight.sh` now checks this live (section 16) and tells you exactly what to do if it's missing.

All three are wired into the Grafana dashboard's row A as live stat panels (variables resolve `<ns>`/`<vm>` for you).

---

## (b) Panel-by-panel PromQL for every Act 1 panel

Priority order matches the brief: no-VMware-equivalent metrics first, then standard CPU/mem/net/storage. `$namespace` / `$vm` are the dashboard template variables; `$__rate_interval` is Grafana's/Perses' auto rate window.

| Panel | PromQL | Prerequisite |
|---|---|---|
| Phase-transition latency (creation→phase), p50/95/99 | `histogram_quantile(0.95, sum by (le) (rate(kubevirt_vmi_phase_transition_time_from_creation_seconds_bucket{namespace="$namespace",name="$vm"}[$__rate_interval])))` | none (native histogram); verify `phase` label if you group by it |
| Migration phase-transition latency, p95 | `histogram_quantile(0.95, sum by (le) (rate(kubevirt_vmi_migration_phase_transition_time_from_creation_seconds_bucket{namespace="$namespace",name="$vm"}[$__rate_interval])))` | none |
| Storage flush rate | `sum(rate(kubevirt_vmi_storage_flush_requests_total{namespace="$namespace",name="$vm"}[$__rate_interval]))` | none |
| Derived avg flush latency | `sum(rate(kubevirt_vmi_storage_flush_times_seconds_total{...}[$__rate_interval])) / sum(rate(kubevirt_vmi_storage_flush_requests_total{...}[$__rate_interval]))` | none |
| Memory available vs usable | `kubevirt_vmi_memory_available_bytes{namespace="$namespace",name="$vm"}` and `kubevirt_vmi_memory_usable_bytes{...}` | none |
| number_of_outdated (fleet gauge, post-upgrade) | `kubevirt_vmi_number_of_outdated` | none (cluster-wide, not per-VM); alert `OutdatedVirtualMachineInstanceWorkloads` |
| guest_os_panic (24h) | `increase(kubevirt_vmi_guest_os_panic_total{namespace="$namespace",name="$vm"}[24h])` | none; alerts `VMNonRecoverableOSPanic`, `ClusterVMPanicDetected` |
| non_evictable | `kubevirt_vmi_non_evictable{namespace="$namespace",name="$vm"}` | none (boolean gauge); alert `VMCannotBeEvicted` |
| Guest OS load 1m/5m/15m | `kubevirt_vmi_guest_load_1m{...}` and `kubevirt_vmi_guest_load_5m{...}` and `kubevirt_vmi_guest_load_15m{...}` | **qemu-guest-agent ≥ 10.0.0** |
| Time since last console/VNC/SSH | `time() - kubevirt_vmi_last_api_connection_timestamp_seconds{namespace="$namespace",name="$vm"}` | none |
| vCPU delay | `sum by (id) (rate(kubevirt_vmi_vcpu_delay_seconds_total{namespace="$namespace",name="$vm"}[$__rate_interval]))` | **schedstats=enable** kernel arg (worker MachineConfig) — else silently blank |
| vCPU wait | `sum by (id) (rate(kubevirt_vmi_vcpu_wait_seconds_total{...}[$__rate_interval]))` | **schedstats=enable** |
| vCPU usage (standard CPU) | `sum(rate(kubevirt_vmi_cpu_usage_seconds_total{namespace="$namespace",name="$vm"}[$__rate_interval]))` | none |
| Allocated vCPUs | `vmi:kubevirt_vmi_vcpu:count{namespace="$namespace",name="$vm"}` | none (recording rule) |
| Domain memory vs virt-launcher WSS | `kubevirt_vmi_memory_domain_bytes{...}` and `container_memory_working_set_bytes{pod=~"virt-launcher-$vm-.*",container="compute"}` | none |
| Network throughput by interface | `sum by (interface) (rate(kubevirt_vmi_network_receive_bytes_total{...}[$__rate_interval]))` (+ transmit) | none; verify `interface` label |
| Network errors/drops | `rate(kubevirt_vmi_network_receive_errors_total{...}[$__rate_interval])` and `rate(kubevirt_vmi_network_transmit_errors_total{...}[$__rate_interval])` and `rate(kubevirt_vmi_network_receive_packets_dropped_total{...}[$__rate_interval])` and `rate(kubevirt_vmi_network_transmit_packets_dropped_total{...}[$__rate_interval])` | none |
| Storage IOPS + throughput by drive | `sum by (drive) (rate(kubevirt_vmi_storage_iops_read_total{...}[$__rate_interval]))` and the `_write_total` counterpart, plus `sum by (drive) (rate(kubevirt_vmi_storage_read_traffic_bytes_total{...}[$__rate_interval]))` and the `_write_traffic_bytes_total` counterpart | none; verify `drive` label; ⚠ flaky in CI during migration (see below) |

*(Fixed in this pass: the "Guest OS load," "Network errors/drops," and "Storage IOPS + throughput by drive" rows previously used shell-style brace-expansion — e.g. `kubevirt_vmi_network_{receive,transmit}_errors_total` — which is not valid PromQL, plus a bare suffix like `_traffic_bytes_total` that isn't a real standalone metric name. The real names are `kubevirt_vmi_storage_read_traffic_bytes_total` / `_write_traffic_bytes_total`, confirmed against kubevirt.io/monitoring/metrics.html and github.com/kubevirt/monitoring/blob/main/docs/metrics.md. The dashboard JSON/YAML already had these right as separate queries; only this table's shorthand notation was wrong.)*

---

## (c) Live-migration beat

**Trigger:**
```bash
virtctl migrate <vm> -n <namespace>
# fallback if virtctl isn't on PATH:
oc create -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  generateName: <vm>-migration-
  namespace: <namespace>
spec:
  vmiName: <vm>
EOF
```
`preflight.sh` checks `LiveMigratable=True` beforehand — don't discover a `non_evictable`/local-storage block live.

**Watch (dashboard row D, and/or `migration-beat.sh` in a terminal pane for the "same numbers, plain PromQL" beat):**

| Signal | PromQL | Note |
|---|---|---|
| Data processed / remaining | `kubevirt_vmi_migration_data_processed_bytes{namespace="$namespace",name="$vm"}` and `kubevirt_vmi_migration_data_remaining_bytes{namespace="$namespace",name="$vm"}` | GAP vs VMware: vSphere shows only an ephemeral % bar |
| Live transfer rate | `kubevirt_vmi_migration_memory_transfer_rate_bytes{...}` | GAP: vSphere 8 gives one post-completion total |
| Queue depth by phase (cluster-wide) | `kubevirt_vmi_migrations_in_pending_phase`, `kubevirt_vmi_migrations_in_scheduling_phase`, `kubevirt_vmi_migrations_in_running_phase`, `kubevirt_vmi_migrations_in_unset_phase` | GAP: Aria counts *completed* vMotions/host, no live queue |
| Phase-transition histogram, live | `histogram_quantile(0.95, sum by (le)(rate(kubevirt_vmi_migration_phase_transition_time_from_creation_seconds_bucket{...}[$__rate_interval])))` | GAP: no distribution in vSphere |

**⚠ AVOID or clearly label dirty-rate.** Two related gauges exist — `kubevirt_vmi_migration_dirty_memory_rate_bytes` (this-migration) and the more general `kubevirt_vmi_dirty_rate_bytes_per_second`. Per the research, the dirty-rate signal carries an **open accuracy bug (CNV‑94992), off by 2–3 orders of magnitude vs ground truth**. Both dashboards include this panel with a title prefixed **"⚠ KNOWN BUG"** and a rule: show it only as a directional trend line, never quote an absolute number on stage, and disclose the bug if asked. (ESXi never surfaces this counter at all — it uses it internally for vMotion convergence — so even the buggy version is "more than VMware shows," but frame it as "this is what we're actively fixing," not a win.)

**⚠ Storage-metric flakiness during migration.** KubeVirt's own e2e tests for storage read/write bytes and flush requests/times were flaky/quarantined in CI (Aug 2026), timing-correlated with a fix that **skips domain-stats collection during live migration**. Translation: the storage IOPS/throughput panels for *this* VM may flatten or gap for a few seconds while the migration in row D is in flight. Disclosed and expected — don't let it read as a broken dashboard live.

---

## (d) Slice by an arbitrary label — the PowerCLI-scripting cases

1. **By node** — top 5 nodes by fleet-wide VM vCPU usage:
   ```promql
   topk(5, sum by (node) (rate(kubevirt_vmi_cpu_usage_seconds_total[$__rate_interval])))
   ```
2. **By namespace** — VM count per namespace, fleet-wide:
   ```promql
   namespace:kubevirt_vm:sum
   ```
3. **By instancetype label** — VM count per instance type, fleet-wide (verify `instance_type` label via preflight — recent KubeVirt builds add it to `kubevirt_vmi_info`, not guaranteed on every build):
   ```promql
   count by (instance_type) (kubevirt_vmi_info)
   ```
4. **By a user-defined VM label** — CPU usage grouped by a business label you put on the VM (`team`, `cost_center`, whatever you allow-list on `kubevirt_vm_labels` — confirm the exact ConfigMap name/mechanism against your CNV version in preflight; the general allow-list mechanism is documented, but this deck's specific ConfigMap name was not independently re-verified in this pass):
   ```promql
   sum by (label_team) (
     sum by (namespace, name) (rate(kubevirt_vmi_cpu_usage_seconds_total{namespace="$namespace"}[$__rate_interval]))
     * on(namespace, name) group_left(label_team)
     kubevirt_vm_labels{namespace="$namespace"}
   )
   ```
5. **Top-k across the fleet** — top 10 VMs by network transmit, cluster-wide:
   ```promql
   topk(10, sum by (namespace, name) (rate(kubevirt_vmi_network_transmit_bytes_total[$__rate_interval])))
   ```
Swap the inner metric in #5 for `storage_iops_*`, `cpu_usage_seconds_total`, or `memory_usable_bytes` — same one-line pattern every time, no PowerCLI required.

---

## (e) Dashboards

**Grafana (Grafana 10/11, schemaVersion 39)** — `act1-grafana-dashboard.json`: 31 panels across 5 rows (A. series-count depth check, B. standard CPU/mem/net/storage, C. no-VMware-equivalent signals, D. live migration beat, E. slice-by-label fleet view). Template variables: `datasource` (type=datasource, query=prometheus), `namespace` and `vm` (label_values against `kubevirt_vmi_info`), and a hidden derived `pod` variable (via `kube_pod_labels{label_vm_kubevirt_io_name=...}`) used by the join queries — see the silent-blank prerequisite called out in section (a) above; `preflight.sh` now checks it live.

**Perses (COO 1.5+, `PersesDashboard` CRD)** — `act1-perses-dashboard.yaml`: a representative subset (15 panels, 5 grid layouts) covering every category. **Namespace-scoped** — the CR must live in the same namespace as your `PersesDatasource`/UIPlugin, which is *not* `openshift-monitoring` by default; the placeholder namespace `virt-observability-demo` and the `directUrl` datasource path both say `# PIN IN PREFLIGHT` and must be corrected against your real cluster. **Honesty note on this file specifically:** Red Hat's own COO articles don't publish a complete, verified end-to-end `PersesDashboard` YAML as of this writing — this schema was assembled from the public Perses dashboard API reference plus COO's documented CRD-wrapping convention (`spec.config.*` mirrors the native Perses `display/variables/panels/layouts`). Treat it as a strong first draft, not a copy-pasted known-good sample, and run `oc apply --dry-run=server -f act1-perses-dashboard.yaml` against the real CRD before presenting. (The `apiVersion: perses.dev/v1alpha2` / `kind: PersesDashboard`, and the plugin kinds used — `ListVariable`, `TextVariable`, `PrometheusTimeSeriesQuery`, `StatChart`, `TimeSeriesChart` — were independently checked against the public Perses dashboard API reference and are correct as written.)

**Both dashboard files had one PromQL correctness bug fixed in this pass:** the row-A / seriesCountJoined "proof point" panel's `count(...) or vector(0) + (count(...) or vector(0))` expression relied on operator precedence that PromQL doesn't give it (see section (a) for the full explanation) and would have silently shown only the VMI-scope count. Both files now wrap each half in parentheses and have been re-validated as syntactically correct JSON/YAML.

---

## GA / Tech Preview / Dev Preview / Experimental status of everything used here

| Capability used in Act 1 | Status |
|---|---|
| `kubevirt_vmi_*` / `kubevirt_vm_*` metrics in cluster Prometheus | **GA** |
| Cluster Observability Operator (COO) | **GA** (1.0, Feb 2025) |
| Perses customizable dashboards / `PersesDashboard` CRD | **GA** (COO 1.5, June 2026) — **namespace-scoped** |
| `virtctl migrate` / live migration | **GA** |
| `schedstats=enable` kernel argument (worker MachineConfig) | No maturity marker — standard kernel debug facility; **applying it reboots workers, don't do it live**, pre-apply before the demo |
| PSI (`psi=1`) | **NOT in scope** — requires OpenShift **≥ 4.21**; this Act 1 targets 4.20 and uses `schedstats`-gated vcpu_delay/wait instead |
| `kubevirt_vmi_dirty_rate_bytes_per_second` / `migration_dirty_memory_rate_bytes` | **GA metric, open accuracy bug CNV‑94992** — shown only as a labeled, trend-only panel |
| `kubevirt-metrics-exporter` (KME) | **Experimental/unsupported** — deliberately **excluded** from this Act 1 build |
| OpenShift Logging 6.x / LokiStack, Network Observability operator, Tempo | **GA** (Tempo optional) — not used by Act 1's PromQL/dashboards directly; `preflight.sh` checks their CRDs anyway because they gate the Korrel8r Troubleshooting Panel's log/netflow/trace nodes if this demo continues into a correlation act |

---

## Files written (all under the scratchpad `demo/` directory)

- `act1-grafana-dashboard.json` — Grafana 10/11 dashboard, 31 panels, validated JSON. **Fixed in this pass:** the row-A "proof point" panel's PromQL had an operator-precedence bug (see (a) above); corrected and re-validated.
- `act1-perses-dashboard.yaml` — `PersesDashboard` CR for COO 1.5+, 15 panels, validated YAML; needs namespace + datasource `directUrl` pinned. **Fixed in this pass:** the same PromQL precedence bug as the Grafana file, in the mirrored `seriesCountJoined` panel; corrected and re-validated.
- `preflight.sh` — run against the real cluster before presenting: checks OCP/CNV/COO versions, VMI existence and `LiveMigratable`, guest-agent connection, `schedstats=enable` MachineConfig presence, PSI version-gate (expects absent on 4.20, now using a real numeric major.minor comparison instead of a fragile lexicographic string compare), the five label assumptions this deck makes (`phase`, `interface`, `drive`, `instance_type`, `node`) via live Thanos queries (section 15, added in this pass — the script did not actually do this before), a live check for the `kube_pod_labels`/`label_vm_kubevirt_io_name` kube-state-metrics allow-list prerequisite the row-A join depends on (section 16, added in this pass), LokiStack/NetObserv/Tempo/korrel8r CRD presence, a live check of cgroups v1-vs-v2 mode on a worker node relevant to the 4.20 `cgroup_id`→`id` rename trap (section 17, added in this pass), and Prometheus scale/OOM context. `bash -n` and `shellcheck -S warning` both pass clean; a live dry-run (with `oc` unauthenticated) exercises every section end-to-end without crashing.
- `migration-beat.sh` — terminal-side companion for Act 1(c): triggers the migration (with a confirmation prompt) and polls the same migration series live via `curl`+Thanos, so the audience sees the identical numbers in the dashboard and in a raw PromQL query. Reviewed, no issues found — metric names and gauge semantics all confirmed correct.

## Open questions to close before the live demo

1. **Label assumptions not independently confirmed from public docs** — `phase` on the phase-transition histograms, `interface` on network metrics, `drive` on storage metrics, `instance_type` and `node` on `kubevirt_vmi_info`/`kubevirt_vmi_cpu_usage_seconds_total`. `preflight.sh` section 15 now actually checks all five live against Thanos (it did not before this pass); if any come back WARN, drop that `by (...)` grouping in the affected panel before presenting.
2. **The `kube_pod_labels`/kube-state-metrics allow-list prerequisite for the row-A "proof point" join and the hidden `pod` variable** — by default this label is NOT exposed on OpenShift; `preflight.sh` section 16 checks it live and tells you how to fix it or fall back to a live `oc get pod -l vm.kubevirt.io/name=<vm>` lookup on stage instead.
3. **Perses schema fidelity** — no verified complete `PersesDashboard` sample exists in public Red Hat docs as of this writing; validate with `oc apply --dry-run=server` and fix any field-name drift the CRD's admission/validation reports.
4. **Which dirty-rate metric CNV‑94992 actually covers** — the research report references "dirty_rate" generically; two related metrics exist (`kubevirt_vmi_dirty_rate_bytes_per_second`, `kubevirt_vmi_migration_dirty_memory_rate_bytes`). Treat both as suspect for the demo rather than assuming only one is affected.
5. **Real datasource UID / Thanos-querier proxy path** and **virt-launcher compute container name** (`compute` is standard but confirm: `oc get pod virt-launcher-<vm>-... -o jsonpath='{.spec.containers[*].name}'`).
6. **Which namespace actually hosts your `PersesDatasource`/UIPlugin** — the Perses CR must go there, not in a namespace you pick arbitrarily.
7. **Confirm the exact ConfigMap name/mechanism for allow-listing `kubevirt_vm_labels`** (referenced in section (d).4) against your specific CNV build — the general allow-list mechanism is documented, but the exact ConfigMap name used in this deck was not independently re-verified in this review pass.
8. **Confirm the pinned korrel8r image contains the compiled KubeVirt quickrules** (`VmToVmi`, `VmiToPod`, `VmiToNode`, …) if this Act 1 leads into a Korrel8r correlation act — they're absent from COO's own release notes 1.0–1.5.2 per the research, so verify the image directly rather than trusting the docs. `preflight.sh` section 10 already attempts a best-effort live check of this.
