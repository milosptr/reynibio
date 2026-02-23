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
echo "Running as root. Real user: ${ACTUAL_USER}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =========================================
# 1. Install Docker CE + Compose Plugin
# =========================================
if command -v docker &> /dev/null; then
    echo -e "${GREEN}Docker already installed:${NC} $(docker --version)"
else
    echo "Installing Docker CE for Debian 12 (Bookworm)..."

    apt-get update -qq
    apt-get install -y ca-certificates curl

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
      bookworm stable" > /etc/apt/sources.list.d/docker.list

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
echo "Installing Intel VA-API drivers for QuickSync..."

apt-get install -y intel-media-va-driver-non-free vainfo

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

chown -R 1000:1000 /data

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
    prowlarr
    sonarr
    radarr
    bazarr
    jellyfin
    jellyseerr
)

for service in "${SERVICES[@]}"; do
    mkdir -p "${CONFIG_DIR}/${service}"
done

chown -R 1000:1000 "${CONFIG_DIR}"

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
        echo -e "${GREEN}.env created from .env.example.${NC}"
    else
        echo -e "${RED}Warning: .env.example not found at ${ENV_EXAMPLE}${NC}"
        echo "You will need to create .env manually."
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
# Summary
# =========================================
echo "========================================="
echo -e "  ${GREEN}Setup complete!${NC}"
echo "========================================="
echo ""
echo "Next steps:"
echo "  1. Edit .env with your VPN credentials"
echo "  2. Start the stack:"
echo "     cd ${SCRIPT_DIR} && docker compose up -d"
echo "  3. Configure services in order:"
echo "     qBittorrent → Prowlarr → Sonarr/Radarr → Jellyfin → Jellyseerr → Bazarr"
echo "  4. Enable QuickSync in Jellyfin:"
echo "     Dashboard → Playback → Hardware acceleration: Intel QuickSync"
echo "     Device: /dev/dri/renderD128"
echo ""
if [[ -n "$RENDER_GID" ]]; then
    echo -e "  Intel QuickSync: ${GREEN}Ready${NC} (render GID: ${RENDER_GID})"
else
    echo -e "  Intel QuickSync: ${YELLOW}Needs manual RENDER_GID${NC}"
fi
echo ""
