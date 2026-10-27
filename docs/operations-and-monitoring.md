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

There are six monitors: three service checks and three push heartbeats.

| # | Monitor | Type | Fails when |
|---|---|---|---|
| 1 | Jellyfin | TODO (HTTP / TCP / Docker container) | The service doesn't respond within the retry window |
| 2 | Syncthing | TODO | The service doesn't respond within the retry window |
| 3 | Samba | TODO | The service doesn't respond within the retry window |
| 4 | System backup | Push | No heartbeat within the interval after 04:30 |
| 5 | Data backup | Push | No heartbeat within the interval after 06:00 |
| 6 | Photo organization | Push | No heartbeat within the interval after the 4-hourly run |

**TODO:** for each monitor, record its type, check interval, retries, and (for push monitors) heartbeat interval. Uptime Kuma runs on a bridge network, so a check against `localhost` reaches the Kuma container itself, not the host-network services. Service checks should target the Pi's hostname or IP.

### Push heartbeat behavior

A script sends its heartbeat only when its main command exits with status 0. Kuma then marks the monitor down if no heartbeat arrives within the configured interval. Size each interval to the job's schedule plus its run time:

| Job | Runs | Typical duration | Suggested heartbeat interval |
|---|---|---|---|
| System backup | Daily, 04:30 | TODO | 25 h |
| Data backup | Daily, 06:00 | About 55 min (sample log) | 25 h |
| Photo organization | Every 4 hours | TODO | 4.5 h |

A heartbeat means the script reached its success line. It doesn't confirm that every expected file was processed, that the backup can be restored, or that pruning succeeded. See [backups-and-recovery.md](backups-and-recovery.md#run-sequence-and-monitoring).

### Not monitored

- **Obsidian auto-commit (05:00).** The script sends no heartbeat. Its output is appended to `/home/ada/scripts/auto_commit_obsidian.log`.
- **Beszel and Uptime Kuma.** Nothing monitors them, and nothing off the Pi monitors the host itself.
- **Disk mounts.** No monitor checks the mounts directly. A missing drive surfaces only indirectly, as a missed backup heartbeat the next morning. The data backup refuses to run when the primary drive isn't mounted, and both backups skip when the backup drive is missing.

## Scheduled tasks

```shell
# crontab -l   (user ada)
0  5 * * * /home/ada/scripts/auto_commit_obsidian.sh >> ~/scripts/auto_commit_obsidian.log
0 */4 * * * /home/ada/scripts/organize_mobile_photos.sh

# sudo crontab -l   (root)
30 4 * * * /root/.restic/restic_backup_system.sh
0 6 * * * /root/.restic/restic_backup_data.sh
```

The photo job and both Restic jobs don't redirect their output in these crontab lines. Unless cron is configured to mail it somewhere, their output is discarded. To keep a log, add `>> <logfile> 2>&1` to each line.

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
cd /home/ada/homelab     && docker compose ps && docker compose logs --tail 100 -f
cd /home/ada/uptime-kuma && docker compose ps && docker compose logs --tail 100
cd /home/ada/beszel      && docker compose ps && docker compose logs --tail 100

# A single container
docker logs --since 1h jellyfin

# Restart one service without touching the others
cd /home/ada/homelab && docker compose restart syncthing
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
| TODO | | | | |

