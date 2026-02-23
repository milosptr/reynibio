# ReyniBio Media Server

Home media server stack running on Debian 12 with Intel QuickSync hardware transcoding.

## Quick Start

```bash
# 1. Provision the machine (Docker, Intel GPU drivers, Tailscale, directories)
sudo bash setup.sh

# 2. Connect to Tailscale (services are localhost-only)
sudo tailscale up
tailscale ip -4          # note your Tailscale IP

# 3. Edit .env with your VPN credentials
nano .env

# 4. Start all services
docker compose up -d

# 5. Open the dashboard at http://<tailscale-ip>:7575
```

## Services

All ports are bound to `127.0.0.1` — services are only reachable via Tailscale VPN or from the host itself.

| Service | Port | Purpose |
|---------|------|---------|
| Gluetun | 8080 | VPN tunnel (qBittorrent WebUI exposed here) |
| qBittorrent | via Gluetun | Torrent client (behind VPN) |
| Prowlarr | 9696 | Indexer manager |
| Sonarr | 8989 | TV show management |
| Radarr | 7878 | Movie management |
| Bazarr | 6767 | Subtitle management |
| Jellyfin | 8096 | Media server (QuickSync transcoding) |
| Jellyseerr | 5055 | Media request UI |
| Homarr | 7575 | Service dashboard |

## Wiring Pipeline

```
Jellyseerr (:5055) — request UI
    ↓
Sonarr (:8989) / Radarr (:7878) — decide what to grab
    ↓
Prowlarr (:9696) — search indexers
    ↓
qBittorrent (:8080 via Gluetun VPN) — download
    ↓
/data/torrents/ → hardlink → /data/media/
    ↓
Jellyfin (:8096) — stream with QuickSync transcoding
    ↓
Bazarr (:6767) — auto-download subtitles for media
```

## Networks

| Network | Purpose | Members |
|---------|---------|---------|
| `reyni-vpn` | VPN tunnel | Gluetun, qBittorrent (via network_mode) |
| `reyni-media` | Service communication | All services (Gluetun bridges both) |

The *arr apps reach qBittorrent at `reyni-gluetun:8080` through the `reyni-media` network.

## Security

Two layers keep services private:

1. **Localhost binding** — every Docker port maps to `127.0.0.1`, so no service is reachable from the LAN or internet.
2. **Tailscale VPN** — the host runs Tailscale, which creates an encrypted WireGuard mesh. Only devices on your Tailscale network can reach the server.

### Accessing services from another device

1. Install Tailscale on your client device (laptop, phone, etc.).
2. Join the same Tailscale network.
3. Get the server's Tailscale IP: `tailscale ip -4` (on the server).
4. Open `http://<tailscale-ip>:<port>` in your browser.

### Optional: UFW hardening

If the server has a public IP, add a firewall as a third layer:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0
sudo ufw enable
```

This allows all traffic over the Tailscale interface and blocks everything else.

## Directory Structure

```
/data/
  torrents/
    incomplete/    # qBittorrent active downloads
    complete/      # qBittorrent finished downloads
  media/
    tv/            # Sonarr imports here (hardlinked from torrents)
    movies/        # Radarr imports here (hardlinked from torrents)
```

Sonarr and Radarr mount the full `/data` tree so hardlinks work across `torrents/` and `media/` (same filesystem, no copy needed).

## Post-Deploy Configuration

Configure services in this order:

### 1. qBittorrent (`:8080`)

- Default login: `admin` / check container logs for temporary password
- Settings → Downloads:
  - Default Save Path: `/data/torrents/complete`
  - Incomplete: `/data/torrents/incomplete`

### 2. Prowlarr (`:9696`)

- Add your indexers (torrent trackers)
- Settings → Apps: add Sonarr and Radarr connections

### 3. Sonarr (`:8989`) & Radarr (`:7878`)

- Settings → Media Management:
  - Root Folder: `/data/media/tv` (Sonarr) or `/data/media/movies` (Radarr)
  - Enable "Use Hardlinks instead of Copy"
- Settings → Download Clients:
  - Add qBittorrent: host `reyni-gluetun`, port `8080`
- Prowlarr will auto-sync indexers if configured in step 2

### 4. Jellyfin (`:8096`)

- Run initial setup wizard
- Add libraries: `/data/media/tv` and `/data/media/movies`
- **Enable QuickSync** (see below)

### 5. Jellyseerr (`:5055`)

- Connect to Jellyfin: URL `http://reyni-jellyfin:8096`
- Add Sonarr: URL `http://reyni-sonarr:8989`
- Add Radarr: URL `http://reyni-radarr:7878`

### 6. Homarr (`:7575`)

- Open `http://<server-ip>:7575` and create an admin account
- Docker containers are auto-discovered via the mounted socket
- Add service widgets to your board for at-a-glance status

### 7. Bazarr (`:6767`)

- Settings → Sonarr: URL `http://reyni-sonarr:8989`, add API key
- Settings → Radarr: URL `http://reyni-radarr:7878`, add API key
- Settings → Subtitles: configure preferred languages and providers

## Intel QuickSync (i7-6700 Skylake, HD 530)

### Jellyfin Dashboard Settings

Dashboard → Playback → Transcoding:

- **Hardware acceleration**: Intel QuickSync Video
- **Hardware acceleration device**: `/dev/dri/renderD128`
- **Enable hardware decoding for**: H.264, HEVC, MPEG2, VC1, VP8
- **Enable hardware encoding**: checked
- **Allow encoding in HEVC format**: checked

### Skylake HD 530 Codec Support

| Codec | Decode | Encode |
|-------|--------|--------|
| H.264 (AVC) | Yes | Yes |
| HEVC 8-bit | Yes | Yes |
| HEVC 10-bit | No | No |
| VP8 | Yes | No |
| VP9 | No | No |
| AV1 | No | No |
| MPEG-2 | Yes | No |
| VC-1 | Yes | No |

**Not supported**: VP9, AV1, 10-bit HEVC, hardware tone mapping. These will fall back to software transcoding.

### Verify QuickSync on Host

```bash
# Check GPU device exists
ls -la /dev/dri/

# Check VA-API capabilities
vainfo
```
