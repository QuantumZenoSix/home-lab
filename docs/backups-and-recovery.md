# Backups and Recovery

Two Restic jobs back up the Pi to two encrypted repositories: one on the secondary SSD and one offsite in Backblaze B2. This document describes what each job covers, how jobs are monitored, and how to check the repositories and restore from them.

## Backup jobs

Both scripts run from root's crontab and live in [`/root/.restic/`](../filesystem/root/.restic/).

| | System backup | Data backup |
|---|---|---|
| Script | [`restic_backup_system.sh`](../filesystem/root/.restic/restic_backup_system.sh) | [`restic_backup_data.sh`](../filesystem/root/.restic/restic_backup_data.sh) |
| Schedule | `30 4 * * *` (04:30) | `0 6 * * *` (06:00) |
| Source | `/` | `/media/HDD-Seagate-1TB-Primary` |
| Destinations | Local repo, then B2 | Local repo, then B2 |
| Snapshot `--host` tag | `system-ada-pi-server` | `data-primary` |
| Compression | `max` | `max` |
| Retention | `forget --keep-daily 7 --prune` | `forget --keep-daily 7 --prune` |

The two jobs use different `--host` tags, so each one's retention and restores apply only to its own snapshots. Each job runs the same backup and prune against both repositories, so both apply the same retention to its snapshots.

### Encryption and credentials

Restic encrypts every repository. The scripts don't pass the repository or password on the command line. Before each run they `source` environment files from `/etc/`, which set Restic's standard variables:

| | Local repository | B2 repository |
|---|---|---|
| Restic settings | [`/etc/restic-env`](../filesystem/etc/restic-env) | [`/etc/restic-env-b2`](../filesystem/etc/restic-env-b2) |
| `RESTIC_REPOSITORY` | `/media/HDD-Seagate-2TB-Backup/restic-repo` | `s3:s3.us-west-004.backblazeb2.com/<bucket>` |
| `RESTIC_PASSWORD_FILE` | [`/etc/restic-password`](../filesystem/etc/restic-password) | [`/etc/restic-password-b2`](../filesystem/etc/restic-password-b2) |
| Other credentials | None | `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (the B2 application key) |
| Kuma push tokens | [`/etc/kuma-env`](../filesystem/etc/kuma-env) | [`/etc/kuma-env-b2`](../filesystem/etc/kuma-env-b2) |

The two repositories have **separate passwords**. **Without the matching password, a repository's backups can't be decrypted.** Keep a copy of both somewhere other than the Pi, such as a password manager. The B2 application key is also needed to reach the B2 repository after the Pi is lost.

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
2. Sources `/etc/kuma-env` and `/etc/restic-env` for the local repository.
3. Checks that the local repository directory (`$RESTIC_REPOSITORY`) exists. If it doesn't, for example because the backup drive isn't mounted, the script skips steps 4–7 and moves on to B2.
4. Runs `restic backup`.
5. If the backup exited with status 0, sends a push heartbeat to Uptime Kuma.
6. Runs `restic forget --keep-daily 7 --prune`.
7. If that exited with status 0, sends a separate prune heartbeat to Uptime Kuma.
8. Sources `/etc/kuma-env-b2` and `/etc/restic-env-b2`, which point Restic at the B2 repository and switch to the B2 push tokens. Then repeats steps 4–7 against B2.

There are four push heartbeats per script (backup and prune, for each repository), and each one has its own Uptime Kuma monitor. When a backup or prune fails, or the backup drive is missing, its heartbeat isn't sent. Uptime Kuma then raises a Signal alert once that monitor's interval runs out.

A failure in the local repository doesn't stop the B2 run, and a failed backup doesn't stop the prune that follows it.

What the heartbeats do **not** tell you:

- Whether the repository is consistent, or whether any of it can be restored.
- Whether every expected file was included. The mount guard catches a missing drive, but not a drive that is mounted with missing or damaged folders.

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

Don't run these while a scheduled backup is in progress (from 04:30 and from 06:00). **TODO:** add how long each job now takes, including the B2 run. `forget --prune` and `check` need an exclusive lock and will fail if another process holds one.

Reading from B2 uses B2 download bandwidth and API calls, which Backblaze can bill for. Prefer the local repository for browsing and routine restores.

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

**No automated check is configured yet.** Run them by hand against each repository (after sourcing its environment file) until one is scheduled:

```shell
restic check                              # metadata and structure, fast
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
2. Stop the services that write to it: `docker compose -f /home/ada/homelab/docker-compose.yml down`.
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

- **Restores from B2.** **TODO:** record when a restore from the B2 repository was last tested, ideally from a machine other than the Pi.

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

- [ ] Restore `/etc/fstab`, `/home/ada/homelab/docker-compose.yml`, and `/root/.restic/` to a scratch directory. Diff them against the live files.
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
