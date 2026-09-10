# OpenShift Virtualization Observability Demo — Master Runbook

**Audience:** VMware admins / infra teams evaluating OpenShift Virtualization.
**Thesis (say it before touching a keyboard):** the win is not prettier dashboards. VM telemetry lands in the *same* open, label-indexed store as every pod and node (Prometheus/Thanos, Loki, netflow, Tempo), so it is **joinable with ordinary PromQL**, **correlatable across signals** (Korrel8r), and **automatable with the pipeline you already run**. Korrel8r is the proof.
**Pinned target:** OpenShift 4.20 · OpenShift Virtualization 4.20 · Cluster Observability Operator 1.5+ · OpenShift Logging 6.x + LokiStack · Network Observability (GA) · Tempo optional.
**Status:** every metric, alert, rule, CR field and click path in this package was source-verified (kubevirt.io metrics reference, kubevirt/kubevirt alert rules, korrel8r quickrules, rhobs/observability-operator, HCO API types, docs.redhat.com COO 1.x) on 2026-09-08. It has **not yet been run on a live cluster** — `assets/preflight.sh` exists to close that gap the first time you log in.

---

## Files in this package

| File | What it is |
|---|---|
| `0-prereqs-preflight-failure-modes.md` | Cluster prerequisites, exact install order with manifests, the preflight script, the alert-trigger thresholds, and a 15-row failure-mode/mitigation table |
| `1-act1-depth.md` | Act 1: time-series-per-VM count (the honest comparison), PromQL for every panel, the live-migration beat, label-slicing examples, Grafana + Perses dashboards |
| `2-act2-correlation.md` | Act 2: the contrast beat, mandatory Korrel8r rule verification, three trigger recipes, the exact console walk, expected node graph, resets |
| `3-act3-agentic.md` | Act 3: upstream Korrel8r MCP standalone (experimental), the 8 tools and what they return, three prompts, REST fallback, GA-vs-roadmap box |
| `4-narrative-and-objections.md` | Presenter script for all three acts, concede-first block, 12-objection table, do-not-say list |
| `assets/` | Everything runnable: `preflight.sh`, `manifests/00–09`, `cloud-init/`, dashboards, trigger recipes, reset script, Act 3 MCP configs |

---

## Run order

### T-minus 1 week — build the environment (`0-prereqs…md` §2, `assets/manifests/`)
1. `00-hco-subscription.yaml` — OpenShift Virtualization, **pinned one z-stream behind stable with Manual approval** (this is what makes the upgrade beat possible).
2. `01-machineconfig-schedstats-psi.yaml` — `schedstats=enable` (required for vCPU wait/delay). Node reboot. **Do not expect PSI panels on 4.20: PSI needs OCP ≥ 4.21.**
3. `02-user-workload-monitoring.yaml`
4. `03-coo-subscription.yaml` — COO 1.5+.
5. `04-logging-lokistack.yaml` — Logging 6.x + LokiStack (`1x.extra-small` for a demo).
6. `05-netobserv-flowcollector.yaml` — FlowCollector wired to Loki. **Without this the netflow node silently never renders.**
7. `06-tempo-tempostack.yaml` — optional.
8. `07-uiplugins.yaml` — Logging, TroubleshootingPanel, DistributedTracing, Monitoring. **Without the Logging plugin the log node silently never renders.**
9. `08-demo-vm.yaml` + `cloud-init/qga-userdata.yaml` — demo VMs with qemu-guest-agent (one migratable, one deliberately non-migratable for recipe (a)).

### T-minus 24 hours — pre-stage the upgrade beat (`2-act2…md` §4)
```bash
./assets/act2-03-recipe-b-outdated-workloads.sh stage
```
Empties `workloadUpdateMethods` (version-aware for HCO `v1beta1` vs `v1`), then you approve the pending CNV InstallPlan. `kubevirt_vmi_number_of_outdated` goes non-zero within a scrape or two. **The `OutdatedVirtualMachineInstanceWorkloads` alert has a 24-hour `for` clause (verified in source), so it will not reach Firing in a live session unless staged the day before.** Graph the gauge regardless.

### T-minus 1 hour — preflight
```bash
oc login https://api.<cluster>:6443
./assets/preflight.sh
```
Gates on: versions, all four UIPlugins Available, LokiStack Ready, FlowCollector Ready, korrel8r pod + image tag, **korrel8r KubeVirt rules present** (`VmiToPod`, `AlertToVMI`, `VmiToLogs` …), user-workload monitoring, `schedstats` live on nodes, guest agent connected on the demo VM, Prometheus headroom, and the label assumptions the dashboards make (`phase`, `interface`, `drive`, `instance_type`). Also run:
```bash
./assets/act2-01-korrel8r-verify.sh    # exits 1 if the KubeVirt rules are missing from your COO build
```

### Show time (≈ 35–40 min)

| Act | Minutes | What lands the point | File |
|---|---|---|---|
| Opening | 2 | The thesis sentence, then **concede first**: capacity/What-If, Predictive DRS, cost/chargeback, multi-year retention are VMware wins today | `4-narrative…md` Part 1–2 |
| **1 — Depth** | 10 | Count series for one VM (three widening queries), show the **no-VMware-equivalent** panels, run `virtctl migrate` and watch bytes-remaining / transfer-rate live, then slice the fleet by an arbitrary label | `1-act1-depth.md` + `assets/act1-grafana-dashboard.json` |
| **2 — Correlation** | 12 | Show the dead end first (Observe → Dashboards, hot VM, nothing to click). Fire `VMCannotBeEvicted` (1-minute `for`). Application Launcher → **Signal Correlation** → **Focus** on the alert: alert → VMI → virt-launcher pod → node/PVC/logs; click the pod, re-Focus for netflows | `2-act2-correlation.md` §1–3 |
| 2b — Fleet beat | 3 | The pre-staged `number_of_outdated` gauge, then `…recipe-b… drain` and watch the fleet self-migrate onto the new virt-launcher | `2-act2-correlation.md` §4 |
| **3 — Agentic** | 6 | Same question in natural language over the **upstream** Korrel8r MCP. "The agent walks the rule graph, it does not guess." Label it experimental; state the roadmap honestly | `3-act3-agentic.md` |
| Close + objections | 5 | The close, then the objection table | `4-narrative…md` Part 3–4 |

### After — reset
```bash
./assets/act2-07-reset.sh      # removes trigger VMs, restores workloadUpdateMethods, clears the memory hog
```

---

## Six things the source-verification changed versus the original plan

1. **The upgrade-beat alert cannot fire live.** `OutdatedVirtualMachineInstanceWorkloads` = `kubevirt_vmi_number_of_outdated{namespace!=''} != 0` with **`for: 24h`**. Pre-stage it, or demo the gauge. Also, that gauge is a **single cluster-wide value with no per-VM labels**, so the alert → VMI walk does **not** resolve from it. Use recipes (a) or (c) for the walk; use (b) as a fleet-health beat with no vCenter analog.
2. **The memory-pressure alert is `KubeVirtVMGuestMemoryPressure`** (warning, `for: 5m`: headroom < 5% **and** major faults > 5/s or swap > 1 MiB/s). The assumed name `KubevirtVmHighMemoryUsage` does not exist. It needs the virtio balloon (default), **not** the guest agent.
3. **`VMCannotBeEvicted` is the deterministic trigger** (`for: 1m`): a VM with `evictionStrategy: LiveMigrate` that cannot migrate. No upgrade, no load generator.
4. **Korrel8r's KubeVirt rules are compiled into the binary** (`VmToVmi`, `VmiToPod`, `VmiToNode`, `VmiToPVC`, `AlertToVMI`, `VmiToLogs`, 20+ more), added upstream July–Aug 2026 and **absent from the COO release notes**. Whether *your* build has them depends only on the pinned image. The `UIPlugin` CR has **no field for custom rules**; the fallback in `act2-06-…yaml` is a demo trick the operator will revert.
5. **virt-launcher pods have no ownerReference to their VMI** (label-only: `vm.kubevirt.io/name`). This is why generic console navigation dead-ends, why Korrel8r needs the KubeVirt-specific `VmiToPod` rule, and why the Act 1 "joinable series" query joins through `kube_pod_labels`.
6. **HCO API layout differs by version.** `hco.kubevirt.io/v1beta1` = `spec.workloadUpdateStrategy`; `v1` = `spec.virtualization.workloadUpdateStrategy`. Patching the wrong one is silently pruned. The scripts detect it (`hco_patch_wum`); `preflight.sh` reports it.

Plus: **PSI (`psi=1`) requires OCP ≥ 4.21** — on a 4.20 target every contention panel uses the `schedstats`-gated `kubevirt_vmi_vcpu_delay/wait_seconds_total` instead. And `kubevirt_vmi_dirty_rate_bytes_per_second` has an open accuracy bug — the migration beat uses processed/remaining/transfer-rate only.

---

## Prerequisites that silently break the demo if missing

| Missing | Symptom | Where it's fixed |
|---|---|---|
| Logging UI plugin / LokiStack | `log` node never appears in the graph, no error | manifests 04, 07 |
| Network Observability plugin / FlowCollector | `netflow` node never appears | manifests 05, 07 |
| `schedstats=enable` on workers | vCPU wait/delay panels blank | manifest 01 |
| qemu-guest-agent in the VM | guest load, filesystem, IP panels blank | cloud-init/qga-userdata.yaml |
| user-workload monitoring | Perses/custom PromQL against user namespaces fails | manifest 02 |
| KubeVirt rules in the pinned korrel8r image | graph stops at the alert node | `act2-01-korrel8r-verify.sh`; upgrade COO or use the fallback |
| Correct HCO API path | `stage` looks successful but auto-drain clears the outdated gauge before you see it | `hco_patch_wum` in the scripts |

Full table with 15 failure modes (dashboard breakage on 4.20 cgroups v2, Prometheus sizing at ~60 series per VM, ODF false-positive alerts on LVM guests, Loki 30-day retention, and more) is in `0-prereqs-preflight-failure-modes.md` §5.

---

## GA / preview status of everything used

| Capability | Status |
|---|---|
| `kubevirt_vmi_*` / `kubevirt_vm_*` metrics, KubeVirt alerts | GA |
| Cluster Observability Operator; Troubleshooting Panel (Korrel8r) | GA (COO 1.3+, OCP 4.19+; not 4.17) |
| Perses dashboards | GA (COO 1.5), namespace-scoped |
| Logging UI plugin + LokiStack; Network Observability; Tempo | GA |
| Korrel8r KubeVirt correlation rules | Upstream (v0.11.4 / v0.12.1); verify in your COO image |
| Korrel8r MCP server (Act 3) | **Experimental upstream**; console/Lightspeed integration is **roadmap**; `get_console`/`show_in_console` and agent-navigation are **Dev Preview** (4.22+) |
| Lightspeed incident-detection MCP | Dev Preview |
| ACM VM right-sizing | GA (ACM 2.16) |

## Do not say
"Better dashboards than vROps." · "Agentic troubleshooting ships today." · "We have more metrics than vCenter" (say *joinable by arbitrary label* instead). · Any customer name as a reference. See `4-narrative-and-objections.md` Part 4.
