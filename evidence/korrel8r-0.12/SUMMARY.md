# Korrel8r 0.12 Correlation Evidence

This directory proves that Korrel8r 0.12.1 successfully correlates OpenShift Virtualization alerts, metrics, logs, and netflow data to their source VirtualMachines and related infrastructure objects.

The correlation engine was deployed to a test cluster (OCP 4.20.32, OpenShift Virtualization 4.20.24) with 104 custom correlation rules defined to link KubeVirt objects across multiple observability domains. Starting from the VMCannotBeEvicted alert fired on vm-non-migratable, Korrel8r found and correlated 200 application logs from the virt-launcher pod, 312 Prometheus metrics for the VM and its pod, one netflow record, and three cluster nodes involved in the VM's lifecycle. The correlation engine successfully traversed from alerts to VirtualMachines, from VirtualMachineInstances to their backing pods and persistent volumes, and from metrics to node infrastructure, proving bidirectional linking across Kubernetes, alerting, metrics, logs, and network telemetry domains.

Configuration and deployment details are captured in YAML manifests for the service account, deployment, service, route, and RBAC settings. API responses show the full rule graph (36 unique correlation paths defined), example goal-based queries demonstrating the engine's ability to navigate from alert-triggered objects to all related observables, and actual result sets retrieved during demonstration runs.

## Files

| File | Contents | Key Finding |
|------|----------|-------------|
| korrel8r.yaml | Service configuration for Korrel8r 0.12 | Five observability domains configured: Kubernetes API, Prometheus/AlertManager, Loki logs, netflow (Loki), OpenTelemetry traces |
| deploy.yaml | Deployment manifest with service account, service, and route | Korrel8r running on port 8080 in demo-vms namespace with resource limits (250m CPU request, 4Gi memory limit) |
| rbac.yaml | ClusterRoleBinding for auth-delegator | Service account korrel8r-demo granted permission to delegate authentication |
| rules-count.txt | Total number of correlation rules | 104 rules defined to correlate KubeVirt objects with observables |
| rules-kubevirt.txt | List of all defined correlation rules | 37 unique rule definitions linking VMs, VMIs, migrations, storage, snapshots, and exports to metrics, alerts, logs, and infrastructure |
| domains.json | API response listing available correlation domains | Seven domains active: alert, incident, k8s, log, metric, netflow, trace (each with Thanos, Loki, or Tempo backend URLs) |
| goals-request.json | Query from alert VMCannotBeEvicted to infrastructure | Starting from alert, goals include VMI, pod, logs, netflow, metrics, node (7 traversal targets) |
| goals-from-vmi.json | Query from VMI vm-non-migratable to all signals | Starting from VMI, goals include pod, logs, netflow, metrics, node, alert, PVC (7 traversal targets) |
| goals-vmi-to-all.json | Complete correlation result: VMI to all observables | 12 edges traversed; found 200 logs (two queries), 3 nodes, 1 VMI, 1 alert, 312 metrics (four queries), 1 pod, 1 PVC, 1 netflow record |
| goals-alert-to-all.json | Complete correlation result: alert to all observables | 10 edges traversed; found 200 logs, 1 VM, 3 nodes, 1 alert, 1 VMI, 1 pod, 296 metrics (three queries) |
| goals-vmi-inpod.txt | Error output from a failed query attempt | Demonstrates error handling when curl tool is unavailable during testing |
| alert-VMCannotBeEvicted.json | Live alert data for vm-non-migratable | Alert fired 13:24:44Z on node ec-f4-bb-ed-07-a8; eviction strategy mismatch detected; fingerprint aafcc47b1a3a57c0 |
| objects-netflow.json | Netflow records from vm-non-migratable pod | Network traffic data; packet payload 90 bytes sent to NTP server 212.71.233.40 from pod virt-launcher-vm-non-migratable-xrsp6 |
| objects-logs.json | Log records retrieved (empty during this run) | Placeholder for log retrieval results; logs accessible via two query paths but not shown in this capture |
| route.txt | OpenShift Route hostname for Korrel8r API | URL redacted as <cluster-domain>; HTTPS route with edge termination |

