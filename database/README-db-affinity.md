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
- Since the DB StatefulSet now hard-excludes `k3s-worker-z690`, future
  drills only need to cordon `k3s-node1` (z690 is filtered by the scheduler
  itself, not by cordoning).

## Known limitation: z690 cannot host Longhorn-attached volumes (root-caused 2026-10-11)

Longhorn volume attach to `k3s-worker-z690` fails with CSI `DeadlineExceeded`
(the DB volume, redis, and a freshly provisioned empty volume — all identical).
The node runs an instance-manager + engine image, but engine attach times out.
z690 is not a valid failover target for the DB or any Longhorn-backed
workload; valid targets are `k3s-server-hp-g9` (holds the DB volume's second
replica) and `k3s-server-nuc`. Accordingly, both `statefulset.yaml` (DB) and
`redis.yaml` carry a HARD `NotIn [k3s-worker-z690]` exclusion plus the
weight-100 node1 preference.

### Root cause (fully debugged 2026-10-11 — three layers, two fixed, one unfixable)

Evidence trail from `instance-manager` engine logs during a live attach
attempt (the CSI error is a generic timeout; the engine logs hold the real
cause):

1. **`iscsi_tcp` kernel module missing (FIXED).** The Longhorn v1 engine
   creates its userspace `tgt` target fine, then acts as the *initiator*: it
   `nsenter`s into the host (LXC) mount+net namespaces and runs `iscsiadm`,
   which failed with `kmod_module_insert_module: could not find module by
   name='iscsi_tcp'` — the LXC's `/lib/modules` was empty, so the module
   couldn't auto-load for the shared Proxmox kernel.
   *Fix applied (PVE host `192.168.12.201`):* `modprobe iscsi_tcp dm_crypt`
   and persisted in `/etc/modules-load.d/longhorn.conf`; LXC 108 config
   (`/etc/pve/lxc/108.conf`) got
   `lxc.mount.entry: /lib/modules usr/lib/modules none bind,optional,create=dir 0 0`
   (note: the container's `/lib` is a symlink to `usr/lib` on merged-usr
   Debian 13 — a target of `lib/modules` is silently skipped by LXC, the
   target must be `usr/lib/modules`). After an LXC stop/start, `modprobe`
   works inside the LXC and discovery succeeds.
2. **`cryptsetup` missing (FIXED).** Node CR `RequiredPackages=False` →
   installed on z690; CR now shows `RequiredPackages=True` and
   `KernelModulesLoaded=True (dm_crypt)`. (`NFSClientInstalled=False`
   remains — the manager can't read `/proc/config.gz` in the LXC; cosmetic,
   NFS RWX works fine.)
3. **Kernel iSCSI netlink is `init_net`-only (UNFIXABLE in an LXC).** With
   modules loaded, discovery succeeds and the TCP connect to the engine
   portal succeeds, but iscsid's session creation fails with
   `sendmsg: bug? ctrl_fd` → iscsiadm error 18 (`could not communicate to
   iscsid`). Direct evidence: a raw `AF_NETLINK` probe (protocol
   `NETLINK_ISCSI=8`) `sendto` to the kernel **succeeds from the PVE host's
   init_net but returns `ECONNREFUSED` from the LXC's netns** — the
   kernel-side iSCSI netlink socket is created in `init_net` only
   (mainline `drivers/scsi/scsi_transport_iscsi.c`:
   `netlink_kernel_create(&init_net, NETLINK_ISCSI, ...)`, and
   `net/netlink/af_netlink.c` scopes unicast lookup to the *sender's* netns,
   so a container netns can never reach it). The LXC maintainer confirmed
   the same in lxc/lxc#177 ("turn off netns or change the kernel"), the
   netns-aware patchset (LWN 922664) was never merged, and Longhorn has the
   same open question (longhorn/longhorn#2585 → discussion #9284,
   open-iscsi#214).

**Eliminated hypotheses:** configfs/LIO target-side (v1 engine target is
userspace tgt and starts fine — target id allocated, portal listening);
network/portal reachability (TCP connect to the portal succeeds);
disk-space/host thin-pool pressure (LXC disk 83G free; PVE thin pool at 75%
— worth monitoring, unrelated to this error).

### Options if z690 must host Longhorn volumes someday

- **Convert z690 to a VM** with UHD770 passthrough (the proven pattern —
  `k3s-server-nuc` is a VM with passed-through UHD660). VMs have their own
  kernel = init_net = iSCSI works. This is the clean fix.
- **Share the PVE host netns with the LXC** (`lxc.net.0.type = none`) —
  unsupported by PVE's net0 config, big blast radius (shared IP/ports).
  Not recommended.
- **Longhorn v2 data engine** — avoids iSCSI entirely but needs
  `/dev/uio*`/NVMe passthrough for SPDK; not applicable to this cluster's
  filesystem-backed disks.

**Left in place (harmless, useful if the limitation is ever lifted):** PVE
host `/etc/modules-load.d/longhorn.conf` (iscsi_tcp + dm_crypt), the LXC
`/lib/modules` bind-mount, and `cryptsetup` on z690. The node CR conditions
are now green except the cosmetic `NFSClientInstalled` check. The
`iscsid.socket` unit inside the LXC was disabled to stop a pointless
socket-activation crash loop (`sendmsg: bug?` every 5s) — attach was
already impossible either way.

The DB volume's `persistentVolumeReclaimPolicy` is now `Retain` (was
`Delete`) as protection against accidental PV deletion; the recreated PVC is
name-bound to the retained PV.
