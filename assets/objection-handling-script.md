# OpenShift Virtualization vs vSphere: Objection-Handling Script for a Skeptical Architect

**Audience:** a vSphere/vROps/Aria architect evaluating OpenShift Virtualization observability.
**Target build this script is written for:** OpenShift 4.20, OpenShift Virtualization 4.20, Cluster Observability Operator (COO) 1.5+ (Perses GA), OpenShift Logging 6.x + LokiStack, Network Observability operator (GA), Tempo optional.
**Companion artifacts** (same scratchpad `demo/` directory, built for Acts 1-3 of the live demo): `preflight.sh`, `manifests/00-09-*.yaml`, `act1-perses-dashboard.yaml` / `act1-grafana-dashboard.json`, `migration-beat.sh`, `act2-01…07-*`, `act3/*`. This script narrates that build; it does not replace running `preflight.sh` against the actual cluster before you present.

**Maturity legend used throughout:** **GA** = generally available and supported · **TP** = Tech Preview · **DP** = Dev Preview · **Experimental** = upstream-only, explicitly not productized · **Roadmap** = not shipping.

Every metric and alert name below was checked verbatim against the KubeVirt metrics reference (kubevirt.io/monitoring/metrics.html and github.com/kubevirt/monitoring/blob/main/docs/metrics.md), the KubeVirt monitoring runbooks index (github.com/kubevirt/monitoring/tree/main/docs/runbooks), the korrel8r `kubevirt.qtpl` and `alert.qtpl` quickrules source, and current Red Hat documentation. Where a claim in the earlier internal research could not be independently confirmed against these public sources, it is marked so below rather than repeated as fact.

---

## Part 1: Presenter Script (3-Act Narrative Arc)

### Opening thesis (say this before touching a keyboard)

> "I'm not going to argue that our dashboards look better than vCenter's. Out of the box, they don't. What I want to show you is that once a VM runs on this platform, its metrics, logs, and traces land in the same open, label-indexed store as every pod and node you already run. That means you can query it, correlate it, and automate against it with the tools you already use for containers. That's the claim. Let's test it."

### Act 1: The Store (open, joinable telemetry)

**Transition in:** "Let's start with where the data actually lives, not with a chart."

**What you show:** Open the Perses (or Grafana) dashboard (`act1-perses-dashboard.yaml`). Row A shows the raw series count for one VM's `kubevirt_vmi_*` metrics next to the same series joined by `namespace`/`name` to pod and node labels, proving it's one TSDB, not an export. Row B is parity ground (CPU/memory, a fair tie with Aria). Row C is the set with no vCenter/Aria equivalent: `kubevirt_vmi_storage_flush_requests_total`, `kubevirt_vmi_guest_os_panic_total`, `kubevirt_vmi_non_evictable`, vCPU wait/delay (`kubevirt_vmi_vcpu_wait_seconds_total` / `kubevirt_vmi_vcpu_delay_seconds_total`, **needs the `schedstats=enable` kernel argument via MachineConfig, GA-documented, rolls the node**), and guest load (`kubevirt_vmi_guest_load_1m/5m/15m`, **needs qemu-guest-agent ≥ 10.0.0 in the guest**). Row D is the live-migration beat; run `migration-beat.sh` in a second pane so the audience sees the same `kubevirt_vmi_migration_data_processed_bytes` / `_data_remaining_bytes` numbers in a plain PromQL query and in the dashboard simultaneously.

**Landing sentence:** "This is one time-series database, not a separate VM product bolted on the side. The join key is an ordinary label, not an export-and-import step."

### Act 2: The Correlation (Korrel8r Troubleshooting Panel)

**Transition in:** "Data sitting in one place is necessary but not sufficient. Watching someone actually walk it during an incident is the part that matters."

**What you show:** Trigger the `VMCannotBeEvicted` alert (recipe `act2-02-recipe-a-vmcannotbeevicted.yaml`, a VM with `evictionStrategy: LiveMigrate` on a `ReadWriteOnce` disk; fires in about a minute, no guest boot required). Open the alert in the Troubleshooting Panel (COO 1.3+, **GA** on OCP 4.19+) and walk the node graph: alert → `VirtualMachine` → `VirtualMachineInstance` → the `virt-launcher` pod → its logs (needs LokiStack, **GA**) → its node.

**The one sentence that makes this land:** "That last hop, VMI to its virt-launcher pod, works because korrel8r ships a KubeVirt-specific rule that follows the `kubevirt.io=virt-launcher` / `vm.kubevirt.io/name=<vmi>` **label**, not a standard Kubernetes owner reference; the generic rule alone would never make that jump, and it's exactly the click-through a plain dashboard-to-VM navigation doesn't have today."

**Caution for the presenter, not the audience:** do not use the `OutdatedVirtualMachineInstanceWorkloads` alert for this walk. Its backing metric (`kubevirt_vmi_number_of_outdated`) carries no per-VM labels, the alert has no `name`/`namespace` to hand `AlertToVMI`, and its `for: 24h` window means it cannot fire live in a demo slot anyway. Run `act2-01-korrel8r-verify.sh` against the actual cluster beforehand. The KubeVirt rules are compiled into the korrel8r binary from v0.12.1 onward and are not called out in COO's own release notes, so the only way to know your build has them is to ask the running pod.

### Act 3: The Automation (same fabric, same pipeline)

**Transition in:** "Now the part that changes operations: what happens after that click, with nobody watching."

**What you show:** Alertmanager routes the same alert class (VM or pod, it doesn't distinguish) to whatever webhook-based remediation you already run (Event-Driven Ansible or equivalent); a `VirtualMachine` custom resource under GitOps (ArgoCD) reconciles back to its declared state within seconds of manual drift, the same as any Deployment. If your remediation tooling isn't wired into the demo cluster, narrate this from the architecture rather than faking a click. It's a **GA** mechanism (Alertmanager routing and GitOps reconciliation are unchanged by the workload being a VM), so it does not need a live trigger to be credible; showing the identical `AlertmanagerConfig`/route used for pod alerts, now also matching a VM alert's labels, makes the point without inventing anything.

**Optional stretch beat, clearly labeled:** if the room is technical and asks "can an agent do this walk for me," show `act3/korrel8r-goals-fallback.sh`. It calls the exact REST endpoint (`POST /api/v1alpha1/graphs/goals`) that korrel8r's **Experimental** MCP server (`create_goals_graph`) calls underneath, for the `KubeVirtVMIExcessiveMigrations` alert. Say explicitly: "this is the deterministic rule graph, no LLM in the loop. The MCP wrapper around it is an upstream-only, Experimental feature with no announced roadmap toward standalone productization, and the console-assistant integration is roadmapped, not shipping." Do not run the MCP config (`act3/mcp-config-*.json`) as if it were a supported product feature.

**Landing sentence:** "The remediation pipeline doesn't know or care whether the alert came from a VM or a container. That's the automation win, and it's the one a vCenter custom-alarm script can't give you without you building a second, parallel pipeline just for VMs."

### Close

> "So the ask isn't 'trust our dashboards', concede that point, they're not the win. The ask is: bring one of your own workloads, point your own PromQL and your own automation at this store, and see if it joins, correlates, and triggers the way you just watched. If it doesn't hold up under your own query, that's useful information for both of us, and I'd rather find that out now than after a migration."

---

## Part 2: Concede First

State these unprompted, before the architect raises them. One honest sentence each on the OpenShift-side answer.

| VMware/Aria strength | What OpenShift offers instead (stated plainly) |
|---|---|
| **Capacity planning / What-If modeling:** Aria models adding or removing workload up to a year out and returns fit/no-fit, time-to-exhaustion, and cost. | RHACM VM/namespace right-sizing (**GA**, ACM 2.16) gives current-state CPU/memory over- and under-provisioning recommendations at the VM level (real, but it does not forecast forward in time the way Aria's What-If does). |
| **Predictive DRS:** Aria feeds forecast utilization into the scheduler nightly to pre-emptively rebalance. | OpenShift's descheduler acts on current-state metrics (optionally node-level PSI, where enabled) to rebalance. It reacts, it does not forecast. |
| **Built-in cost / showback / chargeback** with configurable cost drivers. | No native OCP Virt equivalent ships in the box; cost visibility is assembled from the same Prometheus metrics via a separate cost-management tool. |
| **Multi-year native retention:** Aria keeps full 5-minute resolution for 6 months and hourly rollups for years, no external TSDB required. | In-cluster Prometheus is short-horizon by design; multi-year retention means you deploy, size, and operate Thanos (or forward metrics externally) yourself. |
| **esxtop scheduler-level depth** (`%RDY`, `%CSTP`, `%MLMTD`): a decades-mature, stable counter taxonomy. | The nearest equivalents, `kubevirt_vmi_vcpu_delay_seconds_total` and `kubevirt_vmi_vcpu_wait_seconds_total`, need the `schedstats=enable` kernel argument turned on cluster-wide and use a different counter model (close, not a 1:1 mapping). |
| **Mature PowerCLI `Get-Stat`:** a stable, decades-old scripting interface with a well-known counter catalog. | PromQL against `kubevirt_vmi_*` is equally scriptable and language-agnostic, but the counter catalog is younger and still evolving release to release. |

---

## Part 3: Objection Table

**1. "vROps already has all these metrics."**
Utilization metrics are a fair tie: CPU, memory, disk, and network overlap closely enough that neither side should claim a win there. But roughly a third of the KubeVirt metric set has no vROps/Aria counterpart at all: live migration data-processed/remaining as a queryable time series, per-phase lifecycle histograms, storage flush counters, and guest-panic counts, because Aria's model wasn't built to expose in-flight migration or lifecycle-phase telemetry as label-queryable series. And even where a metric overlaps one-for-one, vROps's copy lives in a closed store queryable only through vROps itself, while the KubeVirt series joins by label to every pod and node metric in the same TSDB.

**2. "Aria has PromQL too."**
That's Aria Operations for Applications (formerly Wavefront), a separate SaaS product for application and cloud-native telemetry. It does not ingest vCenter or ESXi host/VM performance counters, so it doesn't close this gap for infrastructure metrics; you'd still have two disconnected stores, one for VM-infra data and one for app/cloud data. On OpenShift, the VM's `kubevirt_vmi_*` series and the application's own metrics land in the same Prometheus instance, queryable with one PromQL statement.

**3. "You need an agent in every VM."**
That's parity, not a gap either direction. Hypervisor-level CPU, memory, disk, and network metrics are collected agentlessly on both platforms. Guest-level depth (filesystem usage, load average, in-guest process/network detail) needs the qemu-guest-agent on OpenShift, exactly as guest-level depth on vSphere needs VMware Tools. Neither vendor gets guest interiority for free.

**4. "Your dashboards are worse than vCenter out of the box."**
Conceded. The out-of-the-box console experience is genuinely behind vCenter today, and there is no built-in click-through from a stock dashboard panel to the VM object the way vCenter links a chart to its inventory item. The win isn't the default dashboard; it's the store underneath it: Perses (**GA**, COO 1.5+) and Grafana dashboards are fully customizable and importable, and the Troubleshooting Panel's correlation walk gives you the click-through vCenter has natively, through a different mechanism.

**5. "Prometheus won't scale to my 10,000 VMs."**
Budget roughly 60 series per VMI for the core `kubevirt_vmi_*` metric set; at 10,000 VMs that's on the order of 600,000+ series for VM metrics alone, before pods, nodes, and kube-state-metrics are added in, and clusters at multi-thousand-VM scale have needed deliberate Prometheus CPU/memory sizing to avoid resource exhaustion. This is a real capacity-planning exercise, not a checkbox. Thanos for long-term storage plus sizing sized against your actual VM count is the answer, and it deserves the same seriousness you already give vCenter's statistics-level and rollup-interval planning. We size this against your VM count and target retention before committing to a number, not after.

**6. "The Principled Technologies benchmark says OpenShift is slower."**
Those published results exist, and we're not disputing that the numbers are the numbers for the configuration tested, but that configuration used Ceph-backed storage without a local NVMe caching tier, and Red Hat's own OpenShift Virtualization reference architecture recommends a hyperconverged Ceph deployment backed by local NVMe device sets for VM storage, so the tested configuration does not match what Red Hat actually recommends you run. VMware's EULA prevents publishing a counter-benchmark on vSphere, so we can't hand you an equivalent number back even if we ran one. The fair resolution is to run one of your own representative workloads on both platforms with your own storage configuration and compare directly.

**7. "Where is my What-If / cost model?"**
Narrower today, honestly. RHACM's right-sizing recommendations (**GA**, ACM 2.16) give current CPU/memory over- and under-provisioning at the VM level across a fleet, but they don't do Aria's forward-looking fit/no-fit-in-N-months modeling or built-in cost-vs-price. If a multi-year capacity or cost forecast is a hard requirement today, that's a real gap, not something to paper over.

**8. "How long do you keep logs?"**
LokiStack is supported for up to 30 days by design. It's built as a fast, short-term troubleshooting store, not a compliance archive, and that includes VM logs; there is no separate retention rule for VMs versus pods. For longer retention, forward logs externally through the same log-forwarding API used for container logs. Size the LokiStack tier deliberately rather than defaulting to the smallest one: the smallest supported tier (`1x.pico`) locks in a fixed minimum resource footprint that can be more than a genuinely light VM log volume needs (a real cost-sizing conversation on some fleets) while a heavier VM fleet can just as easily outrun it on ingest. Size up or down from `1x.pico` against your actual VM log volume; don't assume the smallest tier is either automatically safe or automatically right-sized.

**9. "Can an AI agent really troubleshoot this?"**
Not end-to-end, not yet. OpenShift Lightspeed is **GA** and answers how-to questions today; a korrel8r MCP server exists upstream but is explicitly **Experimental**, with no announced roadmap toward standalone productization, and the Lightspeed-to-korrel8r console integration is roadmapped for a later OpenShift release, not shipping now. What is real today is the deterministic version: the Troubleshooting Panel's rule-based alert-to-VM-to-pod-to-logs walk runs without an LLM in the loop at all, which is arguably the more trustworthy story to lead with.

**10. "Migration metrics: can I trust them?"**
The transfer-progress series are solid: `kubevirt_vmi_migration_data_processed_bytes` and `kubevirt_vmi_migration_data_remaining_bytes` give a live, queryable view of an in-flight migration, which vSphere doesn't expose as a time series at all, only a point value after completion. The dirty-rate series (`kubevirt_vmi_dirty_rate_bytes_per_second` and `kubevirt_vmi_migration_dirty_memory_rate_bytes`) has a known open accuracy issue tracked upstream, so don't build an alert threshold on dirty rate specifically until it's resolved. Trust the transfer/remaining numbers for progress tracking; treat dirty rate as directional only for now.

**11. "Is Korrel8r VM-aware, or is it generic Kubernetes tooling?"**
VM-aware. Upstream korrel8r ships KubeVirt-specific quickrules (`VmToVmi`, `VmiToPod`, `VmiToNode`, `VmToPVC`, `VmToAlert`/`VmiToAlert`, and the reverse `AlertToVM`/`AlertToVMI` rules that resolve a VM or VMI directly from an alert's `namespace`/`name` labels) alongside the generic Kubernetes rules. This matters concretely: a virt-launcher pod is linked to its VMI by label (`kubevirt.io=virt-launcher`, `vm.kubevirt.io/name=<vmi>`), not a standard ownerReference, so the generic owner-following rule alone would never make that hop; verify the korrel8r image your specific COO build pins actually contains these rules before you rely on the walk live, since they are recent additions and not yet mentioned in COO's own release notes.

---

## Part 4: Do Not Say

Claims below are not supportable against the current build and should not be used, even as color:

- **"Our dashboards are better than vCenter/vROps out of the box."** They aren't, by Red Hat's own field assessment. Concede this every time, don't contest it.
- **"Agentic troubleshooting ships today."** The korrel8r MCP server is upstream-only and **Experimental**, with no announced roadmap toward standalone productization; the Lightspeed console integration is roadmap, not current. Say "deterministic rule-based walk, with an experimental AI layer on top," never "AI troubleshoots your VMs."
- **Citing any specific customer as a reference for this capability.** No customer account is cleared for public reference on this claim; use hypothetical or your-own-workload framing instead.
- **Referencing internal deal size, pilot status, or any internal chat/Slack discussion as evidence.** None of that is verifiable or appropriate in a customer setting.
- **"You don't need any agent for guest-level metrics."** Guest-level metrics (filesystem, load average, guest panic detail) need the qemu-guest-agent, exactly as VMware Tools is needed on the other side. State the dependency, don't imply it's agentless.
- **"PSI-based pressure panels work out of the box on this build."** Node-level PSI (`psi=1`) is documented as available starting OpenShift 4.21; on the 4.20 target in this demo, do not promise or demo PSI panels. Drop them rather than show a silently blank one.
- **"Prometheus scales to any VM count with no planning."** It needs explicit capacity planning; clusters at high VM counts have hit resource exhaustion without deliberate sizing.
- **"The dirty-rate metric is production-accurate."** It has an open, upstream-tracked accuracy issue. Say so if it comes up, don't build a live threshold demo around it.
- **"Migration and storage metrics are 100% reliable during a live migration."** There is known intermittent flakiness in storage read/write/flush metric collection specifically during live migration. Acknowledge it if asked rather than asserting flawless reliability.
- **Quoting or promising a specific counter-benchmark number against the Principled Technologies report.** Red Hat cannot publish one due to VMware's EULA; redirect to running the customer's own workload instead.

---

## Appendix A: Preflight / Pin-Before-Demo Checklist

The demo cluster was not reachable while this script was written; every claim above is pinned to a version or a verification step, not to a live cluster. Before presenting, run `preflight.sh` (top-level) and `act2-01-korrel8r-verify.sh` and `act3/preflight.sh`, and confirm:

1. OpenShift / OpenShift Virtualization are at 4.20 as targeted; COO is at 1.5+ with Perses enabled.
2. The korrel8r image actually deployed contains the KubeVirt quickrules (`VmToVmi`, `VmiToPod`, `VmiToNode`, `VmToAlert`, `VmiToAlert`, `AlertToVM`, `AlertToVMI`). Check the running pod, not the release notes.
3. LokiStack + Logging UI plugin are installed (needed for the `log` domain node in the Troubleshooting Panel and for Act 2's logs hop).
4. Network Observability operator/plugin is installed if the netflow node or `oc netobserv` wire capture is in scope for this session.
5. `schedstats=enable` MachineConfig is applied to the node pool running the demo VMs, and nodes have already rebooted. Do this well before the demo, never live.
6. `psi=1` is **not** expected to do anything on this 4.20 target; drop PSI panels from the deck rather than demo them.
7. The demo VM's guest image has qemu-guest-agent ≥ 10.0.0 for guest-load metrics, and the guest agent is running, before promising filesystem or load-average panels.
8. Alert rules referenced in Act 2/Act 3 (`VMCannotBeEvicted`, `KubeVirtVMGuestMemoryPressure`, `KubeVirtVMIExcessiveMigrations`) exist and are wired to Alertmanager routes if the automation beat will be triggered live.
9. RHACM version is 2.16+ if right-sizing recommendations are shown as part of the concede-first section.
10. User Workload Monitoring is enabled (`enableUserWorkload: true` in the `cluster-monitoring-config` ConfigMap, `manifests/02-user-workload-monitoring.yaml`), needed for any custom ServiceMonitors/PrometheusRules the demo adds and for the namespace-scoped `AlertmanagerConfig` used in Act 3's automation beat. KubeVirt's own `kubevirt_vmi_*`/`kubevirt_vm_*` metrics are scraped by the platform Prometheus regardless and do not depend on this setting.

## Appendix B: Verified Names Reference (source-checked)

**Metrics** (all confirmed verbatim against kubevirt.io/monitoring/metrics.html and github.com/kubevirt/monitoring/blob/main/docs/metrics.md):
`kubevirt_vmi_vcpu_wait_seconds_total`, `kubevirt_vmi_vcpu_delay_seconds_total` (both need `schedstats=enable`) · `kubevirt_vmi_migration_data_processed_bytes`, `kubevirt_vmi_migration_data_remaining_bytes`, `kubevirt_vmi_migration_data_bytes_total`, `kubevirt_vmi_migration_memory_transfer_rate_bytes`, `kubevirt_vmi_migration_dirty_memory_rate_bytes`, `kubevirt_vmi_dirty_rate_bytes_per_second` · `kubevirt_vmi_migrations_in_pending_phase`/`_scheduling_phase`/`_running_phase`/`_unset_phase` · `kubevirt_vmi_phase_transition_time_from_creation_seconds`, `_from_deletion_seconds`, `kubevirt_vmi_migration_phase_transition_time_from_creation_seconds` · `kubevirt_vmi_storage_flush_requests_total`, `_storage_flush_times_seconds_total` · `kubevirt_vmi_guest_os_panic_total` · `kubevirt_vmi_number_of_outdated` (cluster-wide gauge, no per-VM labels) · `kubevirt_vmi_non_evictable` · `kubevirt_vmi_last_api_connection_timestamp_seconds` · `kubevirt_vmi_guest_load_1m`/`_5m`/`_15m` (needs qemu-guest-agent ≥ 10.0.0) · `kubevirt_vm_disk_allocated_size_bytes` · `kubevirt_vmi_memory_pgmajfault_total`/`_pgminfault_total` · `kubevirt_vmi_memory_swap_in_traffic_bytes`/`_swap_out_traffic_bytes` · `kubevirt_vmi_memory_available_bytes`/`_usable_bytes` · `kubevirt_vmi_filesystem_capacity_bytes`/`_used_bytes` (needs QGA) · `kubevirt_vmi_gpu_info` · `kubevirt_vmi_vcpu_seconds_total{state}`.

**Alerts** (confirmed present in the kubevirt/monitoring runbooks index): `VMCannotBeEvicted`, `OutdatedVirtualMachineInstanceWorkloads`, `KubeVirtVMGuestMemoryPressure`, `KubeVirtVMGuestMemoryAvailableLow`, `VMNonRecoverableOSPanic`, `KubeVirtVMIExcessiveMigrations`, `OrphanedVirtualMachineInstances`, `GuestFilesystemAlmostOutOfSpace`.

**Korrel8r rules** (confirmed in `pkg/rules/quickrules/kubevirt.qtpl` and `alert.qtpl` on the korrel8r main branch): `VmToVmi`, `VmiToPod` (label match: `kubevirt.io=virt-launcher`, `vm.kubevirt.io/name=<vmi>`), `VmiToNode`, `VmToPVC`, `VmiToPVC`, `VmToAlert`, `VmiToAlert`, `VmimToAlert`, `VmToMetric`, `VmiToMetric`, `VmiToLogs`, `NodeToVmi`, and (from the alert domain's own rules) `AlertToVM`, `AlertToVMI`, `AlertToVmim`.

**GA / maturity status used in this script:** KubeVirt metrics in cluster Prometheus (GA) · COO + Troubleshooting Panel (GA, COO 1.3+, OCP 4.19+) · Korrel8r KubeVirt quickrules (ship upstream from v0.12.1; not called out in COO release notes, verify per build) · Perses dashboards (GA, COO 1.5+) · LokiStack + Logging UI (GA; ~30-day retention by design) · Network Observability operator + `oc netobserv` (GA) · RHACM VM right-sizing (GA, ACM 2.16) · RHACM Fleet Virtualization single-VM view (Tech Preview, ACM 2.15) · OpenShift Lightspeed (GA) · Lightspeed incident-detection MCP (Dev Preview) · Lightspeed ACM fleet-health MCP (Tech Preview) · korrel8r MCP server (Experimental upstream since v0.10.0; no announced roadmap toward standalone productization) · korrel8r/Lightspeed console integration (Roadmap) · node-level PSI via `psi=1` (OpenShift 4.21+, **not** the 4.20 target of this script) · `kubevirt-metrics-exporter` / KME (Experimental/unsupported, opt-in HCO annotation).
