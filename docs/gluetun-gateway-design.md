# Gluetun VPN gateway for Installarr

## Context

An ISP piracy notice landed against traffic from the arr stack. The fix already
built and verified by hand on a live Proxmox host is a dedicated Gluetun LXC
acting as a routing gateway, with every arr container dual-homed: `eth0` on an
uplink-less bridge (`vmbr1`) carrying all internet traffic through the tunnel,
and `eth1` on the LAN for management only, with no default route. Because
`vmbr1` has no physical uplink, isolation is structural rather than
firewall-dependent — if the tunnel drops there is no path to WAN at all.

This branch ports that verified configuration into `installarr.sh` as an opt-in
provisioning path. Today the script builds every container single-homed on one
bridge and wires the apps to each other over LAN addresses.

Intended outcome: a user who opts in gets the same working topology the manual
build produced, gated on a kill-switch test that must pass before the run is
allowed to report success.

## Key constraint discovered while reading the code

`install_loop` ([installarr.sh:955-965](installarr.sh#L955-L965)) hands upstream
`ct/*.sh` exactly one NIC via `var_brg` / `var_net` / `var_gateway`, and
upstream `build_container` only ever creates `net0`. **Dual-homing cannot be
expressed through upstream.** Branching the network setup at container-creation
time would mean forking upstream's creation path — the exact fragility that
burned the last session.

So this is **not** an if/else at network-setup time. Every container is built
the way it is built today (LAN, normal gateway, fast reliable `apt`), and a
separate post-install pass converts the ones that belong behind the VPN via
`pct set`. Upstream is never modified or second-guessed.

A second consequence: everything host-side (`wait_for_port`, `extract_arr_key`,
`api_post`) reaches containers over `APP[$s.ip]`, and the host has **no leg on
`vmbr1`**. `APP[$s.ip]` must therefore stay the LAN address. Inter-app wiring
payloads need a separate address, `APP[$s.wireip]`.

## Scope decisions (confirmed)

- **VPN membership is by role, no prompt.** `indexer`, `arr`, `client` kinds go
  behind the tunnel. `media` (Jellyfin) and `requests` (Seerr) stay LAN-only —
  they are consumer-facing and tunnelling them breaks remote access.
- **Credentials:** whiptail prompts, with `var_gluetun_env_file=<path>` as an
  override that skips every prompt. Private key entered via `--passwordbox`.
- **vmbr1 addressing:** subnet prompted once (default `10.10.10.0/24`, gateway
  `.1`), container addresses auto-assigned `.10`, `.11`, … in install order.
- **Layout:** new `installarr-vpn.func`, sourced from the repo only when VPN is
  opted into — mirroring how `core.func` / `tools.func` are already sourced at
  [installarr.sh:7-8](installarr.sh#L7-L8). Plus a separate, independently
  reviewable dedupe commit on the existing IP-collection code.

## Files

- `installarr.sh` — modified (prompts, catalog, ordering, wiring addresses,
  summary, `main()` sequence)
- `installarr-vpn.func` — **new**, all Gluetun/bridge/conversion/verification
  logic
- `README.md` — usage, env vars, workflow, manual steps

---

## Commit 1 — Dedupe the IP collectors (no VPN code)

Strictly behaviour-preserving. Landed first so the VPN diff stays readable.

`_collect_ips_one_by_one` ([installarr.sh:620-806](installarr.sh#L620-L806))
carries a `dialog` branch (66 lines) and a `whiptail` branch (67 lines) that
differ only in the invocation and its fd redirection. The validation block —
valid IPv4 / gateway collision / duplicate — is written out three times
(lines [590-611](installarr.sh#L590-L611),
[652-682](installarr.sh#L652-L682),
[720-750](installarr.sh#L720-L750)).

Extract two helpers:

- `_validate_ip_set <check_live> <ip>...` — runs the existing checks in the
  existing order, shows the existing whiptail msgbox on failure, returns 1.
  `check_live` gates the `ping -c 1 -W 1` reachability check so current
  behaviour is preserved exactly: **on** for both form modes, **off** for list
  mode.
- `_run_ip_form <slug>...` — resolves `form_input_program`, runs the form, and
  emits one IP per line. The plain-inputbox fallback loop
  ([installarr.sh:759-805](installarr.sh#L759-L805)) is untouched.

Reuses the existing `is_valid_ipv4` ([installarr.sh:267](installarr.sh#L267))
and `form_input_program` ([installarr.sh:275](installarr.sh#L275)).

Net: roughly −130 lines, core goes ~1621 → ~1490.

**Verify:** run all three entry paths (list, dialog form, whiptail form) and
confirm each rejects a malformed IP, a gateway collision, a duplicate, and
(form modes only) a live host — same messages as before.

---

## Commit 2 — `installarr-vpn.func`

Sourced from
`https://raw.githubusercontent.com/JVKeller/arr-script/main/installarr-vpn.func`
immediately after the user opts in, so a declined VPN never fetches it.

### `vpn_prompt_settings`

- Yes/no: "Route download traffic through a Gluetun VPN gateway?" — sets
  `VPN_ENABLED`. Everything below is skipped when off.
- VPN subnet + gateway (default `10.10.10.0/24`, `.1`). **Reject any subnet
  overlapping the container LAN** derived from `var_gateway`/`var_cidr`.
- Bridge name for the isolated segment (default `vmbr1`).
- Management subnet: blank default. Blank means the admin workstation shares
  the container LAN, and the `mgmt-route.service` unit is skipped entirely.
- Credentials — skipped wholesale if `var_gluetun_env_file` is set and readable:
  - provider menu (surfshark / nordvpn / mullvad / protonvpn / other→inputbox)
  - VPN type (wireguard default; OpenVPN allowed)
  - private key via `--passwordbox`
  - `WIREGUARD_ADDRESSES` — **validated as CIDR, explicitly rejected if it
    parses as a hostname.** This is the single most common Gluetun start
    failure and the error message must say so.
  - `SERVER_COUNTRIES` (not `SERVER_HOSTNAMES` — hostnames break on Gluetun
    server-data updates)

### `vpn_ensure_bridge`

Idempotent. Returns early if `^\s*iface vmbr1\b` already matches in
`/etc/network/interfaces`.

**Abort if `/etc/network/interfaces.new` exists** — pending GUI network changes
would later overwrite our appended stanza. Tell the user to apply or discard
them first.

Appends and brings up:

```
auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
```

then `ifup vmbr1`. No ports and no host IP — the absence of an uplink *is* the
security property. Using `ifup` on a single new isolated bridge cannot disturb
existing networking, which `pvesh`-driven apply-everything would risk.

### `vpn_assign_addresses`

Walks `ORDERED_SLUGS`; for each slug whose `kind` is `indexer|arr|client`, sets
`APP[$s.vpnip]` to the next host in the VPN subnet starting at `.10` and
`APP[$s.wireip]` to that value. For every other slug `APP[$s.wireip]` falls back
to `APP[$s.ip]`.

### `vpn_configure_gateway`

Runs after `install_loop`, against the already-built Gluetun container.

1. `pct set <id> -net1 name=eth1,bridge=vmbr1,ip=<gw>/<mask>,type=veth`.
   `net0` is left alone — Gluetun keeps its LAN default gateway, since it needs
   that path to build the tunnel in the first place.
2. Write `/opt/gluetun-data/.env` as a **full replacement**. Upstream's
   `install/gluetun-install.sh` seeds `VPN_SERVICE_PROVIDER=custom` plus
   `OPENVPN_*` keys that must not survive; a wholesale rewrite is deterministic
   and idempotent where key-patching is neither. Pin
   `HTTP_CONTROL_SERVER_ADDRESS=:8000` (never `:51820`), `TZ` from the host's
   `timedatectl show -p Timezone --value`. File written `chmod 600` — it holds
   the private key.
3. `systemctl restart gluetun`, then poll
   `http://<gluetun-lan-ip>:8000/v1/publicip/ip` up to ~120s. Building Gluetun
   from Go source is slow, so this may already be warm.
4. Detect the tunnel interface — `ip -o link` matched against `wg[0-9]`/`tun[0-9]`.
   **Never hardcode `wg0`**: OpenVPN yields `tun0`, and a kill-switch rule
   written against the wrong interface silently does nothing.
5. `net.ipv4.ip_forward=1` to `/etc/sysctl.d/99-gluetun-gw.conf`.
6. Install `/etc/systemd/system/gluetun-gw.service` — `Type=oneshot`,
   `RemainAfterExit=yes`, `After=gluetun.service`, `Wants=gluetun.service` —
   whose `ExecStart` script re-detects the tunnel interface and applies, each
   guarded by a matching `iptables -C` so re-runs do not grow the chain:

   ```
   -t nat -A POSTROUTING -o $TUN -j MASQUERADE
   -A FORWARD -i eth1 -o $TUN -j ACCEPT
   -A FORWARD -i $TUN -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
   -A FORWARD -i eth1 ! -o $TUN -j DROP
   -t mangle -A FORWARD -p tcp --syn -j TCPMSS --clamp-mss-to-pmtu
   ```

   The MSS clamp is not optional — `wg0` MTU 1320 against `eth0` MTU 1500 is
   what produces "web UI loads fine, downloads stall at 0%".

   > **Deviation from the manual build, flagged deliberately.** The hand-built
   > host used `iptables-persistent`. That pulls a debconf prompt (which this
   > script's whole design avoids) and, worse, `netfilter-persistent.service`
   > has no ordering relationship to `gluetun.service`. An ordered oneshot unit
   > guarantees the rules land *after* Gluetun installs its own chains and sets
   > `FORWARD` policy to `DROP`. Step 4 of `vpn_verify` re-checks the rules
   > after a deliberate `systemctl restart gluetun`, which is the condition the
   > spec asked to confirm.

### `vpn_convert_clients`

Per VPN-member container, then `pct reboot` and wait for the LAN port again:

```
pct set <id> -net0 name=eth0,bridge=vmbr1,gw=<vpn-gw>,ip=<vpnip>/<mask>,type=veth
pct set <id> -net1 name=eth1,bridge=<var_bridge>,firewall=0,ip=<lanip>/<var_cidr>,type=veth
pct set <id> -nameserver <vpn-gw>
```

Three non-negotiables, each of which caused a failure in the manual build:

- Gateway on `net0` **only**. A second default route is a coin-flip leak.
- No `gw=` on `net1`.
- `firewall=0` on `net1`. Proxmox's per-NIC firewall defaults to dropping
  inbound when no rules are defined, which silently kills LAN web UI access.

Then pushed into the container:

- `/etc/sysctl.d/99-rp.conf` with **both**
  `net.ipv4.conf.all.rp_filter=2` and `net.ipv4.conf.eth1.rp_filter=2` — the
  kernel takes the max of the two, so setting only the interface does nothing.
- `/etc/systemd/system/mgmt-route.service`, only when a management subnet was
  given: `After=sysinit.target` (**not** `network-online.target`, which
  frequently never fires in an LXC and leaves the unit waiting forever), and
  `ip route replace` (**not** `add`, which returns non-zero on an existing
  route and fails the unit). Never `/etc/network/interfaces` — Proxmox rewrites
  it on container start.

DNS points at the Gluetun gateway, which upstreams through the tunnel. It must
**not** point at a LAN resolver: a LAN resolver forwards upstream over WAN from
its own interface, so every indexer and tracker hostname would reach the ISP in
cleartext while the payload is tunnelled. The trade-off — these containers
bypass LAN-side blocklists — is accepted for download infrastructure.

### `vpn_verify` — the gate

Runs before credential extraction, so a leaking build fails while there is
still nothing to report as success.

1. Exactly one default route per container, via the VPN bridge.
2. `curl -s -m10 ifconfig.me` from each container returns the **same** IP, and
   that IP matches Gluetun's own `/v1/publicip/ip`.
3. `sysctl -n net.ipv4.conf.all.rp_filter` is `2`; mgmt route present when
   configured.
4. `systemctl restart gluetun`, then confirm the FORWARD ACCEPT rules are still
   in place ahead of the DROP policy.
5. **Kill-switch test.** Stop Gluetun; `curl -s -m10 ifconfig.me` from a client
   **must time out**; start Gluetun again.

Any returned IP in step 5 aborts the run loudly with remediation text.
Containers are left in place — `orphan_report`
([installarr.sh:894](installarr.sh#L894)) already prints the cleanup commands. A
silently leaking build is worse than a failed one, and this is the whole point
of the branch.

---

## Commit 3 — `installarr.sh` integration

- **Catalog** ([installarr.sh:295-305](installarr.sh#L295-L305)): add
  `gluetun|gluetun.sh|8000|||vpn|Gluetun|`. Kind `vpn` falls through every
  existing `case` on `APP[$s.kind]` harmlessly.
- **`compute_ordered_slugs`** ([installarr.sh:528](installarr.sh#L528)):
  prepend `gluetun` when `VPN_ENABLED`. It then flows through the existing IP,
  CTID, template and install machinery with no special-casing — including
  `prepare_templates`, which reads `var_os=debian` / `var_version=13` straight
  out of upstream `ct/gluetun.sh`.
- **`install_loop`**: unchanged. Gluetun builds on the LAN like everything
  else; the tunnel is configured afterwards.
- **Wiring payloads**: swap `APP[$s.ip]` → `APP[$s.wireip]` in
  `wire_arrs_into_prowlarr` (`prowlarrUrl`, `baseUrl` —
  [installarr.sh:1302-1303](installarr.sh#L1302-L1303)),
  `wire_clients_into_arrs` (qBittorrent `host`
  [1352](installarr.sh#L1352), SABnzbd `host`
  [1384](installarr.sh#L1384)), and `wire_bazarr_into_arrs` (`baseUrl`
  [1437](installarr.sh#L1437)). This keeps app-to-app traffic on `vmbr1` rather
  than hairpinning through the LAN. The `arr_ip` used to *build the API URL*
  stays `APP[$s.ip]`, because that call originates on the host.
- **`write_summary`**: user-facing URLs stay on LAN IPs. Add a `[VPN]` block —
  exit IP, gluetun URL, both addresses per container — and keep the manual
  Seerr wiring lines on LAN addresses, since Seerr is not on `vmbr1`.
- **`confirm_summary`** ([installarr.sh:881](installarr.sh#L881)): show the VPN
  topology before anything is created.
- **`main()`** ([installarr.sh:1591](installarr.sh#L1591)) new order:

  ```
  ... pick_clients
  vpn_prompt_settings          # new, sources installarr-vpn.func on opt-in
  ... pick_ctids / pick_verbose
  vpn_ensure_bridge            # new
  confirm_summary
  prepare_templates
  install_loop                 # unchanged
  vpn_configure_gateway        # new
  vpn_convert_clients          # new
  vpn_verify                   # new — aborts on leak
  wait_and_extract_keys
  wire_apis
  write_summary
  ```

---

## Verification

**Reference build:** CT 999 on the PVE host is the hand-built, working Gluetun
gateway this design is ported from. It is healthy and running — an earlier note
in this plan claimed it was locked with no network device, which was wrong and
has been removed. Before implementing Commit 2, dump its live configuration
(`pct config 999`, `iptables -S`, the systemd units, `/etc/network/interfaces`)
and port the verified values rather than the ones reconstructed from memory
below. Where this document and CT 999 disagree, CT 999 wins.

1. **Dedupe regression (commit 1, before any VPN work).** Run the script to the
   IP prompt in all three modes; confirm identical rejection messages for
   malformed IP, gateway collision, duplicate, and live host.
2. **VPN declined.** Full run with the VPN prompt answered no. `installarr-vpn.func`
   must never be fetched, `vmbr1` must not be created, and the resulting stack
   must behave exactly as it does on `main`.
3. **VPN accepted, small stack.** Prowlarr + Sonarr + qBittorrent + Jellyfin.
   Then per container:

   ```bash
   pct exec <id> -- ip route | grep default          # one, via the VPN bridge
   pct exec <id> -- curl -s -m10 ifconfig.me         # identical across containers
   curl -s http://<vpn-gw>:8000/v1/publicip/ip       # matches
   pct exec <id> -- sysctl -n net.ipv4.conf.all.rp_filter   # 2
   ```

   Jellyfin must still show its LAN IP here — confirming the role split works.
4. **Kill switch.** `systemctl stop gluetun`, then `curl -s -m10 ifconfig.me`
   from a client **must time out**. Then restart. Also confirm the script's own
   `vpn_verify` aborts the run when this fails — test by deliberately breaking
   the FORWARD DROP rule.
5. **Persistence.** Reboot one client container and the Gluetun container, then
   re-run everything in 3 and 4. The systemd units and sysctl settings are the
   parts that silently fail.
6. **Idempotence.** Re-run `vpn_configure_gateway` and confirm the `iptables -S`
   line count is unchanged.
7. **Throughput, not just connectivity.** Pull a large file inside a client.
   A connection that opens and then hangs means the MSS clamp is missing.
8. **Management access.** Load each web UI from the LAN, and from a different
   subnet if one is available, before and after a reboot.

## Out of scope

Per section 5 of the spec, pointing Sonarr/Radarr/Prowlarr at each other's
`vmbr1` addresses is handled automatically by the `wireip` change. The remaining
Prowlarr "Sync App Indexers" click and Seerr's first-run wizard stay manual —
they already are today.
