#!/usr/bin/env bash
# Act 3 preflight — run this against the LIVE target cluster before rehearsing the demo.
# The cluster was not reachable while this deliverable was written, so nothing here is
# hand-guessed: every cluster-specific value (service port, image tag, route host, token)
# is resolved live and written to resolved.env. Re-run it the morning of the demo too —
# the bearer token expires and the port-forward will need restarting.
#
# Usage: ./preflight.sh   (needs: oc CLI logged in as the demo user, jq optional)

set -uo pipefail
NS_COO="${NS_COO:-openshift-cluster-observability-operator}"
NS_LOGGING="${NS_LOGGING:-openshift-logging}"
NS_NETOBSERV="${NS_NETOBSERV:-netobserv}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/resolved.env"
LOCAL_PORT="${LOCAL_PORT:-8443}"

fail=0
say() { echo; echo "== $* =="; }

say "0. oc login"
if ! oc whoami >/dev/null 2>&1; then
  echo "FAIL: not logged in. Run: oc login <cluster-api-url>"; exit 1
fi
CURRENT_USER=$(oc whoami)
echo "Logged in as: $CURRENT_USER  (this MUST be the same user shown in the console during the demo — korrel8r's console-navigation session is keyed on identity, see ai-agents.md)"

say "1. Cluster Observability Operator installed, at target version?"
oc get csv -n "$NS_COO" -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null | grep -i observability \
  || { echo "WARNING: no COO CSV found in $NS_COO — is it installed in this namespace?"; fail=1; }
echo "Target for this deliverable: COO 1.5+ (Perses GA). Confirm the installed version matches — Korrel8r's"
echo "compiled-in KubeVirt rules only exist from the image that ships with COO builds using korrel8r >= v0.12.1,"
echo "and this is NOT called out in the COO release notes (verify, don't assume — see step 3)."

say "2. troubleshooting-panel UIPlugin present and console-navigation state"
if oc get uiplugin troubleshooting-panel -o yaml >/tmp/tsp-uiplugin.yaml 2>/dev/null; then
  grep -A3 'troubleshootingPanel:' /tmp/tsp-uiplugin.yaml || true
  grep -q 'enableAgentNavigation: true' /tmp/tsp-uiplugin.yaml \
    && echo "enableAgentNavigation: true — Dev Preview console-chat integration is ON." \
    || echo "enableAgentNavigation is NOT set (or false) — fine for the standalone-MCP demo in this deliverable;"
  echo "only needed if you also want to demo the in-console AI icon (get_console/show_in_console live in the UI)."
else
  echo "WARNING: troubleshooting-panel UIPlugin not found. Act 2's console panel and the get_console/"
  echo "show_in_console MCP tools in this Act 3 deliverable both depend on it."
  fail=1
fi

say "3. Exact korrel8r image + rule set actually running in-cluster"
KORREL8R_POD=$(oc get pod -n "$NS_COO" -l app.kubernetes.io/name=korrel8r -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "${KORREL8R_POD:-}" ]; then
  echo "WARNING: no pod labeled app.kubernetes.io/name=korrel8r in $NS_COO."
  echo "List pods manually and adjust the label selector in this script: oc get pods -n $NS_COO"
  fail=1
else
  KORREL8R_IMAGE=$(oc get pod "$KORREL8R_POD" -n "$NS_COO" -o jsonpath='{.spec.containers[0].image}')
  echo "korrel8r pod: $KORREL8R_POD"
  echo "korrel8r image: $KORREL8R_IMAGE"
  echo "Rule-set smoke test — grep startup logs for KubeVirt rule registration:"
  oc logs "$KORREL8R_POD" -n "$NS_COO" 2>/dev/null | grep -i -m5 kubevirt \
    && echo "  -> found kubevirt references in the log, good sign." \
    || echo "  -> nothing matched. Not conclusive (rules may not log by name at INFO level) —"
  echo "     confirm for real with: oc exec $KORREL8R_POD -n $NS_COO -- korrel8r rules 2>/dev/null | grep -i vmi"
  echo "     (see korrel8r-standalone-config.yaml header for why this matters — report Section 2.3 caveat.)"
fi

say "4. korrel8r Service + port"
KORREL8R_SVC=$(oc get svc -n "$NS_COO" -l app.kubernetes.io/name=korrel8r -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
KORREL8R_SVC="${KORREL8R_SVC:-korrel8r}"
KORREL8R_PORT=$(oc get svc "$KORREL8R_SVC" -n "$NS_COO" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
if [ -z "${KORREL8R_PORT:-}" ]; then
  echo "WARNING: could not read a port from svc/$KORREL8R_SVC in $NS_COO. Inspect manually:"
  echo "  oc get svc -n $NS_COO"
  fail=1
else
  echo "Service: $KORREL8R_SVC   Port: $KORREL8R_PORT"
fi

say "5a. Expose it — port-forward (fastest, terminal must stay open through the demo)"
echo "Run in a separate terminal, leave it running:"
echo "  oc port-forward -n $NS_COO svc/$KORREL8R_SVC ${LOCAL_PORT}:${KORREL8R_PORT:-<PORT-FROM-STEP-4>}"
KORREL8R_URL_PF="https://localhost:${LOCAL_PORT}"

say "5b. Expose it — reencrypt Route (survives terminal closing; needs router/DNS access)"
echo "  oc create route reencrypt --service=$KORREL8R_SVC -n $NS_COO 2>/dev/null || echo 'route may already exist'"
ROUTE_HOST=$(oc get route korrel8r -n "$NS_COO" -o jsonpath='{.spec.host}' 2>/dev/null)
if [ -n "${ROUTE_HOST:-}" ]; then
  echo "Route host: https://$ROUTE_HOST"
else
  echo "No route named 'korrel8r' found/created yet. Create one (command above) then re-run this script."
fi

say "6. Bearer token (same user as the console session)"
TOKEN=$(oc whoami -t 2>/dev/null)
if [ -z "${TOKEN:-}" ]; then
  echo "WARNING: could not get a token via 'oc whoami -t' (some auth methods don't support it)."
  fail=1
else
  echo "Token acquired for $CURRENT_USER. Tokens are short-lived — regenerate right before the demo, not the night before."
fi

say "7. Reachability + REST domain-list smoke test (needs the port-forward from 5a running)"
if [ -n "${TOKEN:-}" ]; then
  if curl -sk -m 5 -H "Authorization: Bearer $TOKEN" "$KORREL8R_URL_PF/api/v1alpha1/domains" -o /tmp/korrel8r-domains.json 2>/dev/null \
     && [ -s /tmp/korrel8r-domains.json ]; then
    echo "Reached $KORREL8R_URL_PF. Domains response saved to /tmp/korrel8r-domains.json:"
    cat /tmp/korrel8r-domains.json
    echo
    echo "Confirm log, netflow, alert, and kubevirt-bearing k8s objects all show non-empty stores before the demo."
  else
    echo "Could not reach $KORREL8R_URL_PF yet. Start the port-forward from step 5a in another terminal, then:"
    echo "  curl -sk -H \"Authorization: Bearer \$KORREL8R_TOKEN\" \"\$KORREL8R_URL/api/v1alpha1/domains\""
  fi
fi

cat > "$OUT" <<EOF
# Generated by preflight.sh on $(date -u +%FT%TZ) for cluster user: $CURRENT_USER
# DO NOT COMMIT — contains a live bearer token. Source before using korrel8r-goals-fallback.sh
# or before hand-filling mcp-config-http.json.
export KORREL8R_URL="${KORREL8R_URL_PF}"
export KORREL8R_ROUTE_URL="https://${ROUTE_HOST:-NOT-CREATED}"
export KORREL8R_TOKEN="${TOKEN:-}"
export KORREL8R_NAMESPACE="${NS_COO}"
export KORREL8R_SERVICE="${KORREL8R_SVC}"
export KORREL8R_SERVICE_PORT="${KORREL8R_PORT:-}"
export KORREL8R_IMAGE="${KORREL8R_IMAGE:-}"
EOF

say "Done"
echo "Wrote $OUT"
[ "$fail" -eq 1 ] && echo "One or more checks above need attention before this demo is safe to run live." || echo "All checks passed."
exit 0
