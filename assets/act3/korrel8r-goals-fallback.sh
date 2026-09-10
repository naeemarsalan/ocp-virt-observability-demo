#!/usr/bin/env bash
# Honest fallback for Act 3 if the MCP transport is unavailable in the room (blocked egress,
# Claude Code/Desktop MCP config rejected by a locked-down laptop, etc). This calls the exact
# same REST endpoint the korrel8r MCP server's create_goals_graph tool calls underneath —
# nothing here is a lesser demo, it's the same rule-graph walk with the AI narration removed.
# Endpoint reference (fully confirmed, not inferred):
#   https://github.com/korrel8r/korrel8r/blob/main/doc/content/docs/reference/rest/index.md#postgraphsgoals
#
# Run preflight.sh FIRST and source resolved.env — do not hand-type KORREL8R_URL/TOKEN.
#   source ./resolved.env
#
# Requires: curl, jq (optional, for pretty output)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${KORREL8R_URL:?Run: source $HERE/resolved.env   (or export KORREL8R_URL manually, e.g. https://localhost:8443)}"
: "${KORREL8R_TOKEN:?Run: source $HERE/resolved.env   (or export KORREL8R_TOKEN=\$(oc whoami -t))}"

# --- Demo parameters — the only things you edit per-run -----------------------------------
ALERTNAME="${ALERTNAME:-KubeVirtVMIExcessiveMigrations}"   # real alert, see kubevirt/monitoring runbooks
VMI_NAMESPACE="${VMI_NAMESPACE:-vm-workloads}"
VMI_NAME="${VMI_NAME:-rhel9-erp-01}"
# ---------------------------------------------------------------------------------------------

# Task's literal ask: start = the firing alert, goals = k8s:Pod and log:application.
# This is the SAME two-hop walk the MCP create_goals_graph tool would run for
# "why is this VM alerting, and show me its pod and logs" — minus the netflow hop and
# minus the actual log content (that needs a follow-up GET /objects call, see the note
# at the bottom — the generated REST docs don't pin the exact query-string encoding for
# the `constraint` object, so don't guess it live; resolve it from `korrel8r web --spec -`
# against your build, or just use the `korrel8r objects` CLI shown below instead).
BODY=$(cat <<EOF
{
  "start": {
    "queries": [
      "alert:alert:{\"alertname\":\"${ALERTNAME}\",\"namespace\":\"${VMI_NAMESPACE}\",\"name\":\"${VMI_NAME}\"}"
    ]
  },
  "goals": ["k8s:Pod", "log:application"]
}
EOF
)

echo "POST ${KORREL8R_URL}/api/v1alpha1/graphs/goals"
echo "$BODY" | (command -v jq >/dev/null && jq . || cat)
echo

RESP=$(curl -sk -X POST "${KORREL8R_URL}/api/v1alpha1/graphs/goals" \
  -H "Authorization: Bearer ${KORREL8R_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$BODY")

echo "$RESP" | (command -v jq >/dev/null && jq . || cat)

# --- Reading the response -------------------------------------------------------------------
# nodes[]  = one per class reached (e.g. alert:alert, k8s:VirtualMachineInstance.kubevirt.io,
#            k8s:Pod, log:application) with .count = how many real objects matched and
#            .queries[].query = the ready-to-run query string for that class.
# edges[]  = the rule(s) that connected each pair of nodes — e.g. "AlertToVMI", "VmiToPod",
#            "VmiToLogs" — THIS is "the agent walks the rule graph, it does not guess": every
#            hop below is a named, versioned rule in korrel8r's config, not a heuristic guess.
# Neither nodes nor edges contain the actual Pod spec or log lines — this call answers
# "what's related, and how many", not "show me the content" (that's get_objects/GET /objects,
# same distinction the MCP tools make — see the MCP tool reference).

# --- Netflow: NOT a safe goal to add to the call above ---------------------------------------
# korrel8r's compiled netflow quickrules (pkg/rules/quickrules/netflow.qtpl) only run
# netflow -> k8s (NetflowToSrcK8s, NetflowToDstK8s, "which pod produced this flow"), not the
# reverse. There is no shipped k8s -> netflow rule as of v0.12.1 (a "K8sSrcToNetflow" rule
# name exists only in an upstream _samples/netflow.yaml file explicitly marked superseded,
# which is not loaded by a stock config). Adding "netflow:network" to goals above will most
# likely just come back with zero matches for that node, silently — not an error.
# Verify on your actual build before promising this live:
#   korrel8r --config korrel8r-standalone-config.yaml rules --start k8s:Pod --goal netflow:network --long
# If that returns nothing (expected on a stock build), get the netflow rows the same way the
# markdown's Prompt 1 step 4 does: build the query yourself from the Pod's own namespace/name
# (see below) rather than expecting a graph-walk hop to find them.

# --- Getting the actual objects (last 50 log lines, dropped-flow rows) -----------------------
# Take a query string out of the nodes[] response above and either:
#   (a) MCP-equivalent, once MCP is back: get_objects(query=<that string>, constraint={limit:50})
#   (b) CLI, needs no running web server at all — just store connectivity from wherever you run it:
#       korrel8r --config korrel8r-standalone-config.yaml objects \
#         'log:application:{"namespace":"'"${VMI_NAMESPACE}"'","labels":{"kubevirt.io":"virt-launcher","vm.kubevirt.io/name":"'"${VMI_NAME}"'"}}' \
#         --limit 50 -o json-pretty
#       (both labels are required — kubevirt.io=virt-launcher alone matches every VM's
#       launcher pod in the namespace, not just this one; VmiToLogs generates the query
#       with both labels for exactly this reason.)
#   (c) REST GET /objects exists (query=<string>&constraint=<object>) but the generated docs do
#       not pin how `constraint` is encoded in a query string — verify against
#       `korrel8r web --spec -` (dumps the live OpenAPI spec) before relying on it live;
#       (b) is the documented, flag-based alternative and is what this script recommends.
