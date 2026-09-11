# ACT 2 (Correlation): Alert → VMI → Pod → Logs → Netflows

**What this act proves:** the same alert, VM, pod, log line, and network flow all live in one open, label-joinable store, so the walk from "something fired" to "here is the exact traffic that pod sent" is a few clicks, not a context switch into a different product. **What this act must not claim:** that the out-of-the-box Observe dashboards already do this walk. They don't (see the contrast beat). The Troubleshooting Panel is the piece that closes that specific, real gap.

Target versions this runbook is written against: **OpenShift 4.20 / OpenShift Virtualization 4.20 / Cluster Observability Operator 1.5+ (Perses GA) / OpenShift Logging 6.x with LokiStack / Network Observability operator (GA) / Tempo optional**. The demo cluster was not reachable while writing this, every claim below is sourced against upstream source code (kubevirt/kubevirt, kubevirt/hyperconverged-cluster-operator, korrel8r/korrel8r, rhobs/observability-operator) rather than assumed, and a preflight script pins the live-cluster facts before you rely on any of it. Where a source fact could plausibly have drifted between "when this was written" (2026-09-08) and your demo date, that's flagged explicitly rather than glossed over.

All files referenced below are written to `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/act2-*`. They sit alongside an existing Act 1 preflight (`preflight.sh`) and migration beat (`migration-beat.sh`) from earlier work on this same demo, Act 2's own preflight (`act2-01-korrel8r-verify.sh`) is additive to that, not a replacement.

**Update: this act has since been run against the live cluster** (OCP 4.20.32, OpenShift Virtualization 4.20.24, COO 1.5.2, korrel8r 0.11.1). Two things changed from the source-only version of this document below, both called out inline where they apply, and both worth reading before you rehearse: the Troubleshooting Panel's Focus button does not work from the VirtualMachine, VirtualMachineInstance, or Pod detail pages on this build (§3, §4); and the `OutdatedVirtualMachineInstanceWorkloads` alert has stayed Pending all week on this cluster for a reason beyond the documented 24h `for` clause (§4).

---

## 0. Before anything else: run the preflight checks

1. Run the existing `preflight.sh` (checks OCP version, CNV install, guest agent, schedstats, COO/Perses/korrel8r presence, LokiStack/NetObserv/Tempo CRDs, the 4.20 cgroups v1→v2 `cgroup_id`→`id` panel-break, Prometheus scale). Fix every `FAIL` before continuing.
2. Run **`act2-01-korrel8r-verify.sh`** (new, Act-2-specific, see §2 below). This is the single most important preflight step in this entire act: it is the difference between the walk working live and a silent dead end on stage.

---

## 1. The contrast beat, show the dead end first

Before touching the Troubleshooting Panel, show the audience the OOTB path that does **not** work, so the panel lands as a fix to a real, demonstrated gap rather than a feature nobody asked for.

**Console path:** Administrator perspective → **Observe → Dashboards** → Dashboard dropdown → **KubeVirt / Infrastructure Resources / Top Consumers**.

**What to show:**
1. Switch the table to **By VM**, sort by CPU or memory. Point at whichever demo VM is hot (reuse the Act 1 demo VM, or recipe (c)'s `vm-memory-pressure` once its hog is running).
2. Try to click through from the VM name to its virt-launcher pod. **There is nothing to click.** The VM name in this dashboard is text, not a link to the pod that's actually consuming the resource. This is not a bug you're pointing out to be unkind about the product, it is the literal, verifiable gap: the pod that owns the workload has no ownerReference back to the VMI (label-only relationship, `kubevirt.io=virt-launcher`, `vm.kubevirt.io/name=<vmi>`), so generic console navigation and generic Kubernetes tooling both dead-end here.
3. Name it plainly: "This is the OOTB console experience. If your workflow today is vCenter → esxtop → per-VM drill-down, this specific screen is a step backward from that, and I want to be upfront about it before I show you the piece that fixes it."

Then pivot: "Everything on this dashboard is still just Prometheus underneath, it's the same TSDB, same labels, same query language your pod/node dashboards already use. Watch what happens when we ask a rules engine to walk those labels for us instead of a hand-built dashboard."

---

## 2. Korrel8r rule verification (mandatory, before you promise the walk)

### Why this step exists (verified, not assumed)

The KubeVirt-aware correlation rules (`VmToVmi`, `VmiToPod`, `VmiToNode`, `VmToAlert`, `VmiToAlert`, `AlertToVM`, `AlertToVMI`, `VmiToLogs`, and 20+ others) are **not** a YAML file you can grep on the cluster. I fetched the actual upstream source (`korrel8r/korrel8r @ pkg/rules/quickrules/kubevirt.qtpl` and `alert.qtpl`) to confirm this: they are Go quicktemplates compiled directly into the `korrel8r` binary via `//go:embed *.qtpl`, loaded unconditionally at startup. The Cluster Observability Operator's own generated korrel8r config (`pkg/controllers/uiplugin/config/korrel8r.yaml`, verified from source) ends with:

```yaml
include:
  - /etc/korrel8r/rules/all.yaml
```

and `etc/korrel8r/rules/all.yaml` upstream is **an empty stub**, literally: *"Empty: all rules previously in YAML are now compiled into the binary."* So whether your cluster has the KubeVirt rules depends entirely on which `korrel8r` container image tag your COO build pinned, not on any config you or the operator can see in a ConfigMap.

Per the upstream `CHANGELOG.md` (dates verified): KubeVirt rules first shipped as YAML config in **korrel8r v0.11.4 (2026-07-22)**, *"KubeVirt correlation rules for VM troubleshooting"*, then were recompiled as quickrules in **v0.12.1 (2026-08-26)**, *"Moved all existing rules to quickrules."* Both dates are recent. They are **not mentioned anywhere in the COO 1.0-1.5.2 product release notes**. The only way to know if your build has them is to ask the running pod, which is what step 2 below does.

### The verification commands

Run **`act2-01-korrel8r-verify.sh`** (`COO_NS` defaults to `openshift-cluster-observability-operator`, the documented default COO install namespace, confirmed current as of this writing; it changed from `openshift-operators` in an earlier COO release, so double-check on older clusters). It performs, in order:

1. **`korrel8r version`** inside the pod, compare against the changelog dates above.
2. **`korrel8r rules --config=/config/korrel8r.yaml -n '(Vm|Vmi|Vmim|Alert)' --long`**, the real, load-bearing check. This is a genuine CLI subcommand (`cmd/korrel8r/rules.go`, verified from source, including its `--start`/`-s`, `--goal`/`-g`, `--name`/`-n`, and `--long` flags) that lists every rule *actually loaded in the running engine*, matched by name/start/goal:
   ```bash
   oc exec -n openshift-cluster-observability-operator <korrel8r-pod> -- \
     korrel8r rules --config=/config/korrel8r.yaml -n '(Vm|Vmi|Vmim|Alert)' --long
   ```
   Expect to see lines like:
   ```
   VmToVmi: [VirtualMachine.kubevirt.io] -> [VirtualMachineInstance.kubevirt.io]
   VmiToPod: [VirtualMachineInstance.kubevirt.io] -> [Pod]
   AlertToVMI: [alert] -> [VirtualMachineInstance.kubevirt.io]
   VmiToLogs: [VirtualMachineInstance.kubevirt.io] -> [log]
   ```
   Names to specifically confirm are present: `VmToVmi`, `VmiToPod`, `VmiToNode`, `VmToAlert`, `VmiToAlert`, `AlertToVM`, `AlertToVMI`, `VmiToLogs`. (Full verified list in §6.)
3. Cross-check via the REST API, **`GET /api/v1alpha1/domain/k8s/classes`** should list `VirtualMachineInstance.kubevirt.io`, and (with a route) **`GET /api/v1alpha1/domains`** lists every configured domain and its store. (Both paths confirmed directly against korrel8r's own OpenAPI spec: base path `/api/v1alpha1`, routes `/domains` and `/domain/{domain}/classes`.) Note: this alone is **not sufficient proof**, it only shows the `k8s` domain knows the CRD exists, not that any rule connects an alert to it. Use the `rules` CLI output as the real signal.
4. Fails loudly (`exit 1`) if any required rule is missing, and tells you exactly what to do next (upgrade COO to pick up a newer pinned korrel8r image, or use the fallback below).

**Confirmed on the live cluster:** the shipped korrel8r is 0.11.1 with 47 rules total, 4 of them KubeVirt-specific. `PASS` for `VmToVmi`, `VmiToPod`, `VmiToNode`, `VmToPVC`, plus the generic (not KubeVirt-specific) `PodToLogs`, `PodToAlert`, `PodToNode`, `K8sSrcToNetflow`, and `AllToMetric`. `FAIL, rule missing` for `VmToAlert`, `VmiToAlert`, `AlertToVM`, `AlertToVMI`, and `VmiToLogs`, exactly the set that needs korrel8r 0.11.4 or later. That means on this cluster today: VMI to pod to logs, metrics, flows, and alerts all work, because the walk starts from a `k8s` object and the generic rules carry it the rest of the way; what does not work is starting from an alert and reaching a VM or VMI directly, or reaching logs straight from a VMI. Upstream 0.12.1 (verified separately, see Act 3) ships 104 rules, 30 of them KubeVirt-specific, and closes every one of those gaps.

### If the rules are missing: the honest fallback

**The TroubleshootingPanel UIPlugin CR has no field for this.** Verified against `rhobs/observability-operator @ pkg/apis/uiplugin/v1alpha1/types.go`:

```go
type TroubleshootingPanelConfig struct {
    Timeout string `json:"timeout,omitempty"`
    EnableAgentNavigation bool `json:"enableAgentNavigation,omitempty"`
}
```

That's the entire spec. No `rules:`, no `configMapRef:`, nothing. (`EnableAgentNavigation` is itself gated Dev Preview to OCP 4.22+, verified directly in the operator's controller code, `pkg/controllers/uiplugin/troubleshooting_panel.go`, which checks `IsVersionAheadOrEqual(clusterVersion, "v4.22")` and logs *"Agent Navigation only available as a Dev Preview in OpenShift 4.22+"*, irrelevant at our pinned 4.20 target; don't turn it on.)

The korrel8r `ConfigMap`/`Deployment` that *does* control rules is entirely operator-managed and continuously reconciled (standard controller-runtime `NewUpdater` pattern). So the honest framing is: **patching it is a demo trick, not a configuration.** It'll work for a single live run and get silently reverted by the operator afterward. `act2-06-korrel8r-custom-rule-fallback.yaml` has the exact YAML rule syntax (lifted verbatim from a real upstream reference file, `korrel8r/korrel8r @ etc/korrel8r/rules/_samples/kubevirt.yaml`, I diffed it character-for-character and it matches, not invented) plus the `oc set volume` / ConfigMap-edit steps, with this same caveat repeated in its header. Say this out loud if you use it: *"This isn't something I'd hand you as a production config today, it's proof the mechanism is a plain rules file you could extend, not a black box."*

**Tried live, and it confirms the caveat above.** Adding `AlertToVMI`/`VmiToLogs` YAML rules by hand to the operator's ConfigMap was reverted by the Cluster Observability Operator within about 2 minutes, before the patched config was even useful for more than one run. Worse, 0.11.1 doesn't have the `required` template function that the 0.12.1-style rule text uses, so the patched pod came up with the Troubleshooting Panel broken outright ("Search Error: invalid rule AlertToVMI: template: AlertToVMI:1: function \"required\" not defined") until the pod was restarted back onto the clean config. Do not try this as a live save during a demo; if you need the missing rules, the only real fix is a newer korrel8r image.

---

## 3. Trigger recipe (a), deterministic, no upgrade: `VMCannotBeEvicted`

**Verified verbatim from `kubevirt/kubevirt @ pkg/monitoring/rules/alerts/vms.go`:**

```
Alert: VMCannotBeEvicted
Expr:  kubevirt_vmi_non_evictable * on(name, namespace) group_left()
         topk by(name, namespace) (1, kubevirt_vmi_info{phase='running'}) == 1
For:   1m
Labels: severity=warning, operator_health_impact=none
Summary: "The VM's eviction strategy is set to Live Migration but the VM is not migratable"
```
(Note: the compiled rule additionally wraps this whole expr in an outer `label_replace(..., "vm", "$1", "name", "(.+)")` that copies the `name` label into a redundant `vm` label, omitted above for readability. It doesn't change when the alert fires or what it joins on; the korrel8r walk below keys off `name`/`namespace`, which are already present without the wrapper.)

### Trigger manifest

File: `act2-02-recipe-a-vmcannotbeevicted.yaml`

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-non-migratable
  namespace: demo-vms
spec:
  running: true
  dataVolumeTemplates:
    - metadata:
        name: vm-non-migratable-disk
      spec:
        storage:
          accessModes: ["ReadWriteOnce"]   # forces LiveMigratable=False, any storage backend
          resources:
            requests:
              storage: 10Gi
        source:
          registry:
            url: "docker://quay.io/containerdisks/fedora:latest"  # swap for your golden image
  template:
    spec:
      evictionStrategy: LiveMigrate       # NOT LiveMigrateIfPossible
      domain:
        cpu: { cores: 1 }
        resources: { requests: { memory: 1Gi } }
        devices:
          disks: [{ name: rootdisk, disk: { bus: virtio } }]
      volumes:
        - name: rootdisk
          dataVolume: { name: vm-non-migratable-disk }
```

**Two traps that silently defeat this recipe:**
1. `evictionStrategy: LiveMigrateIfPossible` instead of `LiveMigrate`, the "IfPossible" variant is *designed* to fall back to non-disruptive behavior for a non-migratable VM; `kubevirt_vmi_non_evictable` stays 0 and the alert never fires. Verified enum (`staging/src/kubevirt.io/api/core/v1/types.go`): `EvictionStrategyNone`, `EvictionStrategyLiveMigrate`, `EvictionStrategyLiveMigrateIfPossible`, `EvictionStrategyExternal`.
2. Letting the storage class grant `ReadWriteMany` even though you didn't need it. Forcing `accessModes: [ReadWriteOnce]` guarantees the block, per upstream docs: *"Live migration is only permitted when the volume access mode is set to ReadWriteMany"* (kubevirt.io/user-guide, Live Migration page).

### Apply and confirm

```bash
oc apply -f act2-02-recipe-a-vmcannotbeevicted.yaml
oc wait vmi/vm-non-migratable -n demo-vms --for=jsonpath='{.status.phase}'=Running --timeout=180s
oc get vmi vm-non-migratable -n demo-vms -o wide
# -> LIVE-MIGRATABLE column: False
```

**Time to fire:** no drain or manual action needed, KubeVirt evaluates migratability continuously from VMI status. Budget **~2-3 minutes** from Running to `state=firing` (one Prometheus eval interval to set the gauge, plus the alert's own `for: 1m`).

### The walk

1. **Observe → Alerting → Alerts.** This console's Alerting page has a Project selector (the COO monitoring plugin); it shows nothing until you pick **All Projects**, set that first, or the alert simply won't be in the list. Filter by alert name `VMCannotBeEvicted`, state Firing. Click the instance for `demo-vms/vm-non-migratable`. Confirmed live: this alert fires at 13:24:44Z for vm-non-migratable. Note that this alert instance's own `pod` label points at the exporting virt-handler pod, not the VM's virt-launcher pod, use the alert's `name`/`namespace` to find the actual workload, not that label.
2. **Console reality, confirmed live on COO 1.5.2 (korrel8r 0.11.1): the Focus button does not build a starting query from the VirtualMachine, VirtualMachineInstance, or Pod detail pages on this build.** Clicking it there returns "Empty Query, No starting point for correlation." Two paths do work: opening the Troubleshooting Panel from the alert's own detail page (Application Launcher → Signal Correlation → Focus), when korrel8r's alert domain recognises that alert instance, and typing a korrel8r query directly into the panel's own query editor, which works from any page. Confirm which path works on your build during rehearsal; don't promise Focus-from-a-VM-page live.
3. **On this build's actual rule set, the walk cannot start from the alert either.** `AlertToVMI` is one of the rules missing from korrel8r 0.11.1 (confirmed live, see §2), so Focus on the firing alert reaches only the `alert` and `metric` nodes, the same dead end the outdated-workloads alert hits in §4. To show the VMI → pod → logs walk on this build, type the VMI query directly into the panel's query editor instead: `k8s:VirtualMachineInstance.v1.kubevirt.io:{"namespace":"demo-vms","name":"vm-non-migratable"}`. From there, the rules that *are* present on 0.11.1 take over: `VmiToPod` → the `virt-launcher-vm-non-migratable-xxxxx` pod, then the generic `PodToLogs` → a `log` domain node, `PodToAlert` → back to the firing alert, `PodToNode` → the node it's scheduled on, and `AllToMetric` → metric series. `VmiToNode` and `VmToPVC` are also compiled into 0.11.1 (§2), so expect a node/PVC edge too; confirm the exact shape on your own build rather than assuming it matches the fuller rule list in §6, which describes the upstream rule set in general, not this specific pinned image. No `netflow` node appears from a VMI or alert by default; to show netflow, click into the pod node and re-run Focus from there, `K8sSrcToNetflow` is confirmed present on 0.11.1 and applies once you're at a Pod node.
4. Click the pod node → console navigates to the virt-launcher pod's own resource page. Show its logs tab (live `oc logs`) side by side with the Loki-backed `log` node in the graph (aggregated/searchable, same content, different store path) to make the "same data, joined" point concrete.
5. **If you want the full alert → VM → VMI → pod walk on stage**, that is the Act 3 upstream korrel8r 0.12.1 story, not this console build: the same `VMCannotBeEvicted` query, run against the experimental upstream instance, reaches VM, VMI, pod, node, metric, and log in one graph call (see `3-act3-agentic.md`). Frame that explicitly as "here is the same walk on the rule set that's coming," not as something this console does today.

### The click path that works on this build (confirmed live, COO 1.5.2)

1. Open the page you want to start from. The Alerting list (Observe, Alerting, Project set to All Projects) is the one page where Focus is enabled; on the VM, VMI and Pod pages it is greyed out.
2. Open the panel: Application launcher (the grid icon, top right), then Signal Correlation.
3. Click the small expand chevron just right of the time-range dropdown. A Start Query box appears with the placeholder `domain:class:selector`.
4. Paste the query. For the VMI walk: `k8s:VirtualMachineInstance.v1.kubevirt.io:{"namespace":"demo-vms","name":"vm-non-migratable"}`. For the alert: `alert:alert:{"alertname":"VMCannotBeEvicted","namespace":"demo-vms","name":"vm-non-migratable"}`.
5. Leave Search Type on Neighbours with 3 hops and click Search.

What you get on the shipped korrel8r 0.11.1: from the VMI query, twelve node classes (VMI, VM, Pod, Node, PVC, PersistentVolume, StorageClass, DataVolume, Events, Metric, Network flows, Application logs; screenshot `evidence/screenshots/console-panel-graph-from-VMI-korrel8r-0.11.1.png`). From the alert query, Alert and Metric only (`console-panel-graph-from-alert-korrel8r-0.11.1.png`). Click any node to open that resource or its logs.

### Reset

```bash
oc delete vm vm-non-migratable -n demo-vms
```
`kubevirt_vmi_non_evictable` drops to 0 immediately on VMI deletion; the alert resolves instantly (resolution is not gated by `for`, only the transition *into* Firing is).

---

## 4. Trigger recipe (b), the upgrade beat: `OutdatedVirtualMachineInstanceWorkloads`

**Verified verbatim from `kubevirt/kubevirt @ pkg/monitoring/rules/alerts/vms.go`:**

```
Alert: OutdatedVirtualMachineInstanceWorkloads
Expr:  kubevirt_vmi_number_of_outdated{namespace!=''} != 0
For:   24h
Labels: severity=warning, operator_health_impact=none
Summary: "Some running VMIs are still active in outdated pods after KubeVirt control plane update has completed."
```

### Two things that change how you run this recipe, read before staging

**1. The 24-hour `for` is real, and on this cluster pre-staging 24h ahead is not actually enough.** The metric goes nonzero within a couple of scrape intervals of the upgrade completing with an outdated VMI running (alert enters **Pending** almost immediately), but it will not become **Firing** until 24 continuous hours later. Confirmed live: this alert has sat in **Pending for at least 7 days straight** on this cluster, even though the underlying condition (21 outdated VMIs) has been true the entire time. The reason is not the workload; it's that both virt-controller replicas are crash-looping on leader-election lease renewal failures (106 and 105 restarts each over 7 days), and the `ALERTS_FOR_STATE` series is tied to whichever replica currently holds the lease, so every restart resets the 24h pending timer back to zero (36 resets counted in 7 days, roughly one every 4-5 hours). **Do not promise this alert will reach Firing on a fixed schedule.** `act2-03-recipe-b-outdated-workloads.sh stage` still walks the setup and is worth running the day before for the Pending transition and the gauge itself; just don't build the demo around watching it go Firing. Demo `kubevirt_vmi_number_of_outdated` and `oc get vmi -A -l kubevirt.io/outdatedLauncherImage` instead, those are the reliable, always-available signals for this beat.

**2. This metric carries no per-VM labels, the alert→VMI walk will not resolve from this alert.** I verified this from the exporter source, `kubevirt/kubevirt @ pkg/monitoring/metrics/virt-controller/leader_metrics.go`:

```go
outdatedVirtualMachineInstanceWorkloads = operatormetrics.NewGauge(
    operatormetrics.MetricOpts{ Name: "kubevirt_vmi_number_of_outdated", ... })

func SetOutdatedVirtualMachineInstanceWorkloads(value int) {
    outdatedVirtualMachineInstanceWorkloads.Set(float64(value))
}
```

This is a single **cluster-wide gauge with zero label dimensions**, a bare `.Set(value)`, no `.WithLabelValues(...)`. Any `namespace` label the alert instance carries comes only from Prometheus's own scrape-target relabeling (the CNV operator's own namespace, e.g. `openshift-cnv`), there is no `name` label identifying any specific VM. Korrel8r's `AlertToVMI`/`AlertToVM` quickrules both do `Require(l["name"])` (verified, `alert.qtpl`); with no `name` label present, that `Require()` fails and the rule silently produces **no edge**. Opening the Troubleshooting Panel on *this* alert shows only the isolated alert node (or, at best, a link to the virt-controller pod itself, not to any VM).

**This is not a flaw in the demo, it's a true, verifiable statement about this specific alert, and it's worth saying out loud:** *"Notice this one doesn't walk to a VM, that's because the metric is genuinely fleet-scoped, not VM-scoped, by design."* Recall from §3 that Focus doesn't build a starting query from a VMI's own resource page on this build anyway, so the way to show a per-VM view for one of these outdated VMIs is the same query-editor path used in recipe (a): pick a name/namespace from the outdated list and type `k8s:VirtualMachineInstance.v1.kubevirt.io:{"namespace":"<ns>","name":"<name>"}` into the panel's query editor. Use recipes (a) or (c) as your primary "walk" demos; use (b) for a different, equally real beat, a fleet-health signal with no vCenter/Aria analog, and its automated remediation.

### Stage → verify → drain

File: `act2-03-recipe-b-outdated-workloads.sh` (three subcommands)

**Stage (24h+ before the demo):**
```bash
# FIELD PATH DEPENDS ON THE HCO API VERSION YOUR CLUSTER PREFERS (both verified in
# kubevirt/hyperconverged-cluster-operator: api/v1beta1 = top-level
# spec.workloadUpdateStrategy; api/v1 = nested spec.virtualization.workloadUpdateStrategy).
# Patching the wrong layout is silently pruned. Check first:
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.apiVersion}{"\n"}'
# hco.kubevirt.io/v1beta1  (Red Hat docs 4.9-4.21 layout):
oc patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged -n openshift-cnv --type=merge \
  -p '{"spec":{"workloadUpdateStrategy":{"workloadUpdateMethods":[]}}}'
# hco.kubevirt.io/v1:
oc patch hyperconverged.v1.hco.kubevirt.io kubevirt-hyperconverged -n openshift-cnv --type=merge \
  -p '{"spec":{"virtualization":{"workloadUpdateStrategy":{"workloadUpdateMethods":[]}}}}'
# (act2-03-recipe-b-outdated-workloads.sh does this detection for you via hco_patch_wum)
# then upgrade the OpenShift Virtualization operator (any version bump that
# changes the virt-launcher image is enough, a z-stream patch works, you
# do not need a full minor jump)
```
Default HCO behavior (verified via the field's `+kubebuilder:default` in `hyperconverged_types.go`: `{"workloadUpdateMethods": {"LiveMigrate"}, "batchEvictionSize": 10, "batchEvictionInterval": "1m0s"}`) is `workloadUpdateMethods: [LiveMigrate]`, emptying the list is what deliberately leaves outdated VMIs running instead of auto-draining them before you ever see the alert.

**Verify (anytime before the demo):**
```bash
oc get vmi -A -l kubevirt.io/outdatedLauncherImage   # verified label, openshift/runbooks diagnosis steps
```

**Drain (on stage, after showing Firing):**
```bash
# version-aware (see Stage above); or simply:  ./act2-03-recipe-b-outdated-workloads.sh drain
oc patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged -n openshift-cnv --type=merge \
  -p '{"spec":{"workloadUpdateStrategy":{"workloadUpdateMethods":["LiveMigrate"]}}}'   # v1beta1
# oc patch hyperconverged.v1.hco.kubevirt.io ... -p '{"spec":{"virtualization":{"workloadUpdateStrategy":{"workloadUpdateMethods":["LiveMigrate"]}}}}'   # v1
```
HCO batch-migrates outdated, migratable VMIs (default `batchEvictionSize: 10` per `batchEvictionInterval: 1m`, both confirmed as the kubebuilder defaults above). Non-migratable outdated VMIs are left alone unless `Evict` is also added to the method list (`WorkloadUpdateMethodEvict = "Evict"`, a real enum value), which restarts/shuts them off and is off by default because it's disruptive; mention this explicitly if asked how a non-migratable outdated VM ever gets updated. The alert resolves the instant the gauge returns to 0 (again, no `for` delay on resolution).

### Reset
```bash
# version-aware (see Stage above); or simply:  ./act2-03-recipe-b-outdated-workloads.sh drain
oc patch hyperconverged.v1beta1.hco.kubevirt.io kubevirt-hyperconverged -n openshift-cnv --type=merge \
  -p '{"spec":{"workloadUpdateStrategy":{"workloadUpdateMethods":["LiveMigrate"]}}}'   # v1beta1
# oc patch hyperconverged.v1.hco.kubevirt.io ... -p '{"spec":{"virtualization":{"workloadUpdateStrategy":{"workloadUpdateMethods":["LiveMigrate"]}}}}'   # v1
```

---

## 5. Trigger recipe (c), memory pressure: `KubeVirtVMGuestMemoryPressure`

### Name correction (verify-before-use, as instructed)

The brief assumed an alert called `KubevirtVmHighMemoryUsage`. **That alert does not exist.** Checked against `kubevirt/kubevirt @ pkg/monitoring/rules/alerts/vms.go` and the full runbook index at `kubevirt/monitoring`, there is no runbook or alert definition by that name anywhere in either source. The two real guest-memory alerts are:

| Alert | Severity | `for` | Fires when |
|---|---|---|---|
| **`KubeVirtVMGuestMemoryPressure`** ← use this | warning | 5m | headroom < 5% **AND** (pgmajfaults > 5/s **OR** swap traffic > 1MiB/s) |
| `KubeVirtVMGuestMemoryAvailableLow` | info | 30m | headroom < 3% **AND** swap < 2KiB/30m **AND** pgmajfaults < 1/30m (i.e., low headroom *without* swap, a slow leak, the opposite condition of a hog under active pressure) |

`KubeVirtVMGuestMemoryAvailableLow`'s condition is specifically the *absence* of swap/fault activity, it is the wrong alert to build a "run a memory hog" demo around, and its 30-minute `for` makes it worse for a live demo regardless. `KubeVirtVMGuestMemoryPressure` is the correct target.

**Verified exact expr** (`vms.go`; the trailing `topk` join clause is abbreviated below for readability, it's a double `label_replace` on `kubevirt_vmi_info{phase='running'}`, full text in the source):
```
((vmi:kubevirt_vmi_memory_headroom_ratio:sum < 0.05)
  and (vmi:kubevirt_vmi_pgmajfaults:rate5m > 5
       or vmi:kubevirt_vmi_swap_traffic_bytes:rate5m > 1048576)
  and (vmi:kubevirt_vmi_memory_available_bytes:sum > 0))
* on(name, namespace) group_left(vm) topk by(name, namespace) (1, ...)
```

### Prerequisite correction, this needs a 4th thing, not QGA/schedstats/psi

The brief's hard rule flags three known prerequisites (QEMU guest agent, `schedstats=enable`, `psi=1`). **This recipe needs none of them.** Its metrics, `kubevirt_vmi_memory_available_bytes`, `_usable_bytes`, `_pgmajfault_total`, `_swap_in_traffic_bytes`, `_swap_out_traffic_bytes`, come from the **libvirt/QEMU memory-balloon device's extended stats** (`virtio_balloon` guest kernel driver, polled via libvirt), confirmed from the metric descriptions themselves (`kubevirt.io/monitoring/metrics.html`: e.g. `kubevirt_vmi_memory_usable_bytes` = *"the amount of memory which can be reclaimed by balloon..."*). None of these carry the "Requires qemu-guest-agent" note that `kubevirt_vmi_guest_load_1m/5m/15m` explicitly does. The real prerequisite: don't set `autoattachMemBalloon: false` (default is attached), and use a guest kernel with the standard `virtio_balloon` driver (default on any stock Fedora/CentOS Stream/RHEL cloud image, no install step needed).

### Trigger manifest + driver

Files: `act2-04-recipe-c-memory-pressure-vm.yaml`, `act2-05-memory-pressure-driver.sh`

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-memory-pressure
  namespace: demo-vms
spec:
  running: true
  template:
    spec:
      domain:
        cpu: { cores: 2 }
        resources:
          requests: { memory: 512Mi }
          limits: { memory: 512Mi }     # tight ceiling, do not omit
        devices:
          disks:
            - { name: rootdisk, disk: { bus: virtio } }
            - { name: cloudinitdisk, disk: { bus: virtio } }
      volumes:
        - name: rootdisk
          containerDisk: { image: quay.io/containerdisks/fedora:latest }
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              packages: [stress-ng]
              runcmd:
                - fallocate -l 256M /swapfile
                - chmod 600 /swapfile
                - mkswap /swapfile
                - swapon /swapfile
                - echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

**Guest swap is not optional here.** Without it, a memory hog just gets OOM-killed by the guest kernel with no sustained page-fault/swap I/O, and the alert's compound condition (needs pgmajfaults>5/s *or* swap>1MiB/s, not just low headroom) may never trip even though the VM is visibly starved.

```bash
oc apply -f act2-04-recipe-c-memory-pressure-vm.yaml
oc wait vmi/vm-memory-pressure -n demo-vms --for=jsonpath='{.status.phase}'=Running --timeout=180s
# give cloud-init ~60-90s more to install stress-ng and set up swap
NAMESPACE=demo-vms VM=vm-memory-pressure ./act2-05-memory-pressure-driver.sh
```
The driver script prompts you to start `stress-ng --vm 2 --vm-bytes 90% --vm-keep --timeout 600s` via `virtctl console`, then polls `vmi:kubevirt_vmi_memory_headroom_ratio:sum`, the pgmajfault/swap rate recording rules, and the live `ALERTS{alertname="KubeVirtVMGuestMemoryPressure"}` series every 15s in a second terminal pane, so the audience watches the exact numbers the alert expr reads move in real time next to the console.

**Time to fire:** ~10 minutes (5-minute rate-window warm-up for the recording rules, plus the alert's own `for: 5m`); can be faster if pressure is immediate.

### The walk

Same shape as recipe (a), with the same corrected console reality (see recipe (a)'s §3, steps 2-3): **Observe → Alerting → Alerts** (Project set to All Projects) **→ `KubeVirtVMGuestMemoryPressure` (Firing)**. This alert's own expr does carry `name`/`namespace` labels via its `group_left(vm)` join, which satisfies `AlertToVMI`'s label requirement, unlike recipe (b), but on this cluster's actual korrel8r (0.11.1), `AlertToVMI` itself is missing, so Focus on the alert still won't reach the VMI (confirmed in §2). Use the same query-editor workaround as recipe (a): type `k8s:VirtualMachineInstance.v1.kubevirt.io:{"namespace":"demo-vms","name":"vm-memory-pressure"}` directly into the panel. From there, expect the same VMI → Pod → Node → Logs → Metric shape as recipe (a).

### Reset

```bash
oc delete vm vm-memory-pressure -n demo-vms
```
(Or gracefully first: `virtctl console vm-memory-pressure -n demo-vms`, `pkill stress-ng` inside the guest.) Headroom and rates recover over their own 5-minute windows; the alert clears with no additional delay once the expr goes false.

---

## 6. Expected node-graph contents, reference

**Full verified rule list relevant to this walk** (`korrel8r/korrel8r @ pkg/rules/quickrules/kubevirt.qtpl` + `alert.qtpl`). This is the upstream rule set in general, not a guarantee for any one pinned image: on this cluster's actual korrel8r (0.11.1), only `VmToVmi`, `VmiToPod`, `VmiToNode`, and `VmToPVC` from the KubeVirt-specific rows below are confirmed present, alongside generic `PodToLogs`, `PodToAlert`, `PodToNode`, `K8sSrcToNetflow`, and `AllToMetric`; `AlertToVM`, `AlertToVMI`, `VmToAlert`, `VmiToAlert`, and `VmiToLogs` are confirmed missing and need korrel8r 0.11.4 or later (see §2 for the live verification output).

| Rule | Start → Goal | Notes |
|---|---|---|
| `AlertToVM` / `AlertToVMI` | `alert` → `VirtualMachine`/`VirtualMachineInstance` | Requires alert labels `namespace` **and** `name`, see recipe (b)'s caveat |
| `AlertToVmim` | `alert` → `VirtualMachineInstanceMigration` | Requires alert labels `namespace` + `vmim` |
| `VmToVmi` | `VirtualMachine` → `VirtualMachineInstance` | Direct namespace/name match |
| `VmiToPod` | `VirtualMachineInstance` → `Pod` | **Label match** `kubevirt.io=virt-launcher`, `vm.kubevirt.io/name=<vmi>`, confirmed no ownerReference exists; this is the rule that makes the walk possible at all |
| `VmiToNode` | `VirtualMachineInstance` → `Node` | From `.status.nodeName` |
| `VmToAlert` / `VmiToAlert` / `VmimToAlert` | reverse of the above | For navigating VM→alert |
| `VmToPVC` / `VmiToPVC` | → `PersistentVolumeClaim` | Covers `dataVolumeTemplates`, `persistentVolumeClaim`, `dataVolume`, `ephemeral`, `memoryDump` volume types |
| `VmiToLogs` | `VirtualMachineInstance` → `log` domain | Same label match as `VmiToPod`, targets Loki `application` or `infrastructure` tenant via `logTypeForNamespace()` (infra only for `default`/`openshift*`/`kube*` namespaces, any normal demo namespace resolves to `application`) |
| `VmToMetric` / `VmiToMetric` | → `metric` domain | `metric:metric:{namespace=...,name=...}` |
| `NodeToVmi` | `Node` → `VirtualMachineInstance` | Via `kubevirt.io/nodeName` label, useful for "what else is on this node" |
| `VmimToVmi` / `VmiToVmim` | migration ↔ VMI | For the migration-beat crossover with Act 1 |
| `K8sSrcToNetflow` / `K8sDstToNetflow` | `Node`/`Pod`/`Service` → `netflow` | Generic k8s rules (not KubeVirt-specific), verified in `pkg/rules/quickrules/k8s.qtpl`, this is how a virt-launcher Pod node reaches netflow; netflow-domain rules only run in the reverse direction |

**Domains and what backs them** (verified, COO's generated korrel8r config template):

| Domain | Store | Requires |
|---|---|---|
| `k8s` | live API server | nothing extra |
| `alert` | Thanos-querier + Alertmanager (`openshift-monitoring`) | nothing extra, always available |
| `metric` | Thanos-querier | nothing extra |
| `log` | LokiStack gateway, expected in `openshift-logging` | **Logging Operator + LokiStack CR**, in that namespace |
| `netflow` | LokiStack gateway, expected in `netobserv` namespace | **Network Observability operator + its own LokiStack**, in that namespace |
| `trace` | Tempo gateway, expected in `openshift-tracing` | **Tempo Operator + TempoStack** (not exercised by these 3 recipes) |

### What silently does NOT render if a plugin/store is missing

This is not hypothetical, I verified it from the operator's own config-generation code (`pkg/controllers/uiplugin/components.go`, `newKorrel8rConfigMap`): the store URL for `log`/`netflow`/`trace` is written into the korrel8r config from a real live lookup (`getLokiServiceName`/`getTempoServiceName` actually list Services in the target namespace looking for the LokiStack/Tempo gateway), but if that lookup finds nothing, the config falls back to a guessed default service name (`logging-loki-gateway-http`, `loki-gateway-http`, `tempo-platform-gateway`) **regardless of whether that service actually exists**. If LokiStack isn't installed in `openshift-logging`, korrel8r's `log` store ends up pointing at a Service that isn't there, any query to it fails (connection error) inside the korrel8r pod. **The graph does not show an error node for this.** It simply omits the log node, one fewer branch on the VMI, no visible indication anything is missing, unless you go check the korrel8r pod's own logs. Same mechanism, same silence, for `netflow` without Network Observability + its LokiStack.

**Practical implication for this act:** if you're demoing the log/netflow branches (which you should be, per the brief), confirm both are actually installed and their LokiStack pods are Ready *before* you're on stage, `preflight.sh` §7 already checks the CRDs exist; also confirm the LokiStack pods themselves are running (`oc get pods -n openshift-logging`, `oc get pods -n netobserv`), since a CRD existing doesn't mean the stack is healthy.

---

## 7. Full reset reference

Run `act2-07-reset.sh` (env vars `NAMESPACE`, `HCO_NS`, `HCO_NAME`, all defaulted) to reset all three recipes in one pass: deletes `vm-non-migratable` and `vm-memory-pressure`, restores `workloadUpdateMethods: [LiveMigrate]` on the HyperConverged CR, and reminds you to roll back any fallback korrel8r rules if you used §2's unsupported path (the operator generally does this on its own).

---

## Files written

All under `/tmp/claude-1000/-home-anaeem-virt-monitorong/2f0da83a-3cef-49d6-93d9-35e42bb17a53/scratchpad/demo/`:

- `act2-01-korrel8r-verify.sh`, mandatory pre-demo korrel8r KubeVirt-rule check (CLI + REST)
- `act2-02-recipe-a-vmcannotbeevicted.yaml`, deterministic non-migratable VM trigger
- `act2-03-recipe-b-outdated-workloads.sh`, HCO patch / upgrade / verify / drain flow for the outdated-workloads alert
- `act2-04-recipe-c-memory-pressure-vm.yaml`, tight-memory VM with guest swap via cloud-init
- `act2-05-memory-pressure-driver.sh`, live-demo companion that polls the alert's own recording rules
- `act2-06-korrel8r-custom-rule-fallback.yaml`, unsupported custom-rule fallback (real upstream YAML syntax, honest caveats)
- `act2-07-reset.sh`, one-pass reset for all three recipes

All seven files were confirmed to exist on disk and to parse cleanly (YAML via `python3 -c "import yaml; yaml.safe_load_all(...)"`, bash via `bash -n`) both before and after the `operator_health_impact` label-key fix described above.

---

## Open questions only your live cluster can answer

1. **Does your COO build's pinned korrel8r image actually contain the KubeVirt rules?** Answered on this specific cluster: 0.11.1, 4 of 8 relevant KubeVirt rules present, `AlertToVMI`/`VmToAlert`/`VmiToAlert`/`VmiToLogs` missing (see §2). This remains the single largest risk on any *other* cluster this act runs on, run `act2-01-korrel8r-verify.sh` days before the demo, not hours before, and don't assume a different cluster matches this one.
2. **What are your default/available StorageClasses' access modes?** Recipe (a) forces `ReadWriteOnce` explicitly so it works regardless, but confirm the DataVolume actually binds (some CSI drivers reject `ReadWriteOnce` + `Block` combinations, or need a different `volumeMode`).
3. **Is `autoattachMemBalloon` disabled anywhere in your cluster's default VM template/instancetype?** If your demo VMs are built from a customized golden image or instancetype that turns the balloon device off, recipe (c)'s entire metric chain goes silently empty, check `oc get vm <name> -o jsonpath='{.spec.template.spec.domain.devices.autoattachMemBalloon}'` on whatever base template you actually use.
4. **Which namespace is LokiStack (logging) and Network Observability's LokiStack actually installed in?** The korrel8r config assumes `openshift-logging` and `netobserv` respectively (verified from source), if your cluster used different namespaces, the `log`/`netflow` domains will silently fail to resolve even though both operators are technically installed. Confirm namespace names match before relying on §6's table.
5. **Exact default value of the Troubleshooting Panel's "Distance" advanced-settings control**, confirmed from docs.redhat.com that this control exists and is described as "the maximum number of steps" the correlation search takes from the starting point, and that it's user-adjustable in the panel's Advanced settings, but the documentation does not state a numeric default and I could not confirm one from source in the time available. If the VMI→Pod→Logs chain doesn't fully render at the default, increase Distance manually.



---

## Appendix: code items

### act2-01-korrel8r-verify.sh (bash)
*Prerequisites:* oc CLI logged into the cluster; COO's TroubleshootingPanel UIPlugin already created

Mandatory pre-demo check. Runs `korrel8r version` and the real load-bearing check `korrel8r rules -n '(Vm|Vmi|Vmim|Alert)' --long` inside the running korrel8r pod (verified CLI subcommand, cmd/korrel8r/rules.go), cross-checked against the REST API. Fails loudly and names the exact fallback if KubeVirt rules are missing. No changes required -- verified correct against upstream source (rule names, REST paths /api/v1alpha1/domains and /api/v1alpha1/domain/k8s/classes, pod label app.kubernetes.io/instance=korrel8r, port 9443, --config=/config/korrel8r.yaml -- all confirmed byte-for-byte against korrel8r/korrel8r and rhobs/observability-operator source).

```bash
#!/usr/bin/env bash
set -uo pipefail
COO_NS="${COO_NS:-openshift-cluster-observability-operator}"
KORREL8R_POD=$(oc get pods -n "$COO_NS" -l app.kubernetes.io/instance=korrel8r -o jsonpath='{.items[0].metadata.name}')
oc exec -n "$COO_NS" "$KORREL8R_POD" -- korrel8r version
oc exec -n "$COO_NS" "$KORREL8R_POD" -- korrel8r rules --config=/config/korrel8r.yaml -n '(Vm|Vmi|Vmim|Alert)' --long
# Expect: VmToVmi, VmiToPod, VmiToNode, VmToAlert, VmiToAlert, AlertToVM, AlertToVMI, VmiToLogs
# Full script with pass/fail gating: see file_path (on disk, verified present and syntactically valid).
```

### act2-02-recipe-a-vmcannotbeevicted.yaml (yaml)
*Prerequisites:* namespace demo-vms exists; a StorageClass that can provision at least ReadWriteOnce

Deterministic, no-upgrade trigger for VMCannotBeEvicted (severity warning, for 1m). Two traps called out inline: evictionStrategy must be exactly LiveMigrate (not LiveMigrateIfPossible), and accessModes: [ReadWriteOnce] is what forces LiveMigratable=False regardless of storage backend. FIX APPLIED: the on-disk file's header comment had the alert's operator-health label spelled operatorHealthImpact -- verified against kubevirt/kubevirt @ pkg/monitoring/rules/alerts/alerts.go, the actual emitted Prometheus label key is operator_health_impact (snake_case; the Go identifier operatorHealthImpactLabelKey's *value* is "operator_health_impact"). Corrected in place on disk and below. (Minor nuance, not fixed in the manifest itself since it doesn't affect the trigger: the real compiled alert additionally wraps this expr in an outer label_replace(...,"vm","$1","name","(.+)") that adds a redundant "vm" label -- cosmetic, doesn't change when the alert fires or what it joins on.)

```yaml
# =============================================================================
# act2-02-recipe-a-vmcannotbeevicted.yaml
#
# Trigger recipe (a): deterministic, no CNV upgrade needed.
# Fires: VMCannotBeEvicted (severity: warning, for: 1m)
#
# Verified verbatim against kubevirt/kubevirt @ pkg/monitoring/rules/alerts/vms.go:
#
#   Alert: "VMCannotBeEvicted"
#   Expr:  kubevirt_vmi_non_evictable * on(name, namespace) group_left()
#            topk by(name, namespace) (1, kubevirt_vmi_info{phase='running'}) == 1
#   For:   1m
#   Labels:      severity: warning, operator_health_impact: none
#   Summary:     "The VM's eviction strategy is set to Live Migration but the
#                 VM is not migratable"
#   (Note: the compiled rule wraps this whole expr in an outer
#   label_replace(..., "vm", "$1", "name", "(.+)") that copies "name" into a
#   redundant "vm" label -- omitted above for readability; doesn't change
#   trigger behavior or the korrel8r walk, which keys off "name"/"namespace".)
#
# Mechanism: kubevirt_vmi_non_evictable is a gauge that is 1 for any Running
# VMI whose evictionStrategy resolves to LiveMigrate AND whose LiveMigratable
# status condition is False. No node drain, no actual eviction attempt, and
# no guest OS boot are required to trip this -- KubeVirt evaluates
# migratability continuously from VMI spec/status.
#
# TWO THINGS THAT WILL SILENTLY DEFEAT THIS RECIPE IF YOU GET THEM WRONG:
#   1. evictionStrategy MUST be exactly "LiveMigrate", not
#      "LiveMigrateIfPossible". The "IfPossible" variant is specifically
#      designed to fall back to non-disruptive behavior for a VM that can't
#      migrate -- kubevirt_vmi_non_evictable stays 0 and this alert never
#      fires. (Verified: staging/src/kubevirt.io/api/core/v1/types.go,
#      EvictionStrategy const block: None/LiveMigrate/LiveMigrateIfPossible/External.)
#   2. The disk must actually be non-migratable. RWX-capable storage classes
#      (Ceph RBD in RWX mode, NFS, etc.) will happily grant ReadWriteMany even
#      if you don't ask for it in some configurations -- forcing
#      accessModes: [ReadWriteOnce] on the DataVolumeTemplate is what
#      guarantees LiveMigratable=False regardless of backend, per the
#      upstream doc: "Live migration is only permitted when the volume
#      access mode is set to ReadWriteMany" (kubevirt.io/user-guide, Live
#      Migration page).
#
# Swap the boot source below (registry/containerDisk URL) for whatever image
# your Act 1 demo already uses -- the guest OS content is irrelevant here,
# only the disk's access mode and the eviction strategy matter.
# =============================================================================
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-non-migratable
  namespace: demo-vms          # <- match your Act 1 namespace
  labels:
    demo.act2/recipe: "a-vmcannotbeevicted"
spec:
  running: true
  dataVolumeTemplates:
    - metadata:
        name: vm-non-migratable-disk
      spec:
        storage:
          accessModes: ["ReadWriteOnce"]   # <- the trigger: forces LiveMigratable=False
          resources:
            requests:
              storage: 10Gi
        source:
          registry:
            url: "docker://quay.io/containerdisks/fedora:latest"  # swap for your golden image
  template:
    metadata:
      labels:
        demo.act2/recipe: "a-vmcannotbeevicted"
    spec:
      evictionStrategy: LiveMigrate      # <- the trigger: NOT LiveMigrateIfPossible
      domain:
        cpu:
          cores: 1
        resources:
          requests:
            memory: 1Gi
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
      volumes:
        - name: rootdisk
          dataVolume:
            name: vm-non-migratable-disk

---
# Apply, then confirm:
#   oc apply -f act2-02-recipe-a-vmcannotbeevicted.yaml
#   oc wait vmi/vm-non-migratable -n demo-vms --for=jsonpath='{.status.phase}'=Running --timeout=180s
#   oc get vmi vm-non-migratable -n demo-vms -o wide
#     -> LIVE-MIGRATABLE column should read False
#   oc get vmi vm-non-migratable -n demo-vms \
#     -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")]}'
#     -> reason should reference the disk access mode
#
# Time to fire: ~1-2 Prometheus scrape/eval intervals (default 30s) to make
# kubevirt_vmi_non_evictable go to 1, plus the alert's own `for: 1m`.
# Budget ~2-3 minutes from VMI reaching Running to the alert showing
# state=firing in Observe > Alerting.
#
# RESET:
#   oc delete vm vm-non-migratable -n demo-vms
#   (the DataVolumeTemplate PVC is deleted with it; kubevirt_vmi_non_evictable
#   drops to 0 as soon as the VMI object is gone, and the Alert instance
#   clears immediately -- there is no "for" delay on alert *resolution*, only
#   on the transition into Firing.)
```

### act2-03-recipe-b-outdated-workloads.sh (bash)
*Prerequisites:* cluster-admin on the HyperConverged CR; a pending OpenShift Virtualization operator update to apply

Stage/verify/drain flow for OutdatedVirtualMachineInstanceWorkloads (severity warning, for 24h). Must be pre-staged 24h+ before the live demo -- the alert's own for-duration cannot be compressed. Explicitly documents that this alert's metric has zero label dimensions in source, so the alert->VMI korrel8r walk will NOT resolve from it -- use recipe (a) or (c) for the walk itself. FIX APPLIED: same operator_health_impact label-key typo as act2-02, corrected in place on disk and below. All other technical claims verified exact against source: HCO field path spec.virtualization.workloadUpdateStrategy.workloadUpdateMethods, default [LiveMigrate]/batchEvictionSize=10/batchEvictionInterval=1m0s (hyperconverged_types.go kubebuilder defaults), kubevirt.io/outdatedLauncherImage label, WorkloadUpdateMethodEvict enum value, and the Require(l["name"]) failure mode in alert.qtpl.

```bash
#!/usr/bin/env bash
# =============================================================================
# act2-03-recipe-b-outdated-workloads.sh -- Trigger recipe (b): the upgrade
# beat. Fires: OutdatedVirtualMachineInstanceWorkloads (severity: warning,
# for: 24h)
#
# Verified verbatim against kubevirt/kubevirt @ pkg/monitoring/rules/alerts/vms.go:
#
#   Alert: "OutdatedVirtualMachineInstanceWorkloads"
#   Expr:  kubevirt_vmi_number_of_outdated{namespace!=''} != 0
#   For:   24h
#   Labels:  severity: warning, operator_health_impact: none
#   Summary: "Some running VMIs are still active in outdated pods after
#             KubeVirt control plane update has completed."
#
# *** READ THIS BEFORE YOU BUILD A DEMO AROUND THIS ALERT ***
#
# 1) THE 24-HOUR FOR-DURATION IS REAL, AND CONFIRMED LIVE, PRE-STAGING 24H
#    AHEAD IS NOT ACTUALLY ENOUGH ON A CLUSTER WHERE VIRT-CONTROLLER IS
#    CRASH-LOOPING. The underlying gauge (kubevirt_vmi_number_of_outdated)
#    goes nonzero within a couple of scrape intervals of the upgrade
#    completing with an outdated VMI still running -- the alert enters
#    Pending state almost immediately. On this cluster it has sat in
#    Pending for at least 7 days straight: both virt-controller replicas
#    restart on leader-election lease-renewal failures (106 and 105
#    restarts each over 7 days), and every restart resets the alert's 24h
#    pending timer (36 resets counted in 7 days). Run steps 1-3 below the
#    day before as good practice, but do not promise Firing on a fixed
#    schedule -- demo the gauge and the labeled VMI list instead (step 4
#    below), not the alert reaching Firing.
#
# 2) THIS METRIC HAS NO PER-VM LABELS -- THE WALK IN THE TROUBLESHOOTING
#    PANEL WILL NOT RESOLVE A VMI FROM THIS ALERT.
#    Verified against kubevirt/kubevirt @
#    pkg/monitoring/metrics/virt-controller/leader_metrics.go:
#      outdatedVirtualMachineInstanceWorkloads = operatormetrics.NewGauge(
#          operatormetrics.MetricOpts{ Name: "kubevirt_vmi_number_of_outdated", ... })
#      func SetOutdatedVirtualMachineInstanceWorkloads(value int) {
#          outdatedVirtualMachineInstanceWorkloads.Set(float64(value))
#      }
#    This is a single cluster-wide gauge with ZERO label dimensions in the
#    exporter code -- it is set with a bare .Set(value), no .WithLabelValues().
#    Any "namespace" label you see on the alert instance comes only from
#    Prometheus's own ServiceMonitor scrape-target relabeling (the namespace
#    the virt-controller pod itself runs in, e.g. openshift-cnv) -- there is
#    no "name" label identifying a specific VM.
#    Korrel8r's AlertToVM / AlertToVMI quickrules both do
#    `Require(l["name"])` on the alert's labels (verified against
#    korrel8r/korrel8r @ pkg/rules/quickrules/alert.qtpl) -- with no "name"
#    label present, that Require() fails and the rule silently produces no
#    edge. Opening the Troubleshooting Panel FROM THIS ALERT will show only
#    the alert node itself (isolated, or at best linked to the
#    virt-controller pod, never to a VM).
#    -> For the actual alert-to-VMI-to-pod WALK, use recipe (a) or (c).
#       Use recipe (b) to show the metric/alert firing and the automated
#       drain -- a different, equally real beat: "here is a KubeVirt-only
#       signal with no vCenter/Aria analog, and here is it self-healing via
#       the same GitOps/operator machinery you already trust."
#    -> If you still want to show a graph for THIS scenario, pick one
#       specific outdated VMI from the list in step 4 and open the
#       Troubleshooting Panel (Application Launcher > Signal Correlation >
#       Focus) from THAT VMI's own resource page (Virtualization >
#       VirtualMachines > <name>), not from the alert.
#
# Usage:
#   oc login ...
#   HCO_NS=openshift-cnv HCO_NAME=kubevirt-hyperconverged ./act2-03-recipe-b-outdated-workloads.sh stage
#   ... (pre-stage 24h+ before the demo) ...
#   ./act2-03-recipe-b-outdated-workloads.sh verify
#   ... (on stage, after showing the alert firing) ...
#   ./act2-03-recipe-b-outdated-workloads.sh drain
# =============================================================================
set -uo pipefail

HCO_NS="${HCO_NS:-openshift-cnv}"
HCO_NAME="${HCO_NAME:-kubevirt-hyperconverged}"
CMD="${1:-}"

case "$CMD" in
  stage)
    echo "== Step 1: disable automated workload updates BEFORE the upgrade =="
    echo "   Field (verified against kubevirt/hyperconverged-cluster-operator @"
    echo "   api/v1/hyperconverged_types.go and docs/cluster-configuration.md):"
    echo "     spec.virtualization.workloadUpdateStrategy.workloadUpdateMethods"
    echo "   Default value is [LiveMigrate] -- HCO will auto-drain outdated VMIs"
    echo "   unless you empty this list first, which would clear the alert"
    echo "   before you ever see it fire."
    oc patch hyperconverged "$HCO_NAME" -n "$HCO_NS" --type=merge \
      -p '{"spec":{"virtualization":{"workloadUpdateStrategy":{"workloadUpdateMethods":[]}}}}'
    echo
    echo "== Step 2: confirm at least one VM is Running, then upgrade the"
    echo "   OpenShift Virtualization operator (any version bump that changes"
    echo "   the virt-launcher image works -- a z-stream patch is enough; you"
    echo "   do not need a full minor upgrade for this alert). Do this via"
    echo "   Console > Operators > Installed Operators > OpenShift"
    echo "   Virtualization > Subscription, or:"
    echo "     oc get subscription kubevirt-hyperconverged -n $HCO_NS -o yaml"
    echo "   and approve the pending InstallPlan:"
    echo "     oc get installplan -n $HCO_NS"
    echo "     oc patch installplan <name> -n $HCO_NS --type=merge -p '{\"spec\":{\"approved\":true}}'"
    echo
    echo "== Step 3: wait for the HCO/CNV upgrade to report Completed =="
    echo "     oc get hyperconverged $HCO_NAME -n $HCO_NS -o jsonpath='{.status.conditions}'"
    echo
    echo "Now WAIT. Do not run 'drain' until after you have demoed the Firing"
    echo "alert (24h+ later). Run './act2-03-recipe-b-outdated-workloads.sh verify'"
    echo "anytime in between to check Pending status."
    ;;

  verify)
    echo "== Outdated VMIs (verified label: kubevirt.io/outdatedLauncherImage,"
    echo "   from the openshift/runbooks OutdatedVirtualMachineInstanceWorkloads"
    echo "   diagnosis steps) =="
    oc get vmi -A -l kubevirt.io/outdatedLauncherImage
    echo
    echo "== Alert state (Observe > Alerting, or via Thanos-querier / Alertmanager API) =="
    echo "   Console path: Observe > Alerting > Alerts (set Project to All Projects first),"
    echo "   filter Alert = OutdatedVirtualMachineInstanceWorkloads"
    echo "   State reads Pending once the metric goes nonzero. On a cluster where"
    echo "   virt-controller is stable it reaches Firing 24h later; on this cluster"
    echo "   it has stayed Pending for a week because virt-controller restarts reset"
    echo "   the timer every 4-5 hours -- see the header comment. Don't wait for Firing."
    ;;

  drain)
    echo "== Re-enabling automated drain =="
    oc patch hyperconverged "$HCO_NAME" -n "$HCO_NS" --type=merge \
      -p '{"spec":{"virtualization":{"workloadUpdateStrategy":{"workloadUpdateMethods":["LiveMigrate"]}}}}'
    echo
    echo "HCO's workload-updater will batch-migrate outdated, migratable VMIs"
    echo "(default batchEvictionSize: 10 VMIs per batchEvictionInterval: 1m)."
    echo "Non-migratable outdated VMIs are left as-is unless you also add"
    echo "\"Evict\" to workloadUpdateMethods -- that restarts/shuts them off,"
    echo "which is disruptive and off by default; mention this explicitly if"
    echo "an architect asks how a non-migratable outdated VM ever gets updated."
    echo
    echo "Watch it drain:"
    echo "  watch oc get vmi -A -l kubevirt.io/outdatedLauncherImage"
    echo "The alert clears (Alertmanager resolves it) the instant the metric"
    echo "returns to 0 -- resolution is NOT gated by the 24h 'for', only the"
    echo "transition into Firing is."
    ;;

  *)
    echo "Usage: $0 {stage|verify|drain}" >&2
    exit 2
    ;;
esac
```

### act2-04-recipe-c-memory-pressure-vm.yaml (yaml)
*Prerequisites:* namespace demo-vms exists; outbound access for the containerDisk image and cloud-init package install (or a pre-baked image with stress-ng already installed)

Triggers KubeVirtVMGuestMemoryPressure (severity warning, for 5m) -- corrected from the brief's assumed, nonexistent 'KubevirtVmHighMemoryUsage'. Verified: no runbook or alert by that name exists in kubevirt/monitoring; the two real guest-memory alerts are KubeVirtVMGuestMemoryPressure and KubeVirtVMGuestMemoryAvailableLow, both confirmed present with matching expr/for/severity against pkg/monitoring/rules/alerts/vms.go. Guest swap via cloud-init is required, not optional. Needs the memory-balloon device (default-on), not QEMU guest agent -- confirmed the guest-memory metrics carry no "Requires qemu-guest-agent" note in kubevirt.io/monitoring/metrics.html, unlike kubevirt_vmi_guest_load_1m/5m/15m which explicitly do. No changes required to this file.

```yaml
# =============================================================================
# act2-04-recipe-c-memory-pressure-vm.yaml
#
# Trigger recipe (c): guest memory pressure.
# Fires: KubeVirtVMGuestMemoryPressure (severity: warning, for: 5m)
#
# *** NAME CORRECTION ***
# The brief for this recipe assumed an alert called "KubevirtVmHighMemoryUsage".
# No such alert exists. Verified against kubevirt/kubevirt @
# pkg/monitoring/rules/alerts/vms.go, the KubeVirt runbook index
# (github.com/kubevirt/monitoring/tree/main/docs/runbooks), and
# kubevirt.io/monitoring/runbooks/ -- the two real guest-memory alerts are:
#
#   KubeVirtVMGuestMemoryPressure     severity: warning   for: 5m   <- used here
#   KubeVirtVMGuestMemoryAvailableLow severity: info       for: 30m
#
# KubeVirtVMGuestMemoryPressure is the right one for a "run a memory hog"
# demo: its condition explicitly requires ACTIVE major page faults or swap
# I/O (a hog under pressure), fires in 5 minutes, and is severity warning.
# KubeVirtVMGuestMemoryAvailableLow requires the OPPOSITE -- LOW swap/fault
# activity (a slow leak with no swap configured) -- and needs 30 minutes;
# it is the wrong alert to build a live demo around.
#
# Exact expr (verified, vms.go):
#   ((vmi:kubevirt_vmi_memory_headroom_ratio:sum < 0.05)
#     and (vmi:kubevirt_vmi_pgmajfaults:rate5m > 5
#          or vmi:kubevirt_vmi_swap_traffic_bytes:rate5m > 1048576)
#     and (vmi:kubevirt_vmi_memory_available_bytes:sum > 0))
#   * on(name, namespace) group_left(vm) topk by(name, namespace) (1, ...)
#   (the abbreviated topk join clause is a double label_replace on
#   kubevirt_vmi_info{phase='running'} -- full text in vms.go; abbreviated
#   here for readability, semantics unchanged)
#
# Recording rules used (verified, pkg/monitoring/rules/recordingrules/vmi.go):
#   vmi:kubevirt_vmi_memory_headroom_ratio:sum =
#       sum(kubevirt_vmi_memory_usable_bytes) / sum(kubevirt_vmi_memory_available_bytes)
#   vmi:kubevirt_vmi_pgmajfaults:rate5m = sum(rate(kubevirt_vmi_memory_pgmajfault_total[5m]))
#   vmi:kubevirt_vmi_swap_traffic_bytes:rate5m =
#       sum(rate(kubevirt_vmi_memory_swap_in_traffic_bytes[5m]))
#     + sum(rate(kubevirt_vmi_memory_swap_out_traffic_bytes[5m]))
#
# *** PREREQUISITE CORRECTION (hard rule 6 in the brief only listed 3 known
# prerequisites -- QEMU guest agent, schedstats=enable, psi=1. This recipe's
# metrics need a 4th, DIFFERENT one that isn't any of those three): ***
#   kubevirt_vmi_memory_available_bytes / _usable_bytes / _pgmajfault_total /
#   _swap_in_traffic_bytes / _swap_out_traffic_bytes are all sourced from the
#   libvirt/QEMU MEMORY BALLOON DEVICE's extended stats (virtio-balloon guest
#   kernel driver + a libvirt <stats period='...'/> poll), NOT from
#   qemu-guest-agent. Confirmed against the metric descriptions themselves
#   (kubevirt.io/monitoring/metrics.html): e.g. kubevirt_vmi_memory_usable_bytes
#   = "amount of memory which can be reclaimed by balloon...". None of the
#   guest-memory metric descriptions carry the "Requires qemu-guest-agent"
#   note that kubevirt_vmi_guest_load_1m/5m/15m explicitly do.
#   Requirement instead: the VM must NOT set
#   spec.domain.devices.autoattachMemBalloon: false (it defaults to true /
#   attached), and the guest kernel needs the virtio_balloon driver loaded
#   (default on any stock Linux cloud image -- Fedora/CentOS Stream/RHEL all
#   ship it). No guest agent install, no kernel arg, no MachineConfig needed
#   for this specific recipe.
# =============================================================================
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-memory-pressure
  namespace: demo-vms          # <- match your Act 1 namespace
  labels:
    demo.act2/recipe: "c-memorypressure"
spec:
  running: true
  template:
    metadata:
      labels:
        demo.act2/recipe: "c-memorypressure"
    spec:
      domain:
        cpu:
          cores: 2
        resources:
          requests:
            memory: 512Mi
          limits:
            memory: 512Mi        # tight ceiling: the hog will exceed usable
                                  # headroom quickly once the guest has swap
        devices:
          disks:
            - name: rootdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
          # autoattachMemBalloon defaults to true -- do NOT set it false here,
          # or kubevirt_vmi_memory_usable_bytes/available_bytes stop reporting
          # and this whole alert silently never fires (no error, just no data).
      volumes:
        - name: rootdisk
          containerDisk:
            image: quay.io/containerdisks/fedora:latest   # swap for your golden image
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              # stress-ng and an in-guest swapfile are what make pgmajfaults/
              # swap-traffic actually move -- without guest swap configured,
              # a hog just gets OOM-killed by the guest kernel with no
              # sustained swap I/O, and KubeVirtVMGuestMemoryPressure's
              # condition (which needs pgmajfaults>5/s OR swap>1MiB/s) may
              # never trip even though the VM is clearly starved.
              packages:
                - stress-ng
              runcmd:
                - fallocate -l 256M /swapfile
                - chmod 600 /swapfile
                - mkswap /swapfile
                - swapon /swapfile
                - echo '/swapfile none swap sw 0 0' >> /etc/fstab

---
# Apply, then wait for boot + cloud-init:
#   oc apply -f act2-04-recipe-c-memory-pressure-vm.yaml
#   oc wait vmi/vm-memory-pressure -n demo-vms --for=jsonpath='{.status.phase}'=Running --timeout=180s
#   (give cloud-init another ~60-90s to install stress-ng and set up swap)
#
# Then run act2-05-memory-pressure-driver.sh to start the hog and watch the
# recording rules move in real time.
```

### act2-06-korrel8r-custom-rule-fallback.yaml (excerpt) (yaml)
*Prerequisites:* Only if act2-01-korrel8r-verify.sh reports missing rules. Requires cluster-admin to patch the operator-managed korrel8r ConfigMap/Deployment -- explicitly unsupported and will be reconciled away.

Real upstream YAML rule syntax -- I diffed the on-disk file's AlertToVMI and VmiToPod rules character-for-character against korrel8r/korrel8r @ etc/korrel8r/rules/_samples/kubevirt.yaml and they match exactly, not invented. The TroubleshootingPanel UIPlugin CR has no field for custom rules (verified: only .spec.timeout and .spec.enableAgentNavigation exist in rhobs/observability-operator @ pkg/apis/uiplugin/v1alpha1/types.go). No changes required.

```yaml
rules:
  - name: AlertToVMI
    start:
      domain: alert
    goal:
      domain: k8s
      classes: [VirtualMachineInstance.kubevirt.io]
    result:
      query: |-
        k8s:VirtualMachineInstance.kubevirt.io:{"namespace":"{{index .Labels "namespace" | required}}","name":"{{index .Labels "name" | required}}"}

  - name: VmiToPod
    start:
      domain: k8s
      classes: [VirtualMachineInstance.kubevirt.io]
    goal:
      domain: k8s
      classes: [Pod]
    result:
      query: |-
        k8s:Pod:{"namespace":"{{.metadata.namespace}}","labels":{"vm.kubevirt.io/name":"{{.metadata.name}}","kubevirt.io":"virt-launcher"}}
```

