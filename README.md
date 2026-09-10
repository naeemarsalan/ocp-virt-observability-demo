# OpenShift Virtualization observability demo

A demo for VMware admins who are looking at OpenShift Virtualization and want to know what they'd actually get on the monitoring side.

## The idea in one paragraph

We're not going to win by saying our dashboards are nicer than vCenter's. Out of the box, they aren't. What's different is where the data goes. Every VM's metrics, logs and network flows land in the same open store as every pod and node on the cluster. That means you query them with PromQL, join them by any label, walk from an alert to the VM to its pod to its logs in one graph, and wire the same alert into the same automation you already use for containers. Korrel8r's troubleshooting panel is how we show that on screen.

## What the demo does

**Act 1, depth.** Take one VM. Count how many time series you can query for it and show the ones vCenter and Aria simply don't have: live migration progress as a stream, lifecycle timing histograms, disk flush counters, a guest kernel panic counter, guest load average. Kick off a live migration and watch the bytes drain. Then slice the whole fleet by a label a vCenter admin would need a PowerCLI script for.

**Act 2, correlation.** This is the one that matters. First show the dead end: a hot VM on the built-in dashboard with nothing to click. Then fire an alert and open the troubleshooting panel. It walks alert to VMI to virt-launcher pod to logs, and from the pod out to network flows. Same data, joined, no hand-built dashboard.

**Act 3, agentic.** Ask the same question in plain English over Korrel8r's MCP interface. The agent walks the rule graph instead of guessing. This part runs on the upstream project and is experimental. We say so.

## Where to start

Read `RUNBOOK.md`. It has the run order, timings, what to say, and the six things that changed once we checked the plan against source code.

Then the five guides in order: `0-` prerequisites and failure modes, `1-` Act 1, `2-` Act 2, `3-` Act 3, `4-` the presenter script and objection handling.

Everything runnable is in `assets/`: install manifests in order, a preflight script, dashboards, the alert triggers, a reset script, and the Act 3 MCP configs.

## Honest status

Nobody has run this on a live cluster yet. Every metric name, alert name, Korrel8r rule, CR field and console click path was checked against source (kubevirt.io, the kubevirt alert rules, the korrel8r repo, the observability operator, the HCO API types, and the COO docs). That is not the same as having watched it work. `assets/preflight.sh` is there to close that gap the first time someone logs in.

Two things only a real cluster can answer: which HCO API version it prefers, and whether the Korrel8r image in the installed COO build actually has the KubeVirt rules. Both have a check in preflight.

## What we don't claim

That our dashboards beat vROps. That AI troubleshooting ships today. That we have "more metrics" than vCenter (say "joinable by any label" instead). And we don't name customers. See the do-not-say list at the end of `4-narrative-and-objections.md`.

## Want to review it?

`REVIEW.md` lists what I'd like a second pair of eyes on.
