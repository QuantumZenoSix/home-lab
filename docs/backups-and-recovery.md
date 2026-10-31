# Backups and Recovery

Two Restic jobs back up the Pi to two encrypted repositories: one on the secondary SSD and one offsite in Backblaze B2. This document describes what each job covers, how jobs are monitored, and how to check the repositories and restore from them.

## Backup jobs

Both scripts run from root's crontab and live in [`/root/.restic/`](../filesystem/root/.restic/).

| | System backup | Data backup |
|---|---|---|
| Script | [`restic_backup_system.sh`](../filesystem/root/.restic/restic_backup_system.sh) | [`restic_backup_data.sh`](../filesystem/root/.restic/restic_backup_data.sh) |
| Schedule | `30 3 * * *` (03:30) | `0 5 * * *` (05:00) |
| Source | `/` | `/media/HDD-Seagate-1TB-Primary` |
| Destinations | Local repo, then B2 | Local repo, then B2 |
| Snapshot `--host` tag | `system-ada-pi-server` | `data-primary` |
| Compression | `max` | `max` |
| Retention, local repo | `forget --keep-daily 7 --keep-weekly 6 --prune` | `forget --keep-daily 7 --prune` |
| Retention, B2 repo | `forget --keep-daily 30 --keep-monthly 12 --prune` | `forget --keep-daily 7 --prune` |

The two jobs use different `--host` tags, so each one's retention and restores apply only to its own snapshots.

Each repository applies its own retention. In the local repository the system job keeps 7 daily and 6 weekly snapshots. In B2 it keeps more: 30 daily and 12 monthly. Restic keeps a snapshot if any of its rules matches it. So the local repository holds a system snapshot for each of the last 7 days and one for each of the last 6 weeks, and B2 holds one for each of the last 30 days and one for each of the last 12 months. B2 therefore covers mistakes found long after they happened, while the local repository covers the recent ones. The data job still uses `--keep-daily 7 --prune` in both repositories.

### Why two repositories instead of an rclone copy

Another option was to keep a single Restic repository on the secondary SSD and copy its files to B2 with rclone. Two independent Restic repositories work better:

- **`rclone sync` spreads damage.** A sync makes the bucket match the local repository. If the local repository is corrupted, or someone deliberately wipes it, the next sync carries that into B2, and the offsite copy is lost too.
- **`rclone copy` leaves obsolete files.** A copy never deletes, so pack and index files that the local prune has removed stay in the bucket. They take up storage and leave the bucket out of step with the repository it's supposed to mirror.
- **Restores from a copied repository are slower.** If the local repository is destroyed, the usual way to restore from an rclone copy is to download all of it and rebuild the repository locally before the restore can start. A Restic repository in B2 can be restored from directly.

With two repositories:

1. **Local recovery.** Restore quickly from the secondary SSD without downloading anything.
2. **Offsite recovery.** If the server, or both local drives, are lost, restore straight from the B2 repository.
3. **Independent retention.** Each repository can keep a different number of snapshots. The system job now does this: 7 daily plus 6 weekly locally, 30 daily plus 12 monthly in B2. That gives more recovery points to choose from without filling the SSD.
4. **Independent repository health.** Each repository is checked and maintained on its own. The system script's [repository check](#repository-checks) runs against each one, and a failure in one doesn't stop the other.
5. **No automatic deletion propagation.** Pruning or deleting snapshots in the local repository doesn't prune the B2 repository, and the reverse is also true.

Encryption doesn't suffer either. Restic encrypts data on the Pi before uploading it, so B2 only ever stores encrypted data, the same as it would with an rclone copy of the encrypted local repository. Each repository also has its own password. So the primary drive and the system both go to two repositories: one local and one offsite.

The trade-off is that each job runs its backup twice, once per repository. The two repositories hold separate snapshots, taken a few minutes apart, not identical copies.

### Encryption and credentials

Restic encrypts every repository. The scripts don't pass the repository or password on the command line. Before each run they `source` environment files from `/etc/`, which set Restic's standard variables:

| | Local repository | B2 repository |
|---|---|---|
| Restic settings | [`/etc/restic-env`](../filesystem/etc/restic-env) | [`/etc/restic-env-b2`](../filesystem/etc/restic-env-b2) |
| `RESTIC_REPOSITORY` | `/media/HDD-Seagate-2TB-Backup/restic-repo` | `s3:s3.us-west-004.backblazeb2.com/<bucket>` |
| `RESTIC_PASSWORD_FILE` | [`/etc/restic-password`](../filesystem/etc/restic-password) | [`/etc/restic-password-b2`](../filesystem/etc/restic-password-b2) |
| Other credentials | None | `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (the B2 application key) |
| `TMPDIR` (Restic's temporary files) | `/media/HDD-Seagate-2TB-Backup/restic-tmp` if that directory exists, otherwise `/var/tmp/restic` | Same as local |
| Kuma push tokens | [`/etc/kuma-env`](../filesystem/etc/kuma-env) | [`/etc/kuma-env-b2`](../filesystem/etc/kuma-env-b2) |

On Debian trixie `/tmp` is a RAM-backed tmpfs, and Restic's temporary files had filled it. So both env files check for `/media/HDD-Seagate-2TB-Backup/restic-tmp`, which is missing when the backup drive isn't mounted. If it's there, they point `TMPDIR` at it. If it isn't, they create `/var/tmp/restic` and use that instead. That's on the SD card rather than in RAM, and the system backup already excludes `/var/tmp`. So the B2 run doesn't depend on the local drive, and it doesn't fill `/tmp` either. The env files don't create `restic-tmp` on the backup drive. It's made once during provisioning.

The two repositories have **separate passwords**. **Without the matching password, a repository's backups can't be decrypted.** Obviously we'd want to keep a copy of both somewhere other than the Pi, such as a password manager. The B2 application key is also needed to reach the B2 repository after the Pi is lost.

### Exclusions

**System backup.** The script lists its exclusions inline:

- `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/var/tmp`, `/var/cache`, `/var/run`, `/lost+found`
- `/media` and `/mnt`. This keeps the data drives out of the system snapshot.
- `**/.cache`, `**/.node_modules`, `**/.npm`, `**/..Trash`
- `.deleted`, plus any directory tagged by `--exclude-caches`

**Data backup.** It excludes only `.deleted`.


### Run sequence and monitoring

Each script runs these steps:

1. **Data backup only:** checks that the primary drive is mounted (`mountpoint -q /media/HDD-Seagate-1TB-Primary`). If it isn't, the script exits with status 1 and neither repository is touched. See [issue addressed here](https://github.com/QuantumZenoSix/home-lab/issues/9).
2. **System backup only:** writes the current date into the restore-test file `/root/.restic/backup_testing/test_file.txt`. See [Automated restore test](#automated-restore-test).
3. Sources `/etc/kuma-env` and `/etc/restic-env` for the local repository.
4. Checks that the local repository directory (`$RESTIC_REPOSITORY`) exists. If it doesn't, for example because the backup drive isn't mounted, the script skips steps 5–10 and moves on to B2.
5. **System backup only:** runs `restic unlock` to clear stale locks, for example one left behind by an interrupted run. Then runs `restic check` on the repository (structure and metadata, not pack data). The check adds `--with-cache` when `TMPDIR` is the `/var/tmp/restic` fallback. If the check passes, sends a repository-check heartbeat to Uptime Kuma. If it fails, the script skips steps 6–10 for this repository. See [Repository checks](#repository-checks).
6. Runs `restic backup`. The data script runs `restic unlock` just before it (the system script already did in step 5).
7. If the backup exited with status 0, sends a push heartbeat to Uptime Kuma.
8. Runs `restic forget` with that repository's retention (see the table in [Backup jobs](#backup-jobs)). For the system job that is `--keep-daily 7 --keep-weekly 6 --prune` locally and `--keep-daily 30 --keep-monthly 12 --prune` in B2. For the data job it is `--keep-daily 7 --prune` in both.
9. If that exited with status 0, sends a separate prune heartbeat to Uptime Kuma.
10. **System backup only:** restores the test file from the latest system snapshot into a scratch directory and, if its checksum matches the live file, sends a restore heartbeat to Uptime Kuma.
11. Sources `/etc/kuma-env-b2` and `/etc/restic-env-b2`, which point Restic at the B2 repository and switch to the B2 push tokens. Then repeats steps 5–10 against B2, using B2's retention in step 8.

The data script sends four push heartbeats (backup and prune, for each repository). The system script sends eight: the same four plus a repository-check heartbeat and a restore heartbeat for each repository. Each one has its own Uptime Kuma monitor. When a check, backup, prune, or restore test fails, or the backup drive is missing, its heartbeat isn't sent. Uptime Kuma then raises a Signal alert once that monitor's interval runs out. A failed check also means that repository's backup, prune, and restore heartbeats go missing, because those steps are skipped.

A failure in the local repository, including a failed check, doesn't stop the B2 run. A failed backup doesn't stop the prune or restore test that follows it.

What the heartbeats do **not** tell you:

- Whether the repository data is intact. The system script's nightly `restic check` covers structure and metadata only, and doesn't read pack data. The restore test reads back one small file from tonight's system snapshot, and the data snapshots aren't restore-tested at all.
- Whether every expected file was included. The mount guard catches a missing drive, but not a drive that is mounted with missing or damaged folders.

### Automated restore test

The system script checks that it can read a file back out of each repository it has just written to ([issue #8](https://github.com/QuantumZenoSix/home-lab/issues/8)):

1. Before the first backup, `setup_restore_test` creates `/root/.restic/backup_testing/` if needed and writes the current date into `test_file.txt`. The system backup includes `/root/.restic/`, so the file ends up in every system snapshot.
2. After each repository's backup and prune, `test_restore` restores `test_file.txt` from the latest system snapshot into a scratch directory (`mktemp -d`, so under `TMPDIR`):

   ```shell
   restic restore latest:/root/.restic/backup_testing/ --host system-ada-pi-server \
     --include test_file.txt --target "$restore_dir"
   ```

3. It compares the SHA-256 of the restored file with the live `test_file.txt`. On a match it sends a heartbeat using `KUMA_RESTORE_KEY` (from `/etc/kuma-env` for the local repository, `/etc/kuma-env-b2` for B2). On a mismatch, or when the restore fails, it prints `Restore verification FAILED` and sends nothing, so the monitor alerts when its interval runs out. Then it deletes the scratch directory.

Like the backup and prune, the local restore test is skipped when the local repository directory is missing.

Design choices:

- **What it tests.** The point is to prove that a restore works end to end against each repository: password file, decryption, index, and the restore itself. What's in the file doesn't matter, so it's a tiny file holding a timestamp.
- **New content every night.** Because the timestamp changes, the restored file only matches if it came from tonight's snapshot. Restic also has to store the new content, so the test reads back data that was uploaded that night, not a chunk deduplicated from the first run.
- **Only system snapshots (`--host system-ada-pi-server`).** `latest` is limited to the system job's snapshots, so a newer `data-primary` snapshot can never be picked by mistake.
- **A failed backup also fails the restore test.** If tonight's system backup fails, the newest system snapshot is from an earlier night, and its timestamp doesn't match. Both the backup and restore monitors alert. That's intended: the restore monitor means "tonight's snapshot can be restored".
- **Restores into a scratch directory.** The live test file is never moved or overwritten. So even if the local restore fails, the B2 backup still includes tonight's file and the B2 test runs independently.

For scale, a sample data-backup run to the local repository processed about 76,000 files and 410 GiB in 53 minutes. It added 41 MiB, which took 14 MiB in the repository after compression.

## Working with the repository

Run these as root. Source the environment file for the repository you want to work with, the same way the backup scripts do:

```shell
source /etc/restic-env        # local repository on the secondary SSD
# source /etc/restic-env-b2   # or the B2 repository

restic snapshots                              # all snapshots
restic snapshots --host data-primary          # data snapshots only
restic stats --host data-primary latest       # restore size of the latest data snapshot
restic ls latest --host system-ada-pi-server /etc   # browse files in a snapshot
```

Don't run these while a scheduled backup is in progress (from 03:30 and from 05:00). **TODO:** add how long each job now takes, including the B2 run. `forget --prune` and `check` need an exclusive lock and will fail if another process holds one. Each backup run starts with `restic unlock`, which (without `--remove-all`) removes only stale locks, not one held by a restic process that is still running.

Reading from B2 uses B2 download bandwidth and API calls, which Backblaze can bill for. Prefer the local repository for browsing and routine restores. Beyond the last 7 days, the local repository keeps only one system snapshot per week, going back 6 weeks (see [retention](#backup-jobs)). Use B2 when you need a particular day from the last 30 days, or a system snapshot older than 6 weeks.

_More_

```bash
restic -r /srv/restic-repo snapshots                        # View snapshots
restic -r /srv/restic/repo ls latest                        # List items in a snapshot
restic -r /srv/restic/repo ls {snapshot_id}                 # List items in a snapshot
            --recursive      --long                         # Options
restir -r /srv/restic-repo stats --mode files-by-contents   # Space actual repo is taking
restir -r /srv/restic-repo stats                            # Space repo would take if restored

```  

## Repository checks

Every night the system backup script runs `restic check` on each repository before it backs up to it (`repo_integrity_check`). It runs `restic unlock` first, because the check needs a lock and would otherwise fail on a stale one. The check covers the repository's structure and metadata. If it passes, the script sends a heartbeat using `KUMA_REPOCHECK_KEY` (from `/etc/kuma-env` or `/etc/kuma-env-b2`). If it fails, the script prints the exit code and skips the backup, prune, and restore test for that repository. A failed local check doesn't stop the B2 run. The data script doesn't run a check.

A plain `restic check` downloads all the repository metadata into a fresh temporary cache in `TMPDIR`. The check runs that way when `TMPDIR` is `restic-tmp` on the backup drive, which has room for it. For B2, that means downloading all the metadata every night. When the env files have fallen back to `/var/tmp/restic`, the script adds `--with-cache` instead. The check then reuses root's normal Restic cache in `/root/.cache/restic`, which is on the SD card and excluded from the system backup (`**/.cache`). That keeps the SD card from holding a second full copy of the metadata, but the check then trusts the cached copies instead of a fresh download.

**No check that reads pack data is configured yet.** Run those by hand against each repository (after sourcing its environment file):

```shell
restic check                              # metadata and structure, fast (runs nightly in the system script)
restic check --with-cache                 # same, reusing the local cache instead of a fresh temporary one
restic check --read-data-subset=5%        # also reads a random 5% of pack data
restic check --read-data                  # reads everything, slow
```

A reasonable cadence is a weekly `--read-data-subset`, scheduled outside the backup windows, sending its own Uptime Kuma heartbeat on success. Add a full `--read-data` run monthly.



## Restore procedures

Restore to a scratch directory first. Only copy files back into place after you have checked them.

### Single file or folder from the data drive

```shell
restic find --host data-primary 'some-file.md'          # find which snapshots contain it
restic restore latest --host data-primary \
  --include '/media/HDD-Seagate-1TB-Primary/Documents/Obsidian/some-note.md' \
  --target /tmp/restore
ls -la /tmp/restore/media/HDD-Seagate-1TB-Primary/Documents/Obsidian/
```

To restore from an older point in time, replace `latest` with a snapshot ID from `restic snapshots`.

For the Obsidian vault, the local Git history and Syncthing's file versioning are often quicker for recent mistakes. Use Restic when those don't have the file.


### Whole primary drive (drive replaced)

1. Format the new drive as exFAT. Put its UUID in `/etc/fstab` and mount it at `/media/HDD-Seagate-1TB-Primary`.
2. Stop the services that write to it: `docker compose -f /home/ada/containers/homelab/docker-compose.yml down`.
3. Restore. The `<snapshot>:<path>` syntax restores the drive's contents without the full path prefix. It needs a recent version of restic, so check `restic version` first:

   ```shell
   restic restore latest:/media/HDD-Seagate-1TB-Primary --host data-primary \
     --target /media/HDD-Seagate-1TB-Primary
   ```

4. Start the services again and check Syncthing. Make sure it doesn't push stale data over newer copies on other devices.


## More restore procedures

_Setup_  

Make a dir to place the uncompressed backup (so make sure you have space to accomodate)

```sh
mkdir /tmp/restore-work
```

<br /> 

### Full restore from latest backup

Restore a full backup from latest snapshot
```sh
restic -r /srv/restic-repo restore latest --target /tmp/restore-work
```

Instead of "latest" there's also a way to specify a snapshot id.

<br /> 

### Restore a single file (to specific folder)

```sh
restic -r /srv/restic-repo restore latest:/home/ada/docs --target /home/ada/docs --include myfile.txt
```

Notes
- This restores `myfiletxt` under `/home/ada/docs/` .
- Instead of "latest" there's also a way to specify a snapshot id.
- Restores back to original location.  

<br /> 

### Restore a single file (and parent folder structure)

```sh
restic -r /srv/restic-repo restore latest --target /home/ada/docs/ --include /home/ada/docs/myfile.txt
```

Notes
- This restores `/home/ada/docs/<files>` under `/home/ada/docs/` - which includes `myfile.txt` .
- Instead of "latest" there's also a way to specify a snapshot id.
- Restores back to original location.

---

### System configuration files

```shell
restic restore latest --host system-ada-pi-server \
  --include /etc --include /home/ada --include /root/.restic \
  --target /tmp/system-restore
```

Then copy across what you need, such as `/etc/fstab`, the Restic and Kuma environment files in `/etc/` (`restic-env*`, `restic-password*`, `kuma-env*`), the Compose directories, the crontabs in `/var/spool/cron/crontabs/`, and the SSH host keys. Restoring all of `/` over a running system isn't supported. To rebuild a whole host, see the checklist below.



## Known gaps

- **Restores from B2.** The [automated restore test](#automated-restore-test) restores one file from B2 every night, but only from the Pi. **TODO:** record when a full restore from the B2 repository was last tested, ideally from a machine other than the Pi.
- **Data snapshots.** Only the system backup has an automated restore test. Restores from `data-primary` snapshots are tested by hand.

<!--
<br />


## Recovery checklist

Each step can be tested without damaging the live system. Record the date of each test run.

**Repository access**

- [ ] Both repository passwords work from their off-Pi copies: `restic snapshots` with each password typed by hand.
- [ ] In both the local and B2 repositories, `restic snapshots` lists recent snapshots for both `data-primary` and `system-ada-pi-server`. The newest of each should be less than 24 hours old.
- [ ] `restic check --read-data-subset=5%` reports `no errors were found`.

**Data restore test**

- [ ] Restore a known file from the data drive to `/tmp/restore`. Compare it with the live copy: `cmp` or `sha256sum`.
- [ ] Restore a file from a snapshot older than 3 days. This confirms retention is keeping history.
- [ ] Restore a photo from `Photo Timelime/` and confirm that it opens.

**System restore test**

- [ ] Restore `/etc/fstab`, `/home/ada/containers/homelab/docker-compose.yml`, and `/root/.restic/` to a scratch directory. Diff them against the live files.
- [ ] Confirm that the restored crontabs contain all four scheduled jobs.

**Rebuild on fresh hardware** (full drill; needs a spare SD card or SSD)

- [ ] Flash Raspberry Pi OS and install Docker, Tailscale, restic, and uv/Phockup.
- [ ] Mount the backup SSD and read the repository using the off-Pi password. If the SSD is lost too, read the B2 repository with its off-Pi password and B2 application key.
- [ ] Restore `/etc/fstab`, `/home/ada`, `/root/.restic`, and the crontabs. Then bring up each Compose project.
- [ ] Re-authenticate Tailscale, then confirm that Uptime Kuma and Beszel show healthy checks.
- [ ] Record how long the rebuild took: ______

| Date | Steps tested | Result | Notes |
|---|---|---|---|
| TODO | | | |

-->
