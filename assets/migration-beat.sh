#!/usr/bin/env bash
# =============================================================================
# migration-beat.sh -- terminal-side companion to Act 1(c), the live migration
# beat. Run this in a second terminal/pane while the Grafana or Perses
# dashboard (row D) is on screen, so the audience sees the SAME numbers in
# both a dashboard and a plain PromQL query -- reinforcing "it's just an open
# store, query it however you want."
#
# Usage:
#   oc login ...
#   NAMESPACE=<ns> VM=<vm> ./migration-beat.sh
#
# Prerequisite: run preflight.sh first and confirm VMI LiveMigratable=True.
# =============================================================================
set -uo pipefail

NAMESPACE="${NAMESPACE:?set NAMESPACE}"
VM="${VM:?set VM}"
POLL_SECS="${POLL_SECS:-3}"

THANOS_ROUTE=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)
TOKEN=$(oc whoami -t 2>/dev/null)
if [[ -z "$THANOS_ROUTE" || -z "$TOKEN" ]]; then
  echo "Could not resolve thanos-querier route or auth token -- check 'oc login' and that" >&2
  echo "openshift-monitoring/thanos-querier route exists. Falling back to dashboard-only mode." >&2
fi

q_instant() {
  local promql="$1"
  curl -sk -H "Authorization: Bearer ${TOKEN}" \
    "https://${THANOS_ROUTE}/api/v1/query" --data-urlencode "query=${promql}" \
    | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    r = d.get("data", {}).get("result", [])
    if not r:
        print("  (no data yet)")
    for item in r:
        labels = {k: v for k, v in item["metric"].items() if k not in ("__name__",)}
        val = item["value"][1]
        print(f"  {labels}: {val}")
except Exception as e:
    print("  (query error:", e, ")")
'
}

echo "=============================================================================="
echo " ACT 1(c) -- LIVE MIGRATION BEAT: ${NAMESPACE}/${VM}"
echo "=============================================================================="
echo
echo "Step 1 -- confirm the VM is migratable (should already be checked by preflight.sh):"
oc get vmi "$VM" -n "$NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null | python3 -m json.tool 2>/dev/null || true
echo

echo "Step 2 -- trigger the migration:"
echo "  \$ virtctl migrate ${VM} -n ${NAMESPACE}"
read -r -p "Press Enter to actually run this now (or Ctrl+C to abort) ... "
if command -v virtctl >/dev/null 2>&1; then
  virtctl migrate "$VM" -n "$NAMESPACE"
else
  echo "virtctl not found -- falling back to a VirtualMachineInstanceMigration object:"
  oc create -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  generateName: ${VM}-migration-
  namespace: ${NAMESPACE}
spec:
  vmiName: ${VM}
EOF
fi

echo
echo "Step 3 -- poll the live migration series every ${POLL_SECS}s until the migration completes."
echo "          (Ctrl+C to stop polling; the migration itself keeps running.)"
echo

while true; do
  clear
  echo "== migration_data_processed_bytes / migration_data_remaining_bytes =="
  q_instant "kubevirt_vmi_migration_data_processed_bytes{namespace=\"${NAMESPACE}\", name=\"${VM}\"}"
  q_instant "kubevirt_vmi_migration_data_remaining_bytes{namespace=\"${NAMESPACE}\", name=\"${VM}\"}"
  echo
  echo "== migration_memory_transfer_rate_bytes =="
  q_instant "kubevirt_vmi_migration_memory_transfer_rate_bytes{namespace=\"${NAMESPACE}\", name=\"${VM}\"}"
  echo
  echo "== migrations_in_pending/scheduling/running_phase (cluster-wide queue) =="
  q_instant "kubevirt_vmi_migrations_in_pending_phase"
  q_instant "kubevirt_vmi_migrations_in_scheduling_phase"
  q_instant "kubevirt_vmi_migrations_in_running_phase"
  echo
  echo "== migration_succeeded / migration_failed (0/1 gauges) =="
  q_instant "kubevirt_vmi_migration_succeeded{namespace=\"${NAMESPACE}\", name=\"${VM}\"}"
  q_instant "kubevirt_vmi_migration_failed{namespace=\"${NAMESPACE}\", name=\"${VM}\"}"
  echo
  echo "== ⚠ dirty-memory rate -- KNOWN BUG CNV-94992, trend only, never quote the number =="
  q_instant "kubevirt_vmi_migration_dirty_memory_rate_bytes{namespace=\"${NAMESPACE}\", name=\"${VM}\"}"
  echo
  echo "(polling every ${POLL_SECS}s -- Ctrl+C to stop)"
  sleep "$POLL_SECS"
done
