# Using ReyniBio

Once the stack is running, here's how to use it day-to-day.

## Connect

1. Make sure your device can reach the server (local WiFi, Tailscale VPN, or SSH tunnel).
2. Open any service at `https://<name>.reyni.lan` (see quick reference below).
3. Fallback: `http://<tailscale-ip>:<port>` still works if DNS or Caddy is unavailable.

## Request something to watch

1. Open **Jellyseerr** at `https://request.reyni.lan`.
2. Search for a movie or TV show.
3. Click **Request**. That's it — Sonarr/Radarr will find it, qBittorrent will download it, and it'll appear in Jellyfin automatically.

## Watch

1. Open **Jellyfin** at `https://watch.reyni.lan` in a browser, or use the Jellyfin app on your phone/TV/tablet.
2. Your libraries (Movies, TV Shows) update automatically as content arrives.
3. Subtitles are fetched automatically by Bazarr.

## Check on things

- **Homarr** at `https://home.reyni.lan` — dashboard showing all services at a glance.
- **Uptime Kuma** at `https://status.reyni.lan` — uptime history and alerts if something goes down.

## Quick reference

| What you want to do | Where to go |
|---|---|
| Request a movie or show | `https://request.reyni.lan` |
| Watch something | `https://watch.reyni.lan` |
| Check download progress | `https://downloads.reyni.lan` |
| Manage TV shows | `https://tv.reyni.lan` |
| Manage movies | `https://movies.reyni.lan` |
| Manage subtitles | `https://subtitles.reyni.lan` |
| Manage indexers | `https://indexers.reyni.lan` |
| See all services | `https://home.reyni.lan` |
| Check service health | `https://status.reyni.lan` |
