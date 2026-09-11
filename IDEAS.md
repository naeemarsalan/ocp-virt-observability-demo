# More ways to show VMs benefiting from a cloud-native platform, and what is hard

You already ran a demo where Alertmanager fired a VM alert and Event-Driven Ansible, through AAP, turned it into remediation instead of a page. This builds on that: cloud-native objects and patterns that make VM management on OpenShift Virtualization look like the rest of the platform, so the same GitOps, RBAC, and admission control your app teams use also covers VMs. It comes from a read-only inventory of this OpenShift 4.20.32 lab, ranked by a separate review. Three ideas need nothing new installed; the rest need one operator or one feature-gate decision, called out below.

## Top ideas, ranked

### 1. GitOps for VirtualMachine objects with self-heal and sync waves

**What you show:** Store VM, DataVolume, and instance type manifests in git. Point OpenShift GitOps at them with `selfHeal: true` and sync-wave annotations. Hand-edit a running VM's memory outside git and watch ArgoCD revert it within seconds.

**Why it lands:** Config drift is a felt vSphere pain; an on-stage auto-revert beats a scheduled report.

**vSphere instead:** Aria Automation Config flags drift on a schedule, a licensed add-on, not self-reverting.

**Needs:** GitOps operator plus a git repo. Already installed here.

**Status:** GA. KubeVirt's own guide documents managing VMs with GitOps.

**Difficulty and catch:** Easy. Self-heal also reverts a real emergency fix, so show the pause path (app suspend, or a maintenance-window label) too.

**Source:** https://kubevirt.io/user-guide/cluster_admin/gitops/

### 2. VM as code: instance types and preferences catalog

**What you show:** Reference a `VirtualMachineClusterInstancetype` and `VirtualMachinePreference` by name, for example `cx1.medium` with `rhel.9`, instead of hand-set cpu and memory. This cluster already has 119 such objects loaded. Resize a class of VMs by editing the shared object once, in git.

**Why it lands:** A named, shared sizing catalog is something vCenter has never had natively.

**vSphere instead:** Aria Automation's flavor mapping is the closest analog, an add-on, not a vCenter primitive.

**Needs:** Nothing; the catalog ships by default and 119 objects are already loaded here.

**Status:** GA, documented in the OpenShift Virtualization "Creating a virtual machine" guide.

**Difficulty and catch:** Easy, the fastest idea here to stage. A resize usually needs a restart to take effect.

**Source:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/creating-a-virtual-machine

### 3. Scheduled VM lifecycle with a plain Kubernetes CronJob

**What you show:** A CronJob under a scoped ServiceAccount patches `runStrategy`, or calls `virtctl stop`/`start`, on labeled dev and test VMs nightly and each morning. The schedule is one YAML file next to the VMs it targets.

**Why it lands:** Every vSphere shop already solves this with a script or an Aria power schedule; this makes it git-reviewed instead.

**vSphere instead:** Aria power schedules, or a PowerCLI script from vCenter Scheduled Tasks; no shared audit trail.

**Needs:** Just core Kubernetes: CronJob, ServiceAccount, RBAC. No CNV dependency.

**Status:** GA. CronJob is stable since Kubernetes 1.21; no CNV-native scheduled-power feature exists.

**Difficulty and catch:** Easy, a five-minute demo. No vendor support statement covers it; guard against stopping a VM mid migration.

**Source:** https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/

### 4. SLA-tiered live migration and node maintenance

**What you show:** Set `evictionStrategy: LiveMigrate`, then cordon and drain its node while a ping runs in the guest, and watch the VM hop nodes instead of restarting. A `MigrationPolicy` CR gives a "gold" VM a tight timeout and a "bronze" VM a relaxed one.

**Why it lands:** Maps onto per-VM DRS/HA rules and Maintenance Mode evacuation, concepts a VMware admin knows.

**vSphere instead:** DRS/HA rules and vMotion, or Maintenance Mode evacuation, set in vCenter, not code.

**Needs:** An RWX storage class and a MigrationPolicy CR. Five exist here; no Node Maintenance Operator, so use `oc adm drain` directly.

**Status:** GA, documented since OCP 4.3.

**Difficulty and catch:** Easy. Plain `iscsi` here is RWO-only, so a VM on it gets evicted, not migrated.

**Source:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.21/html/virtualization/live-migration

### 5. VM State RBAC: start and stop as a permission, not a button

**What you show:** A Role granting get, list, and watch on virtualmachines but withholding the start/stop verb, bound to a junior account and proved with `oc auth can-i`. A second Role with that verb shows it now can.

**Why it lands:** Separating "can see a VM" from "can power it on" is a normal ask on shared infrastructure.

**vSphere instead:** vCenter's privilege tree has done this for over a decade; here it's plain RBAC YAML.

**Needs:** Standard RBAC plus CNV subresource verbs, already present here.

**Status:** GA, documented in the OCP 4.20 virtualization guide.

**Difficulty and catch:** Easy. It only proves from a terminal unless the console is shown too.

**Source:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/managing-vms

### 6. Snapshots, restores, clones and exports as Kubernetes objects

**What you show:** A live, guest-coordinated `VirtualMachineSnapshot`, a `VirtualMachineRestore` onto the same VM, a `VirtualMachineClone` into another namespace, and a `VirtualMachineExport` over HTTP, all plain `oc get`-able objects.

**Why it lands:** These become RBAC-governed objects a pipeline can gate on, no vendor SDK call needed.

**vSphere instead:** Native snapshot, clone, and Content Library OVA export; mature already, the win here is the object model.

**Needs:** All four CRD families already installed; check CSI VolumeSnapshot support per class.

**Status:** GA, including live and online snapshotting.

**Difficulty and catch:** Easy for the objects, medium to wire into Tekton. Not backup: no scheduling or off-cluster copy without OADP/Velero.

**Source:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/virtualization/backup-and-restore

### 7. Zero-install guardrails with ValidatingAdmissionPolicy

**What you show:** A `ValidatingAdmissionPolicy` rejecting a VM missing an instance type reference, or one pairing LiveMigrate with an RWO-only disk. Try creating a non-compliant VM and watch the API server reject it, no extra pod running.

**Why it lands:** An in-apiserver check with zero extra pods, versus standards enforced by convention or a licensed gate.

**vSphere instead:** Compliance profiles, manual review, or Aria blueprint and tagging rules at provisioning time.

**Needs:** Native ValidatingAdmissionPolicy and Binding, no operator. Neither Kyverno nor Gatekeeper is on this cluster.

**Status:** GA upstream since Kubernetes 1.30, well before OCP 4.20.

**Difficulty and catch:** Medium; CEL against nested specs is fussy. It only rejects, it cannot auto-fix a bad spec.

**Source:** https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/

### 8. Namespace tenancy: kubevirt.io roles plus ResourceQuota

**What you show:** Two namespaces as tenant boundaries, `kubevirt.io:edit` bound per namespace, a ResourceQuota capping `count/virtualmachines` and `requests.cpu`. A user in one namespace gets a 403 reading VMs in the other.

**Why it lands:** One construct, namespace plus RBAC plus quota, governs VMs and everything else together.

**vSphere instead:** Folders or resource pools plus separate CPU/memory shares, three constructs to keep in sync by hand.

**Needs:** Namespaces, default kubevirt.io ClusterRoles, ResourceQuota. 65 VMs and 119 instance types already exist.

**Status:** GA, long-standing default ClusterRoles.

**Difficulty and catch:** Easy, pure YAML. This is API-access and fairness, not isolation; two tenants can still share a node.

**Source:** https://kubevirt.io/user-guide/cluster_admin/authorization/

### 9. VM placement rules: affinity and anti-affinity as code

**What you show:** `nodeAffinity` pinning a VM to `disktype=ssd` nodes, and `podAntiAffinity` spreading two replica VMs across nodes, the same syntax already used for pods. Confirm with `oc get vmi -o wide`.

**Why it lands:** The same syntax app teams already write for containers, so placement becomes shared knowledge.

**vSphere instead:** DRS VM/Host affinity rules, configured per cluster in vCenter, invisible outside it.

**Needs:** Nothing; these are core VirtualMachine spec fields.

**Status:** GA, mirrors core Kubernetes pod affinity.

**Difficulty and catch:** Easy. A hard rule with too few matching nodes leaves a VM stuck Pending; check node count first.

**Source:** https://kubevirt.io/user-guide/compute/node_assignment/

### 10. NetworkPolicy micro-segmentation for VM traffic

**What you show:** A default-deny NetworkPolicy in a VM namespace, plus a narrow allow rule, for example a web-tier VM to a db-tier VM on port 5432, using ordinary NetworkPolicy YAML. Test the connection from inside the guest before and after.

**Why it lands:** One firewalling model covers VMs and containers side by side, no separate product or license.

**vSphere instead:** NSX-T Distributed Firewall, with flow visibility and L7-aware profiles a plain NetworkPolicy does not match.

**Needs:** OVN-Kubernetes and NetworkPolicy; NADs are already active in 8 namespaces here.

**Status:** GA, core OpenShift networking.

**Difficulty and catch:** Easy. No built-in flow-log UI, no Layer 7 rules; a free L3/L4 layer, not an NSX-DFW replacement.

**Source:** https://kubevirt.io/user-guide/architecture/

### 11. Real-time load rebalancing with the descheduler

**What you show:** Install the Kube Descheduler Operator and set profile `KubeVirtRelieveAndMigrate` (renamed from `DevKubeVirtRelieveAndMigrate`, GA in 4.20). It enables `LowNodeUtilization` with `EvictionsInBackground`, scored on actual CPU utilization from Prometheus combined with PSI (`devActualUtilizationProfile: PrometheusCPUCombined`), against deviation thresholds (Low 10%/10%, Medium 20%/20%, High 30%/30%, plus asymmetric variants). `devEnableSoftTainter` soft-taints hot nodes as a scheduling hint before any eviction. Set `mode: Automatic` (`Predictive` is a dry run only), matching `evictionLimits` to the HyperConverged CR's live-migration concurrency. A VM opts out with the annotation `descheduler.alpha.kubernetes.io/prefer-no-eviction` on its template annotations.

**Why it lands:** DRS load balancing is one of vSphere's most trusted features; this is Red Hat's GA answer.

**vSphere instead:** DRS already vMotions on real-time utilization, not just allocation. The real edge is PSI, a kernel pressure signal DRS does not read; the CPU side is parity.

**Needs:** The Kube Descheduler Operator (not installed here; catalog carries v5.3.4) and PSI enabled on every worker via a MachineConfig `psi=1` kernel argument, forcing a rolling reboot of the fleet.

**Status:** GA in OpenShift Virtualization 4.20, per the release notes.

**Difficulty and catch:** Hard, and reactive, not predictive: it responds to load already built up, with no forecasting like DRS. It reads CPU and PSI, not memory. Not Storage DRS or DPM: no disk balancing, no host power-down, no what-if planner. On this lab it was not demoed: the operator is not installed and PSI is not enabled, which would mean rebooting every worker.

**Source:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/openshift-virtualization-release-notes and https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/nodes/controlling-pod-placement-onto-nodes-scheduling

### 12. Live hot-plug: CPU, memory, disks and NICs with no reboot

**What you show:** Hot-add a disk and a vNIC to a running VM, then bump vCPU and memory, all with no reboot and a ping running throughout.

**Why it lands:** Each change is one command against a spec that is its own audit trail, not four vCenter dialogs.

**vSphere instead:** vSphere already hot-adds all four; this is parity, the win is a diffable object, not a new capability.

**Needs:** Disk hot-plug is long GA; CPU and memory hot-plug need instance type opt-in and ride the live-migration path.

**Status:** GA; CPU hot-plug shipped in 4.16 per Red Hat's own blog. A 4.17 memory-hotplug claim appears elsewhere but was not confirmed here.

**Difficulty and catch:** Medium. It rides live migration, so a VM on plain `iscsi` (RWO) cannot hot-plug CPU or memory.

**Source:** https://www.redhat.com/en/blog/whats-new-openshift-virtualization-416

## Ideas from the mixed-application lens

Each idea puts a VM and a container component in one namespace or request path, on one Kubernetes object, instead of separate VM and container tools.

### 13. Service and Route in front of a VM

**What you show:** A VM behind a plain Service and Route, like a pod app.

**Why it lands:** Not IP mobility, vSphere already keeps a VM's IP across vMotion. The win is one config surface and GitOps flow for both.

**vSphere instead:** A static IP plus a manually managed NSX Advanced Load Balancer or F5 VIP.

**Needs:** Nothing beyond OpenShift Virtualization.

**Status:** GA, a standard doc chapter.

**Difficulty and catch:** Easy; really just `kubectl expose vm`. A consistency win, not a resiliency one.

**Source:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/networking#virt-exposing-vm-with-service

### 14. Gateway API and Service Mesh routing to a VM

**What you show:** One gateway splits traffic between a VM-backed and a pod-backed Service; the VM's sidecar adds mTLS and traffic-splitting.

**Why it lands:** NSX-ALB or F5 do this too, but as a separate product for a separate team; here it is one Gateway API resource.

**vSphere instead:** NSX-ALB or F5 GSLB and VIP pools, apart from Ingress.

**Needs:** OpenShift Service Mesh with the VM sidecar-injection annotation on the VMI.

**Status:** Sidecar-mode VM mesh is standard; ambient mode is only in OSSM 3.4 docs, and this lab runs OSSM 2.6.

**Difficulty and catch:** Medium; demo sidecar mode, not ambient, without a 3.x upgrade plan.

**Source:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/networking#virt-connecting-vm-to-service-mesh

### 15. Container front end talking to a database VM, one NetworkPolicy

**What you show:** A container front end reaches a database VM, restricted by one NetworkPolicy naming the allowed pods and port; the VM's pod (virt-launcher) takes plain NetworkPolicy like any workload.

**Why it lands:** On vSphere plus NSX the same rule is a distributed firewall rule owned by a separate team; here it is one YAML object.

**vSphere instead:** NSX distributed firewall rules or VM firewall groups, outside Kubernetes.

**Needs:** Standard NetworkPolicy, already GA; correct virt-launcher labels.

**Status:** GA.

**Difficulty and catch:** Check the real labels first; a default-deny in a namespace that never had one, 65 VMs and 8 NAD namespaces here, can break existing traffic.

**Source:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/network_security

### 16. Developer Hub template: provision a VM plus its app from one form

**What you show:** A Backstage form takes a VM size and app image, producing a VirtualMachine, from one of 119 instance type and preference objects here, plus a Deployment, Service, and Route, one catalog entry in git.

**Why it lands:** Aria's catalog has no Deployment concept, so a mixed request splits across two catalogs; here it is one.

**vSphere instead:** Aria blueprints provision the VM; the container part uses a separate CI/CD catalog.

**Needs:** Developer Hub with the Kubernetes plugin, GitOps already present, and a hand-built template.

**Status:** Developer Hub is GA; no shipped kubevirt scaffolder action exists.

**Difficulty and catch:** Hard; real build work plus an RBAC review, since the form grants VM-create rights.

**Source:** https://github.com/redhat-developer/rhdh-plugins

### 17. OpenShift AI notebook next to a GPU-backed VM

**What you show:** A notebook and a GPU VM, say a legacy CAD box, both scheduled on GPU Operator and NFD hardware, one inventory for both.

**Why it lands:** vSphere's vGPU manager carves a GPU for a VM, but container GPU access needs a separate GPU Operator elsewhere; here it is one inventory.

**vSphere instead:** NVIDIA vGPU manager as an ESXi VIB for VMs; container GPU access, if any, runs separately.

**Needs:** GPU Operator and NFD, already present; passthrough or vGPU configuration on the HyperConverged CR's `permittedHostDevices` list.

**Status:** GA; standard Managing VMs chapters.

**Difficulty and catch:** Passthrough locks a card to one VM; only vGPU-licensed cards share. Check the model first.

**Source:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/managing-vms#virt-configuring-virtual-gpus

### 18. One alert pipeline and one dashboard for both halves

**What you show:** A Grafana dashboard shows VM and pod metrics from one namespace side by side; one Alertmanager routes a VM disk-pressure and a pod crash-loop alert alike.

**Why it lands:** vSphere splits VM health (vCenter or Aria) from pod health (a separate stack); here it is one Prometheus, one Alertmanager, one Grafana.

**vSphere instead:** vCenter or Aria alarms cover VMs; a separate stack covers pods, joined by hand.

**Needs:** Cluster Observability Operator and Grafana Operator, both present, plus a shared label convention.

**Status:** GA; already installed here.

**Difficulty and catch:** The console ships separate built-in dashboards; a mixed view means authoring one yourself.

**Source:** https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/monitoring

## Three you could run tomorrow on this cluster

These three need no new operator and no feature gate.

**1. VM as code: instance type catalog**
1. `oc get virtualmachineclusterinstancetypes`.
2. Pick a pair, for example `cx1.medium` and `rhel.9`.
3. Create a VM referencing them by name.
4. Show `oc get vm`/`vmi` running; no cpu or memory block in the spec.
5. Edit the instance type's memory in git, apply, restart, show the change.

**2. Scheduled VM lifecycle with a CronJob**
1. Pick two or three labeled dev/test VMs from the 65 already here.
2. Create a ServiceAccount and a Role/RoleBinding scoped to that namespace.
3. Write a CronJob running `virtctl stop` nightly and one running `virtctl start` mornings.
4. Apply both; trigger one manually with `kubectl create job --from=cronjob/...`.
5. Show the CronJob, RBAC, and schedule in the same git repo as the VMs.

**3. GitOps for VirtualMachine objects with self-heal**
1. Export a few VM, DataVolume, and NetworkAttachmentDefinition manifests into git.
2. Add sync-wave annotations so DataVolumes and NADs land first.
3. Point an ArgoCD Application at the repo with automated sync and `selfHeal: true`.
4. Sync once, confirm Synced and Healthy.
5. Hand-edit a running VM's memory outside git and show ArgoCD revert it.

## What is genuinely difficult

**1. RWX-vs-RWO storage, plus the migration network.** Live migration, hot-plug, and storage migration all need RWX storage; a VM on RWO storage is blocked or restarted, not migrated, and migration traffic competes with pod traffic without a dedicated migration network. Mitigation: run `oc get storageclass` first, standardize new disks on an RWX class, and set up a dedicated migration network early. Source: https://kubevirt.io/user-guide/compute/live_migration/

**2. Self-heal fighting a human's emergency fix.** Self-heal silently reverts an on-call fix unless the team has a pause path. Mitigation: give the app a suspend step or a maintenance-window label, and drill it. Source: https://kubevirt.io/user-guide/cluster_admin/gitops/

**3. No vendor-shipped remediation content.** There is no Red Hat rulebook or pipeline library for VM problems; every one is authored in house. Mitigation: budget real time for it. Source: https://kubevirt.io/monitoring/runbooks_index.html

**4. Tech Preview as a one-way door.** Enabling a `TechPreviewNoUpgrade` gate, such as VM Storage Live Migration, blocks future upgrades. Mitigation: do not enable it on a shared cluster with real VMs; demo from a recording. Source: https://access.redhat.com/solutions/7089972

**5. Packaging changes between versions.** The Tekton Tasks Operator older docs describe is gone; VM tasks now come from ssp-operator and ArtifactHub. Mitigation: pull the current catalog before following any guide. Source: https://access.redhat.com/solutions/7093978

**6. Assuming a product is wired up.** This cluster has 11 aap-* namespaces and AAP/EDA CRDs, but no confirmed OLM Subscription or reachable EDA controller. Mitigation: confirm with a read-only check first; namespace names are not proof of an install. Source: https://www.redhat.com/en/technologies/management/ansible/event-driven-ansible

**7. Placement rules that cannot be satisfied.** A hard affinity rule written without checking node count leaves a VM stuck Pending. Mitigation: run `oc get nodes --show-labels` first. Source: https://kubevirt.io/user-guide/compute/node_assignment/

**8. Signal-driven automation needs a warm-up, and it is reactive, not predictive.** The descheduler needs several scrape intervals before it acts, and it responds to load already built up rather than forecasting ahead like DRS. Mitigation: start the stress workload minutes ahead. Source: https://developers.redhat.com/blog/2025/06/03/dynamic-vm-cpu-workload-rebalancing-load-aware-descheduler

**9. Windows and the guest agent both need manual care.** Windows has no native virtio drivers, so a driver disk or golden image is needed, plus a clock check after migration; qemu-guest-agent is optional, so a missing agent gives crash-consistent snapshots with no error. Mitigation: build one hardened golden image with drivers, time-sync, and the agent verified, then clone from it. Source: https://kubevirt.io/user-guide/user_workloads/guest_agent_information/

**10. Day-1 learning curve, and no built-in capacity or what-if tool.** The console covers VM lifecycle but not vCenter-style topology maps or one-click patching, and there is no Aria-style what-if planner, only Prometheus queries and quotas. Mitigation: budget weeks for admins moving from vSphere, and track capacity on the observability stack already installed. Source: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/virtualization/index

**11. Performance tuning and node maintenance are manual, per-VM opt-ins.** CPU pinning, hugepages, and NUMA all need node prep, Guaranteed QoS, a kernel argument, a reboot, before any VM can use them; single-node maintenance is a hand-run `oc adm drain`, since the Node Maintenance Operator is not installed. Mitigation: build audited instance types for performance-critical VMs, and install the Node Maintenance Operator if node work is routine. Source: https://kubevirt.io/user-guide/compute/dedicated_cpu_resources/

**12. The monitoring stack has real, underestimated cost and a blind spot.** KubeVirt exposes 67 `kubevirt_vmi_` metrics alone, multiplied per disk, NIC, and vCPU, so sizing Prometheus, Loki, and Grafana is real work; separately, the upgrade-completion alert `OutdatedVirtualMachineInstanceWorkloads` needs 24 continuous hours to fire, and a monitoring-pod restart during an upgrade resets that countdown to zero. Mitigation: size the stack from each project's own sizing guide, and query `kubevirt_vmi_number_of_outdated` directly after an upgrade instead of waiting on the alert. Source: https://github.com/kubevirt/monitoring/blob/main/docs/metrics.md

**13. Migrating in from VMware, and backing up VMs, both need an extra operator not installed here.** The Migration Toolkit for Virtualization handles inbound migration, with real warm-migration limits (Changed Block Tracking required, a 28-snapshot cap); the snapshot, clone, and export CRDs already here are building blocks, not scheduled off-cluster backup, which needs OADP configured separately. Mitigation: pilot MTV on a small batch first, and install and test-restore OADP if scheduled VM backup is required. Source: https://docs.redhat.com/en/documentation/migration_toolkit_for_virtualization/2.9/html-single/installing_and_using_the_migration_toolkit_for_virtualization/index

Two more lessons: a single-cluster pilot cannot show ACM's fleet-wide payoff, and any GA or tech-preview claim should be checked against the target version's own release notes.

## What to say to a skeptic

Storage vMotion is more mature than anything shown here; KubeVirt's storage migration is still tech preview, and that should be said first, not last. NSX-T Distributed Firewall does more today than a plain NetworkPolicy, with flow visibility and Layer 7 profiles a free CNI feature does not match. A vSphere admin's workflow library for common alarms is real and pre-built; every rulebook and pipeline here is something your own team writes and owns. vSphere DRS already balances hosts on real-time utilization, not just allocation, so the descheduler's edge is one new signal, PSI, not a smarter DRS. The descheduler is also reactive, not predictive: it acts on load that has already built up, where vSphere's predictive DRS forecasts ahead of it. None of that changes the point: the same VirtualMachine, RBAC, NetworkPolicy, and GitOps objects your app teams already use now also cover VMs, in the same git repo and audit trail, a real change in operating model even where the underlying capability is only parity.
