# OpenShift Virtualization observability: reference architecture

## What this is

This describes how VM observability works on OpenShift Virtualization, based on a live-cluster run on 2026-09-11 (OpenShift 4.20.32, OpenShift Virtualization 4.20.24, Cluster Observability Operator 1.5.2). It is written for a platform engineer who already runs OpenShift for containers and is being asked to take on VMs too. The short version: there is nothing new to learn. A VM is a pod with an extra label. Its metrics live in the Prometheus you already query, its logs in the Loki you already query, and the correlation engine that walks an alert to a pod's logs for a Deployment walks the same path for a VirtualMachineInstance (VMI). What matters is knowing which parts of that walk work on the GA build you would install, and which need a newer component.

Every number below cites the file it came from, under `demo/evidence/`; illustrative numbers are labeled as such.

## The one idea

The case for this platform is not that its dashboards look better than vCenter's. Out of the box they do not. What is different is where a VM's data lives.

A VirtualMachine runs as QEMU/KVM inside a virt-launcher pod, carrying a label, `vm.kubevirt.io/name`, but no ownerReference back to the VMI object. That one fact explains most of what follows: VM metrics join to `kube_pod_labels` and `container_*` metrics on shared `namespace`/`pod` labels with plain PromQL; generic Kubernetes navigation dead-ends at the VM; and the correlation engine needs a purpose-built rule, `VmiToPod`, for that same hop by label.

One Prometheus, one log store, one alert pipeline, one correlation engine, for VMs and containers alike. The honest phrase here is "joinable by any label," not "more metrics than vCenter."

## How it is built

Four tiers. Only the top one is specific to virtual machines.

**Workloads.** VirtualMachine/VMI objects run inside a virt-launcher pod, labeled `vm.kubevirt.io/name`. `qemu-guest-agent` reports filesystem, load and IP data, the same dependency VMware Tools is. `virt-handler`, a DaemonSet on every worker, exports metrics at `/metrics:8443`, scraped every 30 seconds.

**Open stores.** One Prometheus/Thanos for metrics (port 9091); Alertmanager for the roughly 80 KubeVirt alert rules; a LokiStack for application logs; a second for network flows via NetObserv's eBPF agent, its own tenant. Tempo exists but is unused here.

**Correlation.** Korrel8r, managed by the Cluster Observability Operator, is the rule engine behind the Troubleshooting Panel: it turns one object into the query for the next, alert to VMI, VMI to pod, pod to logs, metrics and flows, over REST and MCP (port 9443). Perses dashboards, GA since COO 1.5, sit alongside it.

**Consumers.** An operator clicks Focus and gets a graph from alert to root cause. An AI agent can ask the same engine over MCP, upstream and experimental today. Automation is the same Alertmanager webhook path already used for any pod alert, illustrative here since none was wired up.

## What the run proved

One idle Fedora VM, `vm-demo`, returns 61 `kubevirt_vmi_*` series, 72 once `kubevirt_vm_*` is added. The planned join to `kube_pod_labels` through `group_left()` fails on this Thanos build: "multiple matches for labels: grouping labels must ensure unique matches." A plain `and on(namespace,pod)` filter works instead and returns 345, inflated by a live migration that left a stale virt-launcher pod carrying the same label for about ten minutes (`act1-metrics/SUMMARY.md`).

That migration, via `virtctl migrate`, took 47 seconds wall time from VMIM creation to Succeeded, VMI Running throughout; only the last 14 seconds were the memory copy, about 849 MiB moved out of about 4.02 GiB of addressable guest memory. One transfer-rate sample was captured, about 445 MiB/s, a single scrape, not a measured peak. The phase-transition histogram behind that figure carries no per-VM label, only fleet-wide by `phase`; with one migration recorded, `rate()` returns NaN, so the real number is the raw `_sum`/`_count` pair, 47 and 1 (`act1-migration/SUMMARY.md`).

Two assumed recording rules, `vmi:kubevirt_vmi_vcpu:count` and `namespace:kubevirt_vm:sum`, do not exist on this build; use the raw metrics instead, `kubevirt_vmi_vcpu_count` (2 for vm-demo) and `count by (namespace)(kubevirt_vmi_info)`. `kubevirt_vmi_last_api_connection_timestamp_seconds` carries a label named `vmi`, not `name`, and `kubevirt_vm_labels` has zero series here; `kube_pod_labels{label_tier="..."}` is the working substitute. Cluster-wide: 144 distinct `kubevirt_*` metric names, 3,068 `kubevirt_vmi_*` series, 31 running VMIs across 9 namespaces on 3 nodes, and vCPU wait/delay series populate only because `kernel.sched_schedstats` was set to 1 at runtime with `sysctl`, not a MachineConfig, so it reverts on reboot (`act1-metrics/SUMMARY.md`).

`VMCannotBeEvicted` fired as designed, held for one minute, starting 13:24:44Z for `vm-non-migratable`. Its `pod` and `container` labels point at the virt-controller replica exporting the metric, not the VM's virt-launcher pod; don't use them to find the workload (`verify/alerts-summary.txt`).

`OutdatedVirtualMachineInstanceWorkloads` (`for: 24h`) has sat Pending all week, not because 21 outdated VMIs is borderline, but because both virt-controller replicas crash-loop on leader-election lease renewal (106 and 105 restarts), resetting the timer 36 times in 7 days. The gauge has read 21 all week across 7 namespaces, matched by `oc get vmi -A -l kubevirt.io/outdatedLauncherImage`. The gauge and a label query are the honest way to show this; the alert is not (`fleet-beat/SUMMARY.md`).

The GA console (korrel8r 0.11.1, 47 rules, 4 KubeVirt-specific) won't let Focus build a starting query from the VM, VMI or Pod pages; it reports "Empty Query, No starting point for correlation." Two paths work instead: the alert detail page, when korrel8r recognizes the alert, and typing a query into the panel's editor. Typed by hand, a VMI query reaches VMI, VM, pod, node, metrics and logs; an alert query reaches only the alert and metrics, since 0.11.1 lacks `AlertToVMI` and `VmiToLogs` (need 0.11.4+). Hand-adding those rules to the ConfigMap is reverted in two minutes, and briefly broke the panel: 0.11.1 lacks the `required` template function the newer rules need (`troubleshooting-panel/custom-rule-experiment-outcome.txt`).

Against upstream korrel8r 0.12.1 (104 rules, 37 KubeVirt-specific), the same alert produced a graph in 6.8 seconds: VM 1, VMI 1, pod 1, node 3, 296 metric series, 200 log lines. From the VMI it also reached PVC 1, alert 1, netflow 1 in 15.3 seconds, pulling 100 real virt-launcher log lines and one real NTP flow, UDP 123, 90 bytes. Over MCP, the same 8 tools answered identically; GA 0.11.1's `/mcp` stopped at alert (1) and metric (136) (`act3-mcp/SUMMARY.md`).

## Concepts a VMware admin needs

**The label join.** In vCenter, a VM's identity is a first-class object with built-in relationships. Here it is a set of shared Prometheus labels: `namespace`, `name` (or `vmi`), `pod`, `node`. Any two metrics carrying the same labels join with ordinary PromQL, no special VM query language required. Coming from vCenter's typed object model, expect label-matched PromQL instead of an object graph, with edge cases like `group_left()` failing or two pods sharing a label mid-migration, things a PowerCLI script never had to handle.

**The rule graph.** Korrel8r does not search or guess. It holds declarative rules, each a typed edge from one object class to another, walked toward a set of goals. Every node carries the exact backend query that produced it; the walk is only as good as the rule set compiled into the image.

**The alert pipeline.** KubeVirt's alert rules run in the same Prometheus engine as every other OpenShift alert, same `for:` semantics, routing tree, webhook receivers. A metric's `pod` label, though, can point at the controller exporting it, not the VM, as `VMCannotBeEvicted` does above.

**Guest agent parity.** `qemu-guest-agent` supplies filesystem, load and IP data, the same dependency VMware Tools is, and fails the same way: silently, panels blank, no error. Connected, it reports normally, guest load average of 0.177, 0.0908 and 0.0547 over 1, 5 and 15 minutes on `vm-demo` here.

**The 24-hour alert design.** A 24-hour `for:` clause is meant to protect against paging for something expected to clear on its own. But the pending timer is tied to the reporting series' identity, so a leader-election restart resets it; an unstable control plane can hold that clock at zero indefinitely, as it did here.

## Trade-offs

| Decision | Why | What you give up |
|---|---|---|
| One Prometheus for everything | Shared-label joins, one query language, one alert pipeline | You size the TSDB. Roughly 60 series/VM, so 8,000 VMs is roughly 480,000 series |
| Two LokiStacks (logs, netflows) | Different tenants; NetObserv needs its own | Two stores to size. 30-day default retention |
| Korrel8r rules, not per-VM dashboards | Works for any VM from creation | Only as good as the rule set actually running; check first |
| GA COO 1.5.2, korrel8r 0.11.1 | VMI to pod to logs, metrics and flows already works | No Alert-to-VMI hop; Focus disabled on VM, VMI, Pod pages |
| Runtime `sysctl` for schedstats | No reboot needed; series appear at once | Reverts on reboot; a permanent install needs a MachineConfig |
| MinIO in-cluster for S3 | Fastest way to give LokiStack storage for a demo | Not production-grade; use ODF or external S3 for a pilot |

## Where VMware still wins

Say this before anyone asks. Capacity planning with What-If modeling, predictive DRS on forecast load, built-in cost and chargeback, and multi-year native retention are turnkey in vCenter and Aria Operations today, and none exist here out of the box. ACM's VM right-sizing, GA since 2.16, covers part of the same ground but narrower. Conceding this before anyone raises it is what makes the rest of the argument credible.

## What to check before a pilot

- Run the KubeVirt rule check against your own korrel8r image before promising a specific hop. Here `VmToVmi`, `VmiToPod`, `VmiToNode` were present; `AlertToVMI`, `VmiToLogs` were not, deciding whether Focus worked.
- Confirm the Logging UI plugin, LokiStack and NetObserv FlowCollector report Ready, and `qemu-guest-agent` is in your VM images. Any one missing means a graph node or panel goes silently empty, not an error.
- Check whether kube-state-metrics allow-lists `vm.kubevirt.io/name` on `kube_pod_labels` before assuming the pod-join query works. It did here, but that's a per-cluster ConfigMap setting.
- Confirm any recording rules your dashboards assume actually exist. Two assumed here do not, on 4.20.24; the raw metrics worked as substitutes.
- If vCPU wait/delay data needs to survive a reboot, put schedstats in a MachineConfig, not the live `sysctl` used here.
- Check virt-controller's stability before relying on any alert with a long `for:` clause. Leader-election restarts reset the outdated-workloads timer 36 times in a week here.
- Set the console's Alerting page to All Projects before judging whether an alert has fired. It defaults to the last-used project and shows nothing otherwise, easy to misread as "never fired."

## Versions and status

`kubevirt_vmi_*`/`kubevirt_vm_*` metrics and the roughly 80 KubeVirt alert rules are GA, as are the Cluster Observability Operator and Troubleshooting Panel (COO 1.3+, OCP 4.19+), Perses dashboards (COO 1.5+), the Logging UI plugin with LokiStack, and Network Observability. The korrel8r rules for Alert-to-VMI and VMI-to-logs are upstream only, landing in 0.11.4 and more fully in 0.12.1; COO 1.5.2 here does not have them (0.11.1, 47 rules, 4 KubeVirt-specific). The korrel8r MCP server is experimental upstream: it worked as described against 0.12.1, but is not the GA path, and any console or AI-assistant feature built on it is roadmap.

## How to read the evidence

Every number above cites a file under `demo/evidence/`. `act1-metrics` holds the series-count and per-panel evidence for `vm-demo`, including the Thanos error text and the working substitute query. `act1-migration` holds the migration timeline, byte counts and the phase-transition histogram's NaN root cause. `fleet-beat` holds the outdated-workloads gauge, virt-controller restart counts and the 36 pending-timer resets. `act3-mcp` and `korrel8r-0.12` hold the MCP and REST graph results for the GA 0.11.1 and upstream 0.12.1 korrel8r builds. `troubleshooting-panel` holds the console rule listing and the ConfigMap-patch experiment and its revert. `verify` holds the raw alert payloads and preflight checks run before this went on stage. `act1-metrics`, `act1-migration`, `fleet-beat` and `act3-mcp` each have a `SUMMARY.md` indexing the raw files; the other three are raw captures, readable directly. `reference-architecture.html` here renders the same architecture as an animated diagram; read it alongside this document.
