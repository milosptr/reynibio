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

### Common Commands

```bash
make up              # start all services
make down            # stop all services
make restart         # restart all services
make logs            # tail all logs
make logs-sonarr     # tail logs for one service
make status          # show container status
make backup          # hot backup of config/ and .env
make certs           # extract Caddy root CA cert
make vpn-check       # verify VPN tunnel
make quicksync-check # verify Intel QuickSync
make help            # list all targets
```

## Services

14 containers across 2 Docker networks. All ports are bound to `127.0.0.1` — services are only reachable via Tailscale VPN or from the host itself.

| Service | Port | Domain | Purpose |
|---------|------|--------|---------|
| Gluetun | 8080, 8191 | `downloads.reyni.lan` | VPN tunnel (qBittorrent + Flaresolverr exposed here) |
| qBittorrent | via Gluetun | — | Torrent client (behind VPN) |
| Flaresolverr | via Gluetun | — | Cloudflare CAPTCHA solver for Prowlarr (behind VPN) |
| Prowlarr | 9696 | `indexers.reyni.lan` | Indexer manager |
| Sonarr | 8989 | `tv.reyni.lan` | TV show management |
| Radarr | 7878 | `movies.reyni.lan` | Movie management |
| Bazarr | 6767 | `subtitles.reyni.lan` | Subtitle management |
| Jellyfin | 8096 | `watch.reyni.lan` | Media server (QuickSync transcoding) |
| Jellyseerr | 5055 | `request.reyni.lan` | Media request UI |
| Docker Socket Proxy | internal | — | Restricts Docker API access for Homarr |
| Homarr | 7575 | `home.reyni.lan` | Service dashboard |
| Uptime Kuma | 3001 | `status.reyni.lan` | Service monitoring & alerting |
| Caddy | 80, 443 | — | Reverse proxy (HTTPS, security headers, compression) |

## Wiring Pipeline

```
Jellyseerr (:5055) — request UI
    ↓
Sonarr (:8989) / Radarr (:7878) — decide what to grab
    ↓
Prowlarr (:9696) → Flaresolverr (:8191) — search indexers (bypass Cloudflare)
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
| `reyni-vpn` | VPN tunnel | Gluetun, qBittorrent, Flaresolverr (via network_mode) |
| `reyni-media` | Service communication | All services (Gluetun bridges both) |

The *arr apps reach qBittorrent at `reyni-gluetun:8080` and Flaresolverr at `reyni-gluetun:8191` through the `reyni-media` network.

## HTTPS & Domain Names

Services are accessible at `https://<service>.reyni.lan` instead of raw IP+port. Caddy acts as a reverse proxy with automatic internal TLS, security headers (HSTS, `X-Content-Type-Options`, `X-Frame-Options`), and zstd/gzip compression.

```
Browser → https://watch.reyni.lan
       → Caddy (:443) — terminates TLS, adds security headers
       → reyni-jellyfin:8096 (Docker network, plain HTTP)
```

Requests to unknown hostnames return a 404 catch-all.

### DNS Setup

Point `*.reyni.lan` to the server's LAN IP. Choose one:

**Option A: Router DNS (recommended)** — add a wildcard DNS entry `*.reyni.lan → <server-lan-ip>` in your router's DNS/DHCP settings. All devices on the network will resolve automatically.

**Option B: `/etc/hosts` per device** — add entries on each client device:

```
# /etc/hosts (Linux/macOS) or C:\Windows\System32\drivers\etc\hosts (Windows)
<server-lan-ip>  watch.reyni.lan request.reyni.lan downloads.reyni.lan
<server-lan-ip>  tv.reyni.lan movies.reyni.lan subtitles.reyni.lan indexers.reyni.lan
<server-lan-ip>  home.reyni.lan status.reyni.lan
```

### Trusting the CA Certificate

On first start, Caddy generates a root CA. Extract it and install on your devices:

```bash
make certs    # creates caddy-root-ca.crt
```

**macOS**: Double-click `caddy-root-ca.crt` → Keychain Access opens → add to "login" keychain → find the cert, double-click → Trust → "Always Trust".

**Windows**: Double-click `caddy-root-ca.crt` → Install Certificate → Local Machine → "Trusted Root Certification Authorities".

**Linux**: `sudo cp caddy-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates`.

**iOS**: AirDrop or email the `.crt` file → Settings → General → VPN & Device Management → install profile → Settings → General → About → Certificate Trust Settings → enable.

**Android**: Settings → Security → Encryption & credentials → Install a certificate → CA certificate → select the file.

### Fallback Access

The `127.0.0.1` port bindings remain. You can still access services via Tailscale at `http://<tailscale-ip>:<port>` if Caddy or DNS is unavailable.

## Security

### Network Isolation

1. **Localhost binding** — every Docker port maps to `127.0.0.1` (including Caddy). No service is reachable from the LAN or internet directly.
2. **Tailscale VPN** — the host runs Tailscale, creating an encrypted WireGuard mesh. Only devices on your Tailscale network can reach the server.

### Container Hardening

Every container runs with restricted privileges:

- `security_opt: [no-new-privileges:true]` — prevents privilege escalation inside containers.
- `cap_drop: [ALL]` — drops all Linux capabilities by default.
- LinuxServer images (Sonarr, Radarr, Prowlarr, Bazarr) get back only `CHOWN`, `SETUID`, `SETGID`, `FOWNER` (required by s6-overlay init).
- Gluetun gets only `NET_ADMIN` + `NET_RAW` (required for VPN tunnel management).
- Memory limits (`mem_limit`) are set on every container.

### VPN Hardening

Gluetun runs with explicit security settings:

- `FIREWALL=on` — built-in kill switch, blocks all traffic if VPN drops.
- `DOT=on` + `DOT_PROVIDERS=cloudflare` — DNS-over-TLS prevents DNS leaks.
- `BLOCK_MALICIOUS=on` — blocks known malicious domains.
- `UPDATER_PERIOD=24h` — keeps VPN server list fresh.
- qBittorrent and Flaresolverr use `network_mode: "service:gluetun"` — all their traffic is forced through the VPN tunnel with no fallback.

### Docker Socket Proxy

Homarr needs Docker API access to auto-discover containers. Instead of mounting the raw Docker socket (which exposes all container secrets via `docker inspect`), a [socket proxy](https://github.com/Tecnativa/docker-socket-proxy) restricts the API surface:

- Read-only access to container and image info only.
- No access to volumes, networks, exec, or write operations.
- Homarr connects via `DOCKER_HOST=tcp://reyni-docker-proxy:2375`.

### Accessing Services from Another Device

1. Install Tailscale on your client device (laptop, phone, etc.).
2. Join the same Tailscale network.
3. Get the server's Tailscale IP: `tailscale ip -4` (on the server).
4. Open `http://<tailscale-ip>:<port>` in your browser.

### MagicDNS (recommended)

Instead of using raw Tailscale IPs, enable [MagicDNS](https://tailscale.com/kb/1081/magicdns/) in the Tailscale admin console. This lets you access services using friendly hostnames:

```
http://<hostname>.tailnet-name.ts.net:8096   # Jellyfin
http://<hostname>.tailnet-name.ts.net:7575   # Homarr
```

Replace `<hostname>` with your server's Tailscale machine name and `tailnet-name` with your tailnet.

### Optional: UFW Hardening

If the server has a public IP, add a firewall as a third layer:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0
sudo ufw enable
```

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

### 2. Stop Seeding After Download

Sonarr and Radarr will hardlink completed downloads into `/data/media/` automatically. To stop seeding and clean up torrents after import:

**Option A (recommended): Let Sonarr/Radarr handle it**
- Sonarr → Settings → Download Clients → Completed Download Handling → enable **Remove Completed**
- Radarr → Settings → Download Clients → Completed Download Handling → enable **Remove Completed**

This removes the torrent from qBittorrent after import. The media file persists in `/data/media/` via the hardlink.

**Option B: Set seeding limits in qBittorrent**
- Settings → BitTorrent → Seeding Limits:
  - "When ratio reaches": `0` (or your preferred ratio)
  - "When seeding time reaches": `0` minutes
  - Then: **Pause torrent**

### 3. Prowlarr (`:9696`)

- Add your indexers (torrent trackers)
- Settings → Indexers → Add → **FlareSolverr**: host `http://reyni-gluetun:8191`
- Settings → Apps: add Sonarr and Radarr connections

### 4. Sonarr (`:8989`) & Radarr (`:7878`)

- Settings → Media Management:
  - Root Folder: `/data/media/tv` (Sonarr) or `/data/media/movies` (Radarr)
  - Enable "Use Hardlinks instead of Copy"
- Settings → Download Clients:
  - Add qBittorrent: host `reyni-gluetun`, port `8080`
- Prowlarr will auto-sync indexers if configured in step 2

### 5. Jellyfin (`:8096`)

- Run initial setup wizard
- Add libraries: `/data/media/tv` and `/data/media/movies`
- **Enable QuickSync** (see below)

### 6. Jellyseerr (`:5055`)

- Connect to Jellyfin: URL `http://reyni-jellyfin:8096`
- Add Sonarr: URL `http://reyni-sonarr:8989`
- Add Radarr: URL `http://reyni-radarr:7878`

### 7. Homarr (`:7575`)

- Open `http://<server-ip>:7575` and create an admin account
- Docker containers are auto-discovered via the socket proxy
- Add service widgets to your board for at-a-glance status

### 8. Bazarr (`:6767`)

- Settings → Sonarr: URL `http://reyni-sonarr:8989`, add API key
- Settings → Radarr: URL `http://reyni-radarr:7878`, add API key
- Settings → Subtitles: configure preferred languages and providers

### 9. Uptime Kuma (`:3001`)

- Open `http://<server-ip>:3001` and create an admin account
- Add monitors for each service:
  - Type: HTTP(s), URL: `http://reyni-<service>:<port>` (use container names)
  - Example: `http://reyni-jellyfin:8096` for Jellyfin
  - Example: `http://reyni-sonarr:8989` for Sonarr
- Set up notification channels (Telegram, Discord, email, etc.) under Settings → Notifications
- Recommended check interval: 60 seconds

## Backups

### Running a Backup

```bash
make backup          # or: bash backup.sh
```

This creates a timestamped `.tar.gz` of the `config/` directory in `backups/`. Services stay running (hot backup). The 5 most recent backups are kept; older ones are pruned automatically.

### What the Backup Does

1. **SQLite-safe dumps** — all `.db` files are dumped via `sqlite3 .backup` before archiving, preventing corruption from hot-copying live databases.
2. **Includes `.env`** — your secrets file is copied into the archive so a single backup file is sufficient for full restore.
3. **Integrity verification** — the archive is tested after creation; corrupt files are deleted automatically.

If `sqlite3` is not installed, the backup still runs but warns that database files may be inconsistent. The setup script installs `sqlite3` by default.

### What's NOT Backed Up

- `/data/torrents/` and `/data/media/` — media files are large and assumed to be re-downloadable.

### Restoring from Backup

```bash
# 1. Run setup.sh on the fresh machine
sudo bash setup.sh

# 2. Stop all services
make down

# 3. Extract the backup
tar -xzf backups/reynibio-config-YYYYMMDD_HHMMSS.tar.gz -C /path/to/reynibio-fresh-start/

# 4. Restore .env from the backup
cp config/.env.backup .env

# 5. Start services
make up
```

### Cron Setup (recommended)

Run daily at 3 AM:

```bash
# Edit crontab for your user
crontab -e

# Add this line:
0 3 * * * cd /path/to/reynibio-fresh-start && bash backup.sh >> backups/backup.log 2>&1
```

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

## Troubleshooting

### VPN not connecting (Gluetun)

```bash
make logs-gluetun    # check for auth errors
```

- Verify `VPN_SERVICE_PROVIDER`, `VPN_TYPE`, and `WIREGUARD_PRIVATE_KEY` in `.env`
- Ensure the WireGuard private key is correct and not expired
- Try a different `VPN_SERVER_COUNTRY` value
- Check if your VPN provider requires additional env vars (see [Gluetun wiki](https://github.com/qdm12/gluetun-wiki))

### QuickSync not working

```bash
make quicksync-check
```

- Verify `/dev/dri/renderD128` exists on the host
- Ensure `RENDER_GID` in `.env` matches `getent group render | cut -d: -f3`
- Check that `intel-media-va-driver-non-free` is installed: `dpkg -l | grep intel-media`
- A reboot may be needed after first driver install

### Services unreachable

- Confirm Tailscale is connected: `tailscale status`
- Verify you're accessing via Tailscale IP, not LAN IP (ports are `127.0.0.1`-only)
- Check container status: `make status`
- Check health: `docker compose ps` shows healthy/unhealthy status
- Restart a specific service: `docker compose restart <service>`

### Disk full

```bash
df -h /data
docker system df     # check Docker disk usage
```

- Remove completed torrents in qBittorrent
- Prune unused Docker images: `docker image prune -a`
- Check backup directory size: `du -sh backups/`

### Permission errors (PUID/PGID)

- All *arr apps and qBittorrent use `PUID`/`PGID` from `.env`
- `setup.sh` auto-detects your UID/GID and fills these in — only override if needed
- Verify ownership: `ls -la /data/` and `ls -la config/`
- Fix: `sudo chown -R $(id -u):$(id -g) /data config/`
- Jellyfin uses `user:` directive directly — ensure its `PUID:PGID` matches the media file owner

### Flaresolverr not working

- Check logs: `docker compose logs flaresolverr`
- Verify Prowlarr → Settings → Indexers → FlareSolverr tag uses `http://reyni-gluetun:8191`
- Flaresolverr runs behind the VPN — if Gluetun is down, Flaresolverr is unreachable
