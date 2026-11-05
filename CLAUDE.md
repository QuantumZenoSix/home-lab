# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Public documentation for a self-hosted Raspberry Pi 5 home lab. There is no build or test suite. The content is `README.md`, Mermaid diagrams, `filesystem/` (a curated reference copy of selected config files and scripts taken from the Pi), and `provisioning/`: `provisioning.sh` installs packages and directories on a fresh Pi, and `provisioning/README.md` covers the manual, host-specific steps. Keep the script generic and re-runnable; anything involving secrets, drive UUIDs, or SSH/firewall changes that could cause a lockout belongs in the README.

## `filesystem/` mirrors paths on the Pi

Each file lives at the path it has on the host (`filesystem/etc/fstab` corresponds to `/etc/fstab`, `filesystem/usr/local/sbin/...` to `/usr/local/sbin/...`, and so on). When you add or move a file, keep it under its real host path. Root-run scripts go in `usr/local/sbin/` (root-writable only); `ada`'s own jobs go in `home/ada/scripts/`. All four scheduled jobs run from systemd timers in `etc/systemd/system/`. The host user is `ada` and the hostname is `ada-pi-server`.

Two mounted drives tie everything together. Most files hardcode these paths, so a rename has to be applied across all of them:
- `/media/HDD-Seagate-1TB-Primary`: primary data drive (exFAT, uid/gid 1000). Holds the Obsidian vault (`Documents/Obsidian`), `Pictures/MobileUploads`, and the Phockup output.
- `/media/HDD-Seagate-2TB-Backup`: backup drive (ext4). Holds the local Restic repo at `restic-repo` (an offsite copy lives in Backblaze B2).

How the pieces connect:
- **Compose stacks:** `home/ada/containers/homelab/` runs Jellyfin, Syncthing, and Samba with `network_mode: host`. `home/ada/containers/uptime-kuma/` runs Uptime Kuma on port 3001. `home/ada/containers/beszel/` runs the Beszel hub (port 8090) and an agent that talks to it over a shared unix socket.
- **Heartbeats:** the scheduled scripts (`usr/local/sbin/restic_backup_*.sh`, `home/ada/scripts/organize_mobile_photos.sh`) curl `http://ada-pi-server:3001/api/push/<token>` only when the main command succeeds. The backup scripts build the URL from `KUMA_*` variables sourced from `/etc/kuma-env` (local repo) or `/etc/kuma-env-b2` (B2 repo). Uptime Kuma alerts through Signal when an expected heartbeat is missed.
- **Restic:** both backup scripts first take a shared `flock` on `/run/lock/restic_backup.lock` (fd 9, `-w 3600`; exit 1 if not acquired), so only one backup runs at a time. Each script then runs twice: first against the local repo (`source /etc/restic-env`, skipped if the repo directory is missing), then against Backblaze B2 (`source /etc/restic-env-b2`). These files set `RESTIC_REPOSITORY`, `RESTIC_PASSWORD_FILE`, and `TMPDIR` (`restic-tmp` on the backup drive if that directory exists, otherwise `/var/tmp/restic`; never the tmpfs `/tmp`), plus the B2 `AWS_*` keys. The system script first runs `restic unlock` then `restic check` on each repo (adding `--with-cache` when `TMPDIR` is the `/var/tmp/restic` fallback), pushes `KUMA_REPOCHECK_KEY` if it passes, and skips that repo if it fails (B2 still runs). The data script runs `restic unlock` right before backing up. Each run backs up, then runs `forget` with the script's own `--host` tag (`system-ada-pi-server` or `data-primary`): the data script uses `--keep-daily 7 --prune` for both repos; the system script uses `--keep-daily 7 --keep-weekly 6 --prune` locally, and for B2 it calls `prune 'extra-retention'`, which uses `--keep-daily 30 --keep-monthly 12 --prune`. The reasons for two independent repos instead of an rclone copy are in `docs/backups-and-recovery.md`. The system script then also runs a restore test against each repo: `setup_restore_test` writes `date` into `/var/lib/restic-backup/test_file.txt` each run, and `test_restore` restores it from `latest --host system-ada-pi-server` into a `mktemp -d` scratch dir, compares SHA-256 with the live file, and pushes `KUMA_RESTORE_KEY` on a match. The system script lists its excludes inline and does not use `restic_exclude.txt`.
- **Schedules:** each job is a `.service`/`.timer` pair in `etc/systemd/system/` (all system units; the two `ada` jobs set `User=ada`). The `OnCalendar=` times are also listed in the README, `docs/architecture.md`, `docs/operations-and-monitoring.md`, and `docs/backups-and-recovery.md`, so a schedule change has to be applied to all of them. Timers use `Persistent=true`. The data, photo, and Obsidian services use `RequiresMountsFor=/media/HDD-Seagate-1TB-Primary`; the system backup deliberately doesn't require the backup drive, so B2 still runs without it.

## `ansible/` (in progress)

An Ansible playbook (`ansible/site.yml`, roles `base`, `docker`, `tailscale`, `phockup`, `restic`) that is gradually replacing `provisioning.sh` and the manual steps. `docs/ansible-crash-course.md` is a tutorial for the owner, who is learning Ansible: keep its "What's automated so far" table current, and keep comments in `ansible/` explanatory.
- The owner works from more than one control node (WSL and a CachyOS/Arch machine whose default shell is fish), so setup instructions must cover Linux in general, not only WSL.
- Run commands from `ansible/` (that's where `ansible.cfg` is). In the WSL environment Ansible needs `LC_ALL=C.UTF-8`, because `en_US.UTF-8` isn't generated there. Validate with `ansible-playbook site.yml --syntax-check` and `ansible-lint --profile production`; it passes cleanly, so keep it that way.
- Variable prefixes: `homelab_*` (lab-wide, in `inventory/host_vars/<host>/vars.yml`), `<role>_*` (role defaults/vars), and `vault_*` (secrets, only in the gitignored, encrypted `vault.yml`; `vault.yml.example` holds the same placeholders as `filesystem/`).
- The restic templates were generated from the `filesystem/` copies, with values replaced by variables. Until `filesystem/` copies of Ansible-managed files are retired, change a backup script or unit in both places. A schedule or retention change also goes in `roles/restic/defaults/main.yml`.

## Secrets and placeholders

This repo is public. Secret values in committed files are fake placeholders: the `XXXX` push tokens in `etc/kuma-env*`, the `****` values in `etc/restic-password*` and the B2 `AWS_*` keys, the `mybucketname` bucket, the Samba password, and Beszel `<token>`/`<key>`. Never replace them with real-looking values. Flag anything that appears to be a real credential.

## Documentation conventions

- The README separates what is implemented from what is planned. Keep that distinction when you edit it.
- The README's Mermaid flowchart uses index-based `linkStyle N` lines. Adding or removing an edge shifts the indices, so update those styles to match.
- `diagrams/architecture_with_beszel.md` and `docs/architecture.md` contain extended versions of the same flowchart. When the architecture changes, check them along with the README.
- The README is the entry point. Detailed material goes in the four `docs/` files: architecture, networking-and-security, backups-and-recovery, and operations-and-monitoring. A fifth, `docs/ansible-crash-course.md`, covers `ansible/`. Facts that can't be derived from `filesystem/` (UFW rules, SSH settings, Kuma monitor types) are marked **TODO** for the owner to fill in from the live Pi. Don't invent values for them.
