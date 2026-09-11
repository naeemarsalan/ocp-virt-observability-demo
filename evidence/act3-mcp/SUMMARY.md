# Act 3 -- Korrel8r MCP interface, exercised with plain curl (no LLM)

Status flag: everything against **upstream korrel8r 0.12.1** below is **experimental** -- it is
not the GA Cluster Observability Operator (COO) build shipped with OCP 4.20 / OpenShift
Virtualization 4.20. It is a separately-deployed instance running at the route captured in
`../korrel8r-0.12/route.txt`. Section 6 below shows the **GA COO 1.5.2 image (korrel8r 0.11.1)**
also answers MCP requests at `/mcp`, but its rule set does not include the Alert->VirtualMachineInstance
correlation, so the same MCP request that walks Alert -> VMI -> Pod -> logs/metrics on the upstream
build stalls at Alert -> metric on the GA build.

All requests below are plain `curl` with JSON-RPC 2.0 bodies over the MCP "streamable HTTP"
transport. No model, no agent framework, no korrel8r-specific client library -- just HTTP.

## 1. What was run

| # | Step | Files |
|---|------|-------|
| 1 | `initialize` (protocolVersion 2025-03-26) | `01-initialize-request.json`, `01-initialize-headers.txt`, `01-initialize-response.{raw,json,pretty.json}` |
| 2 | `notifications/initialized` | `02-notifications-initialized-request.json`, `02-notifications-initialized-headers.txt`, `02-notifications-initialized-response.raw` |
| 3 | `tools/list` | `03-tools-list-request.json`, `03-tools-list-response.{raw,json,pretty.json}` |
| 4 | `tools/call list_domains` | `04-tools-call-list_domains-*` |
| 5 | `tools/call create_goals_graph` (Alert -> VMI/Pod/log/metric) | `05-tools-call-create_goals_graph-*` |
| 6 | `tools/call get_objects` (the Pod query the graph in step 5 returned) | `06-tools-call-get_objects-pod-*` |
| 7 | `tools/call get_objects` (the log query, limit 5) | `07-tools-call-get_objects-logs-*` |
| 8 | local CLI: `korrel8r mcp --help`, `korrel8r web --help \| grep -i mcp`, `korrel8r version` | `08-korrel8r-*` |
| 9-11 | same `initialize` / `create_goals_graph` sequence run against the **GA 0.11.1** korrel8r pod, for contrast | `09-coo-0.11.1-*`, `10-coo-0.11.1-*`, `11-coo-0.11.1-*` |

Session mechanics: the `initialize` response returned HTTP header `mcp-session-id:
ABQ6F3QAFONIPTAEICRME2BH4V` (saved in `01-initialize-headers.txt` and `session-id.txt`); every
call after that carried `Mcp-Session-Id: ABQ6F3QAFONIPTAEICRME2BH4V`. All responses came back as
SSE (`event: message` / `data: {...}` on `content-type: text/event-stream`), so each `.raw` file
holds the wire bytes and each `.json`/`.pretty.json` file holds the `data:` line extracted and
pretty-printed with `python3 -m json.tool`.

## 2. `initialize`

Route: `https://<cluster-domain>/mcp`

Request (`01-initialize-request.json`):
```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"curl-evidence","version":"1"}}}
```

Response `result.serverInfo` (`01-initialize-response.pretty.json`):

| field | value |
|---|---|
| name | korrel8r |
| title | Korrel8r MCP Server |
| version | 0.12.1 |
| protocolVersion | 2025-03-26 |

The server also returned a free-text `instructions` field telling an agent how to use the tools
(list_domains -> help -> create_goals_graph / create_neighbors_graph), i.e. the MCP server documents
its own workflow.

## 3. `tools/list` -- 8 tools, as expected

From `03-tools-list-response.pretty.json`, tool names in the order returned:

1. `create_goals_graph`
2. `create_neighbors_graph`
3. `get_console`
4. `get_objects`
5. `help`
6. `list_domain_classes`
7. `list_domains`
8. `show_in_console`

All 8 expected tools are present. Two schemas worth recording exactly (full text in the pretty
JSON file):

- **`create_goals_graph`**: `{start: {queries: [string], class?, objects?, constraint?}, goals: [string]}` -- `goals` and `start` are both required, `additionalProperties:false`.
- **`get_objects`**: `{query: string, constraint?: {limit, start, end, queryLimit}}` -- `query` required.

## 4. `tools/call list_domains`

8 domains reported, each with its backing store address (`04-tools-call-list_domains-response.pretty.json`):

| domain | description | store reachable? |
|---|---|---|
| alert | Prometheus/AlertManager alerts | alertmanager-main + thanos-querier svc |
| incident | cluster health incidents | (no store configured) |
| k8s | Kubernetes resources | in-cluster API |
| log | application/infra/audit logs | logging-loki-gateway-http svc |
| metric | Prometheus metrics | thanos-querier svc |
| mock | mock domain | (no store) |
| netflow | network flow data | loki-gateway-http.netobserv svc, **but store reports `403 Forbidden ... You don't have permission to access this tenant`** |
| trace | OpenTelemetry traces | tempo-platform-gateway svc |

The netflow 403 is the server self-reporting its own store health, not an error from this
evidence run -- it's in `structuredContent.domains[].stores[].error`.

## 5. `tools/call create_goals_graph` -- Alert -> VMI/Pod/log/metric, real rule traversal

Request (`05-tools-call-create_goals_graph-request.json`):
```json
{"start":{"queries":["alert:alert:{\"alertname\":\"VMCannotBeEvicted\",\"namespace\":\"demo-vms\",\"name\":\"vm-non-migratable\"}"]},
 "goals":["k8s:VirtualMachineInstance.v1.kubevirt.io","k8s:Pod.v1","log:application","metric:metric"]}
```

Nodes returned (`05-tools-call-create_goals_graph-response.pretty.json`), i.e. the classes the
rule graph actually reached starting from the single firing `VMCannotBeEvicted` alert on
`vm-non-migratable`:

| class | count | representative query |
|---|---|---|
| alert:alert | 1 | the starting alert itself |
| k8s:VirtualMachineInstance.v1.kubevirt.io | 1 | `k8s:VirtualMachineInstance.v1.kubevirt.io:{"namespace":"demo-vms","name":"vm-non-migratable"}` |
| k8s:VirtualMachine.v1.kubevirt.io | 1 | `k8s:VirtualMachine.v1.kubevirt.io:{"namespace":"demo-vms","name":"vm-non-migratable"}` |
| k8s:Pod.v1 | 1 | `k8s:Pod.v1:{"namespace":"demo-vms","labels":{"kubevirt.io":"virt-launcher","vm.kubevirt.io/name":"vm-non-migratable"}}` |
| metric:metric | 296 | 3 queries: the alert's own PromQL expr (100 series), pod-scoped metrics (100), VM-name-scoped metrics (96) |
| log:application | 200 | 2 queries: label-selector on the virt-launcher pod (100 lines) and name-scoped on the exact pod (100 lines) |

Edges show the actual rule path: `alert:alert -> k8s:VirtualMachineInstance.v1.kubevirt.io ->
k8s:Pod.v1 -> log:application`, plus `alert:alert -> k8s:VirtualMachine.v1.kubevirt.io` and
`... -> metric:metric`. This is the correlation graph, not a keyword search -- every node came with
the concrete backend query and result count that produced it.

## 6. `tools/call get_objects` -- turning graph queries into real objects

**Pod** (query taken verbatim from the `k8s:Pod.v1` node in step 5):
```
k8s:Pod.v1:{"namespace":"demo-vms","labels":{"kubevirt.io":"virt-launcher","vm.kubevirt.io/name":"vm-non-migratable"}}
```
-> 1 object returned: pod `virt-launcher-vm-non-migratable-xrsp6`, namespace `demo-vms`, phase `Running`
(`06-tools-call-get_objects-pod-response.pretty.json`, full pod spec/status, 924 lines pretty-printed).

**Logs** (query taken from the `log:application` node in step 5, `constraint.limit=5`):
```
log:application:{"namespace":"demo-vms","labels":{"kubevirt.io":"virt-launcher","vm.kubevirt.io/name":"vm-non-migratable"}}
```
-> exactly 5 log lines returned (limit respected), newest first, e.g.
`2026-09-11T13:53:22.259Z ... "msg":"Polling command: [guest-fsfreeze-status]" ... "pos":"agent_poller.go:374"`
(`07-tools-call-get_objects-logs-response.pretty.json`).

## 7. Local CLI: the stdio transport (no HTTP at all)

```
$ korrel8r mcp --help
Run korrel8r as an MCP server communicating via stdin/stdout.
Allows korrel8r to be run as a sub-process by an MCP tool.
For a HTTP streaming server use the 'web' command with the '--mcp' flag.
```
(full output: `08-korrel8r-mcp-help.txt`)

```
$ korrel8r web --help | grep -i mcp
      --mcp   Enable MCP streamable HTTP protocol on /mcp (default true)
```
(`08-korrel8r-web-help-mcp-grep.txt`, full help in `08-korrel8r-web-help-full.txt`)

So the same korrel8r binary offers MCP two ways: `korrel8r mcp` for a local sub-process talking
JSON-RPC over stdin/stdout (the shape an IDE or a locally-spawned agent uses), and `korrel8r web
--mcp` (the default) for the streamable-HTTP `/mcp` endpoint this evidence run exercised over the
network. Local binary used for `--help`/`version` is `0.12.2-dev` (`08-korrel8r-version.txt`) --
close to but not identical to the deployed `0.12.1`; only used here to show the `mcp` subcommand
and `--mcp` flag exist, not to query the cluster.

## 8. GA COO 1.5.2 (korrel8r 0.11.1) also serves `/mcp` -- but without the Alert->VMI rule

The GA korrel8r pod (`korrel8r-6b57c46ccf-np6dp`, namespace
`openshift-cluster-observability-operator`, image
`korrel8r-rhel9@sha256:90cc7074...`, version `0.11.1` -- see
`../troubleshooting-panel/version.txt`) listens on `localhost:9443` inside its own pod. An
unauthenticated probe from inside the pod got `HTTP 401` (endpoint exists, needs a bearer
token); with `Authorization: Bearer $(oc whoami -t)` the identical `initialize` call this
evidence run used against 0.12.1 succeeds:

`serverInfo`: `{"name":"korrel8r","version":"0.11.1"}` (`09-coo-0.11.1-mcp-initialize-response.pretty.json`)

Running the **exact same** `create_goals_graph` request from section 5 (same alert query, same
four goal classes) against this 0.11.1 server:

| class | count (0.12.1, upstream) | count (0.11.1, GA COO) |
|---|---|---|
| alert:alert | 1 | 1 |
| metric:metric | 296 | 136 |
| k8s:VirtualMachineInstance.v1.kubevirt.io | 1 | **not reached** |
| k8s:VirtualMachine.v1.kubevirt.io | 1 | **not reached** |
| k8s:Pod.v1 | 1 | **not reached** |
| log:application | 200 | **not reached** |

(`11-coo-0.11.1-create_goals_graph-alert-to-vmi-response.pretty.json`) -- the 0.11.1 graph has only
two nodes, `alert:alert` and `metric:metric`; it never crosses into VMI/Pod/log space because the
`AlertToVMI` (and `VmiToLogs`) rules don't exist in that build's rule set. This matches the rule
inventory already captured in `../troubleshooting-panel/version.txt` and
`../verify/act2-01-korrel8r-verify.txt`, which lists `AlertToVMI`, `VmiToAlert`, `VmToAlert`,
`AlertToVM`, and `VmiToLogs` as `FAIL rule MISSING` on that same 0.11.1 pod -- this run reproduces
that gap live, through MCP, not just via the REST rule listing.

## 9. The one-line takeaway

**The agent walks the rule graph; it does not guess.** Every node in the `create_goals_graph`
response carries the literal backend query and result count that produced it -- an MCP client
(human, script, or LLM) never has to construct a PromQL expression, a LogQL query, or a label
selector by hand; it reads the graph korrel8r already computed from its declarative rule set and
asks `get_objects` for exactly the query a node names. On 0.12.1 that graph reaches from a firing
`VMCannotBeEvicted` alert all the way to the owning pod and its live logs in one call; on the GA
0.11.1 build the same request -- same MCP protocol, same tool, same arguments -- dead-ends at
`metric:metric` because the underlying rule to hop Alert->VMI isn't shipped yet.
