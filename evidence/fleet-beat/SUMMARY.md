# Fleet-beat: evidence that the CNV upgrade left workloads outdated

Read-only track. All commands ran against the live cluster on 2026-09-11 between 13:46 and
14:49 UTC. Every number below comes from a file in this directory -- filenames are given so
each claim can be checked against the raw response.

## 1. The core number: 21 VMIs stuck on the old virt-launcher image

`kubevirt_vmi_number_of_outdated` (Thanos instant query, `01-outdated-current.json`) reads
**21** right now, reported by the current virt-controller leader pod
(`virt-controller-7b86885b64-p4m8c`).

A 7-day history at 1-hour resolution (`query_range`, `02-outdated-7d-1h.json`, 2026-09-04
13:46 UTC -> 2026-09-11 13:46 UTC) shows the value has been **constant at 21 for the entire
window** -- every sample from both virt-controller replicas that reported during that time is
`21`. This has not been trending up or down; it has been flat for at least a week.

## 2. Which VMIs, and where

`oc get vmi -A -l kubevirt.io/outdatedLauncherImage` (`03-outdated-vmi-full.json`, namespace
and name columns only in `03-outdated-vmi-namespace-name.txt`) returns exactly 21 VMIs,
matching the metric. None of them are the demo VMs -- `demo-vms` does not appear in the list,
so this is a pre-existing, cluster-wide condition, not something the demo track caused.

Per-namespace counts (`03-outdated-vmi-count-per-namespace.txt`):

| Namespace | Outdated VMIs |
|---|---|
| aap-edb-vms | 6 |
| anaeem | 5 |
| joon | 4 |
| hammer | 3 |
| shannon | 1 |
| default | 1 |
| asaran | 1 |
| **Total** | **21** |

## 3. The alert: pending, and (on current evidence) unlikely to fire on schedule

**State right now** (`04-ALERTS-outdated-vmi-workloads.json`, `05-ALERTS_FOR_STATE-outdated-vmi-workloads.json`):

| Field | Value |
|---|---|
| `alertstate` | `pending` (not firing) |
| `severity` | `warning` |
| Pending since (`ALERTS_FOR_STATE` value) | 2026-09-11T13:45:44Z |

**Rule definition**, pulled from the Thanos rules API (`06-rules-full.json`, extracted rule in
`06b-rule-OutdatedVMIWorkloads-extract.json`):

| Field | Value |
|---|---|
| expr | `kubevirt_vmi_number_of_outdated != 0` |
| for | `86400s` (24h) |
| severity | `warning` |
| summary | "Some running VMIs are still active in outdated pods after KubeVirt control plane update has completed." |
| runbook | github.com/openshift/runbooks .../OutdatedVirtualMachineInstanceWorkloads.md |

**Why it's pending and not firing**: the rule needs its condition to be continuously true for
24 hours before it fires. On its face, since the pending timer restarted at 13:45:44 UTC
today, naive arithmetic says it would reach firing at **2026-09-12T13:46 UTC** -- but that
naive read is misleading, and the deeper evidence says this alert has probably never gotten
close to firing:

- A 7-day range query on `ALERTS_FOR_STATE` (`10-ALERTS_FOR_STATE-7d-history.json`, step=30m)
  shows the "pending since" timestamp has **reset 36 separate times across the two
  virt-controller replicas in the last 7 days** -- about once every 4-5 hours on average
  (analysis in `11-pending-resets-analysis.txt`). Every reset sets the 24h clock back to zero.
- The reason: both virt-controller pods are crash-looping. `virt-controller-7b86885b64-p4m8c`
  has restarted 106 times and `virt-controller-7b86885b64-zxd9s` 105 times over their 30-day
  pod age (`06d-virt-controller-pods.txt`). The most recent crash on `p4m8c`
  (`06e-virt-controller-p4m8c-full.json`) shows `leaderelection.go:429 Failed to update lock
  optimistically ... context deadline exceeded` followed by `leaderelection lost` -- the
  replica is losing its leader-election lease against the API server and restarting.
- Because the `ALERTS`/`ALERTS_FOR_STATE` series carry a `pod`/`instance` label tied to
  whichever replica is currently leader, every leader flip or restart produces a new label set
  from Prometheus's point of view, which restarts the "for" timer at zero -- even though the
  underlying condition (21 outdated VMIs) has been true, unbroken, for the entire 7-day window
  we can see.

**Bottom line**: the condition that should fire this alert has been true for at least 7 days
straight, but the alert itself has apparently never gotten within reach of the 24h threshold,
because the controller that surfaces the metric restarts roughly every 4-5 hours. If the
controller's crash-looping is fixed, expect the alert to move to firing about 24h after that
fix, not before -- not on the naive "13:46 tomorrow" schedule implied by the current pending
timestamp alone.

## 4. Two launcher versions are coexisting, and HCO is not doing anything about it

**HyperConverged CR** (`hco.kubevirt.io/v1beta1`, `07-hyperconverged-full.json`):

```
spec.workloadUpdateStrategy:
  batchEvictionInterval: 10m0s
  batchEvictionSize: 1
  workloadUpdateMethods: []
```

`workloadUpdateMethods` is an **empty list** -- HCO has no automatic mechanism enabled
(neither `LiveMigrate` nor `Evict`), so it will never move a single one of the 21 outdated
VMIs on its own. This directly matches the established fact that
`workloadUpdateMethods=[]` after the operator upgrade.

**Installed CSV** (`08-csv-full.json`): `kubevirt-hyperconverged-operator.v4.20.24`, phase
`Succeeded` -- confirms OpenShift Virtualization 4.20.24 is what's actually installed.

**virt-launcher images in use right now**, compute container, across every virt-launcher pod
cluster-wide (`oc get pods -A -l kubevirt.io=virt-launcher`, full list
`09-virt-launcher-pods-full.json`, sorted+counted digests in
`09b-virt-launcher-image-counts.txt`):

| Image digest (virt-launcher-rhel9@) | Pod count | Status |
|---|---|---|
| `sha256:1b8b24e4...254e918c` | 22 | **Old** -- pre-upgrade image |
| `sha256:c88c03c9...ea529430e` | 11 | **Current** -- matches CSV 4.20.24's `relatedImages` entry for virt-launcher |

Two versions are clearly coexisting. Breaking the 33 total pods down by phase
(`09c-all-vmi-full.json` for VMIs, phase counts computed from `09-virt-launcher-pods-full.json`)
fully reconciles the numbers:

| | Old digest (1b8b24e...) | New digest (c88c03c...) | Total |
|---|---|---|---|
| Running (live VMIs) | 21 | 10 | 31 |
| Succeeded (leftover post-migration source pods, pending GC) | 1 (posthog, ns `anaeem`) | 1 (vm-demo, ns `demo-vms`) | 2 |
| **Total pods** | **22** | **11** | **33** |

The 21 Running pods on the old digest are exactly the 21 outdated VMIs from section 2 -- the
metric, the label query, and the image digest count all agree. The two Succeeded pods are
garbage-collection-pending remnants of live migrations that already completed: `posthog` (ns
`anaeem`) was migrated off the old image -- its new Running pod (`virt-launcher-posthog-gshn9`)
is already on the new digest with no outdated label -- and `vm-demo` (ns `demo-vms`) was
already on the current digest before its own migration, so it was never counted as outdated.

Note: 31 Running VMIs is the live count as of this read; the task's established baseline was
28. This is a live, shared, multi-tenant cluster, so some drift between an earlier baseline
and the current read is expected (other users' VMs starting/stopping, plus the two
already-completed migrations noted above).

## 5. The fix that was NOT run

Full text and caveats saved in `12-patch-NOT-RUN-drain-outdated.txt`. This command was **not
executed** -- guardrail: never patch the HyperConverged CR.

```
oc patch hco kubevirt-hyperconverged -n openshift-cnv --type=merge \
  -p '{"spec":{"workloadUpdateStrategy":{"workloadUpdateMethods":["LiveMigrate"]}}}'
```

That would enable automatic live migration of outdated-but-migratable VMIs, one every 10
minutes (current `batchEvictionSize`/`batchEvictionInterval`). To also cover VMIs that cannot
be live-migrated (like `vm-non-migratable` in this demo's own namespace), `Evict` would need to
be added to the list too -- but `Evict` deletes and recreates the pod, a real interruption, not
a migration. Either way this is a cluster-wide setting living in `openshift-cnv`, not
`demo-vms`, and would touch all 21 outdated VMIs across 7 namespaces belonging to other users
-- which is exactly why it's out of scope for this demo's guardrails and was only documented,
not run.

## Files in this directory

| File | Contents |
|---|---|
| `01-outdated-current.json` | Instant Thanos query: `kubevirt_vmi_number_of_outdated` |
| `02-outdated-7d-1h.json` | 7-day `query_range`, step=1h, same metric |
| `03-outdated-vmi-full.json` | Full `oc get vmi -A -l kubevirt.io/outdatedLauncherImage -o json` |
| `03-outdated-vmi-namespace-name.txt` | Namespace/name columns only |
| `03-outdated-vmi-count-per-namespace.txt` | `uniq -c` per namespace |
| `04-ALERTS-outdated-vmi-workloads.json` | Instant `ALERTS{alertname=...}` |
| `05-ALERTS_FOR_STATE-outdated-vmi-workloads.json` | Instant `ALERTS_FOR_STATE{alertname=...}` |
| `06-rules-full.json` | Full Thanos `/api/v1/rules` dump |
| `06b-rule-OutdatedVMIWorkloads-extract.json` | Just the one rule, extracted |
| `06c-prometheus-pods.txt` | `oc get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus` |
| `06d-virt-controller-pods.txt` | `oc get pods -n openshift-cnv -l kubevirt.io=virt-controller` (restart counts) |
| `06e-virt-controller-p4m8c-full.json` / `06f-...-zxd9s-full.json` | Full pod status incl. crash termination logs |
| `07-hyperconverged-full.json` | Full HyperConverged CR |
| `08-csv-full.json` | All CSVs in `openshift-cnv` |
| `09-virt-launcher-pods-full.json` | Full `oc get pods -A -l kubevirt.io=virt-launcher -o json` |
| `09b-virt-launcher-image-counts.txt` | Compute image digest, sorted + counted |
| `09c-all-vmi-full.json` | Full `oc get vmi -A -o json` (for phase counts) |
| `10-ALERTS_FOR_STATE-7d-history.json` | 7-day `query_range` on `ALERTS_FOR_STATE`, step=30m |
| `11-pending-resets-analysis.txt` | Derived: count of pending-timer resets and why |
| `12-patch-NOT-RUN-drain-outdated.txt` | Exact patch command that would fix this -- documented only, never executed |
