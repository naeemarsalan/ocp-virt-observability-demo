## Act 3 — Agentic: Natural Language Over Korrel8r

### How to present this act (read this before the room does)

Everything below runs against **upstream korrel8r's own MCP server** — a feature the korrel8r project has marked **Experimental since v0.10.0** — talking to the *same* in-cluster korrel8r Deployment that powered the Troubleshooting Panel in Act 2. It is not a Red Hat product you can buy today. Two things must stay explicit on screen and in the script:

1. Red Hat has stated it is **not productizing a standalone korrel8r MCP server**. What *is* on the roadmap is OpenShift Lightspeed talking to korrel8r from inside the console — targeted for **OCP 5.1** — and even that integration's agent-navigation feature-gate (`enableAgentNavigation`, on the `troubleshooting-panel` UIPlugin) is marked **Dev Preview, "subject to change without notice"** in korrel8r's own docs.
2. Present this act as **"this is where the correlation engine you just watched work in Act 2 is headed once an agent can drive it,"** never as a capability shipping in OpenShift Virtualization 4.20 today.

---

### 1. Setup — running korrel8r's MCP server

Two transports, both real, both documented upstream (`doc/content/docs/ai-agents.md`, `doc/content/docs/reference/mcp/index.md`). Run `preflight.sh` against the live cluster before touching either config — it resolves every cluster-specific value below and writes `resolved.env`; nothing here should be hand-typed on demo day.

**Transport A — stdio (korrel8r as a local subprocess)**

```
korrel8r --config /path/to/korrel8r-standalone-config.yaml mcp
```

```json
{
  "mcpServers": {
    "korrel8r": {
      "command": "korrel8r",
      "args": ["--config", "/path/to/korrel8r-standalone-config.yaml", "mcp"]
    }
  }
}
```

- Install the CLI with `go install github.com/korrel8r/korrel8r/cmd/korrel8r@latest` — the only method korrel8r's own getting-started doc documents. Better for rule-set parity: run the **exact container image the cluster is running** instead (`podman run … registry.redhat.io/cluster-observability-operator/korrel8r-rhel9:<tag>`), where `<tag>` comes from `preflight.sh` reading the live pod spec — this guarantees your standalone binary has the same KubeVirt rules as the in-cluster one, which matters because those rules are **not listed in COO's release notes**.
- Auth: korrel8r uses your current `oc`/`kubectl` login. No token handling in this mode.
- Config file: the "outside-cluster" template (`etc/korrel8r/openshift-route.yaml` upstream, saved here as `korrel8r-standalone-config.yaml`) — it resolves each store (Prometheus/Thanos, Alertmanager, LokiStack, NetObserv's Loki, Tempo) through its OpenShift **Route**, because a laptop subprocess has no in-cluster network path. A route that doesn't exist doesn't error — that domain just silently returns 0 results, same "silent blank" failure mode the base research flags for dashboard panels.

**Transport B — Streamable HTTP (against the COO-deployed korrel8r Service)**

```
korrel8r web --http :8080      # --mcp defaults true → serves /mcp ; --rest defaults true → serves /api/v1alpha1
```

```json
{
  "mcpServers": {
    "korrel8r": {
      "type": "streamable-http",
      "url": "<KORREL8R_URL>/mcp",
      "headers": { "Authorization": "Bearer <TOKEN>" }
    }
  }
}
```

- Expose the in-cluster Service either way:
  - `oc port-forward -n openshift-cluster-observability-operator svc/korrel8r <local-port>:<svc-port>` (fast, terminal must stay open)
  - `oc create route reencrypt --service=korrel8r -n openshift-cluster-observability-operator` (survives the terminal closing)
- **`<KORREL8R_URL>` and the exact service port are not hardcoded anywhere in this deliverable** — `preflight.sh` reads them live via `oc get svc korrel8r -n openshift-cluster-observability-operator` because the port was never confirmed against a reachable cluster and guessing it would violate the same "verify, don't assume" rule this whole deliverable is built on.
- Token: `export TOKEN=$(oc whoami -t)`. **Hard requirement from korrel8r's own docs: the bearer token and the console login must belong to the same OpenShift user** — this is what lets the agent and the console share a troubleshooting session.
- This mode also serves the plain REST API at `/api/v1alpha1` on the same listener — that's what Section 4's fallback hits.

Both configs are written out fully in `act3/mcp-config-stdio.json` and `act3/mcp-config-http.json`; the discovery script is `act3/preflight.sh`.

---

### 2. The 8 MCP tools — what an agent actually gets back

The one distinction that matters for everything after this: **the two graph tools return a map (classes, queries, counts, rule names) — they do not return content.** `get_objects` is the tool that returns actual data for the `k8s`, `log`, `netflow`, and `alert` domains. **The `metric` domain is the one documented exception: even `get_objects` on a `metric:metric` query never returns sample values, only the label set that identifies a series** — see the callout under Prompt 3. An agent that only ever called the graph tools would know *how many* logs exist and the *exact query* to fetch them, but not one log line; for metrics, even `get_objects` only tells you a series exists, not what it's doing.

| Tool | Input | Returns | Maturity |
|---|---|---|---|
| `list_domains` | — | Every domain korrel8r knows (`k8s`, `alert`, `log`, `metric`, `netflow`, `trace`, `incident`) and its configured store | Part of the Experimental MCP surface |
| `list_domain_classes` | `domain` | The class names inside one domain (e.g. `k8s` → `Pod`, `VirtualMachineInstance.kubevirt.io`, …) | Experimental |
| `help` | `domain` (optional) | Query-syntax documentation and examples for one or all domains — an agent is expected to call this before it improvises a query string | Experimental |
| `get_objects` | `query` ("domain:class:selector"), `constraint` (time range, result limit) | **The actual matching objects** for k8s/log/netflow/alert — self-contained JSON, every label/field included. **For `metric`, only a label set + fingerprint — no sample values, ever** (confirmed against korrel8r's own metric-domain docs and source: "Korrel8r only uses labels for correlation, it does not use sample values") | Experimental |
| `create_goals_graph` | `start` (queries/objects), `goals` (class names) | A graph of the classes reached walking from start to the goal classes — **each node carries a query string + a result count; each edge names the rule that connects it.** No object content. | Experimental |
| `create_neighbors_graph` | `start`, `depth` | Same node/edge/count shape, but explores outward N rule-hops with no fixed goal — for open-ended "what's related to this" questions | Experimental |
| `get_console` | — | What the human is currently looking at in the OpenShift console (a `view` query and/or an active `search`) — context for the agent, not a query result | **Dev Preview** — depends on the console's `enableAgentNavigation` feature-gate |
| `show_in_console` | `view`, `search` | Pushes a query back into the console so the human sees what the agent found, live | **Dev Preview** — same gate; requires agent and console session to authenticate as the same user |

Source, verbatim tool schemas: `korrel8r/doc/content/docs/reference/mcp/index.md`.

---

### 3. Three demo prompts

All three assume the alert **`KubeVirtVMIExcessiveMigrations`** is already firing on a VMI named `rhel9-erp-01` in namespace `vm-workloads` (real KubeVirt alert — confirmed against both `kubevirt/monitoring`'s runbooks and the identical `openshift/runbooks` copy: *"fires when a virtual machine instance (VMI) live migrates more than 12 times over a period of 24 hours... might indicate a problem in the cluster infrastructure, such as network disruptions or insufficient resources"*). That description is precisely why the third question in Prompt 1 (dropped flows) is a legitimate diagnostic step, not a non-sequitur.

#### Prompt 1 — reproduces Act 2's walk, in one sentence

> **"Why is `rhel9-erp-01` alerting? Show me its pod and the last 50 log lines. Were there any dropped network flows around the same time?"**

Tool-call sequence:

1. `create_goals_graph(start.queries=["alert:alert:{\"alertname\":\"KubeVirtVMIExcessiveMigrations\",\"namespace\":\"vm-workloads\",\"name\":\"rhel9-erp-01\"}"], goals=["k8s:Pod","log:application"])`
   → nodes: `alert:alert` (1) → **rule `AlertToVMI`** → `k8s:VirtualMachineInstance.kubevirt.io` (1) → **rule `VmiToPod`** → `k8s:Pod` (1, query already scoped to the `virt-launcher` pod) → **rule `VmiToLogs`** → `log:application` (N matches).
   **Netflow is deliberately left out of this graph call.** Korrel8r's compiled netflow rules (`pkg/rules/quickrules/netflow.qtpl`) only run *netflow → k8s* (`NetflowToSrcK8s`, `NetflowToDstK8s` — "which pod produced this flow"), not the reverse. There is no shipped *k8s → netflow* rule as of v0.12.1 — a `K8sSrcToNetflow`/`K8sDstToNetflow` name exists only in an upstream **sample** file (`etc/korrel8r/rules/_samples/netflow.yaml`) explicitly marked as superseded, which a stock config does not load (`rules/all.yaml` is now an empty placeholder — "all rules previously in YAML are now compiled into the binary"). Confirm on your actual build with `korrel8r rules --start k8s:Pod --goal netflow:network --long` before promising a graph-walk hop to netflow live. Step 4 below is how the netflow answer actually gets produced — the agent builds that query itself from the Pod's own namespace/name, the same way a human would.
2. `get_objects(query=<the k8s:Pod query from step 1>)` → the real Pod object: name, node, phase, restart count.
3. `get_objects(query=<the log:application query from step 1>, constraint={limit:50})` → the actual last 50 log lines.
4. `get_objects(query="netflow:network:{SrcK8S_Namespace=\"vm-workloads\", SrcK8S_Name=\"<pod-name>\"} | PktDropPackets > 0", constraint={start:<alert start - 15m>, end:<now>})` → real dropped-flow rows if any (`PktDropBytes`, `PktDropPackets`, `PktDropLatestDropCause` — confirmed field names, NetObserv `flows-format.adoc`). This is a query the agent constructs directly from what it already knows (the pod's namespace/name), not a graph-traversal hop.

**Expected answer shape:** *"`rhel9-erp-01` fired `KubeVirtVMIExcessiveMigrations` — the runbook flags this as either node resource pressure or network disruption. Its pod is `virt-launcher-rhel9-erp-01-<hash>` on `worker-3`. The last 50 log lines show [normal migration handoff / a libvirt error — whatever the live logs say]. Checking flows for that pod in the alert window: [either 'no drops — points away from network' or 'N dropped packets, cause `<cause>` — consistent with the runbook's network branch']. Path: AlertToVMI → VmiToPod → VmiToLogs (the netflow check is a direct query I built from the pod's identity, not a graph rule)."* — the agent should name the rules it walked, not just the conclusion, and should be honest about which parts came from a rule and which it constructed itself.

#### Prompt 2 — open-ended breadth (mirrors korrel8r's own example prompt: *"what is related to this pod? show me everything within 2 steps"*)

> **"What's related to `rhel9-erp-01`? Show me everything within two hops."**

Tool-call sequence:

1. `create_neighbors_graph(start.queries=["k8s:VirtualMachineInstance.kubevirt.io:{\"namespace\":\"vm-workloads\",\"name\":\"rhel9-erp-01\"}"], depth=2)`
   → depth-1 reaches, via real named rules off the VMI: `k8s:VirtualMachine` (owner — this hop rides k8s's generic ownerReference-following rule, not a KubeVirt-specific one, since a VMI's ownerReference to its VM is a standard Kubernetes reference), `k8s:Pod` (`VmiToPod`), `k8s:Node` (`VmiToNode`), `alert:alert` (`VmiToAlert`), `metric:metric` (`VmiToMetric`), `log:application`/`log:infrastructure` (`VmiToLogs`), `k8s:PersistentVolumeClaim` (`VmiToPVC`), `k8s:DataVolume` (`VmiToDataVolume`), `k8s:VirtualMachineInstanceMigration` (`VmiToVmim`), plus Secret/ConfigMap/ServiceAccount/NetworkAttachmentDefinition. Depth-2 adds a second `alert:alert` hit off the migration object (`VmimToAlert`), `k8s:PersistentVolume`/`k8s:StorageClass` off the PVC, and **only if your build's compiled rule set has a k8s→netflow direction — the upstream quickrules as of v0.12.1 do not — `netflow:network` off the Pod/Node.** Verify with `korrel8r rules --start k8s:Pod --goal netflow:network --long` before including that branch in the live answer; if it comes back empty, get netflow the way Prompt 1 step 4 does (a direct query, not a graph hop).

**Expected answer shape:** a **map**, not a dump — *"Owner VM (1) · Pod `virt-launcher-…` on `worker-3` (1) · 1 alert firing (`KubeVirtVMIExcessiveMigrations`) · boot PVC (1) · 3 migrations in 24h · [if the netflow rule direction is present on this build] ~2,100 src / ~600 dst netflow records in the last hour, 0 dropped · 46 metric series available (label sets confirmed to exist — not yet pulled). Want me to open any of these?"* — this is the tool contract made visible: `create_neighbors_graph` sizes up the neighborhood; nothing is fetched until `get_objects` is called on the one node worth opening (and for the metric node, `get_objects` still only confirms existence, not values — see Section 2).

Prerequisite callout for this prompt: the `metric:metric` node will only include `kubevirt_vmi_vcpu_wait_seconds_total` / `kubevirt_vmi_vcpu_delay_seconds_total` if the node's MachineConfig sets `schedstats=enable` (and `psi=1`), and only include `kubevirt_vmi_guest_load_1m/5m/15m` if qemu-guest-agent ≥ 10.0.0 is running in the guest — otherwise those series are simply absent from the count, with no error, matching the base report's blank-panel caveat.

#### Prompt 3 — targeted metric investigation, with an honest caveat the tool can't give you itself

> **"This VM's live-migration keeps re-triggering the excessive-migrations alert. Pull its migration metrics — is the memory dirty rate actually the problem?"**

Tool-call sequence:

1. `create_goals_graph(start.queries=["k8s:VirtualMachineInstance.kubevirt.io:{\"namespace\":\"vm-workloads\",\"name\":\"rhel9-erp-01\"}"], goals=["metric:metric"])` → `metric:metric` node (rule `VmiToMetric`), count = however many `kubevirt_vmi_migration_*` series exist for this VMI — a label match, not a values check.
2. `get_objects(query=<that metric:metric query, filtered to kubevirt_vmi_migration_dirty_memory_rate_bytes / kubevirt_vmi_migration_data_remaining_bytes / kubevirt_vmi_migration_memory_transfer_rate_bytes>)` → **confirms which of those three series exist for this VMI and their label sets. Nothing more.** Korrel8r's `metric` domain object is `{labels, fingerprint}` only (confirmed in `pkg/domains/metric/metric.go`); the domain's own docs say plainly: "Korrel8r only uses labels for correlation, it does not use sample values." No tool in this MCP surface returns a numeric time series — this is the one place the "get_objects returns actual data" rule from Section 2 does not hold.
3. To get the actual numbers, the agent has to step outside korrel8r: a direct PromQL range query against the cluster's Thanos-querier (via the console's Metrics tab, `oc exec` into the thanos-querier pod, or a separate Prometheus-aware tool if the agent has one) for those three metric names, scoped to `namespace="vm-workloads",name="rhel9-erp-01"`, over `[<migration start>, <migration end>]`. This is a deliberate, honest gap to narrate out loud: korrel8r tells you *what exists*, not *what the numbers are*, once you're in the metric domain.

**Expected answer shape:** the agent reports that `kubevirt_vmi_migration_dirty_memory_rate_bytes`, `kubevirt_vmi_migration_data_remaining_bytes`, and `kubevirt_vmi_migration_memory_transfer_rate_bytes` all exist for this VMI (via korrel8r), then reports the actual values from the follow-up Prometheus query (not from korrel8r) — and must be told, because korrel8r has no notion of open upstream bugs, that the dirty-rate telemetry carries a known accuracy issue: the research ledger names `kubevirt_vmi_migration_dirty_memory_rate_bytes` and the closely related `kubevirt_vmi_dirty_rate_bytes_per_second` in the same breath as off from ground truth by orders of magnitude (tracked as CNV-94992) — confirm which exact metric name the tracked bug covers on your build before citing a bug ID out loud, and treat either as directional only, leaning on `data_processed_bytes`/`data_remaining_bytes` for the actual convergence story. **Bake this into the demo deliberately** (a one-line system-prompt addendum, or the presenter saying it out loud) — it is exactly the kind of caveat that separates a grounded demo from a highlight reel, and it doubles as the honest segue to `kubevirt-metrics-exporter` (KME): an experimental, unsupported, opt-in component under active development specifically to replace today's averages with real per-migration/per-I/O latency histograms.

**The contrast statement to say out loud after all three:** *"The agent walks the rule graph — `AlertToVMI`, `VmiToPod`, `VmiToLogs`, `VmiToMetric` — named, versioned rules that shipped as YAML config in korrel8r v0.11.4 and compiled into the binary in v0.12.1. It does not guess a query string from a training-data pattern; every hop above is a real edge in a real graph, and you can print that graph yourself with `korrel8r rules`. (The netflow hops, when they're reachable at all on your build, ride a separate, non-KubeVirt rule set that today only runs one direction — verify with `korrel8r rules` rather than asserting a specific name live.)"*

---

### 4. Honest fallback — if MCP isn't available in the room

If the MCP transport is blocked (locked-down laptop, no egress, client config rejected), drop to the plain REST endpoint the `create_goals_graph` tool calls underneath — same walk, same rules, no agent narration:

```bash
curl -sk -X POST "${KORREL8R_URL}/api/v1alpha1/graphs/goals" \
  -H "Authorization: Bearer ${KORREL8R_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "start": {
      "queries": [
        "alert:alert:{\"alertname\":\"KubeVirtVMIExcessiveMigrations\",\"namespace\":\"vm-workloads\",\"name\":\"rhel9-erp-01\"}"
      ]
    },
    "goals": ["k8s:Pod", "log:application"]
  }'
```

The response's `nodes[]` array carries one entry per class reached (`.class`, `.count`, `.queries[].query`); `edges[]` carries the rule name(s) that connect each pair — this is where "the agent walks the rule graph" is visible even without an agent in the loop. Neither array contains actual Pod specs or log text — that needs a follow-up call per query string returned. The generated REST docs don't pin the exact query-string encoding for `GET /objects`'s `constraint` parameter, so rather than guess it live, the fallback script uses the documented, flag-based CLI equivalent instead: `korrel8r objects 'log:application:{"namespace":"vm-workloads","labels":{"kubevirt.io":"virt-launcher","vm.kubevirt.io/name":"rhel9-erp-01"}}' --limit 50 -o json-pretty` — both labels matter; `kubevirt.io=virt-launcher` alone matches every VM's launcher pod in the namespace, not just this one. Do **not** add `netflow:network` to the `goals` list above — korrel8r's compiled netflow rules run netflow→k8s only, not the reverse (see Prompt 1); get netflow rows via a direct query instead, as shown there. Full script with the response-reading guide and this same netflow caveat: `act3/korrel8r-goals-fallback.sh`.

---

### 5. What's GA today vs. what's roadmap

The correlation engine and its rule graph are real and GA: the Troubleshooting Panel (Korrel8r) has been GA since COO 1.3 on OCP 4.19+, and the KubeVirt-specific rules that make the alert→VMI→pod→logs walk work are already shipping upstream — though not yet called out in COO's own release notes, so the pinned image must be verified before every demo. (The netflow hop, when it's reachable at all, rides a separate, generic — not KubeVirt-specific — rule set that today only runs netflow→k8s; confirm direction with `korrel8r rules` before demoing it as a graph-walk step, see Section 3.) Everything in *this* act — an agent driving that same graph over natural language via MCP — sits one layer up and is explicitly **not** a shipping Red Hat capability: korrel8r's MCP server is an **Experimental** upstream feature (since v0.10.0) that Red Hat has said it will **not** productize as a standalone offering; the console-native version of this (Lightspeed asking korrel8r questions from inside the Troubleshooting Panel) is **Dev Preview** today and targeted for **OCP 5.1** on the roadmap. Demo it as direction, not delivery.

---

**Files under `.../scratchpad/demo/act3/`:** `mcp-config-stdio.json`, `mcp-config-http.json`, `korrel8r-standalone-config.yaml`, `preflight.sh` (live-cluster value discovery — run first), `korrel8r-goals-fallback.sh` (REST fallback, tested for shell syntax; both files' netflow comments corrected to reflect that the current compiled quickrules only run netflow→k8s, and the fallback's log-query label filter corrected to also scope by `vm.kubevirt.io/name` so it doesn't return every VM's virt-launcher logs in the namespace).


---

## Appendix: code items

### mcp-config-stdio.json — Claude Code/Desktop, stdio transport
*Prerequisites:* korrel8r CLI on PATH (go install github.com/korrel8r/korrel8r/cmd/korrel8r@latest, or run the exact container image the cluster uses — resolved by preflight.sh); an active `oc login` session; the config file pointed at the cluster's Routes.

No factual errors found — verified against korrel8r's doc/content/docs/ai-agents.md, which documents this exact JSON shape and confirms korrel8r uses current kubectl/oc credentials with no separate token handling in stdio mode. Full file: act3/mcp-config-stdio.json (checked with `jq`, valid JSON).

```json
{
  "mcpServers": {
    "korrel8r": {
      "command": "korrel8r",
      "args": [
        "--config", "/path/to/korrel8r-standalone-config.yaml",
        "mcp"
      ]
    }
  }
}
```

### mcp-config-http.json — Claude Code/Desktop, Streamable HTTP transport
*Prerequisites:* Run preflight.sh to resolve <KORREL8R_URL> (port-forward or Route host) and mint <OC_WHOAMI_T_TOKEN> via `oc whoami -t` for the SAME OpenShift user viewing the console. Tokens expire — remint right before the demo.

No factual errors found — the namespace (openshift-cluster-observability-operator), the 'same user' requirement, and the JSON shape all match korrel8r's ai-agents.md verbatim. Full file: act3/mcp-config-http.json (checked with `jq`, valid JSON).

```json
{
  "mcpServers": {
    "korrel8r": {
      "type": "streamable-http",
      "url": "<KORREL8R_URL>/mcp",
      "headers": {
        "Authorization": "Bearer <OC_WHOAMI_T_TOKEN>"
      }
    }
  }
}
```

### REST fallback — POST /api/v1alpha1/graphs/goals
*Prerequisites:* KORREL8R_URL and KORREL8R_TOKEN sourced from preflight.sh's resolved.env. Endpoint and body schema confirmed against korrel8r's own generated REST reference (doc/content/docs/reference/rest/index.md#postgraphsgoals) — verified directly, request/response shapes match exactly.

No factual errors found — this snippet's goals list ([k8s:Pod, log:application]) correctly omits netflow:network, avoiding the wrong-direction-rule issue found elsewhere in the deliverable's prose and in the fuller act3/korrel8r-goals-fallback.sh script. This is exactly what create_goals_graph calls server-side.

```bash
curl -sk -X POST "${KORREL8R_URL}/api/v1alpha1/graphs/goals" \
  -H "Authorization: Bearer ${KORREL8R_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "start": {
      "queries": [
        "alert:alert:{\"alertname\":\"KubeVirtVMIExcessiveMigrations\",\"namespace\":\"vm-workloads\",\"name\":\"rhel9-erp-01\"}"
      ]
    },
    "goals": ["k8s:Pod", "log:application"]
  }'
```

### korrel8r-standalone-config.yaml — headers only (full file in scratchpad)
*Prerequisites:* OpenShift Logging 6.x + LokiStack (GA) for the log/alert-lokiRuler stores; Network Observability operator + FlowCollector with lokiStorage (GA) for netflow; Tempo (optional) for trace.

Matches upstream etc/korrel8r/openshift-route.yaml closely (verified by fetching it directly) except this excerpt omits the upstream's `incident` domain block and `tuning:` section — both present in the full scratchpad copy, and the incident domain is unused by this act. The fuller scratchpad file (act3/korrel8r-standalone-config.yaml) had two bugs that were fixed in place: (1) its include-block comment named `K8sSrcToNetflow` as a compiled-in rule, which it is not (see the netflow-direction finding); (2) it told the presenter to run a nonexistent `korrel8r ... get domains kubevirt.io` command — corrected to the real `korrel8r rules --start ... --long`. Re-validated with `python3 -c "import yaml..."` after the fix — parses cleanly.

```yaml
stores:
  - domain: k8s
  - domain: alert
    metrics: 'https://{{k8sRouteHost "openshift-monitoring" "thanos-querier"}}'
    alertmanager: 'https://{{k8sRouteHost "openshift-monitoring" "alertmanager-main"}}'
    lokiRuler: 'https://{{k8sRouteHost "openshift-logging" "logging-loki"}}'
  - domain: log
    lokiStack: 'https://{{k8sRouteHost "openshift-logging" "logging-loki"}}'
    direct: true
  - domain: metric
    metric: 'https://{{k8sRouteHost "openshift-monitoring" "thanos-querier"}}'
  - domain: netflow
    lokiStack: 'https://{{k8sRouteHost "netobserv" "loki"}}'
  - domain: trace
    tempoStack: 'https://{{k8sRouteHost "openshift-tracing" "tempo-platform-gateway"}}/api/traces/v1/platform/tempo'
include:
  - rules/all.yaml
```

