# Troubleshooting Panel Evidence Summary

This directory contains evidence from Act 2 of the demo: validation that the Cluster Observability Operator (COO 1.5.2) successfully deploys a UIPlugin for the Troubleshooting Panel on OpenShift Virtualization 4.20.24 (OCP 4.20.32). The panel opens from the App menu in the console and uses korrel8r 0.11.1 to correlate Kubernetes resources and alerts across multiple observability domains.

The key finding is that korrel8r 0.11.1, shipped with COO 1.5.2, lacks five rules that were added in v0.11.4 (2026-07-22) and compiled in v0.12.1 (2026-08-26): VmToAlert, VmiToAlert, AlertToVM, AlertToVMI, and VmiToLogs. This limitation means VM-to-alert correlation requires either an operator upgrade to a newer korrel8r image or a custom rule fallback (verified not to persist when the Cluster Observability Operator reconciles the ConfigMap).

An experiment attempted to patch the korrel8r ConfigMap with custom AlertToVMI and VmiToLogs rules using the v0.12 template syntax (the `required` function). The result demonstrated two problems: the operator reverted the patch within two minutes, and when the pod briefly ran with it, the console showed "Search Error: invalid rule AlertToVMI: template: AlertToVMI:1: function "required" not defined", confirming that korrel8r 0.11.1 cannot parse newer rule templates. This proves the missing rules are a binary compatibility issue tied to the korrel8r image version, not a configuration issue.

The UIPlugin reconciles successfully with no degradation, exposing korrel8r's REST API endpoints to the console via a TroubleshootingPanel rule. Domains (k8s, alert, log, metric, netflow, trace) are healthy and configured to point to their default OpenShift service endpoints.

## File Inventory

| File | Contents | Key Fact |
|------|----------|----------|
| version.txt | korrel8r version reported by the pod | 0.11.1 |
| image.txt | Container image digest | registry.redhat.io/.../korrel8r-rhel9@sha256:90cc70741585b3a555888cc119c1ad630e988513dd2065158b26f6fa33dc8a22 |
| uiplugin.yaml | UIPlugin custom resource spec and status | UIPluginReconciled=True, Available=True, Degraded=False |
| pod.yaml | korrel8r pod spec and metadata | pod name korrel8r-578787ddc4-nnbh6, image digest matches above, runs korrel8r web --config=/config/korrel8r.yaml |
| korrel8r-config.yaml | Default config template (deployed via ConfigMap) | Includes stores for k8s, alert, log, metric, netflow, trace; includes /etc/korrel8r/rules/all.yaml |
| domains.json | Domains listing from pod REST API | 6 domains: alert, incident, k8s, log, metric, netflow, trace |
| rules.txt | Rules matching Vm\|Vmi\|Alert pattern | Lists 18 rules; missing AlertToVM, AlertToVMI, VmToAlert, VmiToAlert, VmiToLogs |
| rules-all.txt | Full rule set from /etc/korrel8r/rules/all.yaml | 47 rules total; confirms same 5 rules missing; show VmiToNode, VmToVmi, VmiToPod, VmToPVC present |
| korrel8r-cm-before.yaml | ConfigMap snapshot before patch | Standard config, no custom rules |
| korrel8r-cm-patched.yaml | ConfigMap with AlertToVMI and VmiToLogs rules added | Uses required() template function; includes query templates for Alert->VMI and VMI->Logs rules |
| act2-01-verify-output.txt | Test output from korrel8r rules verification script | 18 PASS checks; 5 FAIL checks (missing rules); notes version predates v0.11.4/v0.12.1; recommends upgrade or custom-rule fallback |
| custom-rule-experiment-outcome.txt | Result of ConfigMap patch experiment | Operator reverted patch within 2 min; pod showed template parse error "function required not defined"; conclusion: need newer korrel8r image |
| custom-rules-after-restart.txt | File size 0 | (empty; custom rules did not remain after pod restart) |
| custom-rules-persisted-after-2min.txt | File contains "0" | Confirms operator reconciliation deleted custom rules within 2 minutes |

