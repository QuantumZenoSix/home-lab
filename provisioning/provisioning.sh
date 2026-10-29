#!/usr/bin/env bash

# Raspberry Pi 5 Home Server Provisioning
# Target: Raspberry Pi OS Lite / Debian 13 Trixie / ARM64
#
# Installs packages and prepares directories. Safe to re-run.
# Host-specific steps (Tailscale login, UFW, SSH hardening, fstab, secrets,
# crontabs, Compose stacks) are in provisioning/README.md.

set -Eeuo pipefail

# --------------------------------------------------
# Configuration
# --------------------------------------------------

LOG_PREFIX="[provision-pi]"

# Non-root user that owns the Compose stacks and the user crontab
TARGET_USER="${TARGET_USER:-ada}"

PRIMARY_MOUNT="/media/HDD-Seagate-1TB-Primary"
BACKUP_MOUNT="/media/HDD-Seagate-2TB-Backup"

PHOCKUP_DIR="/opt/phockup"
PHOCKUP_REPO="https://github.com/ivandokov/phockup.git"

log() {
    echo -e "\n${LOG_PREFIX} $1"
}

error() {
    echo "${LOG_PREFIX} ERROR: $1" >&2
    exit 1
}

# --------------------------------------------------
# Preflight checks
# --------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    error "Run this script with sudo or as root."
fi

source /etc/os-release

CODENAME="${VERSION_CODENAME:-}"
ARCH="$(dpkg --print-architecture)"

[[ "$ID" == "debian" ]] || error "Expected Debian-based Raspberry Pi OS."
[[ "$CODENAME" == "trixie" ]] || error "Expected Debian 13 Trixie. Found: $CODENAME"
[[ "$ARCH" == "arm64" ]] || error "Expected ARM64. Found: $ARCH"

id "$TARGET_USER" &>/dev/null || error "User '$TARGET_USER' does not exist. Create it first or set TARGET_USER."

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

log "Detected $PRETTY_NAME ($ARCH), target user: $TARGET_USER"

# --------------------------------------------------
# Update package metadata and install prerequisites
# --------------------------------------------------

log "Updating package repositories..."

apt-get update

apt-get install -y \
    ca-certificates \
    curl \
    gnupg

mkdir -p /etc/apt/keyrings

# --------------------------------------------------
# Configure Docker repository
# --------------------------------------------------

log "Configuring Docker repository..."

curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /tmp/docker.asc

gpg --dearmor --yes \
    -o /etc/apt/keyrings/docker.gpg \
    /tmp/docker.asc

chmod 644 /etc/apt/keyrings/docker.gpg

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable
EOF

rm -f /tmp/docker.asc

# --------------------------------------------------
# Configure Tailscale repository
# --------------------------------------------------

log "Configuring Tailscale repository..."

curl -fsSL \
    "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
    -o /usr/share/keyrings/tailscale-archive-keyring.gpg

cat > /etc/apt/sources.list.d/tailscale.list <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian ${CODENAME} main
EOF

# --------------------------------------------------
# Install core system packages
# --------------------------------------------------

log "Updating package metadata..."

apt-get update

log "Installing core system packages..."

CORE_PACKAGES=(
    # Networking and security
    openssh-server
    ufw
    nftables
    avahi-daemon
    bind9-dnsutils
    iproute2
    iputils-ping
    ethtool
    tcpdump
    net-tools

    # Storage and backup
    restic
    rsync
    exfatprogs      # fsck/mkfs for the exFAT primary drive
    cifs-utils
    ntfs-3g
    dosfstools
    parted

    # Scheduling (all backup and automation jobs run from cron)
    cron

    # System utilities
    curl
    wget
    git
    jq
    sqlite3
    unzip
    zip
    7zip
    tree
    rsyslog
    logrotate

    # Python
    python3
    python3-pip
    python3-venv
    python-is-python3

    # Administration and monitoring
    btop
    htop
    sysstat
    ncdu
    dmidecode
    pciutils
    usbutils
    lsof
    strace

    # Terminal utilities (Debian installs bat as batcat and fd-find as fdfind)
    bat
    fzf
    ripgrep
    fd-find
    zoxide
    vim
    nano
    less
    man-db

    # Development utilities
    build-essential
    pkg-config
    gdb

    # Phockup reads photo dates with exiftool
    libimage-exiftool-perl
)

apt-get install -y "${CORE_PACKAGES[@]}"

# --------------------------------------------------
# Install Docker
# --------------------------------------------------

log "Installing Docker infrastructure..."

DOCKER_PACKAGES=(
    docker-ce
    docker-ce-cli
    containerd.io
    docker-buildx-plugin
    docker-compose-plugin
)

apt-get install -y "${DOCKER_PACKAGES[@]}"

# Containers resolve DNS through public resolvers rather than the host's
if [[ ! -f /etc/docker/daemon.json ]]; then
    log "Writing /etc/docker/daemon.json..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "dns": ["8.8.8.8", "8.8.4.4", "1.1.1.1"]
}
EOF
else
    log "Keeping existing /etc/docker/daemon.json"
fi

# Lets the target user run docker and docker compose without sudo
usermod -aG docker "$TARGET_USER"

# --------------------------------------------------
# Install Tailscale
# --------------------------------------------------

log "Installing Tailscale..."

apt-get install -y tailscale

# --------------------------------------------------
# Install optional utilities
# --------------------------------------------------

# Some utilities may not be available in the
# standard Debian repositories on every release.

install_available() {
    local available=()

    for package in "$@"; do
        local candidate

        candidate="$(apt-cache policy "$package" |
            awk '/Candidate:/ {print $2}')"

        if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
            available+=("$package")
        else
            log "Skipping unavailable optional package: $package"
        fi
    done

    if [[ ${#available[@]} -gt 0 ]]; then
        apt-get install -y "${available[@]}"
    fi
}

log "Installing additional utilities..."

install_available \
    dysk \
    lazygit \
    ffmpeg \
    imagemagick \
    mkvtoolnix \
    poppler-utils \
    v4l-utils \
    tshark \
    lua5.1 \
    luajit

# --------------------------------------------------
# Install uv and Phockup (mobile photo organization)
# --------------------------------------------------

# organize_mobile_photos.sh runs: cd /opt/phockup && ~/.local/bin/uv run ./phockup.py

if [[ ! -x "${TARGET_HOME}/.local/bin/uv" ]]; then
    log "Installing uv for ${TARGET_USER}..."
    sudo -u "$TARGET_USER" -H sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
else
    log "uv already installed for ${TARGET_USER}"
fi

if [[ ! -d "$PHOCKUP_DIR" ]]; then
    log "Cloning Phockup into ${PHOCKUP_DIR}..."
    git clone --depth 1 "$PHOCKUP_REPO" "$PHOCKUP_DIR"
    chown -R "${TARGET_USER}:${TARGET_USER}" "$PHOCKUP_DIR"
else
    log "Keeping existing ${PHOCKUP_DIR}"
fi

# uv run picks up .venv in the working directory, which the cron script cds into
if [[ ! -d "${PHOCKUP_DIR}/.venv" && -f "${PHOCKUP_DIR}/requirements.txt" ]]; then
    log "Creating Phockup virtual environment..."
    sudo -u "$TARGET_USER" -H sh -c "cd '${PHOCKUP_DIR}' && '${TARGET_HOME}/.local/bin/uv' venv && '${TARGET_HOME}/.local/bin/uv' pip install -r requirements.txt"
fi

ln -sf "${PHOCKUP_DIR}/phockup.py" /usr/local/bin/phockup

# --------------------------------------------------
# Create directories
# --------------------------------------------------

log "Creating mount points and script directories..."

# Mount points for the two drives (fstab entries are added by hand, see README)
mkdir -p "$PRIMARY_MOUNT" "$BACKUP_MOUNT"

# Restic backup scripts (root) and automation scripts (target user)
install -d -m 700 -o root -g root /root/.restic
install -d -m 775 -o "$TARGET_USER" -g "$TARGET_USER" "${TARGET_HOME}/scripts"

# Compose project directories
for project in homelab uptime-kuma beszel; do
    install -d -m 775 -o "$TARGET_USER" -g "$TARGET_USER" "${TARGET_HOME}/${project}"
done

# Keep the systemd journal across reboots, so a hang leaves a log behind
mkdir -p /var/log/journal

# --------------------------------------------------
# Enable system services
# --------------------------------------------------

log "Enabling Docker..."

systemctl enable --now docker

log "Enabling Tailscale..."

systemctl enable --now tailscaled

log "Enabling SSH..."

systemctl enable --now ssh

log "Enabling cron..."

systemctl enable --now cron

# Picks up the new /var/log/journal directory
systemctl restart systemd-journald

# --------------------------------------------------
# Cleanup
# --------------------------------------------------

log "Cleaning package cache..."

apt-get autoremove -y
apt-get clean

# --------------------------------------------------
# Verification
# --------------------------------------------------

log "Verifying installations..."

docker --version
docker compose version
restic version
tailscale version
ufw --version
python3 --version
sudo -u "$TARGET_USER" -H "${TARGET_HOME}/.local/bin/uv" --version
exiftool -ver

log "Provisioning completed successfully."

echo
echo "Next steps: follow provisioning/README.md from 'After the script'."
echo "  1. Authenticate Tailscale: sudo tailscale up"
echo "  2. Harden SSH and enable UFW (only once connected over Tailscale)."
echo "  3. Add the SSD mounts to /etc/fstab."
echo "  4. Install config files and secrets from filesystem/."
echo "  5. Initialise or connect the Restic repositories."
echo "  6. Start the Docker Compose stacks and signal-api."
echo "  7. Set up Uptime Kuma monitors and install the crontabs."
echo
echo "Log out and back in so the docker group membership for ${TARGET_USER} applies."
