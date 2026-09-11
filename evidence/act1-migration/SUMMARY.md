# Act 1 -- Live Migration of vm-demo

## What happened

`virtctl migrate vm-demo -n demo-vms` was run once. It created VMIM
`kubevirt-migrate-vm-vt94m`, which went Pending -> Scheduling -> Scheduled ->
PreparingTarget -> TargetReady -> Running -> **Succeeded**. The VM moved from
node `ec-f4-bb-ed-07-a8` to node `24-6e-96-33-24-90` and never left the
`Running` phase -- 18 poll ticks (every 3-9s, actual cadence limited by API
round-trip time, see `timeline.csv`) all show `vmi_phase=Running`. No tick
recorded any other VMI phase.

## Headline numbers

| Metric | Value | Source |
|---|---|---|
| Source node | `ec-f4-bb-ed-07-a8` | `before_after_node_state.txt` |
| Target node | `24-6e-96-33-24-90` | `vmim-final.yaml`, `before_after_node_state.txt` |
| VMIM total wall time (creation to Succeeded phase) | 47s (13:37:45Z to 13:38:32Z) | `vmim-final.yaml`, `phase_transition_sum.json` (sum=47, count=1) |
| Actual live-copy duration (migrationState.startTimestamp to endTimestamp) | 14s (13:38:17Z to 13:38:31Z) | `vmi-migrationState.json` |
| Data actually processed (kubevirt_vmi_migration_data_processed_bytes) | 889,836,348 bytes (~848.6 MiB) | `range_data_processed_bytes.json`, `timeline.csv` |
| Data remaining at completion | 0 bytes | `range_data_remaining_bytes.json` |
| Total guest data eligible to migrate (kubevirt_vmi_migration_data_total_bytes) | 4,313,391,104 bytes (~4.02 GiB, i.e. the VM's assigned memory) | `data_total_bytes.json` |
| Transfer rate observed (kubevirt_vmi_migration_disk_transfer_rate_bytes) | 466,555,260 bytes/sec (~445 MiB/s) -- only value ever scraped, see caveat below | `disk_transfer_rate_bytes.json`, `peak_disk_transfer_rate_20m.json` |
| kubevirt_vmi_migration_succeeded{vmi="vm-demo"} | 1 | `migration_succeeded_flag_unfiltered.json` |
| migrationState.completed / .failed | true / absent (not failed) | `vmi-migrationState.json` |
| kubevirt_vmi_migrations_in_running_phase (cluster-wide sum) | 0 -> 1 during the migration -> back to 0 | `timeline.csv` |
| kubevirt_vmi_migrations_in_pending_phase | stayed 0 the whole time | `timeline.csv` (Pending phase lasted under one 3s tick before Scheduling, too fast for this gauge to register) |

## Duration and bytes moved

The whole operation, from `virtctl migrate` to the VMIM reporting
`Succeeded`, took **47 seconds**. Of that, only the last **14 seconds** were
the actual live-copy ("PreCopy") phase -- the rest was scheduling and target
pod preparation. In those 14 seconds, KubeVirt moved **~849 MiB** of dirty
memory pages (data_processed_bytes) out of a **~4.02 GiB** total
addressable guest memory, i.e. it did not have to re-send the whole VM's
memory, only what changed since the last pre-copy iteration.

## Peak transfer rate -- caveat

A single value, 466,555,260 bytes/sec (~445 MiB/s), was returned every time
`kubevirt_vmi_migration_disk_transfer_rate_bytes` was queried, including a
`max_over_time(...[20m])` and a 6-minute `query_range` at 15s steps
(`range_disk_transfer_rate_bytes.json`). That range query shows the exact
same number, flat, at every sample point from the first time the series
existed onward. The reason: the whole PreCopy data-copy phase (14s) was
shorter than the Prometheus/Thanos scrape interval, so the metric endpoint
was only ever scraped **once** while the migration was in flight -- and the
value it captured was already the final one. There is no captured ramp-up;
this is a single data point, not a measured peak across an interval. Treat
"445 MiB/s" as "the one rate sample KubeVirt exposed," not as a verified
maximum throughput.

## Metric-name mismatches found on this cluster

Two metric names requested for this track do not exist anywhere on this
cluster (confirmed via `/api/v1/label/__name__/values` and empty-result
queries both before and after the migration -- see
`confirm_absent_data_bytes_total.json`,
`confirm_absent_memory_transfer_rate_bytes.json`):

- `kubevirt_vmi_migration_data_bytes_total` -- does not exist. The metric
  that does exist and does populate is `kubevirt_vmi_migration_data_total_bytes`
  (a gauge, not a counter -- `increase()` over 15m on it would not be
  meaningful the way it is on a counter, and there is no counter of this
  name to `increase()` on this cluster).
- `kubevirt_vmi_migration_memory_transfer_rate_bytes` -- does not exist. The
  metric that exists and populated during this run is
  `kubevirt_vmi_migration_disk_transfer_rate_bytes` (see caveat above).

## Histogram p50/p95 -- could not be computed the normal way

`histogram_quantile(0.50/0.95, sum(rate(kubevirt_vmi_migration_phase_transition_time_from_creation_seconds_bucket[15m])) by (le))`
returned `NaN` for every phase, both cluster-wide and broken out `by (phase)`
(`histogram_p50.json`, `histogram_p95.json`, `histogram_p50_byphase.json`,
`histogram_p95_byphase.json`). Root cause, confirmed from
`phase_transition_count.json`: **this migration is the only one this
virt-controller pod has ever recorded** (_count = 1 for every phase,
pod has been running since 2026-08-12). With exactly one observation per
phase and that phase's bucket series freshly created seconds before the
query, `rate()` has too little history to extrapolate a slope, and
`histogram_quantile` divides 0/0 into `NaN`. This is a sample-size artifact
of running one migration on a demo VM, not a metrics bug.

The real number is available directly from the raw buckets and the
_sum/_count pair instead:
- `phase_transition_time_from_creation_seconds_sum{phase="Succeeded"}` = 47,
  `_count` = 1 -> the one observation was exactly 47 seconds
  (`phase_transition_sum.json`, `phase_transition_count.json`).
- Raw bucket dump (`histogram_buckets_succeeded_phase.json`) confirms it:
  `le="40"` -> 0 observations, `le="50"` -> 1 observation. The single sample
  falls in (40s, 50s], consistent with the exact value of 47s.

With n=1, p50 and p95 are the same 47-second data point by definition --
there is no distribution to describe yet.

## Dirty-rate metrics

Per instructions, `kubevirt_vmi_migration_dirty_memory_rate_bytes` was
**not** queried for this track (known accuracy bug upstream).

## VM stayed Running -- no findings

Every row of `timeline.csv` (18 rows spanning the whole migration and a
30-second post-Succeeded grace period) shows `vmi_phase=Running`. No tick
recorded any other phase, so there is nothing to flag for "did the VM stay
up."

## What vCenter shows instead

In vCenter, live migration ("vMotion") gives you a real-time progress bar
with a percentage and ETA while the transfer is happening; here, because
KubeVirt's transfer metrics are scraped on a ~15-30s Prometheus interval and
this migration completed in 14 seconds, the Thanos-backed dashboards never
showed a moving number at all -- they went straight from "no data" to the
single final byte-count, the same "progress bar, then one number after
completion" experience the track description predicted, just for a
different underlying reason (scrape cadence vs. vCenter's own polling of
the ESXi host).

## Files in this directory

- `timeline.csv` -- one row per poll tick (VMIM phase, migration data
  metrics, cluster-wide running/pending migration gauges, VMI phase/node).
- `migrate_and_poll.log` -- human-readable log of the same run.
- `virtctl_migrate_output.txt` -- raw `virtctl migrate` output and exit code.
- `vmim-final.yaml` -- final VirtualMachineInstanceMigration object.
- `vmi-vm-demo-final.yaml`, `vmi-migrationState.json` -- final VMI object and
  its status.migrationState block.
- `before_after_node_state.txt` -- node before/after, plus current
  `oc get vmi/vmim -o wide`.
- `baseline_migrations_in_running_phase.json`,
  `baseline_migration_data_bytes_total.json` -- pre-migration baselines.
- `histogram_p50*.json`, `histogram_p95*.json`, `histogram_raw_buckets.json`,
  `histogram_buckets_succeeded_phase.json`, `phase_transition_count.json`,
  `phase_transition_sum.json` -- histogram evidence and the NaN root cause.
- `data_total_bytes.json`, `disk_transfer_rate_bytes.json`,
  `peak_disk_transfer_rate_20m.json`, `range_data_processed_bytes.json`,
  `range_data_remaining_bytes.json`, `range_disk_transfer_rate_bytes.json` --
  per-VM migration data/rate metrics, point-in-time and ranged.
- `migration_succeeded_flag.json`, `migration_succeeded_flag_unfiltered.json`
  -- the kubevirt_vmi_migration_succeeded confirmation (note: this metric
  labels the VM as `vmi=`, not `name=`, unlike the data/rate metrics).
- `confirm_absent_data_bytes_total.json`,
  `confirm_absent_memory_transfer_rate_bytes.json`,
  `increase_migration_data_bytes_15m.json` -- proof the two requested metric
  names do not exist on this cluster.
