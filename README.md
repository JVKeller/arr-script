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
- **Shared network storage (optional)** — Mounts an SMB/CIFS share on the node and bind-mounts it into every container that touches files
- **Automatic deployment** — Downloads and deploys container scripts with generated configuration
- **Headless wiring** — Connects Prowlarr → arr apps and download clients via HTTP APIs (no manual config)
- **Credential extraction** — Auto-extracts API keys from all *arr apps and handles qBittorrent WebUI password setup
- **Validation** — IPv4 validation, duplicate IP detection, port availability checks, collision detection
- **Summary report** — Full deployment details with URLs, credentials, and manual next steps (chmod 600)

## Shared Network Storage (Optional)

The script can point your whole stack at one SMB/CIFS share. This is optional — decline the
prompt and the script behaves exactly as it did before, leaving storage entirely to you.

**What it asks for:** server hostname/IP, share name, and whether the share needs credentials
(username, password, optional domain) or allows guest access.

**It tests before it commits.** The share is mounted to a scratch directory and a test file is
written and removed. If that fails you get the real `mount.cifs` error and can re-enter the
details. Nothing is written to `/etc/fstab` and no containers exist yet at that point.

**Folder structure created on the share** (only the folders for apps you selected):

```
media/                    downloads/
├── tv/                   ├── incomplete/
├── movies/               └── complete/
└── music/                    ├── tv-sonarr/
                              ├── radarr/
                              └── lidarr/
```

Media and downloads live on the **same** mount on purpose. That is what lets the *arr apps
hardlink on import instead of copying the file a second time. Splitting them across different
filesystems doubles your disk usage and import time.

**How it's mounted:**

- One entry in the node's `/etc/fstab` mounts the share at `/mnt/arr-data`, with `_netdev` and
  `nofail` so an unreachable NAS can never block the node from booting.
- Each container that touches files gets a bind mount at `/mnt/data` via
  `pct set <ctid> -mpN /mnt/arr-data,mp=/mnt/data`. Containers are rebooted once so the mount
  point takes effect.
- `prowlarr` and `seerr` are deliberately **not** mounted — an indexer proxy and a request UI
  have no reason to see your media.

**Permissions — read this.** The share is mounted `dir_mode=0777,file_mode=0666` with
`uid=100000,gid=100000`. Because the containers are unprivileged, that makes files appear as
`root:root` inside them and writable by every app without any in-container user/group setup.
The tradeoff is real: **every process in every mounted container can read and write the entire
share.** If you want per-app isolation instead, mount with `dir_mode=0775,file_mode=0664` and
a dedicated GID, then add each app's service user to that group inside its container.

**What persists after the script exits:**

| Path | Contents |
|---|---|
| `/etc/fstab` | The CIFS mount entry for `/mnt/arr-data` |
| `/etc/arr-stack/media-share.cred` | Share username/password/domain, `chmod 600`, root-only |
| `/etc/fstab.arr-stack.bak` | Backup, only if you chose to replace an existing entry |

The share password is **never** printed to the terminal or written into the summary file — the
summary references the credentials file path instead.

**Paths are not auto-configured in the apps.** The folders are created and mounted, but you
enter the paths yourself. The exact strings are printed in the summary's manual-steps section.

## Requirements

- Proxmox VE node with root access
- PVE tools: `pct`, `pvesh`, `pvesm`
- Utilities: `curl`, `whiptail` (or `dialog`), `jq`, `iputils-ping`
- `cifs-utils` — installed automatically, and only if you opt into shared network storage
- An SMB/CIFS share reachable from the PVE node (only if you use shared storage)

## Usage
To use this version, manually download to your PVE host and run it.

```bash
curl -fsSL https://raw.githubusercontent.com/JVKeller/arr-script/main/arr-stack.sh -o arr-stack.sh
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
3. **Shared Storage** — Optionally enter SMB/CIFS share details; access and write are tested immediately
4. **IP Assignment** — Enter IPs for each container (interactive form or list mode)
5. **CTID Allocation** — Set starting container ID (auto-increments for used IDs)
6. **Confirmation** — Review full config before deployment
7. **Share Mount** — Writes the fstab entry, mounts the share, creates the folder structure
8. **Installation** — Downloads and deploys each container with progress gauge
9. **Container Mounts** — Bind-mounts the share into each file-touching container and reboots it
10. **Credential Extraction** — Waits for startup, extracts API keys
11. **API Wiring** — Connects Prowlarr → Sonarr/Radarr/Lidarr, adds qBittorrent/SABnzbd to *arr apps
12. **Summary** — Displays URLs, credentials, storage paths, and manual next steps

Steps 3, 7, and 9 are skipped entirely if you decline shared storage. Step 7 runs *before* any
container is created, so a storage failure aborts while there is nothing to clean up. Step 9
must run after installation because it needs the assigned container IDs.

## Manual Steps Still Required

After provisioning:

- **Prowlarr** — Add indexers (none ship by default)
- **Sonarr/Radarr/Lidarr** — Set root folders and create quality profiles
- **SABnzbd** (if selected) — Open web wizard at `http://<ip>:7777` and complete setup
- **Seerr** (if selected) — Open web wizard at `http://<ip>:5055`, then add Sonarr/Radarr instances

If you used shared storage, the folders already exist — enter these paths:

| App | Setting | Path |
|---|---|---|
| Sonarr | Root folder | `/mnt/data/media/tv` |
| Radarr | Root folder | `/mnt/data/media/movies` |
| Lidarr | Root folder | `/mnt/data/media/music` |
| qBittorrent | Save path | `/mnt/data/downloads/complete` |
| qBittorrent | Temp path | `/mnt/data/downloads/incomplete` |
| SABnzbd | Complete dir | `/mnt/data/downloads/complete` |
| SABnzbd | Incomplete dir | `/mnt/data/downloads/incomplete` |
| Jellyfin | Libraries | `/mnt/data/media/tv`, `/movies`, `/music` |

The summary file prints this same list, filtered to the apps you actually installed.

## Updates & Maintenance

This script is **one-time provisioning only** — it is not designed to be re-run or auto-update.

However, each container can be updated independently via its own ProxmoxVE helper script:

Open the terminal on the container you want to update and simply type `update`

Each *arr container script is separately maintained by the community-scripts project and can be updated without affecting others.

## Files

- `arr-stack.sh` — Main provisioning script (one-time use)
- `/root/arr-stack-summary.txt` — Generated summary (created after successful run)
- `/etc/arr-stack/media-share.cred` — Share credentials, `chmod 600` (only if shared storage used)
- `/etc/fstab` — Gains one CIFS entry for `/mnt/arr-data` (only if shared storage used)

## Troubleshooting

### Container fails to deploy
Check `/tmp/arr-stack-$$.log` for detailed error logs. Script will display the last 20 lines on exit.

### API wiring fails
Ensure containers are fully started and listening on their ports. Check container logs:
```bash
pct logs <ctid>
```

### Share mount fails
The script shows the raw `mount.cifs` error. Common causes:
- `Permission denied` — wrong username/password, or the share requires a domain
- `Host is down` / `Connection timed out` — SMB1-only server, or a firewall between node and NAS
- `No such device` — `cifs-utils` failed to install on the node

### Share is mounted but an app cannot write to it
Verify the mount landed inside the container:
```bash
pct exec <ctid> -- mountpoint /mnt/data
pct exec <ctid> -- touch /mnt/data/media/tv/.probe
```
If the mount is missing, the container may not have restarted. Run `pct reboot <ctid>`.

### qBittorrent password not set
If the script detects a failure, the default `adminadmin` password remains active. Set manually via web UI.

## License

Derived from [community-scripts](https://github.com/community-scripts/ProxmoxVE) (MIT License).

## Support

When requesting help, include the log file from your pve server `/tmp/arr-stack-$$.log` for debugging output from failed deployments.
