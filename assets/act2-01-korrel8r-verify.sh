#!/usr/bin/env bash
# =============================================================================
# act2-01-korrel8r-verify.sh -- MANDATORY pre-demo check for Act 2.
#
# Confirms the korrel8r image your Cluster Observability Operator (COO) build
# actually deployed contains the KubeVirt correlation rules (VmToVmi,
# VmiToPod, VmiToNode, AlertToVM, AlertToVMI, VmiToLogs, ...) before you
# promise the alert -> VMI -> virt-launcher-pod -> logs walk on stage.
#
# WHY THIS MATTERS (verified against source, 2026-09-08):
#   - These rules do not live in a YAML file you can grep on the cluster.
#     They are Go quicktemplates (pkg/rules/quickrules/kubevirt.qtpl) compiled
#     directly into the korrel8r binary via `//go:embed *.qtpl`, and are
#     loaded UNCONDITIONALLY whenever that binary starts -- the COO-managed
#     korrel8r.yaml config's `include: [/etc/korrel8r/rules/all.yaml]` line
#     is an empty stub ("all rules previously in YAML are now compiled into
#     the binary") and has nothing to do with whether KubeVirt rules exist.
#   - The KubeVirt rules first shipped as YAML config in korrel8r v0.11.4
#     (2026-07-22, "KubeVirt correlation rules for VM troubleshooting") and
#     were recompiled as quickrules in v0.12.1 (2026-08-26, "Moved all
#     existing rules to quickrules"). Both dates are recent relative to any
#     COO 1.5.x cut -- do not assume your COO build's pinned korrel8r image
#     postdates them.
#   - They are NOT mentioned anywhere in the COO 1.0-1.5.2 product release
#     notes. The only way to know is to ask the running pod.
#
# Usage:
#   oc login ...
#   COO_NS=<namespace-where-COO-is-installed> ./act2-01-korrel8r-verify.sh
#   (default COO_NS is openshift-cluster-observability-operator, the
#   documented default install namespace)
# =============================================================================
set -uo pipefail

COO_NS="${COO_NS:-openshift-cluster-observability-operator}"
FAIL=0

pass() { echo "  PASS  $1"; }
warn() { echo "  WARN  $1"; }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

echo "=============================================================================="
echo " ACT 2 -- KORREL8R KUBEVIRT RULE VERIFICATION  (namespace: $COO_NS)"
echo "=============================================================================="

# --- 0. Does the TroubleshootingPanel UIPlugin exist at all? ----------------
if oc get uiplugin troubleshooting-panel >/dev/null 2>&1; then
  pass "UIPlugin/troubleshooting-panel exists"
else
  fail "UIPlugin/troubleshooting-panel not found -- create it first:"
  echo "    oc apply -f - <<'EOF'"
  echo "    apiVersion: observability.openshift.io/v1alpha1"
  echo "    kind: UIPlugin"
  echo "    metadata:"
  echo "      name: troubleshooting-panel"
  echo "    spec:"
  echo "      type: TroubleshootingPanel"
  echo "    EOF"
fi

# --- 1. Find the korrel8r pod (label app.kubernetes.io/instance=korrel8r, --
#         verified from rhobs/observability-operator componentLabels()) -----
KORREL8R_POD=$(oc get pods -n "$COO_NS" -l app.kubernetes.io/instance=korrel8r -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$KORREL8R_POD" ]]; then
  fail "no pod with label app.kubernetes.io/instance=korrel8r in $COO_NS -- is the UIPlugin reconciled yet? (oc get deployment korrel8r -n $COO_NS)"
  exit 1
fi
pass "korrel8r pod: $KORREL8R_POD"

KORREL8R_IMG=$(oc get pod "$KORREL8R_POD" -n "$COO_NS" -o jsonpath='{.spec.containers[0].image}')
echo "  image: $KORREL8R_IMG"

# --- 2. Ask the binary directly: `korrel8r version` -------------------------
echo
echo "-- korrel8r version (compare against CHANGELOG.md: KubeVirt rules added as"
echo "   YAML in v0.11.4 / 2026-07-22, compiled to quickrules in v0.12.1 / 2026-08-26) --"
oc exec -n "$COO_NS" "$KORREL8R_POD" -- korrel8r version 2>&1 || warn "version command failed -- binary may not expose 'version' the same way in this build"

# --- 3. The ONE check that actually answers the question: list loaded rules -
#         `korrel8r rules -n <regex>` is a real CLI subcommand
#         (cmd/korrel8r/rules.go) that lists every rule currently loaded in
#         the running engine, matched by name/start/goal. This is stronger
#         proof than /api/v1alpha1/domains, which only proves the k8s domain
#         knows about the VirtualMachineInstance CRD -- it does NOT prove any
#         rule connects an alert to one. -------------------------------------
echo
echo "-- korrel8r rules matching Vm|Vmi|Alert (the exact names to look for:"
echo "   VmToVmi, VmiToPod, VmiToNode, VmToPVC, VmiToPVC, VmToAlert, VmiToAlert,"
echo "   VmimToAlert, AlertToVM, AlertToVMI, AlertToVmim, VmiToLogs, VmimToVmi,"
echo "   VmiToVmim, NodeToVmi) --"
oc exec -n "$COO_NS" "$KORREL8R_POD" -- korrel8r rules --config=/config/korrel8r.yaml -n '(Vm|Vmi|Vmim|Alert)' --long 2>&1 | tee /tmp/korrel8r-rules-seen.txt

REQUIRED_RULES=(VmToVmi VmiToPod VmiToNode VmToAlert VmiToAlert AlertToVM AlertToVMI VmiToLogs)
MISSING=()
for r in "${REQUIRED_RULES[@]}"; do
  if grep -q "^${r}:" /tmp/korrel8r-rules-seen.txt 2>/dev/null; then
    pass "rule present: $r"
  else
    fail "rule MISSING: $r"
    MISSING+=("$r")
  fi
done

# --- 4. Confirm the k8s domain resolves the CRDs (necessary but not
#         sufficient on its own -- see note above) ---------------------------
echo
echo "-- REST API cross-check: GET /api/v1alpha1/domain/k8s/classes (should list"
echo "   VirtualMachineInstance.kubevirt.io, VirtualMachine.kubevirt.io, etc.) --"
oc exec -n "$COO_NS" "$KORREL8R_POD" -- \
  curl -sk --cacert /run/secrets/kubernetes.io/serviceaccount/service-ca.crt \
  "https://localhost:9443/api/v1alpha1/domain/k8s/classes" 2>&1 | grep -o 'VirtualMachine[A-Za-z.]*' | sort -u \
  || warn "in-pod curl check failed -- fall back to the external route method below"

echo
echo "-- Same check from OUTSIDE the pod, via an authenticated route (needs a"
echo "   Route created once: oc apply -k github.com/korrel8r/korrel8r/config/route?version=main) --"
KORREL8R_ROUTE=$(oc get route korrel8r -n "$COO_NS" -o jsonpath='{.spec.host}' 2>/dev/null)
if [[ -n "$KORREL8R_ROUTE" ]]; then
  curl -sk --oauth2-bearer "$(oc whoami -t)" "https://${KORREL8R_ROUTE}/api/v1alpha1/domains" | python3 -m json.tool 2>/dev/null || true
else
  warn "no korrel8r route found -- skip, the in-pod exec checks above are sufficient"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "================================================================"
  echo " ALL REQUIRED KUBEVIRT RULES PRESENT. Safe to demo the walk as written."
  echo "================================================================"
  exit 0
else
  echo "================================================================"
  echo " MISSING RULES: ${MISSING[*]:-<see FAIL lines above>}"
  echo " Your korrel8r image predates v0.11.4/v0.12.1, or ships a stripped"
  echo " rule set. Two options:"
  echo "   1) Upgrade COO to a version that pins a newer korrel8r image (check"
  echo "      the COO release notes / bundle CSV for the korrel8r image tag --"
  echo "      it is not documented in the 1.0-1.5.2 release notes, so you must"
  echo "      check the actual deployed digest, e.g.:"
  echo "        oc get deployment korrel8r -n $COO_NS -o jsonpath='{.spec.template.spec.containers[0].image}'"
  echo "   2) Use the UNSUPPORTED custom-rule fallback: see"
  echo "      act2-06-korrel8r-custom-rule-fallback.yaml -- read its header"
  echo "      comment before you rely on it for anything but a live demo."
  echo "================================================================"
  exit 1
fi
