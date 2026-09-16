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
- **Gluetun VPN gateway** (optional, opt-in) — see [VPN Gateway](#vpn-gateway-optional)
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
- **State file** — Machine-readable record of every container built (`/root/installarr-state.conf`, chmod 600), written on every run
- **Optional VPN gateway** — Installs a Gluetun LXC and prepares an isolated bridge, leaving provider setup and the cutover to you

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
var_vlan=20 \
var_start_ctid=100 \
var_qbt_password=MyStrongPassword \
INSTALL_MODE=advanced \
SUMMARY_FILE=/root/installarr-summary.txt \
STATE_FILE=/root/installarr-state.conf \
var_installarr_ref=main \
sudo bash installarr.sh
```

## Workflow

1. **Install Mode** — `default` for a flat untagged network, or `advanced` to also set a VLAN tag
2. **Storage & Network Selection** — Choose container storage, template storage, network bridge, gateway, CIDR, and (advanced only) the VLAN tag applied to every container
3. **App Selection** — Pick which *arr apps, media server, and download clients to install
4. **Example Indexer Prompt** — Optionally seed Prowlarr with a disabled public indexer
5. **IP Assignment** — Enter IPs for each container (interactive form or list mode)
6. **CTID Allocation** — Set starting container ID (auto-increments for used IDs)
7. **Confirmation** — Review full config before deployment
8. **Template Preparation** — Verifies and downloads any LXC templates the selected apps require
9. **Installation** — Downloads and deploys each container with progress gauge
10. **Credential Extraction** — Waits for startup, extracts API keys
11. **API Wiring** — Connects Prowlarr → Sonarr/Radarr/Lidarr, adds qBittorrent/SABnzbd to *arr apps, wires Bazarr
12. **Summary** — Displays URLs, credentials, and manual next steps
13. **State** — Writes `/root/installarr-state.conf` describing every container built

If the VPN gateway was selected, a prompt appears after app selection, the Gluetun container
is installed alongside the others, and the isolated bridge is prepared. **No other container
is modified during the run.**

---

## VPN Gateway (optional)

Installs [Gluetun](https://github.com/qdm12/gluetun) in its own LXC and prepares an
uplink-less bridge (default `vmbr1`) for tunnelled traffic. Because that bridge has no
physical uplink, isolation is structural: if the tunnel drops there is no path to WAN at all,
without relying on firewall rules.

### Two stages, deliberately

`installarr.sh` does **not** configure a VPN provider and does **not** move any container
behind the tunnel. There are too many providers to prompt for sensibly, and moving a container
onto an uplink-less bridge before a tunnel exists would leave it with no internet at all.

So when the installer finishes, the gateway is **inert and bypassed**. Every container still
uses its normal LAN route and the stack is fully functional. You can test everything before
touching the VPN.

### Post-install

The exact commands, with your CTIDs filled in, are written to the summary file. In short:

**1. Configure your provider** inside the Gluetun container:

```bash
pct exec <gluetun-ctid> -- nano /opt/gluetun-data/.env
pct exec <gluetun-ctid> -- chmod 600 /opt/gluetun-data/.env
```

At minimum set `VPN_SERVICE_PROVIDER`, `VPN_TYPE`, and your credentials. For WireGuard that
means `WIREGUARD_PRIVATE_KEY` and `WIREGUARD_ADDRESSES`.

> **`WIREGUARD_ADDRESSES` must be the address *and prefix* from your provider's config**
> (e.g. `10.14.0.2/16`). A hostname here is the single most common cause of Gluetun failing
> to start.
>
> Prefer `SERVER_COUNTRIES` over `SERVER_HOSTNAMES` — hostnames break whenever Gluetun
> refreshes its server list.

**2. Confirm the tunnel came up:**

```bash
pct exec <gluetun-ctid> -- systemctl restart gluetun
pct exec <gluetun-ctid> -- ip -o link | grep -E 'wg[0-9]|tun[0-9]'
pct exec <gluetun-ctid> -- journalctl -u gluetun -n 50   # if nothing matches
```

**3. Move the stack behind the tunnel:**

```bash
/root/installarr-vpn.sh
```

Reads `/root/installarr-state.conf`, and **refuses to run until step 2 succeeds**. For each
member it sets the default route to the gateway, keeps the LAN address on a second NIC for
management, points DNS at the gateway, and staggers boot order. Then it verifies: one default
route via the gateway, every member egressing the same address, reverse-path filtering, and a
kill-switch test that stops Gluetun and confirms nothing reaches WAN.

Safe to re-run at any time — every step is idempotent, and re-running is how you re-verify.
Pass `-y` to skip the confirmation prompt.

### What goes behind the tunnel

| Behind the VPN | Stays on the LAN |
|---|---|
| Prowlarr, Sonarr, Radarr, Lidarr, Bazarr | Jellyfin |
| qBittorrent, SABnzbd | Seerr |

Jellyfin and Seerr are consumer-facing — tunnelling them breaks remote access. Members keep
their LAN address on a second NIC, so web UIs stay reachable and the API wiring between apps
is unaffected.

### Undo

Point each container's `net0` back at the LAN bridge:

```bash
pct set <ctid> -net0 name=eth0,bridge=vmbr0,gw=<lan-gw>,ip=<lan-ip>/24,type=veth
pct set <ctid> -delete net1
pct set <ctid> -delete nameserver
pct reboot <ctid>
```

> **Status:** the VPN gateway is new and has had no real-world testing yet. Every `pct`,
> `iptables` and `systemctl` path is unexercised. Feedback and bug reports welcome.

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
- `installarr-vpn.func` — Install-time VPN gateway support, fetched only if you opt in
- `installarr-vpn.sh` — Post-install cutover and verification, saved to `/root/`
- `/root/installarr-state.conf` — Machine-readable record of the build (chmod 600)
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

### Gluetun will not start
`pct exec <ctid> -- journalctl -u gluetun -n 50`. The usual cause is `WIREGUARD_ADDRESSES`
set to a hostname instead of an address and prefix.

### installarr-vpn.sh refuses to run
It found no `wg`/`tun` interface in the Gluetun container. That is deliberate — the VPN bridge
has no uplink, so converting containers without a tunnel would cut their internet entirely.
Finish the provider setup first.

### Web UI unreachable after the cutover
Check the container kept its LAN NIC: `pct config <ctid>` should show `net1` on the LAN bridge
with no `gw=`. Only `net0` carries a default route.

### Downloads stall at 0% but the web UI loads
The MSS clamp is missing. Run
`pct exec <gluetun-ctid> -- systemctl restart gluetun-gw.service` and confirm with
`iptables -t mangle -S`.

### qBittorrent password not set
If the script detects a failure, the default `adminadmin` password remains active. Set manually via web UI.

## License

Derived from [community-scripts](https://github.com/community-scripts/ProxmoxVE) (MIT License).

## Support

When requesting help, include the log file from your pve server `/tmp/installarr-<pid>.log` for debugging output from failed deployments.
