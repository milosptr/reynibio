#!/usr/bin/env bash
set -euo pipefail

# === ReyniBio Media Server — Fresh Machine Setup ===
# Target: Debian 12 (Bookworm) on Intel i7-6700 (Skylake)
# Installs Docker CE, Intel GPU drivers, creates directory structure, scaffolds .env
# Safe to run multiple times (idempotent).

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "========================================="
echo "  ReyniBio Media Server Setup"
echo "========================================="
echo ""

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root.${NC}"
    echo "Usage: sudo bash setup.sh"
    exit 1
fi

# --- Detect the real user (not root) ---
ACTUAL_USER="${SUDO_USER:-$USER}"
if ! id "$ACTUAL_USER" &>/dev/null; then
    echo -e "${RED}Error: User '${ACTUAL_USER}' does not exist.${NC}"
    exit 1
fi
ACTUAL_UID=$(id -u "$ACTUAL_USER")
ACTUAL_GID=$(id -g "$ACTUAL_USER")
echo "Running as root. Real user: ${ACTUAL_USER} (${ACTUAL_UID}:${ACTUAL_GID})"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =========================================
# 0. Pre-flight Checks
# =========================================
echo "Running pre-flight checks..."
echo ""

# OS detection
CODENAME="bookworm"
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-bookworm}"
    if [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "12" ]]; then
        echo -e "${GREEN}OS: ${PRETTY_NAME} — supported.${NC}"
    else
        echo -e "${YELLOW}Warning: Expected Debian 12 (Bookworm), detected ${PRETTY_NAME:-unknown}.${NC}"
        echo "This script may still work but has only been tested on Debian 12."
    fi
else
    echo -e "${YELLOW}Warning: /etc/os-release not found — cannot detect OS.${NC}"
fi

# RAM check
TOTAL_MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "0")
if [[ "$TOTAL_MEM_GB" -gt 0 ]]; then
    if [[ "$TOTAL_MEM_GB" -lt 8 ]]; then
        echo -e "${YELLOW}Warning: Only ${TOTAL_MEM_GB}GB RAM detected (recommend at least 8GB).${NC}"
    else
        echo -e "${GREEN}RAM: ${TOTAL_MEM_GB}GB detected.${NC}"
    fi
fi

# Disk space check on /data
DATA_MOUNT="/data"
if mountpoint -q "$DATA_MOUNT" 2>/dev/null || [[ -d "$DATA_MOUNT" ]]; then
    AVAIL_GB=$(df -BG "$DATA_MOUNT" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4}')
    if [[ -n "$AVAIL_GB" && "$AVAIL_GB" -lt 50 ]]; then
        echo -e "${YELLOW}Warning: Only ${AVAIL_GB}GB free on ${DATA_MOUNT} (recommend at least 50GB).${NC}"
    elif [[ -n "$AVAIL_GB" ]]; then
        echo -e "${GREEN}Disk: ${AVAIL_GB}GB free on ${DATA_MOUNT}.${NC}"
    fi
else
    echo -e "${YELLOW}Warning: ${DATA_MOUNT} does not exist yet (will be created in step 4).${NC}"
fi

# Internet connectivity
if curl -sf --max-time 5 https://get.docker.com > /dev/null 2>&1; then
    echo -e "${GREEN}Internet: reachable.${NC}"
else
    echo -e "${YELLOW}Warning: Cannot reach https://get.docker.com — Docker install may fail.${NC}"
fi

# Non-free repo check (needed for Intel GPU drivers)
if [[ -f /etc/apt/sources.list ]] && grep -q "non-free" /etc/apt/sources.list 2>/dev/null; then
    echo -e "${GREEN}APT: non-free repository enabled.${NC}"
elif find /etc/apt/sources.list.d/ -name '*.list' -exec grep -l 'non-free' {} + 2>/dev/null | grep -q .; then
    echo -e "${GREEN}APT: non-free repository enabled (sources.list.d).${NC}"
elif find /etc/apt/sources.list.d/ -name '*.sources' -exec grep -l 'non-free' {} + 2>/dev/null | grep -q .; then
    echo -e "${GREEN}APT: non-free repository enabled (deb822 format).${NC}"
else
    echo -e "${YELLOW}Warning: 'non-free' not found in apt sources — Intel GPU driver install may fail.${NC}"
    echo "Add 'non-free non-free-firmware' to your Debian apt sources if needed."
fi

echo ""

# =========================================
# 1. Install Docker CE + Compose Plugin
# =========================================
if command -v docker &> /dev/null; then
    echo -e "${GREEN}Docker already installed:${NC} $(docker --version)"
else
    echo "Installing Docker CE..."

    apt-get update -qq
    apt-get install -y ca-certificates curl

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    echo -e "${GREEN}Docker installed successfully:${NC} $(docker --version)"
fi

echo ""

# =========================================
# 2. Add user to docker group
# =========================================
if [[ "$ACTUAL_USER" != "root" ]]; then
    if id -nG "$ACTUAL_USER" | grep -qw docker; then
        echo "User '${ACTUAL_USER}' is already in the docker group."
    else
        usermod -aG docker "$ACTUAL_USER"
        echo -e "${GREEN}Added '${ACTUAL_USER}' to docker group.${NC}"
        echo -e "${YELLOW}Note: Log out and back in for group changes to take effect.${NC}"
    fi
else
    echo -e "${YELLOW}Running as root directly (no SUDO_USER). Skipping docker group addition.${NC}"
fi

echo ""

# =========================================
# 3. Install Intel GPU Drivers (QuickSync)
# =========================================
if dpkg -s intel-media-va-driver-non-free &>/dev/null; then
    echo -e "${GREEN}Intel VA-API drivers already installed.${NC}"
else
    echo "Installing Intel VA-API drivers for QuickSync..."
    apt-get install -y intel-media-va-driver-non-free vainfo
fi

# Install sqlite3 for safe backups
if ! dpkg -s sqlite3 &>/dev/null; then
    echo "Installing sqlite3 (for safe database backups)..."
    apt-get install -y sqlite3
fi

# Add user to render and video groups for GPU access
if [[ "$ACTUAL_USER" != "root" ]]; then
    for group in render video; do
        if getent group "$group" > /dev/null 2>&1; then
            if ! id -nG "$ACTUAL_USER" | grep -qw "$group"; then
                usermod -aG "$group" "$ACTUAL_USER"
                echo -e "${GREEN}Added '${ACTUAL_USER}' to ${group} group.${NC}"
            else
                echo "User '${ACTUAL_USER}' is already in the ${group} group."
            fi
        fi
    done
fi

echo ""

# --- Detect render group GID ---
RENDER_GID=""
if getent group render > /dev/null 2>&1; then
    RENDER_GID=$(getent group render | cut -d: -f3)
    echo -e "${GREEN}Render group GID: ${RENDER_GID}${NC}"
else
    echo -e "${YELLOW}Warning: 'render' group not found. QuickSync may not work.${NC}"
    echo "You may need to set RENDER_GID manually in .env"
fi

echo ""

# =========================================
# 4. Create /data directory structure
# =========================================
echo "Creating /data directory structure..."

mkdir -p /data/torrents/incomplete
mkdir -p /data/torrents/complete
mkdir -p /data/media/tv
mkdir -p /data/media/movies

chown -R "${ACTUAL_UID}:${ACTUAL_GID}" /data

echo -e "${GREEN}/data directory structure created:${NC}"
echo "  /data/torrents/incomplete"
echo "  /data/torrents/complete"
echo "  /data/media/tv"
echo "  /data/media/movies"
echo ""

# =========================================
# 5. Create config directories
# =========================================
CONFIG_DIR="${SCRIPT_DIR}/config"

echo "Creating config directories at ${CONFIG_DIR}/..."

SERVICES=(
    gluetun
    qbittorrent
    flaresolverr
    prowlarr
    sonarr
    radarr
    bazarr
    jellyfin
    jellyseerr
    homarr
    uptime-kuma
)

for service in "${SERVICES[@]}"; do
    mkdir -p "${CONFIG_DIR}/${service}"
done

chown -R "${ACTUAL_UID}:${ACTUAL_GID}" "${CONFIG_DIR}"

echo -e "${GREEN}Config directories created for ${#SERVICES[@]} services.${NC}"
echo ""

# =========================================
# 6. Scaffold .env from .env.example
# =========================================
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

if [[ -f "$ENV_FILE" ]]; then
    echo ".env already exists — skipping copy."
else
    if [[ -f "$ENV_EXAMPLE" ]]; then
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        chown "${ACTUAL_USER}:${ACTUAL_USER}" "$ENV_FILE" 2>/dev/null || true
        chmod 600 "$ENV_FILE"
        echo -e "${GREEN}.env created from .env.example (permissions: 600).${NC}"
    else
        echo -e "${RED}Warning: .env.example not found at ${ENV_EXAMPLE}${NC}"
        echo "You will need to create .env manually."
    fi
fi

# Auto-fill PUID/PGID in .env from actual user
if [[ -f "$ENV_FILE" ]]; then
    if grep -q "^PUID=1000$" "$ENV_FILE" && [[ "$ACTUAL_UID" != "1000" ]]; then
        sed -i "s/^PUID=1000$/PUID=${ACTUAL_UID}/" "$ENV_FILE"
        echo -e "${GREEN}Auto-filled PUID=${ACTUAL_UID} in .env${NC}"
    fi
    if grep -q "^PGID=1000$" "$ENV_FILE" && [[ "$ACTUAL_GID" != "1000" ]]; then
        sed -i "s/^PGID=1000$/PGID=${ACTUAL_GID}/" "$ENV_FILE"
        echo -e "${GREEN}Auto-filled PGID=${ACTUAL_GID} in .env${NC}"
    fi
fi

# Auto-fill RENDER_GID in .env if detected
if [[ -n "$RENDER_GID" && -f "$ENV_FILE" ]]; then
    if grep -q "^RENDER_GID=$" "$ENV_FILE"; then
        sed -i "s/^RENDER_GID=$/RENDER_GID=${RENDER_GID}/" "$ENV_FILE"
        echo -e "${GREEN}Auto-filled RENDER_GID=${RENDER_GID} in .env${NC}"
    elif grep -q "^RENDER_GID=" "$ENV_FILE"; then
        echo "RENDER_GID already set in .env — skipping."
    fi
fi

# Auto-generate HOMARR_SECRET_KEY in .env if blank
if [[ -f "$ENV_FILE" ]]; then
    if grep -q "^HOMARR_SECRET_KEY=$" "$ENV_FILE"; then
        HOMARR_KEY=$(openssl rand -hex 32)
        sed -i "s/^HOMARR_SECRET_KEY=$/HOMARR_SECRET_KEY=${HOMARR_KEY}/" "$ENV_FILE"
        echo -e "${GREEN}Auto-generated HOMARR_SECRET_KEY in .env${NC}"
    elif grep -q "^HOMARR_SECRET_KEY=" "$ENV_FILE"; then
        echo "HOMARR_SECRET_KEY already set in .env — skipping."
    fi
fi

echo ""

# =========================================
# 7. Verify QuickSync Readiness
# =========================================
echo "Checking QuickSync readiness..."

if [[ -e /dev/dri/renderD128 ]]; then
    echo -e "${GREEN}/dev/dri/renderD128 exists.${NC}"
else
    echo -e "${YELLOW}Warning: /dev/dri/renderD128 not found.${NC}"
    echo "Intel GPU may not be available. QuickSync will not work without it."
fi

if command -v vainfo &> /dev/null; then
    echo ""
    echo "VA-API info:"
    vainfo 2>&1 | head -5 || echo -e "${YELLOW}vainfo failed — driver may need a reboot.${NC}"
else
    echo -e "${YELLOW}vainfo not available.${NC}"
fi

echo ""

# =========================================
# 8. Verify TUN Device (VPN)
# =========================================
echo "Checking VPN prerequisites..."

if [[ -e /dev/net/tun ]]; then
    echo -e "${GREEN}/dev/net/tun exists.${NC}"
else
    echo -e "${YELLOW}Warning: /dev/net/tun not found. Loading tun module...${NC}"
    modprobe tun 2>/dev/null || true
    if [[ -e /dev/net/tun ]]; then
        echo -e "${GREEN}/dev/net/tun available after modprobe.${NC}"
        # Make it persistent across reboots
        if ! grep -q "^tun$" /etc/modules-load.d/tun.conf 2>/dev/null; then
            echo "tun" > /etc/modules-load.d/tun.conf
            echo "Added tun to /etc/modules-load.d/tun.conf for persistence."
        fi
    else
        echo -e "${RED}Error: Cannot create /dev/net/tun. Gluetun VPN will not work.${NC}"
    fi
fi

echo ""

# =========================================
# 9. Install Tailscale VPN
# =========================================
if command -v tailscale &> /dev/null; then
    echo -e "${GREEN}Tailscale already installed:${NC} $(tailscale version | head -1)"
else
    echo "Installing Tailscale via APT repository..."
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.tailscale-keyring.list" \
        -o /etc/apt/sources.list.d/tailscale.list
    apt-get update -qq
    apt-get install -y tailscale
    echo -e "${GREEN}Tailscale installed:${NC} $(tailscale version | head -1)"
fi

# Check Tailscale auth status
TAILSCALE_IP=""
if tailscale status &> /dev/null; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)
    if [[ -n "$TAILSCALE_IP" ]]; then
        echo -e "${GREEN}Tailscale connected: ${TAILSCALE_IP}${NC}"
    fi
else
    echo -e "${YELLOW}Tailscale installed but not authenticated.${NC}"
    echo "Run 'sudo tailscale up' after setup to connect."
fi

echo ""

# =========================================
# Summary
# =========================================
echo "========================================="
echo -e "  ${GREEN}Setup complete!${NC}"
echo "========================================="
echo ""
echo "Next steps:"
echo "  0. Connect Tailscale (services are localhost-only):"
echo "     sudo tailscale up"
echo "     tailscale ip -4          # note your Tailscale IP"
echo "  1. Edit .env with your VPN credentials"
echo "  2. Start the stack:"
echo "     cd ${SCRIPT_DIR} && docker compose up -d"
echo "  3. Configure services in order:"
echo "     qBittorrent → Prowlarr → Sonarr/Radarr → Jellyfin → Jellyseerr → Bazarr"
echo "  4. Add Flaresolverr to Prowlarr:"
echo "     Settings → Indexers → Add → Flaresolverr"
echo "     Host: http://reyni-gluetun:8191"
echo "  5. Enable QuickSync in Jellyfin:"
echo "     Dashboard → Playback → Hardware acceleration: Intel QuickSync"
echo "     Device: /dev/dri/renderD128"
echo ""
if [[ -n "$TAILSCALE_IP" ]]; then
    echo -e "  Tailscale:       ${GREEN}Connected${NC} (${TAILSCALE_IP})"
else
    echo -e "  Tailscale:       ${YELLOW}Run 'sudo tailscale up' to connect${NC}"
fi
if [[ -n "$RENDER_GID" ]]; then
    echo -e "  Intel QuickSync: ${GREEN}Ready${NC} (render GID: ${RENDER_GID})"
else
    echo -e "  Intel QuickSync: ${YELLOW}Needs manual RENDER_GID${NC}"
fi
echo ""
