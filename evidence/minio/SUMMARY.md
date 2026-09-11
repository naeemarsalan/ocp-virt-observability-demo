# MinIO S3 Object Storage Evidence

This directory proves that MinIO has been deployed and configured as a working S3 backend for the cluster's logging infrastructure. MinIO runs as a single-replica Deployment in the minio-demo namespace with 60 GiB of persistent storage provisioned via NFS CSI. The pod is healthy and running, exposing both the S3 API endpoint (9000) and the web console (9001) via a ClusterIP Service. Root credentials are stored in a Kubernetes Secret and used by both the MinIO server and by a bucket-creation Job that runs the MinIO client (mc). Two S3 buckets have been successfully created: loki-logging for OpenShift Logging and loki-netobserv for NetObserv. Both OpenShift Logging and NetObserv namespaces hold secrets with endpoint details and credentials, configured to write logs to their respective S3 buckets. Health probes on the MinIO container include both liveness and readiness checks that poll the /minio/health endpoints.

## Evidence Files

| File | Contents | Key Metric/Fact |
|------|----------|-----------------|
| namespaces.txt | Kubernetes namespaces where MinIO and dependent workloads live | minio-demo created 4m54s ago, openshift-logging and netobserv also deployed |
| minio-pod-status.txt | Status of the running MinIO pod | Pod minio-85955fbf95-qj6g8 is Running with 1/1 Ready, 0 restarts, deployed on node 80-18-44-f0-71-30 |
| minio-pvc.yaml | Persistent Volume Claim for MinIO data storage | 60 GiB NFS CSI storage requested and bound to volume pvc-d460942f-7754-4b2d-946f-1b4c0874e8e2 |
| minio-deployment.yaml | Deployment spec with container args, probes, and mounts | Single replica (Recreate strategy), quay.io/minio/minio:latest, mounts to /data, health checks on port 9000 paths /minio/health/live and /minio/health/ready |
| minio-svc.yaml | Kubernetes Service exposing MinIO | ClusterIP 172.30.131.55 with ports 9000 (api) and 9001 (console) |
| minio-deployment.yaml status | Deployment status section | 1 available replica, Progressing and Available conditions True, observed generation 1 |
| minio-server-logs.txt | MinIO startup and server logs | Version RELEASE.2025-09-07T16-13-09Z (go1.24.6 linux/amd64), API on http://10.129.1.227:9000, WebUI on http://10.129.1.227:9001, single drive in single set (warning about single host failure) |
| secrets-summary.txt | Secrets referenced by MinIO and log aggregators | minio-root-credentials in minio-demo; logging-loki-s3 in openshift-logging pointing to http://minio.minio-demo.svc:9000; loki-netobserv-s3 in netobserv pointing to same endpoint |
| minio-mc-mb-job.yaml | Job that creates S3 buckets and lists them | Job minio-mc-mb completed successfully, succeeded 1 pod; runs mc to alias local MinIO, create loki-logging and loki-netobserv buckets |
| minio-mc-mb-job-logs.txt | Output from the bucket creation Job | localminio alias added successfully; both loki-logging and loki-netobserv buckets created; bucket listing shows 0B initial size for each |
| operatorgroup-openshift-operators-redhat.yaml | OperatorGroup for cluster-wide operator availability | OperatorGroup in openshift-operators-redhat namespace with default upgrade strategy, namespaces set to empty string (cluster-wide scope) |
