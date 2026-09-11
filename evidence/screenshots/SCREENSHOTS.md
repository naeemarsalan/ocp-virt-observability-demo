# Console screenshots from the live run (2026-09-11)

Taken with a headless browser logged in as a cluster admin on <cluster-domain>, OpenShift 4.20.32, Cluster Observability Operator 1.5.2 (korrel8r 0.11.1). No image was edited.

| File | What it shows |
|---|---|
| console-panel-graph-from-VMI-korrel8r-0.11.1.png | The Troubleshooting Panel after typing the VMI query into its editor and clicking Search. The GA engine drew VirtualMachineInstance, VirtualMachine, Pod, Node, PVC, PersistentVolume, StorageClass, DataVolume, 5 Events, 248 of 263 Metric series, 2 of 3 Network flows and 1000 Application log lines. This is the VMI to pod to logs, metrics and flows walk on the shipped build. |
| console-panel-graph-from-alert-korrel8r-0.11.1.png | The same panel after typing the VMCannotBeEvicted alert query. The GA engine drew the Alert and 128 Metric series and nothing else: it has no AlertToVMI rule. |
| console-panel-query-editor-VMI.png | The panel's query editor, opened with the expand chevron next to the time range. The textarea placeholder is `domain:class:selector`. |
| console-panel-pod-page-focus-disabled.png | The panel opened from the virt-launcher pod's details page. Focus is greyed out and the panel says "No starting point for correlation". The same happens on the VirtualMachine and VirtualMachineInstance pages in this build. |
| console-panel-broken-by-custom-rule-experiment.png | What happened when rules from the 0.12 set were pasted into the operator's ConfigMap: "invalid rule AlertToVMI: function required not defined". The operator reverted the ConfigMap within two minutes; the pod needed a restart. |
| console-dashboard-kubevirt-top-consumers.png | Observe, Dashboards, KubeVirt Top Consumers. The built-in dashboard; VM names here are text, not links to their pods. |
| console-alerting-all-projects.png | Observe, Alerting with the project selector set to All Projects (it defaults to the user's last project and shows nothing otherwise). |
| console-metrics-series-count-one-vm.png | Observe, Metrics with the one-VM series count query. |
| console-vm-metrics-tab.png | The VM's own Metrics tab. |
| reference-architecture-step7-light.png, -dark.png | The animated reference-architecture page at step 7, both themes. |
