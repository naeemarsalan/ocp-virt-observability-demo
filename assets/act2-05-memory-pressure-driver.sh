#!/usr/bin/env bash
# =============================================================================
# act2-05-memory-pressure-driver.sh -- companion to recipe (c). Starts the
# in-guest memory hog and polls the exact recording rules
# KubeVirtVMGuestMemoryPressure's expr depends on, so you can narrate the
# numbers moving in a terminal pane while the alert transitions
# Inactive -> Pending -> Firing on screen in Observe > Alerting.
#
# Style matches migration-beat.sh (Act 1) for a consistent live-demo feel.
#
# Usage:
#   oc login ...
#   NAMESPACE=demo-vms VM=vm-memory-pressure ./act2-05-memory-pressure-driver.sh
# =============================================================================
set -uo pipefail

NAMESPACE="${NAMESPACE:?set NAMESPACE}"
VM="${VM:?set VM}"
POLL_SECS="${POLL_SECS:-15}"

THANOS_ROUTE=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)
TOKEN=$(oc whoami -t 2>/dev/null)

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
echo " ACT 2(c) -- MEMORY PRESSURE BEAT: ${NAMESPACE}/${VM}"
echo "=============================================================================="
echo
echo "Step 1 -- start the hog inside the guest (via virtctl console, since this"
echo "is a demo VM with no external SSH assumed):"
echo "  \$ virtctl console ${VM} -n ${NAMESPACE}"
echo "  (inside the guest, as root/sudo:)"
echo "  \$ stress-ng --vm 2 --vm-bytes 90% --vm-keep --timeout 600s &"
echo "  Ctrl+] to detach the console without stopping the VM."
read -r -p "Press Enter once stress-ng is running in the guest ... "

echo
echo "Step 2 -- poll the exact recording rules the alert expr reads, every ${POLL_SECS}s."
echo "Watch vmi:kubevirt_vmi_memory_headroom_ratio:sum fall below 0.05 AND"
echo "either the pgmajfaults or swap-traffic rate climb -- that combination is"
echo "the alert's condition."
echo "(Ctrl+C to stop polling; the hog keeps running in the guest until its"
echo "600s timeout or you kill it.)"
echo

while true; do
  echo "---- $(date +%H:%M:%S) ----"
  echo "headroom ratio (fires below 0.05):"
  q_instant "vmi:kubevirt_vmi_memory_headroom_ratio:sum{namespace=\"${NAMESPACE}\",name=\"${VM}\"}"
  echo "major page faults / 5m rate (fires above 5):"
  q_instant "vmi:kubevirt_vmi_pgmajfaults:rate5m{namespace=\"${NAMESPACE}\",name=\"${VM}\"}"
  echo "swap traffic bytes / 5m rate (fires above 1048576 = 1MiB/s):"
  q_instant "vmi:kubevirt_vmi_swap_traffic_bytes:rate5m{namespace=\"${NAMESPACE}\",name=\"${VM}\"}"
  echo "current ALERTS state for KubeVirtVMGuestMemoryPressure on this VM:"
  q_instant "ALERTS{alertname=\"KubeVirtVMGuestMemoryPressure\",namespace=\"${NAMESPACE}\"}"
  echo
  sleep "$POLL_SECS"
done
