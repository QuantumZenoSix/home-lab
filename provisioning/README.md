# Provisioning

How to set up `ada-pi-server` from a blank SD card so that it matches the running Pi. It covers two cases:

- **Fresh install:** new drives and new Restic repositories.
- **Rebuild:** the Pi or its SD card is lost, but the backup drive or the B2 bucket survived. Steps that differ are marked **Rebuild**.

Setup has two parts:

1. [`provisioning.sh`](provisioning.sh) installs packages and creates directories. It is generic and safe to re-run.
2. The manual steps below. They involve secrets, drive UUIDs, or changes that can lock you out over SSH, so they are done by hand.

Values marked **TODO** aren't recorded yet and need filling in from the live Pi.

## Before you start

Have these ready. Except for the SSH key, they are all stored off the Pi:

| Item | Needed for |
|---|---|
| SSH public key for `ada` | Logging in. Password authentication is disabled. |
| Tailscale account | Joining the Pi to the tailnet |
| Local Restic repository password | `/etc/restic-password` |
| B2 Restic repository password | `/etc/restic-password-b2` |
| B2 bucket name and application key (key ID and key) | `/etc/restic-env-b2` |
| Signal number registered with signal-cli | Uptime Kuma alerts |
| Samba password for `ada` | `~/containers/homelab/docker-compose.yml` |

## 1. Flash Raspberry Pi OS

Use Raspberry Pi Imager to write **Raspberry Pi OS Lite (64-bit)**, based on Debian 13 trixie. In the Imager's OS customisation settings:

- Hostname: `ada-pi-server`
- User: `ada`
- SSH: enabled, public-key authentication only, with your public key

The Pi runs from a 128 GB microSD card (`mmcblk0`). Both SSDs connect over USB.

## 2. Run the provisioning script

```shell
ssh ada@ada-pi-server.local          # over the LAN; avahi provides .local
git clone https://github.com/QuantumZenoSix/home-lab.git
cd home-lab
sudo ./provisioning/provisioning.sh
```

The script:

- Checks for Debian 13 trixie on arm64, and that user `ada` exists.
- Adds the Docker and Tailscale apt repositories.
- Installs the packages, including `restic`, `exfatprogs`, `cron`, `ufw`, and `exiftool`.
- Writes `/etc/docker/daemon.json` (container DNS: 8.8.8.8, 8.8.4.4, 1.1.1.1) if it doesn't exist, and adds `ada` to the `docker` group.
- Installs `uv` for `ada` in `~/.local/bin`, clones Phockup to `/opt/phockup` with its own `.venv`, and links `/usr/local/bin/phockup`.
- Creates the drive mount points, `/root/.restic`, `~/scripts`, and the three Compose project directories.
- Makes the systemd journal persistent.
- Enables `docker`, `tailscaled`, `ssh`, and `cron`.

Log out and back in afterwards, so the `docker` group membership applies.

## After the script

### 3. Join the tailnet

```shell
sudo tailscale up
```

The live Pi uses plain `tailscale up`, with no Tailscale SSH, subnet routes, exit node, or tags. In the admin console, decide whether to disable key expiry for the Pi. See [networking-and-security.md](../docs/networking-and-security.md#tailscale).

**Disconnect and reconnect over Tailscale** (`ssh ada@ada-pi-server`) before you continue. The next two steps can cut off LAN SSH.

### 4. Harden SSH

The live Pi's effective settings (`sudo sshd -T`) are `permitrootlogin no`, `pubkeyauthentication yes`, `passwordauthentication no`, and `kbdinteractiveauthentication no`. Its only drop-in is `50-cloud-init.conf`, written by the Imager's customisation.

To make sure those settings are applied, add a drop-in that sorts before the cloud-init one. sshd uses the first value it reads for each setting:

```shell
sudo tee /etc/ssh/sshd_config.d/10-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sudo sshd -t && sudo systemctl reload ssh
```

Open a **second** SSH session to confirm that you can still log in before you close the first one.

### 5. Enable the firewall

These commands produce the rules shown in [networking-and-security.md](../docs/networking-and-security.md#ufw):

```shell
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw default deny routed
sudo ufw allow in on tailscale0
sudo ufw logging low
sudo ufw enable
sudo ufw status verbose
```

SSH is only reachable over `tailscale0`. Docker publishes ports for Uptime Kuma (3001), Beszel (8090), and signal-api (8080), and those **bypass UFW**. See [networking-and-security.md](../docs/networking-and-security.md#service-exposure).

### 6. Mount the drives

Find each drive's UUID:

```shell
lsblk -f
```

Copy the two drive lines from [`filesystem/etc/fstab`](../filesystem/etc/fstab) into `/etc/fstab`, replacing the UUIDs. Then mount them:

```shell
sudo systemctl daemon-reload
sudo mount -a
findmnt /media/HDD-Seagate-1TB-Primary /media/HDD-Seagate-2TB-Backup
```

| Mount point | Filesystem | Owner |
|---|---|---|
| `/media/HDD-Seagate-1TB-Primary` | exFAT. fstab sets `uid=1000,gid=1000,umask=000`. | `ada` (from the mount options) |
| `/media/HDD-Seagate-2TB-Backup` | ext4 | `sudo chown ada:ada /media/HDD-Seagate-2TB-Backup` |

**Fresh install with blank drives.** Check the device names with `lsblk` first, because this erases them:

```shell
sudo mkfs.exfat -L "Seagate 1tb" /dev/sdX1    # primary
sudo mkfs.ext4 /dev/sdY1                      # backup
```

On the primary drive, create the folders that the services and scripts expect: `Documents/Obsidian`, `Pictures/MobileUploads`, and the Phockup output folder under `Pictures/`.

### 7. Install config files and secrets

Copy the files from [`filesystem/`](../filesystem/) to the same paths on the Pi. Every secret in the repository is a placeholder (`XXXX`, `****`, `<token>`, `mybucketname`), so replace each one with the real value. Run these from the repository root:

```shell
# Restic and Uptime Kuma environment files: root only
for f in restic-env restic-env-b2 restic-password restic-password-b2 kuma-env kuma-env-b2; do
    sudo install -m 600 -o root -g root filesystem/etc/$f /etc/$f
done

# Backup scripts
sudo install -m 755 -o root -g root filesystem/root/.restic/restic_backup_*.sh /root/.restic/

# Automation scripts and their push-URL files
install -m 755 filesystem/home/ada/scripts/*.sh ~/scripts/
install -m 600 filesystem/home/ada/scripts/.env_* ~/scripts/

# Compose files
for p in homelab uptime-kuma beszel; do
    install -m 644 filesystem/home/ada/$p/docker-compose.yml ~/$p/
done
```

Then edit each file and fill in its real values:

| File | What to fill in |
|---|---|
| `/etc/restic-password`, `/etc/restic-password-b2` | Repository passwords |
| `/etc/restic-env-b2` | Bucket name, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (the B2 key ID and key) |
| `/etc/kuma-env`, `/etc/kuma-env-b2` | Push tokens from step 10 |
| `~/scripts/.env_*` | Full push URLs from step 10 |
| `~/containers/homelab/docker-compose.yml` | Samba password |
| `~/containers/beszel/docker-compose.yml` | `TOKEN` and `KEY` from step 9 |

On the live Pi, `/etc/kuma-env` and `/etc/kuma-env-b2` are `644`, and `~/scripts/.env_*` are `664`. That leaves the push tokens readable by every user, which is why the commands above use `600`.

**Rebuild:** all of these files are in the system snapshot, under `/etc`, `/root/.restic`, and `/home/ada`. Restoring them in step 8 gives you the real values without retyping them.

### 8. Restic repositories

Both repositories were created with a plain `restic init` (repository format version 2).

**Fresh install:**

```shell
sudo -i
source /etc/restic-env    && restic init    # local, on the backup SSD
source /etc/restic-env-b2 && restic init    # B2 bucket
```

**Rebuild:** don't run `init`. Check that each repository opens, then restore the configuration from the latest system snapshot:

```shell
sudo -i
source /etc/restic-env      # or /etc/restic-env-b2 if the backup SSD is gone
restic snapshots --host system-ada-pi-server --latest 1
restic restore latest --host system-ada-pi-server \
  --include /etc --include /home/ada --include /root/.restic \
  --target /tmp/system-restore
```

On a rebuild, `/etc/restic-env*` and the password files have to be written by hand first (step 7), because you need them to read the repository. Then copy the rest across from `/tmp/system-restore`. That includes the Uptime Kuma data in `/home/ada/containers/uptime-kuma` and the Beszel data in `/home/ada/containers/beszel/beszel_data` and `beszel_agent_data`, which bring back the monitors and history. Don't overwrite `/etc/fstab` with the restored copy: the drive UUIDs may have changed. See [backups-and-recovery.md](../docs/backups-and-recovery.md#system-configuration-files).

### 9. Start the containers

```shell
cd ~/containers/homelab     && docker compose up -d     # Jellyfin, Syncthing, Samba
cd ~/containers/uptime-kuma && docker compose up -d     # Uptime Kuma on :3001
cd ~/containers/beszel      && docker compose up -d     # Beszel hub on :8090, plus agent
```

**Beszel:** on a fresh install, start with `TOKEN` and `KEY` blank. Create the admin account at `http://ada-pi-server:8090`, then copy the universal token and public key from the hub's settings into `~/containers/beszel/docker-compose.yml`, and run `docker compose up -d` again.

**signal-api:** this container (`bbernhard/signal-cli-rest-api`) runs on the live Pi with port `8080:8080`, but it was started outside Compose and its run command isn't in this repository. **TODO:** record its `docker run` command, or add a Compose file for it. You can get its current settings with:

```shell
docker inspect signal-api --format '{{json .HostConfig.PortBindings}} {{json .Mounts}} {{json .Config.Env}} {{.HostConfig.RestartPolicy.Name}}'
```

**TODO:** how the Signal number was registered or linked in signal-cli, and where its data directory lives.

**Syncthing:** pair the devices again in the GUI at `http://ada-pi-server:8384`, unless its config was restored. **TODO:** where Syncthing keeps its config on the host.

### 10. Uptime Kuma monitors and Signal

Monitors and notifications are set up by hand in the Uptime Kuma web UI at `http://ada-pi-server:3001`. On a rebuild, restoring `/home/ada/containers/uptime-kuma` (step 8) brings them back, so you can skip this step.

On a fresh install:

1. Create the admin account.
2. Add a **Signal** notification that points at signal-api. Kuma asks for a post URL, the sender number, and the recipients. **TODO:** the post URL used on the live Pi.
3. Create the monitors listed in [operations-and-monitoring.md](../docs/operations-and-monitoring.md#uptime-kuma-checks): three Docker container checks and the push monitors.
4. Copy each push monitor's token into the matching file:

   | Monitor | File and variable |
   |---|---|
   | System backup and prune, local | `/etc/kuma-env`: `KUMA_SYSTEM_KEY`, `KUMA_SYSTEM_PRUNE_KEY` |
   | Data backup and prune, local | `/etc/kuma-env`: `KUMA_DATA_KEY`, `KUMA_DATA_PRUNE_KEY` |
   | The same four for B2 | `/etc/kuma-env-b2`, with the same variable names |
   | Mobile photo organization | `~/scripts/.env_organize_mobile_photos` (full push URL) |
   | Obsidian auto-commit | `~/scripts/.env_auto_commit_obsidian` (full push URL) |

### 11. Crontabs

Use `crontab -e` as `ada`, and `sudo crontab -e` for root. These are the live entries:

```shell
# ada
0  5 * * * /home/ada/scripts/auto_commit_obsidian.sh >> ~/scripts/auto_commit_obsidian.log
0 */4 * * * /home/ada/scripts/organize_mobile_photos.sh

# root
30 3 * * * /root/.restic/restic_backup_system.sh
0  5 * * * /root/.restic/restic_backup_data.sh
```

Before the first scheduled run, run each backup script by hand once (`sudo /root/.restic/restic_backup_system.sh`). Check that all four of its heartbeats arrive in Kuma.

### 12. Optional tools

These are on the live Pi but don't come from apt, so the script doesn't install them:

| Tool | Location on the live Pi |
|---|---|
| [lazydocker](https://github.com/jesseduffield/lazydocker) | `~/.local/bin/lazydocker` |
| [darya](https://github.com/mrkatebzadeh/darya) | `~/.local/bin/darya` |
| [dcv](https://github.com/tokuhirom/dcv) | `/usr/local/bin/dcv` |
| [yazi](https://github.com/sxyazi/yazi) | `/usr/local/bin/yazi`, `/usr/local/bin/ya` |

`bat` is symlinked as `~/.local/bin/bat -> /usr/bin/batcat`.

## Verify

- [ ] `findmnt` shows both drives at their mount points after a reboot.
- [ ] `sudo ufw status verbose` matches step 5, and SSH works over the tailnet.
- [ ] `docker ps` shows `jellyfin`, `syncthing`, `samba`, `uptime-kuma`, `beszel`, `beszel-agent`, and `signal-api` running.
- [ ] Every Uptime Kuma monitor is green, and a test notification reaches Signal.
- [ ] `sudo -i`, `source /etc/restic-env`, then `restic snapshots` lists recent snapshots. Do the same with `/etc/restic-env-b2`.
- [ ] `ls -l /etc/restic-* /etc/kuma-env*` shows `-rw------- root root` for every file.
- [ ] Beszel shows the host and its containers.
