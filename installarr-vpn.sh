#!/usr/bin/env bash
#
# installarr-vpn.sh -- move an Installarr stack behind a Gluetun gateway.
#
# Run this on the Proxmox host AFTER installarr.sh has installed the gateway and
# AFTER you have configured a VPN provider in the Gluetun container and
# confirmed the tunnel is up. It refuses to run otherwise, because the VPN
# bridge has no physical uplink: moving containers onto it without a working
# tunnel leaves them with no internet at all.
#
# Reads the state installarr.sh wrote to /root/installarr-state.conf.
#
# Safe to re-run. Every step is idempotent.

set -eEo pipefail

RD=$'\033[01;31m'
GN=$'\033[1;92m'
YW=$'\033[33m'
BL=$'\033[36m'
CL=$'\033[m'
msg_info() { echo -e " ${YW}${1}${CL}"; }
msg_ok() { echo -e " ${GN}[ok]${CL} ${1}"; }
msg_warn() { echo -e " ${YW}[WARN]${CL} ${1}"; }
msg_err() { echo -e " ${RD}[x]${CL} ${1}"; }
msg_step() { echo -e "\n${BL}==>${CL} ${1}"; }

STATE_FILE="${STATE_FILE:-/root/installarr-state.conf}"
ASSUME_YES=0
[[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && ASSUME_YES=1

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

((EUID == 0)) || {
  msg_err "Run as root on the Proxmox host."
  exit 1
}
command -v pct >/dev/null || {
  msg_err "pct not found -- this must run on the Proxmox host."
  exit 1
}

if [[ ! -r "$STATE_FILE" ]]; then
  msg_err "No VPN state at ${STATE_FILE}."
  msg_err "Run installarr.sh and choose the Gluetun gateway option first."
  exit 1
fi
# shellcheck source=/dev/null
source "$STATE_FILE"

if [[ "${VPN_ENABLED:-0}" != "1" ]]; then
  msg_err "That installarr run did not install a Gluetun gateway."
  msg_err "Re-run installarr.sh and choose the VPN gateway option."
  exit 1
fi

for v in VPN_BRIDGE VPN_GW VPN_MASK LAN_BRIDGE LAN_GW LAN_CIDR GLUETUN_CTID CONTAINERS; do
  [[ -n "${!v:-}" ]] || {
    msg_err "${STATE_FILE} is missing ${v}."
    exit 1
  }
done

# CONTAINERS holds every container installarr built, as
# slug:ctid:lan_ip:port:kind:planned_vpn_ip. A member is one with a planned VPN
# address -- Jellyfin and Seerr are recorded but have none, so they are skipped.
MEMBERS=""
for _c in $CONTAINERS; do
  IFS=: read -r _slug _ctid _lan _port _kind _vpnip <<<"$_c"
  [[ "$_slug" == "gluetun" ]] && continue
  [[ -n "$_vpnip" ]] || continue
  MEMBERS+="${_slug}:${_ctid}:${_lan}:${_vpnip}:${_port} "
done

if [[ -z "${MEMBERS// /}" ]]; then
  msg_err "No containers in ${STATE_FILE} are marked for the tunnel."
  exit 1
fi

msg_step "Preflight"

if ! pct status "$GLUETUN_CTID" 2>/dev/null | grep -q running; then
  msg_err "Gluetun container ${GLUETUN_CTID} is not running."
  exit 1
fi

# The gate. Without a tunnel, converting a container strands it with no route to
# anywhere -- the bridge it moves onto has no uplink.
TUN_IF=$(pct exec "$GLUETUN_CTID" -- sh -c \
  "ip -o link | awk -F': ' '{print \$2}' | grep -E '^(wg|tun)[0-9]+\$' | head -n1" 2>/dev/null || true)

if [[ -z "$TUN_IF" ]]; then
  msg_err "No tunnel interface in Gluetun container ${GLUETUN_CTID}."
  echo
  msg_err "Finish the VPN setup first:"
  msg_err "  pct exec ${GLUETUN_CTID} -- nano /opt/gluetun-data/.env"
  msg_err "  pct exec ${GLUETUN_CTID} -- systemctl restart gluetun"
  msg_err "  pct exec ${GLUETUN_CTID} -- journalctl -u gluetun -n 50"
  echo
  msg_err "Refusing to continue: the ${VPN_BRIDGE} bridge has no uplink, so"
  msg_err "moving containers onto it now would cut their internet entirely."
  exit 1
fi
msg_ok "Tunnel is up on ${TUN_IF}."

# Apply the forwarding rules now that a tunnel actually exists to match.
pct exec "$GLUETUN_CTID" -- systemctl restart gluetun-gw.service >/dev/null 2>&1 || true
if ! pct exec "$GLUETUN_CTID" -- sh -c "iptables -S FORWARD | grep -q 'eth1 ! -o'" 2>/dev/null; then
  msg_err "The gateway forwarding rules are not in place."
  msg_err "Check: pct exec ${GLUETUN_CTID} -- systemctl status gluetun-gw.service"
  exit 1
fi
msg_ok "Gateway forwarding rules are active."

GW_EXIT=$(pct exec "$GLUETUN_CTID" -- curl -s -m10 ifconfig.me 2>/dev/null || true)
[[ -n "$GW_EXIT" ]] && msg_ok "Gateway egresses ${GW_EXIT}."

# --------------------------------------------------------------------------
# Confirm
# --------------------------------------------------------------------------

echo
echo "The following containers will be moved behind the tunnel:"
echo
for m in $MEMBERS; do
  IFS=: read -r slug ctid lanip vpnip _port <<<"$m"
  printf '  %-14s CT %-5s LAN %-15s -> VPN %s\n' "$slug" "$ctid" "$lanip" "$vpnip"
done
echo
echo "Each keeps its LAN address on a second NIC for management and web UI"
echo "access. Only its default route changes."
echo

if ((!ASSUME_YES)); then
  read -r -p "Proceed? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || {
    msg_warn "Cancelled."
    exit 0
  }
fi

# --------------------------------------------------------------------------
# Convert
# --------------------------------------------------------------------------

wait_for_port() {
  local host=$1 port=$2 timeout=${3:-120} waited=0
  while ((waited < timeout)); do
    if timeout 2 bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null; then return 0; fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

push_file() {
  local ctid=$1 dest=$2 tmp
  tmp=$(mktemp)
  cat >"$tmp"
  pct push "$ctid" "$tmp" "$dest"
  rm -f "$tmp"
}

msg_step "Converting containers"

startup=30
for m in $MEMBERS; do
  IFS=: read -r slug ctid lanip vpnip port <<<"$m"

  msg_info "Moving ${slug} (CT ${ctid})..."

  # Two rules that each cost a debugging session in the reference build: the
  # default gateway lives on net0 ONLY -- a second one is a coin-flip leak --
  # and net1 gets no gw=. firewall=0 is explicit for determinism.
  pct set "$ctid" -net0 "name=eth0,bridge=${VPN_BRIDGE},firewall=0,gw=${VPN_GW},ip=${vpnip}/${VPN_MASK},type=veth"
  pct set "$ctid" -net1 "name=eth1,bridge=${LAN_BRIDGE},firewall=0,ip=${lanip}/${LAN_CIDR},type=veth"
  # DNS through the gateway, which upstreams via the tunnel. A LAN resolver here
  # would forward every indexer and tracker hostname over WAN in cleartext while
  # the payload stayed tunnelled.
  pct set "$ctid" -nameserver "$VPN_GW"
  # Must not start before the gateway has a tunnel.
  pct set "$ctid" -startup "up=${startup}"
  startup=$((startup + 10))

  # Loose reverse-path filtering on the management leg. Validation on an
  # interface uses max(conf.all, conf.<iface>), and 2 is the highest valid
  # value, so the interface key alone pins it whatever conf.all holds.
  printf 'net.ipv4.conf.eth1.rp_filter=2\n' | push_file "$ctid" /etc/sysctl.d/99-rp.conf

  if [[ -n "${VPN_MGMT_SUBNET:-}" ]]; then
    # After=sysinit.target, not network-online.target -- the latter frequently
    # never fires in an LXC and leaves the unit waiting forever. And "ip route
    # replace", not "add", which returns non-zero on an existing route and
    # fails the unit. Never /etc/network/interfaces: Proxmox rewrites it.
    push_file "$ctid" /etc/systemd/system/mgmt-route.service <<UNIT
[Unit]
After=sysinit.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip route replace ${VPN_MGMT_SUBNET} via ${LAN_GW} dev eth1

[Install]
WantedBy=multi-user.target
UNIT
    pct exec "$ctid" -- systemctl daemon-reload
    pct exec "$ctid" -- systemctl enable mgmt-route.service >/dev/null 2>&1
  fi

  pct reboot "$ctid"
  if wait_for_port "$lanip" "$port" 150; then
    msg_ok "${slug} back up on ${lanip}:${port} (VPN ${vpnip})."
  else
    msg_warn "${slug} did not answer on ${lanip}:${port} within 150s."
  fi
done

# --------------------------------------------------------------------------
# Verify
# --------------------------------------------------------------------------

msg_step "Verifying"

failures=0
first_ip=""

for m in $MEMBERS; do
  IFS=: read -r slug ctid _lanip _vpnip _port <<<"$m"

  routes=$(pct exec "$ctid" -- sh -c "ip route | grep -c '^default'" 2>/dev/null || echo 0)
  if [[ "$routes" != "1" ]]; then
    msg_err "${slug}: expected exactly 1 default route, found ${routes}."
    failures=$((failures + 1))
  elif ! pct exec "$ctid" -- sh -c "ip route | grep -q '^default via ${VPN_GW}'" 2>/dev/null; then
    msg_err "${slug}: default route does not go via ${VPN_GW}."
    failures=$((failures + 1))
  fi

  rp=$(pct exec "$ctid" -- sysctl -n net.ipv4.conf.eth1.rp_filter 2>/dev/null || echo "")
  if [[ "$rp" != "2" ]]; then
    msg_err "${slug}: eth1 rp_filter is '${rp:-unset}', expected 2."
    failures=$((failures + 1))
  fi

  if [[ -n "${VPN_MGMT_SUBNET:-}" ]] &&
    ! pct exec "$ctid" -- sh -c "ip route | grep -q '${VPN_MGMT_SUBNET}'" 2>/dev/null; then
    msg_err "${slug}: management route to ${VPN_MGMT_SUBNET} is missing."
    failures=$((failures + 1))
  fi

  # The real test. Gluetun's own /v1/publicip/ip returns empty even on a healthy
  # tunnel, so comparing members to each other is what actually proves this.
  exit_ip=$(pct exec "$ctid" -- curl -s -m15 ifconfig.me 2>/dev/null || true)
  if [[ -z "$exit_ip" ]]; then
    msg_err "${slug}: no exit IP -- it may have no route at all."
    failures=$((failures + 1))
  elif [[ -z "$first_ip" ]]; then
    first_ip="$exit_ip"
    msg_ok "${slug} egresses ${exit_ip}"
  elif [[ "$exit_ip" != "$first_ip" ]]; then
    msg_err "${slug}: egresses ${exit_ip}, expected ${first_ip}."
    failures=$((failures + 1))
  else
    msg_ok "${slug} egresses ${exit_ip}"
  fi
done

# --------------------------------------------------------------------------
# Kill switch
# --------------------------------------------------------------------------

msg_step "Kill-switch test"

probe_ctid=""
probe_slug=""
for m in $MEMBERS; do
  IFS=: read -r probe_slug probe_ctid _ _ _ <<<"$m"
  break
done

if [[ -n "$probe_ctid" ]]; then
  msg_info "Stopping Gluetun and probing from ${probe_slug}..."
  pct exec "$GLUETUN_CTID" -- systemctl stop gluetun >/dev/null 2>&1 || true
  sleep 5

  leaked=$(pct exec "$probe_ctid" -- curl -s -m10 ifconfig.me 2>/dev/null || true)

  pct exec "$GLUETUN_CTID" -- systemctl start gluetun >/dev/null 2>&1 || true
  sleep 10
  pct exec "$GLUETUN_CTID" -- systemctl restart gluetun-gw.service >/dev/null 2>&1 || true

  if [[ -n "$leaked" ]]; then
    msg_err "KILL SWITCH FAILED: ${probe_slug} reached the internet as ${leaked} with Gluetun stopped."
    failures=$((failures + 1))
  else
    msg_ok "Kill switch holds -- no route to WAN without the tunnel."
  fi
fi

# --------------------------------------------------------------------------

echo
if ((failures > 0)); then
  msg_err "Finished with ${failures} problem(s). Traffic may not be fully tunnelled."
  msg_err "Containers were left in place so you can inspect them."
  exit 1
fi

msg_ok "All members are behind the tunnel, egressing ${first_ip}."
echo
echo "Re-run this script any time to re-verify. To undo, point each"
echo "container's net0 back at ${LAN_BRIDGE} with gw=${LAN_GW}."
