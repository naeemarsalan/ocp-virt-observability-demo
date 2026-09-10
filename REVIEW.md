# What I'd like reviewed

Plain list. Pick whatever you know best. Comments in a PR or just tell me.

## The pitch

1. Does the core argument land for the customers you talk to? "Same open store, so you can join, correlate and automate" versus "better dashboards." If your customers only care about the dashboard, tell me, because the demo is built around the first one.
2. Act 2 opens by admitting the built-in dashboard is a dead end. Is that the right call, or does it hand the room a stick to beat us with?
3. The concede-first list (capacity planning, What-If, predictive DRS, cost and chargeback, long retention). Too generous? Missing something VMware people will raise anyway?

## The triggers

4. I made `VMCannotBeEvicted` the main alert because it fires in a minute with no upgrade and no load generator. The CNV upgrade beat is still in, but its alert has a 24 hour `for` clause, so it has to be staged the day before. Is that workable for how we usually run demos?
5. The memory pressure alert turned out to be `KubeVirtVMGuestMemoryPressure`, not the name we started with. The recipe uses a stress tool inside the guest. Sanity check the manifest in `assets/act2-04-*.yaml` if you've done this before.

## Things only a cluster can settle

6. Run `assets/preflight.sh` and `assets/act2-01-korrel8r-verify.sh` on a 4.20 cluster with COO 1.5 and tell me what they say. The big unknown is whether the shipped Korrel8r image has the KubeVirt rules. Upstream added them in July and August 2026 and the COO release notes never mention them.
7. Check which `hco.kubevirt.io` API version your cluster prefers. `v1beta1` and `v1` put `workloadUpdateStrategy` in different places. The scripts detect it, but I want to know what real clusters return.
8. The `schedstats=enable` MachineConfig reboots workers. Fine in a demo environment? If not, the vCPU wait panels go blank and we should just say so.

## Act 3

9. It runs on the upstream Korrel8r MCP server, which is experimental, and the product integration is roadmap. Are we comfortable showing it at all, or should it be a slide and a sentence?

## Correctness

10. The Grafana JSON and the Perses dashboard CR have not been loaded anywhere. Perses in particular: I could not find a complete public sample of the CR schema, so expect to fix fields.
11. Read the objection table in `4-narrative-and-objections.md`, especially the answers on the Principled Technologies benchmark and on "Aria has PromQL too." If you know VMware well and either answer sounds wrong or thin, say so.
12. Anything that reads as overclaiming. The whole package is meant to survive a skeptical vSphere architect. If a line would not, it should go.
