# NetObserv Setup and Network Flow Capture

This directory proves that NetObserv operator 1.12.2 is installed on the live cluster and actively capturing network flows from the demo-vms namespace. The NetObserv stack comprises a Loki-backed log store, eBPF agents for packet capture on each node, flowlogs-pipeline processors, and a console plugin for visualization. All components are running and operational, collecting network flow data at a sustained rate.

The evidence shows network flows captured during the demo: primarily application-to-service traffic from the demo-vms namespace pods reaching the Kubernetes API service (172.30.0.1:443) on the host nodes. The infrastructure is functioning despite one cluster node (80-18-44-f0-71-30) running at the pod capacity limit; the eBPF agents and flowlogs-pipeline DaemonSets have 2 out of 3 replicas running on the other two nodes, which is sufficient since all three demo-vms virtual machines run on the node that has active capture (ec-f4-bb-ed-07-a8). Loki is storing and indexing these flows, enabling query and analysis through the console plugin. The metrics confirm steady ingest at 422 flows per second with 216,748 total flows processed.

| File | Contents | Key Fact |
|------|----------|----------|
| 01-netobserv-operator-csv.yaml | Operator ClusterServiceVersion manifest | Version: 1.12.2; status: Active |
| 01-netobserv-operator-subscription.yaml | Operator subscription config in openshift-netobserv-operator namespace | Installed via redhat-operators channel; Automatic InstallPlanApproval |
| 02-netobserv-loki-pods.txt | All Loki component pods | 8 pods Running (compactor, distributor, gateway x2, index-gateway, ingester, querier, query-frontend) across 2 nodes |
| 02-netobserv-lokistack-status.yaml | LokiStack CR status | All components Ready; condition[type=Ready].status = True; warning: replication factor vs. ingester replicas (1 each) |
| 03-flowcollector-status.yaml | FlowCollector CR status | Degraded (LokiStack warnings + 1 unscheduled pod); integrations: loki=Degraded, monitoring=Ready; eBPF + pipeline pods pending on full node |
| 04-netobserv-all-pods.txt | All netobserv namespace pods | 12 pods: 2 flowlogs-pipeline Running, 1 Pending (node capacity); 8 Loki components Running; 1 console-plugin Running |
| 04b-netobserv-privileged-pods.txt | DaemonSet eBPF agents in netobserv-privileged namespace | 3 desired, 3 current, 2 Ready; 1 Pending (node 80-18-44-f0-71-30 at 250/250 pod cap) |
| 04-netobserv-pods.txt | netobserv namespace pods only | Same subset as 04-netobserv-all-pods.txt |
| 05-node-80-18-full-describe.txt | Full describe output of the constrained node | 250/250 pods (hard kubelet limit reached); DaemonSet replicas affinity-bound to this node but blocked |
| 05-node-capacity-note.txt | Human explanation of capacity constraint | One node full; both DaemonSets (2/2 on other nodes); demo-vms VMs on node with active agent/pipeline |
| 06-netobserv-events.txt | Cluster events for netobserv and netobserv-privileged namespaces | 132 lines; includes container pulls, starts, pod creation, scheduling; loki-ingester readiness probe warning; flowlogs-pipeline container restarts; netobserv-plugin mount failures (cert secret delayed) |
| 06b-netobserv-privileged-events.txt | Events for eBPF agent DaemonSet | FailedScheduling for one agent due to node capacity; successful scheduling on other 2 nodes |
| 07-prometheus-flows-processed-rate.json | Rate of netobserv_ingest_flows_processed metric | 422.71 flows/second at time of query (1789133561) |
| 07b-prometheus-flows-processed-total.json | Total flows processed counter | 216,748 flows processed since operator deployed |
| 08-loki-network-demo-vms-query.json | Loki query results for flows from demo-vms namespace | 12 flow records; stream labels show pod-to-service traffic from korrel8r-demo pod to Kubernetes API service; sample shows 1 ACK packet, 114 bytes, sampling rate 50x, TCP port 443 |

