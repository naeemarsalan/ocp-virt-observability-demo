#!/usr/bin/env bash
# =============================================================================
# act2-07-reset.sh -- reset ALL three Act 2 triggers back to a clean state.
# Safe to run between rehearsals or after the live demo. Idempotent --
# missing objects are ignored.
#
# Usage:
#   NAMESPACE=demo-vms HCO_NS=openshift-cnv HCO_NAME=kubevirt-hyperconverged ./act2-07-reset.sh
# =============================================================================
set -uo pipefail

# --- HCO API-version-aware patch helper -------------------------------------
# hco.kubevirt.io serves TWO layouts (verified in kubevirt/hyperconverged-cluster-operator):
#   v1beta1 : spec.workloadUpdateStrategy                 (top-level; Red Hat docs 4.9-4.21)
#   v1      : spec.virtualization.workloadUpdateStrategy  (nested)
# Patching the wrong layout is silently pruned by the API server, so detect
# which version the cluster PREFERS and target it explicitly.
hco_patch_wum() {   # usage: hco_patch_wum '["LiveMigrate"]'  |  hco_patch_wum '[]'
  local methods="$1"
  local api
  api=$(oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" -o jsonpath='{.apiVersion}' 2>/dev/null)
  case "$api" in
    hco.kubevirt.io/v1)
      oc patch hyperconverged.v1.hco.kubevirt.io "$HCO_NAME" -n "$HCO_NS" --type=merge \
        -p "{\"spec\":{\"virtualization\":{\"workloadUpdateStrategy\":{\"workloadUpdateMethods\":${methods}}}}}" ;;
    hco.kubevirt.io/v1beta1)
      oc patch hyperconverged.v1beta1.hco.kubevirt.io "$HCO_NAME" -n "$HCO_NS" --type=merge \
        -p "{\"spec\":{\"workloadUpdateStrategy\":{\"workloadUpdateMethods\":${methods}}}}" ;;
    *)
      echo "ERROR: could not determine HyperConverged apiVersion (got '${api}'); is oc logged in and HCO installed in ${HCO_NS}?" >&2
      return 1 ;;
  esac
  echo "   -> patched ${api} workloadUpdateMethods=${methods}"
  oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" -o jsonpath='{.spec.workloadUpdateStrategy.workloadUpdateMethods}{.spec.virtualization.workloadUpdateStrategy.workloadUpdateMethods}{"\n"}'
}
# ---------------------------------------------------------------------------

NAMESPACE="${NAMESPACE:-demo-vms}"
HCO_NS="${HCO_NS:-openshift-cnv}"
HCO_NAME="${HCO_NAME:-kubevirt-hyperconverged}"

echo "== (a) VMCannotBeEvicted: delete the non-migratable demo VM =="
oc delete vm vm-non-migratable -n "$NAMESPACE" --ignore-not-found=true
echo "   kubevirt_vmi_non_evictable drops to 0 as soon as the VMI object is"
echo "   gone; the alert instance resolves immediately (no 'for' delay on"
echo "   resolution)."

echo
echo "== (b) OutdatedVirtualMachineInstanceWorkloads: restore default"
echo "   automated-update behavior on the HyperConverged CR =="
hco_patch_wum '["LiveMigrate"]'
  2>/dev/null || echo "   (HyperConverged CR not found or already patched -- skipping)"
echo "   Confirm the fleet has drained back to 0:"
echo "     oc get vmi -A -l kubevirt.io/outdatedLauncherImage"
echo "   (If you created a throwaway VM just for this recipe, delete it too:)"
oc delete vm vm-outdated-demo -n "$NAMESPACE" --ignore-not-found=true

echo
echo "== (c) KubeVirtVMGuestMemoryPressure: stop the hog and delete the VM =="
echo "   If stress-ng is still running and you want a graceful stop first:"
echo "     virtctl console vm-memory-pressure -n $NAMESPACE"
echo "     # inside guest: pkill stress-ng"
oc delete vm vm-memory-pressure -n "$NAMESPACE" --ignore-not-found=true
echo "   Headroom ratio and pgmajfault/swap rates recover over their own"
echo "   5-minute rate windows; the alert clears once the expr goes false --"
echo "   again, no 'for' delay on resolution, only on the transition into"
echo "   Firing."

echo
echo "== Fallback korrel8r rules (only if you applied"
echo "   act2-06-korrel8r-custom-rule-fallback.yaml): =="
echo "   These are usually already gone by the time you read this (the"
echo "   operator reconciles the ConfigMap/Deployment back to its generated"
echo "   state on its own). To force it immediately:"
echo "     oc rollout restart deployment/korrel8r -n <coo-ns>"
echo "     oc delete configmap/korrel8r-fallback-rules -n <coo-ns> --ignore-not-found=true"

echo
echo "== Done. Re-run act2-01-korrel8r-verify.sh before your next rehearsal"
echo "   if you touched the fallback config. =="
