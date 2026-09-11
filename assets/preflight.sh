#!/usr/bin/env bash
# =============================================================================
# preflight.sh -- cluster readiness check for the OCP Virt observability demo
#                  stack (OpenShift Virtualization + COO/Perses + Korrel8r
#                  Troubleshooting Panel + Logging/LokiStack + Network
#                  Observability + optional Tempo).
#
# Target versions this was written against: OCP 4.20, OpenShift Virtualization
# 4.20, Cluster Observability Operator 1.5+, OpenShift Logging 6.x/LokiStack,
# Network Observability GA. The cluster this deck was authored on was NOT
# reachable, so every check below is a live re-verification, not a repeat of
# a claim already trusted. Read every WARN before you present -- most of them
# are "this will be silently blank," which is fine to show on purpose, not
# fine to hit by surprise.
#
# This script is READ-ONLY: it does not create, patch, or delete anything.
#
# Usage:
#   oc login <cluster>
#   ./preflight.sh
#
# Optional overrides (defaults shown):
#   CNV_NS=openshift-cnv
#   COO_NS=openshift-cluster-observability-operator
#   LOGGING_NS=openshift-logging
#   LOKI_OPERATOR_NS=openshift-operators-redhat
#   LOKISTACK_NAME=logging-loki
#   FLOWCOLLECTOR_NAME=cluster
#   TEMPO_ENABLED=false            # set true if the optional Tempo beat is in scope
#   DEMO_VM=""                     # VM name for the guest-agent check, e.g. rhel9-demo
#   DEMO_VM_NS=""                  # namespace of DEMO_VM
#   OCP_MIN_MAJOR_MINOR="4.20"     # pinned target -- change if you re-target
# =============================================================================
set -uo pipefail

CNV_NS="${CNV_NS:-openshift-cnv}"
COO_NS="${COO_NS:-openshift-cluster-observability-operator}"
LOGGING_NS="${LOGGING_NS:-openshift-logging}"
LOKI_OPERATOR_NS="${LOKI_OPERATOR_NS:-openshift-operators-redhat}"
LOKISTACK_NAME="${LOKISTACK_NAME:-logging-loki}"
FLOWCOLLECTOR_NAME="${FLOWCOLLECTOR_NAME:-cluster}"
TEMPO_ENABLED="${TEMPO_ENABLED:-false}"
DEMO_VM="${DEMO_VM:-}"
DEMO_VM_NS="${DEMO_VM_NS:-}"
OCP_MIN_MAJOR_MINOR="${OCP_MIN_MAJOR_MINOR:-4.20}"

PASS_N=0; WARN_N=0; FAIL_N=0

pass() { echo "  PASS  $1"; PASS_N=$((PASS_N+1)); }
warn() { echo "  WARN  $1"; WARN_N=$((WARN_N+1)); }
fail() { echo "  FAIL  $1"; FAIL_N=$((FAIL_N+1)); }
hdr()  { echo; echo "== $1 =="; }

csv_line() {
  # csv_line <substring>  -> "<namespace> <name>" of first matching CSV across all namespaces
  oc get csv -A --no-headers 2>/dev/null | grep -i "$1" | head -1
}

# -----------------------------------------------------------------------------
hdr "0. oc login / cluster reachability"
if ! command -v oc >/dev/null 2>&1; then
  fail "oc CLI not found in PATH -- install it before running anything else"
  echo; echo "Cannot continue without oc. Exiting."; exit 2
fi
if oc whoami >/dev/null 2>&1; then
  pass "logged in as $(oc whoami) against $(oc whoami --show-server 2>/dev/null)"
else
  fail "not logged in (oc whoami failed) -- run 'oc login' first. Every check below will FAIL/WARN until this is fixed."
fi

# -----------------------------------------------------------------------------
hdr "1. OpenShift Container Platform version"
OCP_VER=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null)
if [[ -n "$OCP_VER" ]]; then
  echo "  cluster version: $OCP_VER"
  if [[ "$OCP_VER" == ${OCP_MIN_MAJOR_MINOR}* ]]; then
    pass "matches pinned target $OCP_MIN_MAJOR_MINOR"
  else
    warn "cluster is $OCP_VER, this deck targets $OCP_MIN_MAJOR_MINOR -- re-check every version-gated item below (PSI in particular; see section 11)"
  fi
else
  fail "could not read ClusterVersion (oc get clusterversion) -- confirm cluster-admin access"
fi

# -----------------------------------------------------------------------------
hdr "2. OpenShift Virtualization (kubevirt-hyperconverged)"
CNV_LINE=$(csv_line "kubevirt-hyperconverged")
if [[ -n "$CNV_LINE" ]]; then
  CNV_ACTUAL_NS=$(awk '{print $1}' <<<"$CNV_LINE")
  CNV_CSV=$(awk '{print $2}' <<<"$CNV_LINE")
  CNV_PHASE=$(oc get csv "$CNV_CSV" -n "$CNV_ACTUAL_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$CNV_PHASE" == "Succeeded" ]]; then
    pass "OpenShift Virtualization installed in $CNV_ACTUAL_NS: $CNV_CSV (phase=$CNV_PHASE)"
  else
    warn "kubevirt-hyperconverged CSV found ($CNV_CSV) but phase=$CNV_PHASE, not Succeeded"
  fi
  [[ "$CNV_CSV" == *"$OCP_MIN_MAJOR_MINOR"* ]] || warn "CNV CSV version ($CNV_CSV) does not obviously match target $OCP_MIN_MAJOR_MINOR -- confirm CNV/OCP version alignment"
else
  fail "kubevirt-hyperconverged CSV not found in any namespace -- OpenShift Virtualization is not installed"
fi
if oc get hyperconverged kubevirt-hyperconverged -n "$CNV_NS" >/dev/null 2>&1; then
  HCO_COND=$(oc get hyperconverged kubevirt-hyperconverged -n "$CNV_NS" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  [[ "$HCO_COND" == "True" ]] && pass "HyperConverged CR Available=True" || warn "HyperConverged CR Available condition is '$HCO_COND', not True"
else
  warn "HyperConverged CR 'kubevirt-hyperconverged' not found in $CNV_NS"
fi
# HCO API version -- decides the workloadUpdateStrategy field path used by the
# Act 2 upgrade-beat scripts (verified in kubevirt/hyperconverged-cluster-operator):
#   hco.kubevirt.io/v1beta1 -> spec.workloadUpdateStrategy            (top-level)
#   hco.kubevirt.io/v1      -> spec.virtualization.workloadUpdateStrategy (nested)
# A merge-patch against the wrong layout is silently pruned by the API server.
HCO_SERVED=$(oc get crd hyperconvergeds.hco.kubevirt.io -o jsonpath='{range .spec.versions[?(@.served==true)]}{.name}{" "}{end}' 2>/dev/null)
HCO_PREFERRED=$(oc get hyperconverged kubevirt-hyperconverged -n "$CNV_NS" -o jsonpath='{.apiVersion}' 2>/dev/null)
if [[ -n "$HCO_PREFERRED" ]]; then
  case "$HCO_PREFERRED" in
    hco.kubevirt.io/v1beta1) pass "HCO preferred API is v1beta1 (served: ${HCO_SERVED:-?}) -> use spec.workloadUpdateStrategy; 09-upgrade-beat.yaml matches; scripts auto-detect via hco_patch_wum" ;;
    hco.kubevirt.io/v1)      pass "HCO preferred API is v1 (served: ${HCO_SERVED:-?}) -> use spec.virtualization.workloadUpdateStrategy; NOTE 09-upgrade-beat.yaml is written for v1beta1 -- apply it only if v1beta1 is still served, else re-nest under spec.virtualization; scripts auto-detect via hco_patch_wum" ;;
    *)                       warn "HCO apiVersion is '$HCO_PREFERRED' (served: ${HCO_SERVED:-?}) -- unknown layout; inspect 'oc explain hyperconverged.spec' before running the upgrade beat" ;;
  esac
  WUM_NOW=$(oc get hyperconverged kubevirt-hyperconverged -n "$CNV_NS" -o jsonpath='{.spec.workloadUpdateStrategy.workloadUpdateMethods}{.spec.virtualization.workloadUpdateStrategy.workloadUpdateMethods}' 2>/dev/null)
  echo "  NOTE  current workloadUpdateMethods: ${WUM_NOW:-<default: [LiveMigrate]>}  (must be [] while the outdated gauge is being staged; restore [LiveMigrate] via act2-07-reset.sh)"
else
  warn "could not read HyperConverged apiVersion -- upgrade-beat field path cannot be pinned until oc is logged in and HCO exists"
fi

# -----------------------------------------------------------------------------
hdr "3. Cluster Observability Operator (COO)"
COO_LINE=$(csv_line "cluster-observability-operator")
if [[ -n "$COO_LINE" ]]; then
  COO_CSV=$(awk '{print $2}' <<<"$COO_LINE")
  pass "COO installed: $COO_CSV"
  COO_MINOR=$(grep -oE 'v1\.[0-9]+' <<<"$COO_CSV" | grep -oE '[0-9]+$')
  if [[ -n "$COO_MINOR" && "$COO_MINOR" -ge 5 ]]; then
    pass "COO >= 1.5 -- Perses dashboards should be GA"
  else
    warn "COO version ($COO_CSV) looks below 1.5 -- Perses/Monitoring UIPlugin may be pre-GA on this build, re-verify against the COO release notes for this exact version"
  fi
else
  fail "cluster-observability-operator CSV not found -- install it before UIPlugins/Perses/Korrel8r will work"
fi

# -----------------------------------------------------------------------------
hdr "4. OpenShift Logging 6.x + Loki Operator"
LOGGING_LINE=$(csv_line "cluster-logging")
LOKI_OP_LINE=$(csv_line "loki-operator")
if [[ -n "$LOGGING_LINE" ]]; then
  pass "cluster-logging (OpenShift Logging) installed: $(awk '{print $2}' <<<"$LOGGING_LINE")"
else
  fail "cluster-logging CSV not found -- OpenShift Logging operator is not installed"
fi
if [[ -n "$LOKI_OP_LINE" ]]; then
  pass "loki-operator installed: $(awk '{print $2}' <<<"$LOKI_OP_LINE")"
else
  fail "loki-operator CSV not found -- LokiStack cannot be created without it"
fi

# -----------------------------------------------------------------------------
hdr "5. Network Observability operator"
NETOBSERV_LINE=$(csv_line "netobserv-operator")
if [[ -n "$NETOBSERV_LINE" ]]; then
  pass "netobserv-operator installed: $(awk '{print $2}' <<<"$NETOBSERV_LINE")"
else
  fail "netobserv-operator CSV not found -- FlowCollector/netflow domain will not exist"
fi

# -----------------------------------------------------------------------------
hdr "6. Tempo (optional distributed-tracing beat)"
TEMPO_LINE=$(csv_line "tempo-operator\|tempo-product")
if [[ -n "$TEMPO_LINE" ]]; then
  pass "Tempo operator installed: $(awk '{print $2}' <<<"$TEMPO_LINE")"
elif [[ "$TEMPO_ENABLED" == "true" ]]; then
  fail "TEMPO_ENABLED=true but no tempo operator CSV found"
else
  echo "  SKIP  Tempo not requested (TEMPO_ENABLED=false) -- trace domain nodes simply will not render, which is expected, not an error"
fi

# -----------------------------------------------------------------------------
hdr "7. UIPlugins (Logging, TroubleshootingPanel, DistributedTracing, Monitoring)"
if oc get crd uiplugins.observability.openshift.io >/dev/null 2>&1; then
  pass "UIPlugin CRD present"
  check_uiplugin() {
    local name="$1" required="$2"
    local avail
    if oc get uiplugin "$name" >/dev/null 2>&1; then
      avail=$(oc get uiplugin "$name" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
      if [[ "$avail" == "True" ]]; then
        pass "UIPlugin/$name Available=True"
      else
        warn "UIPlugin/$name exists but Available='$avail' -- check its status.conditions for why"
      fi
    else
      if [[ "$required" == "true" ]]; then
        fail "UIPlugin/$name not found -- required for this demo"
      else
        echo "  SKIP  UIPlugin/$name not found (optional)"
      fi
    fi
  }
  check_uiplugin "logging" "true"
  check_uiplugin "troubleshooting-panel" "true"
  check_uiplugin "monitoring" "true"
  check_uiplugin "distributed-tracing" "$TEMPO_ENABLED"
else
  fail "UIPlugin CRD not found -- COO is not installed or not initialized"
fi

# -----------------------------------------------------------------------------
hdr "8. LokiStack readiness"
if oc get lokistack "$LOKISTACK_NAME" -n "$LOGGING_NS" >/dev/null 2>&1; then
  LOKI_READY=$(oc get lokistack "$LOKISTACK_NAME" -n "$LOGGING_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [[ "$LOKI_READY" == "True" ]]; then
    pass "LokiStack $LOGGING_NS/$LOKISTACK_NAME Ready=True"
  else
    REASON=$(oc get lokistack "$LOKISTACK_NAME" -n "$LOGGING_NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
    fail "LokiStack $LOGGING_NS/$LOKISTACK_NAME Ready='$LOKI_READY' -- $REASON"
  fi
  LOKI_SIZE=$(oc get lokistack "$LOKISTACK_NAME" -n "$LOGGING_NS" -o jsonpath='{.spec.size}' 2>/dev/null)
  echo "  size: $LOKI_SIZE"
  [[ "$LOKI_SIZE" == "1x.pico" ]] && warn "LokiStack size is 1x.pico -- known to over-provision replicas relative to typical demo VM log volume; 1x.extra-small is usually the better demo default"
else
  fail "LokiStack $LOGGING_NS/$LOKISTACK_NAME not found -- log domain nodes will be silently absent from the Troubleshooting Panel graph"
fi

# -----------------------------------------------------------------------------
hdr "9. FlowCollector readiness"
if oc get flowcollector "$FLOWCOLLECTOR_NAME" >/dev/null 2>&1; then
  FC_READY=$(oc get flowcollector "$FLOWCOLLECTOR_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [[ "$FC_READY" == "True" ]]; then
    pass "FlowCollector/$FLOWCOLLECTOR_NAME Ready=True"
  else
    warn "FlowCollector/$FLOWCOLLECTOR_NAME Ready='$FC_READY' -- netflow ingestion may not be flowing yet"
  fi
  FC_LOKI=$(oc get flowcollector "$FLOWCOLLECTOR_NAME" -o jsonpath='{.spec.loki.enable}' 2>/dev/null)
  [[ "$FC_LOKI" == "false" ]] && warn "FlowCollector spec.loki.enable=false -- netflows are not being written to Loki, netflow domain queries in Korrel8r will return nothing"
else
  fail "FlowCollector/$FLOWCOLLECTOR_NAME not found -- netflow domain nodes will be silently absent from the Troubleshooting Panel graph"
fi

# -----------------------------------------------------------------------------
hdr "10. Korrel8r: pod health, image tag, domains, and KubeVirt rules"
K_NS_POD=$(oc get pods -A -l app.kubernetes.io/name=korrel8r --no-headers 2>/dev/null | head -1)
if [[ -z "$K_NS_POD" ]]; then
  # fall back ONLY within the COO namespace, so a stray korrel8r deployment elsewhere is never mistaken for the operator's
  K_NS_POD=$(oc get pods -n "$COO_NS" --no-headers 2>/dev/null | grep -m1 '^korrel8r-' | sed "s/^/$COO_NS /")
fi
if [[ -n "$K_NS_POD" ]]; then
  K_NS=$(awk '{print $1}' <<<"$K_NS_POD")
  K_POD=$(awk '{print $2}' <<<"$K_NS_POD")
  K_STATUS=$(awk '{print $4}' <<<"$K_NS_POD")
  K_IMG=$(oc get pod "$K_POD" -n "$K_NS" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null)
  if [[ "$K_STATUS" == "Running" ]]; then
    pass "korrel8r pod $K_NS/$K_POD Running, image=$K_IMG"
  else
    fail "korrel8r pod $K_NS/$K_POD status=$K_STATUS (expected Running)"
  fi
  K_TAG=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$K_IMG" | tail -1)
  if [[ -n "$K_TAG" ]]; then
    echo "  image tag/version hint: $K_TAG (KubeVirt quickrules compiled in from v0.12.1+; if this resolves to a digest with no version, check it explicitly, see below)"
  else
    echo "  image reference has no readable semver tag (likely a digest pin) -- verify the KubeVirt rules directly, don't infer from the tag"
  fi

  # Best-effort: hit the korrel8r REST API from inside the cluster and grep for
  # the compiled KubeVirt quickrules. This is best-effort because the REST path
  # and in-cluster reachability can vary by build -- treat inconclusive as WARN,
  # not FAIL.
  DOMAINS_JSON=$(oc exec -n "$K_NS" "$K_POD" -c korrel8r -- \
      wget -q -O- http://localhost:8080/api/v1alpha1/domains 2>/dev/null || \
      oc exec -n "$K_NS" "$K_POD" -c korrel8r -- \
      curl -sk http://localhost:8080/api/v1alpha1/domains 2>/dev/null || true)
  if [[ -n "$DOMAINS_JSON" ]]; then
    pass "korrel8r REST API reachable from inside its own pod (GET /api/v1alpha1/domains)"
    for d in k8s alert log netflow metric; do
      grep -qi "\"$d\"" <<<"$DOMAINS_JSON" && pass "korrel8r domain '$d' registered" || warn "korrel8r domain '$d' not seen in /domains response -- that signal type will not appear in the panel"
    done
  else
    warn "could not reach korrel8r REST API in-pod (no wget/curl in the image, or a different port/path) -- confirm domains manually: oc port-forward -n $K_NS pod/$K_POD 8080:8080 && curl localhost:8080/api/v1alpha1/domains"
  fi

  # KubeVirt quickrules: grep any reachable rule/config source for the known
  # compiled rule names. AlertToVMI is the reverse-direction walk of the same
  # Vmi/Vm/VmimToAlert rule (korrel8r traverses rules in either direction when
  # building the graph), so a grep hit on VmiToAlert/VmToAlert/VmimToAlert
  # covers it even though "AlertToVMI" is not a separate literal rule name.
  RULE_SOURCE="$DOMAINS_JSON"
  CM_DUMP=$(oc get configmap -n "$K_NS" -o yaml 2>/dev/null | grep -iE 'VmiToPod|VmiToAlert|VmToAlert|VmimToAlert|VmToVmi|VmiToNode' || true)
  if [[ -n "$CM_DUMP" ]]; then
    pass "KubeVirt korrel8r rules found in a ConfigMap in $K_NS (VmiToPod/VmiToAlert family present)"
  elif grep -qiE 'vmitopod|kubevirt' <<<"$RULE_SOURCE"; then
    pass "korrel8r domains response references kubevirt/VMI rules"
  else
    warn "could not confirm the compiled KubeVirt quickrules (VmiToPod, VmiToAlert/VmimToAlert, VmToVmi, VmiToNode) are present in this build. Per the research this pinned image's rule set is NOT listed in COO release notes -- confirm manually before promising the alert -> VMI -> virt-launcher-pod -> logs walk on stage:  oc exec -n $K_NS $K_POD -- korrel8r list rules 2>/dev/null | grep -i vmi   (exact CLI subcommand may differ by build; if it doesn't exist, use the REST /domains + a live click-through in the console as your source of truth instead)"
  fi
else
  fail "no korrel8r pod found in any namespace -- the Troubleshooting Panel will not function; recheck the TroubleshootingPanel UIPlugin"
fi

# -----------------------------------------------------------------------------
hdr "11. User workload monitoring"
UWM_ENABLED=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -c 'enableUserWorkload:[[:space:]]*true' || true)
if [[ "${UWM_ENABLED:-0}" -ge 1 ]]; then
  pass "enableUserWorkload: true set in cluster-monitoring-config"
else
  fail "cluster-monitoring-config does not set enableUserWorkload: true -- user workload monitoring is off"
fi
UWM_PODS=$(oc get pods -n openshift-user-workload-monitoring --no-headers 2>/dev/null | grep -c Running || true)
if [[ "${UWM_PODS:-0}" -ge 1 ]]; then
  pass "$UWM_PODS running pod(s) in openshift-user-workload-monitoring"
else
  warn "no running pods found in openshift-user-workload-monitoring -- confirm the namespace exists and the stack rolled out"
fi

# -----------------------------------------------------------------------------
hdr "12. schedstats=enable and PSI (psi=1) kernel args"
SCHEDSTATS_MC=$(oc get machineconfig -o name 2>/dev/null | xargs -r -I{} oc get {} -o jsonpath='{.spec.kernelArguments}' 2>/dev/null | grep -c 'schedstats=enable' || true)
if [[ "${SCHEDSTATS_MC:-0}" -ge 1 ]]; then
  pass "found a MachineConfig with schedstats=enable"
else
  warn "no MachineConfig with schedstats=enable found -- kubevirt_vmi_vcpu_wait_seconds_total / vcpu_delay_seconds_total will read zero/stale, and the vCPU Wait Top-Consumers panel will be silently blank (no error)"
fi
NODE0=$(oc get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -n "$NODE0" ]]; then
  SCHEDSTAT_FILE=$(oc debug node/"$NODE0" -- chroot /host sh -c 'test -s /proc/schedstat && head -c 40 /proc/schedstat' 2>/dev/null)
  if [[ -n "$SCHEDSTAT_FILE" ]]; then
    pass "/proc/schedstat exists and is non-empty on node $NODE0"
  else
    warn "/proc/schedstat missing or empty on node $NODE0 -- the schedstats MachineConfig has probably not rolled out / not rebooted yet on this node"
  fi
else
  warn "could not enumerate a node to check /proc/schedstat directly"
fi

# Numeric major.minor comparison -- NOT a string/lexicographic "<" compare
# (bash's [[ "$a" < "$b" ]] sorts lexicographically, e.g. it happens to get
# "4.20" vs "4.21" right but is not reliable in general, e.g. double-digit
# minors or a missing/malformed OCP_VER). OCP_MAJOR/OCP_MINOR are unset (empty)
# if OCP_VER couldn't be parsed, and the numeric compares below treat that as
# "unknown" rather than silently misreporting PSI as in/out of scope.
OCP_MAJOR=$(grep -oE '^[0-9]+' <<<"${OCP_VER:-}" 2>/dev/null)
OCP_MINOR=$(grep -oE '^[0-9]+\.[0-9]+' <<<"${OCP_VER:-}" 2>/dev/null | cut -d. -f2)
ocp_lt_4_21() {
  [[ -n "$OCP_MAJOR" && -n "$OCP_MINOR" ]] || return 2   # unknown -- caller must handle
  if (( OCP_MAJOR < 4 )); then return 0; fi
  if (( OCP_MAJOR > 4 )); then return 1; fi
  (( OCP_MINOR < 21 ))
}
PSI_VERSION_GATE=$(ocp_lt_4_21; echo $?)   # 0=below 4.21, 1=4.21+, 2=unknown
if [[ "$PSI_VERSION_GATE" == "2" ]]; then
  warn "could not parse OCP_VER ('${OCP_VER:-<empty>}') into major.minor -- cannot confirm the PSI 4.21 version gate numerically, verify manually"
fi
if [[ "$PSI_VERSION_GATE" == "0" ]]; then
  echo "  NOTE: Pressure Stall Information (psi=1) is documented by Red Hat as available"
  echo "  starting OCP 4.21 (developers.redhat.com, 2026-03-18). On the pinned 4.20"
  echo "  target, /proc/pressure/cpu will NOT appear regardless of any psi=1"
  echo "  MachineConfig you apply -- this is a version gap, not a misconfiguration."
  echo "  Either drop PSI panels from this demo on 4.20, or upgrade the demo cluster"
  echo "  to 4.21+ before relying on them."
fi
PSI_MC=$(oc get machineconfig -o name 2>/dev/null | xargs -r -I{} oc get {} -o jsonpath='{.spec.kernelArguments}' 2>/dev/null | grep -c 'psi=1' || true)
if [[ -n "$NODE0" ]]; then
  PSI_FILE=$(oc debug node/"$NODE0" -- chroot /host sh -c 'test -e /proc/pressure/cpu && echo present' 2>/dev/null)
  if [[ "$PSI_FILE" == "present" ]]; then
    pass "/proc/pressure/cpu exists on node $NODE0"
  else
    if [[ "$PSI_VERSION_GATE" == "0" ]]; then
      echo "  SKIP  /proc/pressure/cpu absent on $NODE0 -- expected on OCP < 4.21, not a bug"
    elif [[ "$PSI_VERSION_GATE" == "1" ]]; then
      warn "/proc/pressure/cpu absent on $NODE0 despite OCP >= 4.21 -- apply the psi=1 MachineConfig and wait for the reboot to complete (found ${PSI_MC:-0} matching MachineConfig(s))"
    else
      warn "/proc/pressure/cpu absent on $NODE0 and the OCP version gate is unknown (see above) -- verify manually whether this is expected"
    fi
  fi
fi

# -----------------------------------------------------------------------------
hdr "13. Guest agent connectivity on the demo VM"
if [[ -n "$DEMO_VM" && -n "$DEMO_VM_NS" ]]; then
  if oc get vmi "$DEMO_VM" -n "$DEMO_VM_NS" >/dev/null 2>&1; then
    AGENT=$(oc get vmi "$DEMO_VM" -n "$DEMO_VM_NS" -o jsonpath='{.status.conditions[?(@.type=="AgentConnected")].status}' 2>/dev/null)
    if [[ "$AGENT" == "True" ]]; then
      pass "VMI $DEMO_VM_NS/$DEMO_VM reports AgentConnected=True"
    else
      warn "VMI $DEMO_VM_NS/$DEMO_VM AgentConnected='$AGENT' -- guest_load_*, filesystem_*, memory_available/usable, and memory panels will be silently blank. Check qemu-guest-agent is installed+running+enabled in the guest (systemctl status qemu-guest-agent)"
    fi
    LIVEMIG=$(oc get vmi "$DEMO_VM" -n "$DEMO_VM_NS" -o jsonpath='{.status.conditions[?(@.type=="LiveMigratable")].status}' 2>/dev/null)
    [[ "$LIVEMIG" == "True" ]] && pass "VMI reports LiveMigratable=True" || warn "VMI LiveMigratable='$LIVEMIG' -- check status.conditions reason before relying on live migration in the demo"
  else
    fail "VMI $DEMO_VM_NS/$DEMO_VM not found -- create/start the demo VM before the run"
  fi
else
  echo "  SKIP  DEMO_VM / DEMO_VM_NS not set -- export both to check guest-agent status, e.g.: DEMO_VM=rhel9-demo DEMO_VM_NS=demo-vms ./preflight.sh"
fi

# -----------------------------------------------------------------------------
hdr "14. Prometheus capacity / cardinality headroom"
VMI_COUNT=$(oc get vmi -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
EST_SERIES=$((VMI_COUNT * 60))
echo "  VMIs cluster-wide: $VMI_COUNT   (rule of thumb ~60 kubevirt_vmi_* series/VM -> ~${EST_SERIES} series just from VMI metrics)"
PROM_POD=$(oc get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null | head -1 | awk '{print $1}')
if [[ -n "$PROM_POD" ]]; then
  PROM_RESTARTS=$(oc get pod "$PROM_POD" -n openshift-monitoring -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
  PROM_MEM_LIMIT=$(oc get pod "$PROM_POD" -n openshift-monitoring -o jsonpath='{.spec.containers[?(@.name=="prometheus")].resources.limits.memory}' 2>/dev/null)
  echo "  prometheus pod: $PROM_POD  restarts=$PROM_RESTARTS  memory limit=${PROM_MEM_LIMIT:-<none set>}"
  if [[ "${PROM_RESTARTS:-0}" -gt 0 ]]; then
    warn "Prometheus has $PROM_RESTARTS restart(s) -- check for prior OOMKills (oc get pod $PROM_POD -n openshift-monitoring -o jsonpath='{.status.containerStatuses[0].lastState}') before trusting historical panels"
  else
    pass "Prometheus pod has 0 restarts"
  fi
  if [[ -z "$PROM_MEM_LIMIT" ]]; then
    warn "Prometheus has no memory limit set -- fine for a small demo, but size explicitly before scaling VM count up for a bigger rehearsal"
  fi
  if [[ "$VMI_COUNT" -gt 500 ]]; then
    warn "VMI count ($VMI_COUNT) is large enough that Prometheus memory sizing matters -- the research baseline saw repeated OOM-kills at ~10K VMs/~20M series on undersized Prometheus; confirm CPU/mem sizing before this scale, not during"
  else
    pass "VMI count is small enough that cardinality is not a concern for this demo"
  fi
else
  warn "could not find a running Prometheus pod in openshift-monitoring to check restarts/memory"
fi

# -----------------------------------------------------------------------------
hdr "15. Live label-existence checks (the label assumptions this deck makes)"
# These five labels could not be independently confirmed from the public
# kubevirt.io/monitoring/metrics.html or docs/metrics.md label tables (they
# document metric names/types, not an exhaustive per-metric label list). If
# any of these come back WARN, drop the corresponding `by (...)` grouping
# from the affected panel before presenting -- it will otherwise render as a
# single unlabeled series or (worse) silently empty, not an error.
THANOS_ROUTE=$(oc get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null)
THANOS_TOKEN=$(oc whoami -t 2>/dev/null)
if [[ -z "$THANOS_ROUTE" || -z "$THANOS_TOKEN" ]]; then
  warn "could not resolve the thanos-querier route or an auth token -- skipping all live label-existence checks below (sections 15-16). Run 'oc login' and confirm route/openshift-monitoring/thanos-querier exists, then re-run."
else
  label_exists() {
    # label_exists <label> <metric-or-selector-to-match-against>
    local label="$1" match="$2"
    local resp
    resp=$(curl -sk -G -H "Authorization: Bearer ${THANOS_TOKEN}" \
      "https://${THANOS_ROUTE}/api/v1/label/${label}/values" \
      --data-urlencode "match[]=${match}" 2>/dev/null)   # -G: label/values is a GET; without it curl POSTs and the route returns 405
    python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    vals = d.get("data", [])
    print("FOUND" if vals else "EMPTY")
except Exception:
    print("ERROR")
' <<<"$resp"
  }
  check_label() {
    local label="$1" match="$2" panel="$3"
    local result
    result=$(label_exists "$label" "$match")
    case "$result" in
      FOUND) pass "label '$label' has values on {${match}} -- safe to group by ($label) in: $panel" ;;
      EMPTY) warn "label '$label' returns NO values on {${match}} on this cluster/build -- drop 'by ($label)' from: $panel (it will render as one unlabeled series or blank)" ;;
      *)     warn "could not evaluate label '$label' on {${match}} (query/auth error) -- verify manually before presenting: $panel" ;;
    esac
  }
  check_label "phase" "kubevirt_vmi_phase_transition_time_from_creation_seconds_bucket" "Phase-transition latency panel"
  check_label "interface" "kubevirt_vmi_network_receive_bytes_total" "Network throughput by interface panel"
  check_label "drive" "kubevirt_vmi_storage_iops_read_total" "Storage IOPS/throughput by drive panel"
  check_label "instance_type" "kubevirt_vmi_info" "VM count by instance type (row E) panel"
  check_label "node" "kubevirt_vmi_cpu_usage_seconds_total" "Top 5 nodes by VM vCPU usage (row E) panel"
fi

# -----------------------------------------------------------------------------
hdr "16. kube-state-metrics pod-label allowlist (label_vm_kubevirt_io_name on kube_pod_labels)"
# The dashboards' Query-3 depth-check panel (\"the actual proof point\") and the
# hidden Grafana `pod` template variable both depend on
# kube_pod_labels{label_vm_kubevirt_io_name="<vm>"} returning data. Since
# kube-state-metrics v2.0, kube_pod_labels exposes ONLY name/namespace by
# default -- an operator must explicitly allow-list a pod label (e.g. via
# --metric-labels-allowlist=pods=[vm.kubevirt.io/name] or OpenShift's
# equivalent kube-state-metrics label configuration) before it shows up as
# label_vm_kubevirt_io_name. This is exactly the kind of "silently blank by
# design, not error" trap the research flags elsewhere -- unlike the
# label_team join (row E.4), this one is easy to miss because it backs the
# HIDDEN pod variable, not a panel you're staring at.
if [[ -n "${THANOS_ROUTE:-}" && -n "${THANOS_TOKEN:-}" ]]; then
  KSM_CHECK=$(label_exists "label_vm_kubevirt_io_name" "kube_pod_labels")
  case "$KSM_CHECK" in
    FOUND) pass "kube_pod_labels exposes label_vm_kubevirt_io_name -- the Query-3 depth-check panel and the hidden 'pod' variable will resolve" ;;
    EMPTY) warn "kube_pod_labels does NOT expose label_vm_kubevirt_io_name on this cluster -- the 'actual proof point' stat panel (row A, '+ virt-launcher pod series') and the hidden 'pod' dashboard variable will silently show 0 / no data. Allow-list the vm.kubevirt.io/name pod label on kube-state-metrics before presenting, or replace the join with a live 'oc get pod -l vm.kubevirt.io/name=<vm>' lookup as a fallback." ;;
    *)     warn "could not evaluate kube_pod_labels/label_vm_kubevirt_io_name (query/auth error) -- verify manually: curl the label/values endpoint or run the row-A '+ virt-launcher pod series' panel live and confirm it returns a nonzero number distinct from the VMI-only count" ;;
  esac
else
  echo "  SKIP  thanos-querier route/token unavailable (see section 15) -- cannot check kube_pod_labels live"
fi

# -----------------------------------------------------------------------------
hdr "17. OCP 4.20 cgroups v1->v2 cgroup_id/id rename trap"
# Per the research: a cgroup_id -> id label rename tied to the OCP 4.20
# cgroups v1->v2 default broke Node Memory panels elsewhere in the product
# and made a vmi:kubevirt_vmi_memory_used_bytes:sum recording rule vanish on
# some builds. None of this Act 1's own panels group by a cgroup_id/id label
# on container_* metrics (the WSS panel matches on pod/container, which is
# stable across the v1/v2 switch), so THIS deck is not directly exposed --
# but confirm that before reusing any panel from another dashboard that does
# group by id/cgroup_id, and before trusting any recording-rule name that
# wasn't independently verified against this exact cluster's build.
CGROUP_MODE=$(oc debug node/"${NODE0:-}" -- chroot /host stat -fc %T /sys/fs/cgroup 2>/dev/null | tr -d '\r')
if [[ "$CGROUP_MODE" == "cgroup2fs" ]]; then
  pass "node ${NODE0:-<unknown>} is on cgroups v2 (expected default on 4.20) -- if you add any panel that groups by 'id' or 'cgroup_id' on container_* metrics, verify the label name live before trusting it, per the research's cgroup_id->id rename note"
elif [[ "$CGROUP_MODE" == "tmpfs" ]]; then
  echo "  NOTE  node ${NODE0:-<unknown>} is on cgroups v1 (hybrid/legacy) -- the cgroup_id->id rename trap does not apply here, but confirm this is intentional for a 4.20 target"
else
  warn "could not determine cgroup mode on node ${NODE0:-<unknown>} (oc debug failed or unexpected output) -- verify manually with 'stat -fc %T /sys/fs/cgroup' on a worker before trusting any id/cgroup_id-grouped panel"
fi

# -----------------------------------------------------------------------------
echo
echo "================================================================"
echo "  SUMMARY:  $PASS_N PASS   $WARN_N WARN   $FAIL_N FAIL"
echo "  Fix every FAIL before the demo. Read every WARN and decide if"
echo "  it changes what you say on stage -- most WARNs mean a panel or"
echo "  graph node will be silently empty, not throw an error."
echo "================================================================"
[[ $FAIL_N -gt 0 ]] && exit 1
exit 0
