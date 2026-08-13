# Installarr: ProxmoxVE Helper Script Automated Media Server Builder

A Proxmox VE helper script to automate deployment and configuration of a basic containerized media automation stack focusing on automated API wiring, credential extraction, and simplified operator experience for self-hosted media libraries.

## What is Included

### Working
- **Prowlarr** (indexers)
- **Sonarr** (TV)
- **Radarr** (movies)
- **Lidarr** (music)
- **Bazarr** (subtitles)
- **Seerr** (requests)
- **Jellyfin** (media server)
- **qBittorrent** (Torrent client)
- **SABnzbd** (Usenet client)
- **Requests Welcome!** Open a discussion to make a request or open a PR with your edits

Derived from [@michelroegl-brunner's](https://github.com/michelroegl-brunner) original community script idea.

## Features

- **Fully interactive setup** — Guided prompts for storage, networking, app selection, IP allocation
- **Automatic template preparation** — Reads the OS each upstream `ct/*.sh` declares and downloads any missing LXC template (the *arr apps are Debian-based, Jellyfin is Ubuntu-based)
- **Automatic deployment** — Downloads and deploys container scripts with generated configuration
- **Headless wiring** — Connects Prowlarr → arr apps and download clients via HTTP APIs (no manual config)
- **Bazarr integration** — Wires Bazarr into each selected *arr app automatically
- **Credential extraction** — Auto-extracts API keys from all *arr apps and handles qBittorrent WebUI password setup
- **Optional example indexer** — Can seed Prowlarr with a public indexer (1337x), added **disabled** and behind an explicit warning prompt
- **Validation** — IPv4 validation, duplicate IP detection, port availability checks, collision detection
- **Summary report** — Full deployment details with URLs, credentials, and manual next steps (chmod 600)

## Requirements

- Proxmox VE node with root access
- PVE tools: `pct`, `pvesh`, `pvesm`, `pveam`
- Utilities: `curl`, `whiptail` (or `dialog`), `jq`, `iputils-ping`

## Usage

To use this version, manually download to your PVE host and run it.

```bash
curl -fsSL https://raw.githubusercontent.com/JVKeller/arr-script/main/installarr.sh -o installarr.sh
bash installarr.sh
```

### Environment Variables (Optional)

Pre-configure settings to skip prompts:

```bash
var_container_storage=local-lvm \
var_template_storage=local \
var_bridge=vmbr0 \
var_gateway=192.168.1.1 \
var_cidr=24 \
var_start_ctid=100 \
var_qbt_password=MyStrongPassword \
SUMMARY_FILE=/root/installarr-summary.txt \
sudo bash installarr.sh
```

## Workflow

1. **Storage & Network Selection** — Choose container storage, template storage, network bridge, gateway, CIDR
2. **App Selection** — Pick which *arr apps, media server, and download clients to install
3. **Example Indexer Prompt** — Optionally seed Prowlarr with a disabled public indexer
4. **IP Assignment** — Enter IPs for each container (interactive form or list mode)
5. **CTID Allocation** — Set starting container ID (auto-increments for used IDs)
6. **Confirmation** — Review full config before deployment
7. **Template Preparation** — Verifies and downloads any LXC templates the selected apps require
8. **Installation** — Downloads and deploys each container with progress gauge
9. **Credential Extraction** — Waits for startup, extracts API keys
10. **API Wiring** — Connects Prowlarr → Sonarr/Radarr/Lidarr, adds qBittorrent/SABnzbd to *arr apps, wires Bazarr
11. **Summary** — Displays URLs, credentials, and manual next steps

## Manual Steps Still Required

After provisioning:

- **Prowlarr** — Add indexers. If you accepted the example indexer, 1337x is present but **disabled** — verify you trust it before enabling via Settings → Indexers → 1337x → Enable
- **Sonarr/Radarr/Lidarr** — Set root folders and create quality profiles
- **Bazarr** (if selected) — Open `http://<ip>:6767` and configure subtitle providers and languages
- **Jellyfin** (if selected) — Open `http://<ip>:8096`, complete the setup wizard, and configure library paths
- **SABnzbd** (if selected) — Open web wizard at `http://<ip>:7777` and complete setup
- **Seerr** (if selected) — Open web wizard at `http://<ip>:5055`, then add Sonarr/Radarr instances

## Security Note on the Example Indexer

The optional example indexer is a **public** indexer. Public indexers can surface malicious or mislabeled content. It is deliberately added in a disabled state and is never enabled automatically. Verify it is a legitimate indexer you trust before enabling it.

## Updates & Maintenance

This script is **one-time provisioning only** — it is not designed to be re-run or auto-update.

However, each container can be updated independently via its own ProxmoxVE helper script:

Open the terminal on the container you want to update and simply type `update`

Each *arr container script is separately maintained by the community-scripts project and can be updated without affecting others.

## Files

- `installarr.sh` — Main provisioning script (one-time use)
- `/root/installarr-summary.txt` — Generated summary (created after successful run)
- `/tmp/installarr-<pid>.log` — Verbose log of suppressed command output

## Troubleshooting

### Container fails to deploy
Check `/tmp/installarr-<pid>.log` for detailed error logs. Script will display the last 20 lines on exit.

### Template download fails
The script checks the node's template catalog with `pveam` and downloads what the selected apps need. If a template is unavailable, confirm the node can reach the catalog and that the chosen template storage accepts `vztmpl` content.

### API wiring fails
Ensure containers are fully started and listening on their ports. Check container logs:
```bash
pct logs <ctid>
```

### qBittorrent password not set
If the script detects a failure, the default `adminadmin` password remains active. Set manually via web UI.

## License

Derived from [community-scripts](https://github.com/community-scripts/ProxmoxVE) (MIT License).

## Support

When requesting help, include the log file from your pve server `/tmp/installarr-<pid>.log` for debugging output from failed deployments.
