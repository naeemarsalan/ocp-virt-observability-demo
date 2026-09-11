#!/usr/bin/env bash
# Removes everything the end-to-end run added to the cluster, in reverse order.
# Leaves alone anything that was already there: the existing ClusterLogForwarder 'instance',
# the 'monitoring' UIPlugin, the Cluster Observability Operator itself, OpenShift Logging,
# and every VM outside the demo-vms namespace.
#
# Usage:  ./teardown.sh --dry-run     (print what would be deleted)
#         ./teardown.sh --yes         (actually delete)
set -uo pipefail
MODE="${1:-}"
[[ "$MODE" == "--yes" || "$MODE" == "--dry-run" ]] || { echo "usage: $0 --dry-run | --yes"; exit 2; }
run() { if [[ "$MODE" == "--dry-run" ]]; then echo "DRY: $*"; else echo "+ $*"; "$@" || true; fi; }

echo "== 1. console plugins added by the run =="
run oc delete uiplugin troubleshooting-panel logging --ignore-not-found

echo "== 2. network observability =="
run oc delete flowcollector cluster --ignore-not-found
run oc delete lokistack loki -n netobserv --ignore-not-found
run oc delete secret loki-netobserv-s3 -n netobserv --ignore-not-found
run oc delete subscription netobserv-operator -n openshift-netobserv-operator --ignore-not-found
run bash -c 'oc get csv -n openshift-netobserv-operator -o name | grep network-observability | xargs -r oc delete -n openshift-netobserv-operator'
run oc delete namespace netobserv openshift-netobserv-operator --ignore-not-found

echo "== 3. in-cluster log store added for the demo (the pre-existing forwarder to the external Loki is untouched) =="
run oc delete clusterlogforwarder demo-loki -n openshift-logging --ignore-not-found
run bash -c 'oc get clusterrolebinding -o name | grep -E "demo-collector" | xargs -r oc delete'
run oc delete serviceaccount demo-collector -n openshift-logging --ignore-not-found
run oc delete lokistack logging-loki -n openshift-logging --ignore-not-found
run oc delete secret logging-loki-s3 -n openshift-logging --ignore-not-found
run oc delete subscription loki-operator -n openshift-operators-redhat --ignore-not-found
run bash -c 'oc get csv -n openshift-operators-redhat -o name | grep loki-operator | xargs -r oc delete -n openshift-operators-redhat'
run oc delete namespace openshift-operators-redhat --ignore-not-found

echo "== 4. demo VMs and the upstream korrel8r used for Act 3 =="
run oc delete clusterrolebinding korrel8r-demo-auth-delegator --ignore-not-found
run oc delete namespace demo-vms --ignore-not-found

echo "== 5. object store =="
run oc delete namespace minio-demo --ignore-not-found

echo "== 6. runtime scheduler stats (reverts on reboot anyway) =="
for n in $(oc get nodes -o name); do run oc debug "$n" -q -- chroot /host sysctl -w kernel.sched_schedstats=0; done

echo "Done. Not touched: HyperConverged CR, MachineConfigs, ClusterLogForwarder 'instance', UIPlugin 'monitoring', COO, Logging operator, VMs outside demo-vms."
