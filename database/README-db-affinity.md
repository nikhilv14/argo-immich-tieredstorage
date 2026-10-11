# Immich DB: node affinity & failover (2026-10-11)

## Pod affinity: hard pin -> soft preference

`statefulset.yaml` previously used `requiredDuringScheduling` nodeAffinity to
pin `immich-db-0` to `k3s-node1`. If node1 went down, the DB could never be
rescheduled and Immich stayed down until node1 returned — despite the
Longhorn volume `immich-db-primary` having a second replica on
`k3s-server-hp-g9`. It is now `preferredDuringScheduling` (weight 100), so
the pod stays on node1 normally and can fail over when node1 is unavailable.

## PV-level node affinity: found and removed (manual cluster-state fix)

The pod-affinity change alone was NOT sufficient: the Longhorn **PV**
`pvc-9439e16c-af1f-4322-99ff-57064989aae0` (immich-db-primary) had a
`spec.nodeAffinity` hard-pinning it to `k3s-node1`, so the scheduler rejected
every other node ("didn't match PersistentVolume's node affinity"). PV
nodeAffinity is immutable on this cluster — the PV had to be recreated.

Procedure used (safe: Longhorn volume + replicas are never touched):

1. `kubectl patch pv <pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`
2. `kubectl delete pvc -n immich immich-db-primary` (releases the PV so its
   `pv-protection` finalizer clears; CAUTION: the StatefulSet's
   volumeClaimTemplate auto-recreates the PVC immediately — scale the STS to
   0 FIRST, or it will bind the new PVC to a fresh EMPTY volume)
3. `kubectl delete pv <pv>` (Retain keeps the Longhorn volume + replicas)
4. Recreate the PV with the same `csi` driver/volumeHandle and
   `claimRef` (name+namespace only, no uid) — no `nodeAffinity`
5. Recreate the PVC with `spec.volumeName: <pv>` and scale the STS back up
6. Postgres opens the existing pgdata normally (verified: 7102 assets intact)

NOTE: `immich-redis`'s PV (`pvc-820332aa-...`) had the SAME node1 pin — fixed
2026-10-11 with the same procedure (PV recreated without nodeAffinity,
Retain policy, PVC name-bound via PV claimRef). Redis data intact.

## Redis placement (2026-10-11)

After the PV swap, redis immediately cycled in `ContainerCreating` on
`k3s-worker-z690` — the same Longhorn attach failure the DB hit. The redis
Deployment had no node affinity at all. It now has:
- `requiredDuringScheduling`: hostname `NotIn [k3s-worker-z690]` (z690 cannot
  host ANY Longhorn-attached volume until that is debugged)
- `preferredDuringScheduling` weight 100: `k3s-node1` (keeps it next to its
  volume replica, matching the old pin's intent)

## ArgoCD gotchas encountered (worth remembering)

- The `root` app is an app-of-apps with selfHeal: it re-applies the CHILD
  Application objects, silently re-enabling `syncPolicy.automated` on them.
  To do manual surgery (scale to 0, PV/PVC swaps), disable selfHeal on
  `root` FIRST, then on the child apps, and re-enable afterwards.
- The redis Deployment is tracked by `immich-database` (not
  `immich-storage`); DB PVCs are in `immich-storage`.
- A failing sync RETRIES indefinitely (3 min apart) and re-applies ALL
  resources in the app each time — it fought the redis scale-down even with
  selfHeal "disabled" (the in-flight op predated the change). Root cause of
  the loop: live PVC `immich-db-primary` had `volumeName` set while the git
  manifest did not (immutable field → apply error). Fixed by adding
  `volumeName: pvc-9439e16c-...` to `storage/pvc-config.yaml`.

## Failover test result (cordon test)

- Cordoned `k3s-node1` + `k3s-worker-z690`, deleted `immich-db-0`:
  pod rescheduled to `k3s-server-nuc`, volume attached, `pg_isready` OK,
  all 7102 assets present. Uncordoned, deleted pod again: returned to
  `k3s-node1` via the weight-100 preference. End state: DB on node1, healthy.

## Known limitation: z690 cannot host Longhorn-attached DB volumes

Longhorn volume attach to `k3s-worker-z690` fails with CSI
`DeadlineExceeded` (both the DB volume and a freshly provisioned empty
volume). The node runs an instance-manager + engine image, but engine attach
times out — likely an LXC-layer restriction. Until debugged, z690 is not a
valid failover target for the DB; viable targets are `k3s-server-hp-g9`
(holds the DB volume's second replica) and `k3s-server-nuc`.

The DB volume's `persistentVolumeReclaimPolicy` is now `Retain` (was
`Delete`) as protection against accidental PV deletion; the recreated PVC is
name-bound to the retained PV.
