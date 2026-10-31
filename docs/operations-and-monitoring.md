# Operations and Monitoring

This document covers what is monitored, when alerts fire, what runs on a schedule, and how to investigate a problem on the Pi.

## Monitoring stack

| Tool | Watches | Where to look |
|---|---|---|
| Uptime Kuma | Whether services are up, and heartbeats from scheduled jobs | `http://ada-pi-server:3001` |
| Signal (via signal-cli-rest-api) | Receives Uptime Kuma failure alerts | Phone |
| Beszel | CPU, memory, disk, network, and temperature history for the host and each container | `http://ada-pi-server:8090` |

Uptime Kuma and Beszel both run **on the Pi they monitor**. When the whole host goes down, both go down with it and **no alert is sent**. If the dashboards don't load and no Signal alerts have arrived, treat that silence as a possible host outage.

## Uptime Kuma checks

There are seventeen monitors: three Docker container checks and fourteen push heartbeats. Monitors 4, 5, 8, and 9 track the backups and prunes to the local repository. Monitors 10–13 track the same jobs against the Backblaze B2 repository (their push tokens are in `/etc/kuma-env-b2`). Monitors 14 and 15 track the system script's [automated restore test](backups-and-recovery.md#automated-restore-test) against each repository (`KUMA_RESTORE_KEY`). Monitors 16 and 17 track its nightly [repository check](backups-and-recovery.md#repository-checks) against each repository (`KUMA_REPOCHECK_KEY`).

| # | Monitor | Type | Interval | Retries | Goes down when |
|---|---|---|---|---|---|
| 1 | Syncthing Service | Docker container | 60 s | 3, 60 s apart | The `syncthing` container stops running |
| 2 | Jellyfin Service | Docker container | 60 s | 3, 60 s apart | The `jellyfin` container stops running |
| 3 | Samba Service | Docker container | 60 s | 3, 60 s apart | The `samba` container stops running |
| 4 | Daily Restic Backup (Raspberry Pi) | Push | 100,000 s (about 27.8 h) | 0 | No system-backup heartbeat within the interval |
| 5 | Daily Restic Backup (Primary SSD) | Push | 100,000 s (about 27.8 h) | 0 | No data-backup heartbeat within the interval |
| 6 | Routine mobile photo sync | Push | 4 h | 2, 4 h apart | No photo-organization heartbeat within the interval and retries |
| 7 | Daily Obsidian auto commit | Push | 24 h | 2, 24 h apart | No Obsidian auto-commit heartbeat within the interval and retries |
| 8 | Daily Restic Backup Pruning (Primary SSD) | Push | 24 h | 2, 24 h apart | No data-prune heartbeat within the interval and retries |
| 9 | Daily Restic Backup Pruning (Raspberry Pi) | Push | 24 h | 2, 24 h apart | No system-prune heartbeat within the interval and retries |
| 10 | **TODO** (B2 system backup) | Push | **TODO** | **TODO** | No B2 system-backup heartbeat within the interval |
| 11 | **TODO** (B2 data backup) | Push | **TODO** | **TODO** | No B2 data-backup heartbeat within the interval |
| 12 | **TODO** (B2 system prune) | Push | **TODO** | **TODO** | No B2 system-prune heartbeat within the interval |
| 13 | **TODO** (B2 data prune) | Push | **TODO** | **TODO** | No B2 data-prune heartbeat within the interval |
| 14 | **TODO** (local system restore test) | Push | **TODO** | **TODO** | No local restore-test heartbeat within the interval |
| 15 | **TODO** (B2 system restore test) | Push | **TODO** | **TODO** | No B2 restore-test heartbeat within the interval |
| 16 | **TODO** (local repository check) | Push | **TODO** | **TODO** | No local repository-check heartbeat within the interval |
| 17 | **TODO** (B2 repository check) | Push | **TODO** | **TODO** | No B2 repository-check heartbeat within the interval |

Limits of the Docker container checks:

- They confirm that the container is running, not that the service answers. A hung Jellyfin inside a running container stays green.
- The monitors identify the containers by ID, not by name. Recreating a container (for example, `docker compose up -d` after pulling a new image) gives it a new ID, and the monitor then fails until it is edited. Setting each monitor's container to its name (`jellyfin`, `syncthing`, `samba`) avoids this.

### Push heartbeat behavior

A script sends its heartbeat only when its main command exits with status 0. When the interval passes without a heartbeat, Kuma marks the monitor pending. It marks the monitor down, and sends a Signal alert, once the retries have also passed without a heartbeat.

The durations below are estimates. They come from the heartbeat timestamps in Kuma's database between 25 and 28 October 2026, compared with each job's cron start time. That was before the backup scripts added the B2 run, so they cover the local repository only. The backup durations may also have been worked out from the start times the docs used to list (04:30 and 06:00), not the actual 03:30 and 05:00, which would make them about an hour too short. **TODO:** re-measure, and add the B2 backup and prune durations.

| Job | Runs | Typical duration | Kuma interval |
|---|---|---|---|
| System backup | Daily, 03:30 | 1–7 min | About 27.8 h, no retries |
| Data backup | Daily, 05:00 | About 1.5–2 h | About 27.8 h, no retries |
| Data prune | After the data backup | About 13 min (one run) | 24 h, 2 retries |
| Photo organization | Every 4 hours | About 32–35 min | 4 h, 2 retries |
| Obsidian auto-commit | Daily, 05:00 | About 2 min | 24 h, 2 retries |

The photo-organization interval equals the cron period. A run that takes a few seconds longer than the previous one puts the monitor into pending before its heartbeat arrives, and the heartbeat log shows this several times a day. An interval of 4.5 h would stop the pending flips while still alerting within a few hours.

A heartbeat means the script reached its success line. It doesn't confirm that every expected file was processed or that the whole backup can be restored. Pruning has its own monitors, because the prune heartbeat is sent separately after `restic forget --prune` succeeds. The restore-test monitors confirm only that one test file, rewritten every night, can be restored from that night's system snapshot. See [backups-and-recovery.md](backups-and-recovery.md#run-sequence-and-monitoring).

The Obsidian script sends its heartbeat even when there is nothing to commit, so its monitor confirms that the job ran, not that a commit was made. Its output is appended to `/home/ada/scripts/auto_commit_obsidian.log`. I did it this way because sometimes there is nothing to commit and the heartbeat wouldn't run so I'd get false positives.

## Scheduled tasks

```shell
# crontab -l   (user ada)
0  5 * * * /home/ada/scripts/auto_commit_obsidian.sh >> ~/scripts/auto_commit_obsidian.log
0 */4 * * * /home/ada/scripts/organize_mobile_photos.sh

# sudo crontab -l   (root)
30 3 * * * /root/.restic/restic_backup_system.sh
0  5 * * * /root/.restic/restic_backup_data.sh
```

Commands to confirm that cron ran a job:

```shell
systemctl status cron
journalctl -u cron --since today          # one line per job started
sudo grep CRON /var/log/syslog            # if rsyslog is installed
```

## Service status and logs

```shell
# All containers and their state / health
docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Per Compose project (run in the project directory)
cd /home/ada/containers/homelab     && docker compose ps && docker compose logs --tail 100 -f
cd /home/ada/containers/uptime-kuma && docker compose ps && docker compose logs --tail 100
cd /home/ada/containers/beszel      && docker compose ps && docker compose logs --tail 100

# A single container
docker logs --since 1h jellyfin

# Restart one service without touching the others
cd /home/ada/containers/homelab && docker compose restart syncthing
```

Interactive tools used on the host: `lazydocker` and `dcv` for containers, `btop` for processes, and `dysk` for disks.

## Diagnosing an outage without power-cycling

Power-cycling the Pi destroys useful evidence and can corrupt open files, especially on the exFAT drive. Work through these steps in order and stop at the first one that explains the problem.

### 1. Narrow down what is unreachable

| Symptom | Likely scope |
|---|---|
| One Kuma monitor is red, the others are green | A single service or job |
| Every service monitor is red, but the Kuma UI loads | A host-network problem, or the Docker daemon |
| The Kuma UI, Beszel, and SSH are all unreachable | The host, Tailscale, or the network path |

### 2. Check the network path before the host

From another device on the tailnet:

```shell
tailscale status                 # does the Pi show as online?
tailscale ping ada-pi-server     # is the Pi reachable over the tailnet?
ping <pi-lan-ip>                 # is it reachable over the LAN? (bypasses Tailscale)
ssh ada@<pi-lan-ip>              # try SSH over the LAN if the tailnet path fails
```

If the LAN works but Tailscale doesn't, the host is up and the problem is Tailscale. Check `sudo systemctl status tailscaled` and `journalctl -u tailscaled`.

### 3. Once you have a shell

```shell
uptime                                  # load average; did it reboot on its own?
free -h; df -h                          # memory and disk pressure (a full root fs breaks Docker)
findmnt /media/HDD-Seagate-1TB-Primary  # are both drives mounted?
findmnt /media/HDD-Seagate-2TB-Backup
dmesg -T | tail -50                     # USB resets, I/O errors, OOM kills
journalctl -p err -b                    # errors since boot
vcgencmd get_throttled                  # non-zero = under-voltage or throttling
systemctl status docker
```

On a Pi 5, two USB SSDs together can draw more power than the supply delivers. This shows up as `get_throttled` flags or USB disconnect messages in `dmesg`. That can make the host hang or drop a drive, which fits the occasional unresponsiveness described in the README.

### 4. If the Pi did reboot or hang

```shell
journalctl --list-boots
journalctl -b -1 -e          # end of the previous boot's log
```

This works only if the journal is persistent. Check that `/var/log/journal/` exists. If it doesn't, run `sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald` so the next incident leaves a log behind.

Beszel's history for the period before the outage also helps. Look for a slow climb in memory or temperature, or a disk that stops reporting.

### 5. Fix the smallest thing that's broken

Work from the narrowest fix upward:

1. Restart the one container that has failed.
2. Restart its whole Compose project.
3. Restart the affected daemon: `systemctl restart docker` or `systemctl restart tailscaled`.
4. Reboot the host with `sudo reboot`, which shuts down cleanly. Pull the power only when nothing responds over SSH, the LAN, or a local console.

After any reboot, confirm that both drives mounted. Their entries in `fstab` use `nofail`, so the Pi boots and services start even when a drive is missing.

## Investigation log

Record incidents here.

| Date | Symptom | Cause | Fix | Follow-up |
|---|---|---|---|---|
| | No incidents recorded yet. | | | |

