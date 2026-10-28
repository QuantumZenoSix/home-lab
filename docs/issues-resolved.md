### Data backup could prune real snapshots when the primary drive was missing

**Problem.** The data script checked only that the *backup* drive was present. The primary drive is mounted with `nofail`, so when it's missing the Pi still boots and `/media/HDD-Seagate-1TB-Primary` is just an empty directory on the SD card. In that state the script:

1. Passed its guard, because the backup drive was fine.
2. Backed up the empty directory. Restic treats that as a successful backup.
3. Sent the success heartbeat, so Uptime Kuma showed green.
4. Ran `forget --keep-daily 7 --prune`, which counted the empty snapshot as that day's backup.

After seven days of this, retention would have pruned every snapshot that still held real data, without a single alert.

**Fix.** [`restic_backup_data.sh`](../filesystem/root/.restic/restic_backup_data.sh) now checks `mountpoint -q /media/HDD-Seagate-1TB-Primary` before doing anything else. If the drive isn't mounted, the script exits with status 1, so nothing is backed up or pruned. The missing heartbeat then triggers a Signal alert.

The system backup didn't need this guard. Its source is `/`, which is always present, and it excludes `/media`.

<br />

### Syncthing causing lots of conflicts between devices.

**Problem.** Once I set up syncthing to sync my Obsidian notes between my Pi, laptops, and phone, it became clear that if two devices routinely make edits to the sam file(s) and aren't online at the same time, they won't be aware of each others changes. Once they do sync up, Syncthing will do it's best to get things straight (analyzing timestamps and other metadata) but often things will be so conflicted they will be in need of manual intervention.

**Fix.** The host (Raspberry Pi) being source of truth. Having one "always-on" hub serving as thew central arbiter of what is the latest and greatest, all my other devices can sync with that instead of syncing with each other. All devices will have a bidirectional communication, but instead of with multiple other devices they talk directly and only to the Pi. This works much better and fixed the issue I was seeing before with constant and excessive conflicts. 

Sort of a sidenote to this, having my Obsidian Vault set up as a local git repo and having a script auto-commit daily changes allows me to go back when I need to very quickly without having to perform a restic restore. Also allows me to view a diff of recent changes just to get a glimpse of what's changed.
Changes fo obsidian (automated git commit).

