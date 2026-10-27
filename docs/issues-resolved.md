
UNFINISHED - BRAIN DUMP - WILL REVISE/EDIT
Syncthing being source of truth

Changes fo obsidian (automated git commmit)


### Data backup could prune real snapshots when the primary drive was missing

**Problem.** The data script checked only that the *backup* drive was present. The primary drive is mounted with `nofail`, so when it's missing the Pi still boots and `/media/HDD-Seagate-1TB-Primary` is just an empty directory on the SD card. In that state the script:

1. Passed its guard, because the backup drive was fine.
2. Backed up the empty directory. Restic treats that as a successful backup.
3. Sent the success heartbeat, so Uptime Kuma showed green.
4. Ran `forget --keep-daily 7 --prune`, which counted the empty snapshot as that day's backup.

After seven days of this, retention would have pruned every snapshot that still held real data, without a single alert.

**Fix.** [`restic_backup_data.sh`](../filesystem/root/.restic/restic_backup_data.sh) now checks `mountpoint -q /media/HDD-Seagate-1TB-Primary` before doing anything else. If the drive isn't mounted, the script exits with status 1, so nothing is backed up or pruned. The missing heartbeat then triggers a Signal alert.

The system backup didn't need this guard. Its source is `/`, which is always present, and it excludes `/media`.

