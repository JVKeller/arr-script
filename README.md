# arr-stack: ProxmoxVE Helper Script Automated Media Server Builder

A Proxmox VE helper script to automate deployment and configuration of a basic containerized media automation stack focusing on automated API wiring, credential extraction, and simplified operator experience for self-hosted media libraries.

##What is Included:
### Working
- **Prowlarr** (indexers)
- **Sonarr** (TV)
- **Radarr** (movies)
- **Lidarr** (music)
- **Bazarr** (subtitles)
- **Seerr** (requests)
- **qBittorrent** (Torrent Client)
- **SABnzbd** (Usenet client)
- **Requests Welcome!** Open a discussion to make a request or open a PR with your edits

Derived from [@michelroegl-brunner's](https://github.com/michelroegl-brunner) original community script idea. 

## Features

- **Fully interactive setup** — Guided prompts for storage, networking, app selection, IP allocation
- **Automatic deployment** — Downloads and deploys container scripts with generated configuration
- **Headless wiring** — Connects Prowlarr → arr apps and download clients via HTTP APIs (no manual config)
- **Credential extraction** — Auto-extracts API keys from all *arr apps and handles qBittorrent WebUI password setup
- **Validation** — IPv4 validation, duplicate IP detection, port availability checks, collision detection
- **Summary report** — Full deployment details with URLs, credentials, and manual next steps (chmod 600)

## Requirements

- Proxmox VE node with root access
- PVE tools: `pct`, `pvesh`, `pvesm`
- Utilities: `curl`, `whiptail` (or `dialog`), `jq`, `iputils-ping`

## Usage
To use this version, manually download to your PVE host and run it.

```bash
bash -c "$(curl -fsSL https://github.com/JVKeller/arr-script/blob/main/arr-stack.sh)"
bash arr-stack.sh
```

### Environment Variables (Optional)

Pre-configure settings to skip prompts:

```bash
var_container_storage=local-lvm \
var_bridge=vmbr0 \
var_gateway=192.168.1.1 \
var_cidr=24 \
var_start_ctid=100 \
var_qbt_password=MyStrongPassword \
SUMMARY_FILE=/root/arr-stack-summary.txt \
sudo bash arr-stack.sh
```

## Workflow

1. **Storage & Network Selection** — Choose container storage, network bridge, gateway, CIDR
2. **App Selection** — Pick which *arr apps and download clients to install
3. **IP Assignment** — Enter IPs for each container (interactive form or list mode)
4. **CTID Allocation** — Set starting container ID (auto-increments for used IDs)
5. **Confirmation** — Review full config before deployment
6. **Installation** — Downloads and deploys each container with progress gauge
7. **Credential Extraction** — Waits for startup, extracts API keys
8. **API Wiring** — Connects Prowlarr → Sonarr/Radarr/Lidarr, adds qBittorrent/SABnzbd to *arr apps
9. **Summary** — Displays URLs, credentials, and manual next steps

## Manual Steps Still Required

After provisioning:

- **Prowlarr** — Add indexers (none ship by default)
- **Sonarr/Radarr/Lidarr** — Set root folders and create quality profiles
- **SABnzbd** (if selected) — Open web wizard at `http://<ip>:7777` and complete setup
- **Seerr** (if selected) — Open web wizard at `http://<ip>:5055`, then add Sonarr/Radarr instances

## Updates & Maintenance

This script is **one-time provisioning only** — it is not designed to be re-run or auto-update.

However, each container can be updated independently via its own ProxmoxVE helper script:

Open the terminal on the container you want to update and simply type `update`

Each *arr container script is separately maintained by the community-scripts project and can be updated without affecting others.

## Files

- `arr-stack.sh` — Main provisioning script (one-time use)
- `/root/arr-stack-summary.txt` — Generated summary (created after successful run)

## Troubleshooting

### Container fails to deploy
Check `/tmp/arr-stack-$$.log` for detailed error logs. Script will display the last 20 lines on exit.

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

When requesting help, include the log file from your pve server `/tmp/arr-stack-$$.log` for debugging output from failed deployments.
