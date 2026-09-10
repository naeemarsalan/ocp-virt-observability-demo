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
# 1) THE 24-HOUR FOR-DURATION IS REAL AND CANNOT BE DEMOED LIVE IN ONE
#    SITTING. The underlying gauge (kubevirt_vmi_number_of_outdated) goes
#    nonzero within a couple of scrape intervals of the upgrade completing
#    with an outdated VMI still running -- the alert enters Pending state
#    almost immediately -- but it will not transition to Firing until 24
#    real hours later. You MUST pre-stage this at least 24h before you're on
#    stage: run steps 1-3 below the day before, leave workloadUpdateMethods
#    empty, and let it sit. On demo day it will already be Firing.
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
#       Troubleshooting Panel from THAT VMI's own resource page
#       (Virtualization > VirtualMachines > <name> > Troubleshooting Panel),
#       not from the alert.
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

case "$CMD" in
  stage)
    echo "== Step 1: disable automated workload updates BEFORE the upgrade =="
    echo "   Field (verified against kubevirt/hyperconverged-cluster-operator @"
    echo "   api/v1beta1 AND api/v1 hyperconverged_types.go -- layout differs by API version):"
    echo "     v1beta1: spec.workloadUpdateStrategy.workloadUpdateMethods  |  v1: spec.virtualization.workloadUpdateStrategy.workloadUpdateMethods"
    echo "   Default value is [LiveMigrate] -- HCO will auto-drain outdated VMIs"
    echo "   unless you empty this list first, which would clear the alert"
    echo "   before you ever see it fire."
    hco_patch_wum '[]'
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
    echo "   Console path: Observe > Alerting > Alerts, filter Alert = OutdatedVirtualMachineInstanceWorkloads"
    echo "   State will read Pending until 24h after the metric first went nonzero,"
    echo "   then Firing. This is expected -- see the header comment."
    ;;

  drain)
    echo "== Re-enabling automated drain =="
    hco_patch_wum '["LiveMigrate"]'

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
