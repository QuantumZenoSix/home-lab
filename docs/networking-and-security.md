# Networking and Security

This document covers how the Pi is reached, which ports each service listens on, how the host firewall and SSH are set up, and how to check that nothing is exposed by accident.


## Intended access model

- Remote administration and service access go through the **Tailscale** tailnet.
- No service is meant to be reachable from the public internet. The router has no port forwards to the Pi.
- Signal alerts are sent from the Pi, so they need outbound connections only.
- The services are used **only over Tailscale**, never directly on the home LAN. Anything reachable on the Pi's LAN address is unintended exposure.

## Tailscale

The Pi and the personal devices are members of the same tailnet. Syncthing, Samba, Jellyfin, and the dashboards are all reached through the Pi's tailnet address or MagicDNS name.

- **Installation:** the `tailscale` apt package (1.102.4 at the time of writing).
- **MagicDNS:** enabled, so tailnet devices can reach the Pi as `ada-pi-server`.
- **Key expiry:** enabled for the Pi. When the node key expires, the Pi drops off the tailnet until someone re-authenticates it, and every service becomes unreachable remotely. Check the expiry date with `tailscale status --json | jq .Self.KeyExpiry`, or disable key expiry for the Pi in the admin console.

- **ACLs:** the default allow-all policy. Every device on the tailnet can reach every port on the Pi, so the access controls are UFW and each service's own login.

Useful commands:

```shell
tailscale status          # peers and connection state
tailscale ip -4           # the Pi's tailnet address
tailscale ping <device>   # confirms the path to a peer (direct or relayed)
```

## Service exposure

Ports in the table were confirmed with `sudo ss -tulpn` and `docker ps` on the Pi. Every one of them listens on all interfaces (`0.0.0.0` / `[::]`), so the firewall alone decides which ones the LAN can reach.

| Service | Network mode | Ports | Filtered by UFW | Intended reach |
|---|---|---|---|---|
| Jellyfin | host | 8096/tcp, 7359/udp (client discovery) | Yes | Tailnet |
| Syncthing GUI | host | 8384/tcp | Yes | Tailnet |
| Syncthing sync and discovery | host | 22000/tcp+udp, 21027/udp | Yes | Tailnet |
| Samba | host | 445/tcp, 139/tcp (NetBIOS is on) | Yes | Tailnet |
| Uptime Kuma | bridge | `3001:3001` | **No** | Tailnet |
| Beszel hub | bridge | `8090:8090` | **No** | Tailnet |
| Signal API (`signal-api` container) | bridge | `8080:8080` | **No** | Local only (used by Uptime Kuma), but reachable from the whole tailnet |
| Beszel agent | host | None (listens on a Unix socket) | n/a | Local only |
| SSH | host service | 22/tcp | Yes | Tailnet |
| Tailscale | host service | 41641/udp | Yes | WireGuard transport |

The `signal-api` container's Compose file is not in this repository.


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

- Public key authentication is enabled and root login is disabled.
- **Password authentication is disabled** (`passwordauthentication no`). 

```shell
# sudo sshd -T | grep -Ei 'passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractive|listenaddress'
listenaddress [::]:22
listenaddress 0.0.0.0:22
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
kbdinteractiveauthentication no
```  

SSH is restricted to `tailscale0` by UFW.


## Other security notes from the configuration

These follow directly from the files under `filesystem/`:

- **Uptime Kuma mounts the Docker socket read-write.** Docker socket access is equivalent to root on the host, so the Kuma web UI must stay off untrusted networks and use a strong password. The Beszel agent mounts the socket `:ro`, but that only stops the socket file from being replaced. It doesn't limit which Docker API calls the agent can make.
- **Syncthing runs as root** (`user: "0:0"`) to write to the exFAT drive.
- **The primary drive is mounted with `umask=000`**, so every local user can read and write every file on it.
- **Secrets in this repository are placeholders.** On the Pi, the Restic password files (`/etc/restic-password`, `/etc/restic-password-b2`), `/etc/restic-env-b2` (which holds the B2 application key), and the Kuma push-token files (`/etc/kuma-env`, `/etc/kuma-env-b2`) should be owned by root and readable by root only (`chmod 600`). New files in `/etc/` are usually world-readable (`644`) by default. The Samba password is hard-coded in the Compose file on the host.

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

Every port that shouldn't be reachable from the LAN should show as `filtered` or `closed`. While router client isolation is on, every port shows as unreachable whatever the Pi's own rules are, so this scan can't test the Pi's firewall.

**4. Scan from a device on the tailnet**, using the Pi's Tailscale IP. The intended ports should show as `open`.

**5. Check from outside the home network**, for example over mobile data with Tailscale off, against your public IP. Nothing should respond. This confirms that the router has no port forwards to the Pi.

Record the date and results of the last check here:

| Date | LAN scan | Tailnet scan | External scan | Notes |
|---|---|---|---|---|
| 2026-10-28 | All TCP ports unreachable. Router client isolation blocks LAN-to-LAN traffic, so this doesn't test the Pi's firewall. | All TCP ports open: 22, 139, 445, 3001, 8080, 8090, 8096, 8384, 22000. | Not run yet. Expected: all closed, since the router has no port forwards. | Docker-published 3001, 8080, and 8090 have no Pi-side restriction. See [Docker and UFW](https://github.com/QuantumZenoSix/home-lab/issues/13). The Signal API (8080) is reachable from every tailnet device. |

