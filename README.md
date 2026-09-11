# OpenShift Virtualization observability demo

A demo for VMware admins who are looking at OpenShift Virtualization and want to know what they'd actually get on the monitoring side. It has now been built and run end to end on a real cluster, and this repository carries the evidence.

## The idea in one paragraph

We're not going to win by saying our dashboards are nicer than vCenter's. Out of the box, they aren't. What's different is where the data goes. Every VM's metrics, logs and network flows land in the same open store as every pod and node on the cluster. That means you query them with PromQL, join them by any label, walk from an alert to the VM to its pod to its logs in one graph, and wire the same alert into the same automation you already use for containers. Korrel8r's troubleshooting panel is how we show that on screen.

## Start here

The site version of everything below is at https://naeemarsalan.github.io/ocp-virt-observability-demo/ with one page per demo.

- `reference-architecture.html` is a single self-contained page: the logical view, an animated walk through one real incident with the real numbers, the ports, the trade-offs, and where VMware still wins. Open it in a browser. Light and dark both work.
- `REFERENCE-ARCHITECTURE.md` is the same architecture as a written brief, for people who want to read rather than click.
- `RUNBOOK.md` is what you follow to give the demo, updated with everything the live run changed.
- `IDEAS.md` is the next step: 18 more ways to show VMs benefiting from a cloud-native platform, ranked by a skeptical review, plus what is genuinely difficult. The descheduler entry answers the "do we have DRS now" question with the verified 4.20 facts.
- `evidence/` is the proof. Every number in the pages above comes from a file in there. Start with the `SUMMARY.md` in each folder and `evidence/screenshots/SCREENSHOTS.md`.

## What we ran

On 2026-09-11, on a shared lab cluster: OpenShift 4.20.32, OpenShift Virtualization 4.20.24, Cluster Observability Operator 1.5.2, three bare-metal workers with 31 other VMs already on them. We added an in-cluster LokiStack on MinIO, Network Observability, the Logging and Troubleshooting Panel console plugins, three demo VMs, and a second, upstream korrel8r (0.12.1) next to the operator's own (0.11.1) so we could compare them. Nothing outside the demo namespaces was changed, no node was rebooted, and the existing log forwarder was left alone.

## What the run proved

The non-migratable VM reached Running at 13:06:16Z. The exporter flagged it as non-evictable, the rule held for its one-minute window, and `VMCannotBeEvicted` first fired at 13:13:14Z (it resolved briefly and fired again at 13:24:44Z, which is the instance the correlation calls below used). From that one alert, the upstream engine reached the VM, its VMI, the virt-launcher pod, three nodes, 296 metric series and 200 log lines in 6.8 seconds, and we pulled 100 real log lines and one real network flow back through the graph's own queries. The console panel drew the same picture from the VMI on the shipped engine, twelve node classes including 1000 log lines and 248 metric series.

A live migration of the demo VM moved 849 MiB in a 14-second copy, with the VM reporting Running on every one of 18 polls, and every stage of it is a time series you can query afterwards. vCenter shows you a progress bar, then one number when it's done.

One idle VM exposes 61 KubeVirt series. The whole cluster exposes 144 distinct KubeVirt metric names and about 3,000 VM series, all joinable to pod and node metrics on shared labels.

## What the run also proved, that we'd rather you hear from us

The GA operator ships korrel8r 0.11.1. It walks VMI to pod to logs, metrics and flows, but it has no Alert-to-VMI rule, so from the alert it only reaches metrics. That rule arrived upstream in July and is in 0.12.1. We tried pasting the rule into the operator's config; the operator reverted it in under two minutes and the panel showed an error until the pod restarted. Don't do that.

In this console build, the panel's Focus button is disabled on the VirtualMachine, VMI and Pod pages. It works on the Alerting page, and on any page you can type the query into the panel's editor. The runbook shows both.

The 24-hour alert for outdated VM workloads has never fired on this cluster even though 21 VMs have been outdated all week, because both virt-controller replicas restart on leader-election timeouts and every restart resets the timer. Demo the gauge, not the alert.

Four query details in the original deck were wrong for this build and are fixed in the guides: the pod-join count needs `and on(namespace,pod)` rather than `group_left`, the phase-transition histograms have no per-VM label, two recording rules don't exist on 4.20.24, and one metric uses a `vmi` label rather than `name`.

## Where VMware still wins

Capacity planning with What-If modelling, predictive DRS on forecast load, built-in cost and chargeback, and multi-year native retention. None of that is in this architecture. Say so first; it makes the rest easier to hear.

## What is running on the cluster now

The whole stack is still up so it can be demoed. `assets/teardown.sh --dry-run` lists what would be removed; `--yes` removes it. It does not touch anything that was there before the run.

## Want to review it?

`REVIEW.md` lists what I'd like a second pair of eyes on. Issues and pull requests are welcome.
