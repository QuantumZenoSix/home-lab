# Networking and Security

This document covers how the Pi is reached, which ports each service listens on, how the host firewall and SSH are set up, and how to check that nothing is exposed by accident.

> **Placeholders.** The UFW rules and SSH settings are not stored in this repository. Sections marked **TODO** need values taken from the running Pi. Use the commands in each section to collect them, and remove any addresses or hostnames you don't want published.

## Intended access model

- Remote administration and service access go through the **Tailscale** tailnet.
- No service is meant to be reachable from the public internet. The router has no port forwards to the Pi.
- Signal alerts are sent from the Pi, so they need outbound connections only.

**TODO:** confirm whether the services are also used directly on the home LAN, or only over Tailscale. The firewall rules below depend on the answer.

## Tailscale

The Pi and the personal devices are members of the same tailnet. Syncthing, Samba, Jellyfin, and the dashboards are all reached through the Pi's tailnet address or MagicDNS name.

**TODO:** fill in the installation method, whether MagicDNS is enabled, whether ACLs restrict which devices can reach which ports, and whether key expiry is disabled for the Pi.

Useful commands:

```shell
tailscale status          # peers and connection state
tailscale ip -4           # the Pi's tailnet address
tailscale ping <device>   # confirms the path to a peer (direct or relayed)
```

## Service exposure

Ports in the table come from the Compose files. Where a Compose file doesn't set a port, the table gives the upstream default, which you should confirm with `ss` (see [Verifying exposure](#verifying-exposure)).

| Service | Network mode | Ports | Intended reach |
|---|---|---|---|
| Jellyfin | host | 8096/tcp (default) | Tailnet |
| Syncthing GUI | host | 8384/tcp (default) | Tailnet |
| Syncthing sync and discovery | host | 22000/tcp+udp, 21027/udp (defaults) | Tailnet / LAN |
| Samba | host | 445/tcp (139/tcp if NetBIOS is on) | Tailnet |
| Uptime Kuma | bridge | `3001:3001` published on all interfaces | Tailnet |
| Beszel hub | bridge | `8090:8090` published on all interfaces | Tailnet |
| Beszel agent | host | None (listens on a Unix socket) | Local only |
| SSH | host service | 22/tcp | Tailnet |

### Docker and UFW

How Docker interacts with UFW is the main exposure risk here:

- **Host-network containers** (Jellyfin, Syncthing, Samba) bind directly to the host's sockets. Their traffic goes through the normal `INPUT` chain, so **UFW rules apply** to them.
- **Published ports on bridge networks** (Uptime Kuma `3001`, Beszel `8090`) are handled by Docker's own iptables rules in the `FORWARD`/`DOCKER` chains, which UFW never sees. **UFW rules do not restrict these ports.** A `ufw deny 3001` has no effect.

To keep the published ports off the LAN, use one of these:

- Bind them to the Tailscale address in Compose, for example `"100.x.y.z:3001:3001"`.
- Add rules to the `DOCKER-USER` chain.

Until one of these is in place, assume that ports 3001 and 8090 can be reached from the LAN.

## UFW

```shell
ada@ada-pi-server:~ $ sudo ufw status verbose
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
Anywhere on tailscale0     ALLOW IN    Anywhere
Anywhere (v6) on tailscale0 ALLOW IN    Anywhere (v6)
```

## SSH

- Authentication is by public key only. Root login is disabled.

```shell
# sudo sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractive|listenaddress'
listenaddress [::]:22
listenaddress 0.0.0.0:22
permitrootlogin no
pubkeyauthentication yes
passwordauthentication yes
kbdinteractiveauthentication no
```  

SSH is restricted to `tailscale0` by UFW.


## Other security notes from the configuration

These follow directly from the files under `filesystem/`:

- **Samba shares the backup drive (`myhdd-backup`) with write access.** Consider making that share read-only or removing it. See [backups-and-recovery.md](backups-and-recovery.md#known-gaps).
- **Uptime Kuma mounts the Docker socket read-write.** Docker socket access is equivalent to root on the host, so the Kuma web UI must stay off untrusted networks and use a strong password. The Beszel agent mounts the socket `:ro`, but that only stops the socket file from being replaced. It doesn't limit which Docker API calls the agent can make.
- **Syncthing runs as root** (`user: "0:0"`) to write to the exFAT drive.
- **The primary drive is mounted with `umask=000`**, so every local user can read and write every file on it.
- **Secrets in this repository are placeholders.** On the Pi, `/root/.restic/restic_pass` should be readable by root only (`chmod 600`). The Uptime Kuma push tokens and the Samba password are hard-coded in scripts and Compose files on the host.

## Verifying exposure

Run these checks after any firewall, Compose, or Tailscale change.

**1. List what is listening on the Pi.**

```shell
sudo ss -tulpn
```

Anything bound to `0.0.0.0` or `[::]` listens on every interface, including the LAN.

**2. Check Docker's published ports.**

```shell
docker ps --format 'table {{.Names}}\t{{.Ports}}'
sudo iptables -L DOCKER-USER -n -v
```

These show the ports that UFW doesn't filter.

**3. Scan from a LAN device that is not on the tailnet**, such as a phone with Tailscale turned off, using the Pi's LAN IP:

```shell
nmap -Pn -p 22,139,445,3001,8090,8096,8384,22000 <pi-lan-ip>
nmap -Pn -sU -p 21027,22000 <pi-lan-ip>
```

Every port that shouldn't be reachable from the LAN should show as `filtered` or `closed`.

**4. Scan from a device on the tailnet**, using the Pi's Tailscale IP. The intended ports should show as `open`.

**5. Check from outside the home network**, for example over mobile data with Tailscale off, against your public IP. Nothing should respond. This confirms that the router has no port forwards to the Pi.

Record the date and results of the last check here:

| Date | LAN scan | Tailnet scan | External scan | Notes |
|---|---|---|---|---|
| TODO | | | | |

