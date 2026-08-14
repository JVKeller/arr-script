#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: community-scripts
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/core.func)
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/tools.func)

set -eEo pipefail

color
formatting
icons
set_std_mode

SILENT_LOGFILE="/tmp/installarr-$$.log"
silent() { "$@" >>"$SILENT_LOGFILE" 2>&1; }

msg_info()  { echo -e "${INFO:-[i]} ${YW}${1}${CL}"; }
msg_ok()    { echo -e "${CM:-[ok]} ${GN}${1}${CL}"; }
msg_warn()  { echo -e "${YW}[WARN]${CL} ${1}"; }
msg_error() { echo -e "${CROSS:-[x]} ${RD}${1}${CL}"; }
msg_step()  { echo -e "${BL}==>${CL} ${1}"; }

cancelled() { msg_warn "Cancelled at $1."; exit 0; }

var_container_storage="${var_container_storage:-}"
var_template_storage="${var_template_storage:-}"
var_bridge="${var_bridge:-}"
var_gateway="${var_gateway:-}"
var_cidr="${var_cidr:-24}"
var_start_ctid="${var_start_ctid:-}"
var_repo="${var_repo:-ProxmoxVE}"
var_qbt_password="${var_qbt_password:-}"
SUMMARY_FILE="${SUMMARY_FILE:-/root/installarr-summary.txt}"
# Read by upstream set_std_mode(): "yes" leaves STD empty so output streams.
VERBOSE="${VERBOSE:-no}"

QBT_PERMANENT=0

BACKTITLE="Proxmox VE Helper Scripts — Installarr"

TEMP_DIR=$(mktemp -d)
_on_exit() {
  local rc=$?
  # install_loop's progress gauge owns the whole screen and is only closed on
  # the success path. Tear it down first, or every failure message below gets
  # painted over and the run looks like a silent death.
  exec 4>&- 2>/dev/null || true
  sleep 0.2
  if (( rc != 0 )); then
    if (( ${#INSTALLED_SLUGS[@]} > 0 )); then orphan_report; fi
    if [[ -s "$SILENT_LOGFILE" ]]; then
      echo
      msg_error "Last 20 lines of ${SILENT_LOGFILE}:"
      tail -n 20 "$SILENT_LOGFILE"
    fi
  fi
  rm -rf "$TEMP_DIR"
}
trap _on_exit EXIT

# `set -e` aborts silently, which makes a failure look like a clean exit.
# -E (already set above) propagates this into functions so the message names
# the actual failing line and command.
_on_err() {
  local rc=$? line=$1 cmd=$2
  msg_error "Aborted at line ${line} (exit ${rc}): ${cmd}"
}
trap '_on_err "$LINENO" "$BASH_COMMAND"' ERR

declare -A APP

SELECTED_ARRS=""
SELECTED_CLIENTS=""
SELECTED_MEDIA=""
EXAMPLE_INDEXER=""
ORDERED_SLUGS=()
INSTALLED_SLUGS=()
WIRING_RESULTS=()
WIRING_FAILURES=()

SYNC_CATEGORIES_SONARR='[5000,5010,5020,5030,5040,5045,5050]'
SYNC_CATEGORIES_RADARR='[2000,2010,2020,2030,2040,2045,2050,2060]'
SYNC_CATEGORIES_LIDARR='[3000,3010,3020,3030,3040]'

header_info() {
  clear
  cat <<"EOF"

    █      █▀▀  █▄▄  ▀▀█          ▀▀█ 
    █ ▓▀▀█ ▀▀▀█ █   █▀▀▓ ▓   ▓   █▀▀▓ ▓▀▀█ ▓▀▀█  
    █ █  ▓ █▄▄▓ █▄▄ ▓▄▄▓ █▄▄ █▄▄ ▓▄▄▓ ▓    ▓

EOF
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    msg_error "Run this script as root."
    exit 1
  fi
}

check_pve_tools() {
  local missing=()
  for cmd in pct pvesh pvesm pveam; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    msg_error "Missing Proxmox VE tools: ${missing[*]}. Run this on a PVE node."
    exit 1
  fi
}

# Make sure one template is downloaded to the template storage. Upstream
# searches the storage, not the catalog, so a fresh catalog is not enough.
ensure_template() {
  local tmpl=$1 file

  if pveam list "$var_template_storage" 2>/dev/null | grep -q "${tmpl}_"; then
    return 0
  fi

  file=$(pveam available --section system 2>/dev/null \
    | awk -v t="${tmpl}_" '$2 ~ t {print $2; exit}')

  # An untouched node has never run `pveam update`, so its catalog is empty.
  if [[ -z "$file" ]]; then
    msg_info "Refreshing the LXC template catalog..."
    $STD pveam update || true
    file=$(pveam available --section system 2>/dev/null \
      | awk -v t="${tmpl}_" '$2 ~ t {print $2; exit}')
  fi

  if [[ -z "$file" ]]; then
    msg_error "This node's catalog offers no ${tmpl} template."
    msg_error "Check: pveam available --section system | grep ${tmpl%%-*}"
    exit 1
  fi

  msg_info "Downloading ${file} (this can take a few minutes)..."
  if ! $STD pveam download "$var_template_storage" "$file"; then
    # Verbose mode streams to the terminal instead, leaving the log empty.
    local hint=""
    if [[ "$VERBOSE" != "yes" ]]; then hint=" See ${SILENT_LOGFILE} for details."; fi
    msg_error "Failed to download ${file}.${hint}"
    exit 1
  fi
  msg_ok "Template ${file} ready."
}

# Upstream writes these as var_os="${var_os:-debian}" so the value has to be
# pulled out of the parameter-expansion default. Plain var_os="debian" also works.
read_ct_var() {
  local file=$1 name=$2 raw
  raw=$(sed -n "s/^${name}=//p" "$file" | head -n1)
  raw="${raw%\"}"
  raw="${raw#\"}"
  if [[ "$raw" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*:-(.+)\}$ ]]; then
    raw="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$raw"
}

# The apps do not all share an OS -- Jellyfin is Ubuntu-based while the *arrs
# are Debian -- and each upstream ct/*.sh declares what it needs via var_os and
# var_version. Read those, then make sure every template is actually on disk
# before a single container is created.
prepare_templates() {
  local s script_file os ver tmpl
  local -a needed=()
  declare -A seen=()

  msg_info "Checking LXC templates for the selected apps..."

  for s in "${ORDERED_SLUGS[@]}"; do
    script_file="$TEMP_DIR/${s}.sh"
    if [[ ! -s "$script_file" ]]; then
      $STD curl -fsSL \
        "https://raw.githubusercontent.com/community-scripts/${var_repo}/main/ct/${s}.sh" \
        -o "$script_file" || true
    fi
    if [[ ! -s "$script_file" ]]; then
      msg_error "Could not download ct/${s}.sh"
      exit 1
    fi

    os=$(read_ct_var "$script_file" var_os)
    ver=$(read_ct_var "$script_file" var_version)

    # A leftover $ means the line was some other shape we do not understand;
    # a bad template name would fail later and much less clearly.
    if [[ "$os" == *'$'* || "$ver" == *'$'* ]]; then
      msg_warn "Could not parse the OS in ct/${s}.sh (got '${os}-${ver}'); skipping its template check."
      continue
    fi

    if [[ -z "$os" || -z "$ver" ]]; then
      msg_warn "Could not read the OS that ct/${s}.sh needs; skipping its template check."
      continue
    fi

    tmpl="${os}-${ver}-standard"
    if [[ -z "${seen[$tmpl]:-}" ]]; then
      seen[$tmpl]=1
      needed+=("$tmpl")
    fi
  done

  local t
  for t in "${needed[@]}"; do
    ensure_template "$t"
  done

  msg_ok "Templates ready: ${needed[*]:-none required}"
}

wait_for_port() {
  local ip=$1 port=$2 timeout=${3:-60} elapsed=0
  while ! (echo > "/dev/tcp/${ip}/${port}") >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed >= timeout )); then return 1; fi
  done
  return 0
}

is_valid_ipv4() {
  local ip=$1
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  return 0
}

form_input_program() {
  if command -v dialog >/dev/null 2>&1; then
    echo "dialog"
  elif whiptail --help 2>&1 | grep -q -- '--form'; then
    echo "whiptail"
  else
    echo "none"
  fi
}

seed_catalog() {
  while IFS='|' read -r slug script port impl apiver kind name contract; do
    [[ -z "$slug" ]] && continue
    APP[$slug.script]="$script"
    APP[$slug.port]="$port"
    APP[$slug.impl]="$impl"
    APP[$slug.apiver]="$apiver"
    APP[$slug.kind]="$kind"
    APP[$slug.name]="$name"
    APP[$slug.contract]="$contract"
  done <<'EOF'
prowlarr|prowlarr.sh|9696||v1|indexer|Prowlarr|
sonarr|sonarr.sh|8989|Sonarr|v3|arr|Sonarr|SonarrSettings
radarr|radarr.sh|7878|Radarr|v3|arr|Radarr|RadarrSettings
lidarr|lidarr.sh|8686|Lidarr|v1|arr|Lidarr|LidarrSettings
bazarr|bazarr.sh|6767|Bazarr|-|arr|Bazarr|BazarrSettings
seerr|seerr.sh|5055||-|requests|Seerr|
jellyfin|jellyfin.sh|8096|Jellyfin|-|media|Jellyfin|
qbittorrent|qbittorrent.sh|8090|QBittorrent|-|client|qBittorrent|QBittorrentSettings
sabnzbd|sabnzbd.sh|7777|Sabnzbd|-|client|SABnzbd|SabnzbdSettings
EOF
}

pick_storage() {
  if [[ -n "$var_container_storage" ]]; then
    msg_info "Container storage (from env): ${var_container_storage}"
  else
    local options=() row name type
    while IFS= read -r row; do
      name=$(awk '{print $1}' <<<"$row")
      type=$(awk '{print $2}' <<<"$row")
      [[ -z "$name" ]] && continue
      options+=("$name" "$type")
    done < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1')

    if (( ${#options[@]} == 0 )); then
      msg_error "No PVE storage with content 'rootdir' available."
      exit 1
    fi

    if (( ${#options[@]} == 2 )); then
      var_container_storage="${options[0]}"
      msg_info "Container storage (only option): ${var_container_storage}"
    else
      var_container_storage=$(whiptail --backtitle "$BACKTITLE" \
        --title "Container Storage" \
        --menu "Pick a PVE storage for the container rootfs:" 20 70 10 \
        "${options[@]}" 3>&1 1>&2 2>&3) || cancelled "storage pick"
    fi
  fi

  if [[ -z "$var_template_storage" ]]; then
    var_template_storage=$(pvesm status -content vztmpl 2>/dev/null \
      | awk 'NR>1 && $1=="local" {print $1; exit}')
    [[ -z "$var_template_storage" ]] && var_template_storage=$(pvesm status -content vztmpl 2>/dev/null \
      | awk 'NR>1 {print $1; exit}')
  fi
  [[ -n "$var_template_storage" ]] && msg_info "Template storage: ${var_template_storage}"
}

pick_network_defaults() {
  if [[ -z "$var_bridge" ]]; then
    local options=() b
    while IFS= read -r b; do
      [[ -n "$b" ]] && options+=("$b" "")
    done < <(awk '/^iface vmbr/ {print $2}' /etc/network/interfaces 2>/dev/null)

    if (( ${#options[@]} == 0 )); then
      options=("vmbr0" "")
    fi

    var_bridge=$(whiptail --backtitle "$BACKTITLE" \
      --title "Network Bridge" \
      --menu "Pick the Linux bridge for all containers:" 15 60 6 \
      "${options[@]}" 3>&1 1>&2 2>&3) || cancelled "bridge pick"
  fi

  # Prefill from this node's own default route so the field usually arrives
  # already correct and the user just presses OK.
  local default_gw default_mask="" dev
  default_gw=$(ip -4 route show default | awk '{print $3}' | head -n1)
  dev=$(ip -4 route show default | awk '{print $5}' | head -n1)
  if [[ -n "$dev" ]]; then
    default_mask=$(ip -4 -o addr show dev "$dev" 2>/dev/null \
      | awk '{print $4}' | head -n1 | cut -d/ -f2)
  fi
  [[ "$default_mask" =~ ^[0-9]+$ ]] || default_mask=24

  # Fully specified by env: nothing to ask.
  if is_valid_ipv4 "$var_gateway" \
    && [[ "$var_cidr" =~ ^[0-9]+$ ]] && (( var_cidr >= 1 && var_cidr <= 32 )); then
    msg_info "Bridge ${var_bridge} | gateway ${var_gateway} | mask /${var_cidr}"
    return 0
  fi

  local answer="${var_gateway:-$default_gw}/${var_cidr:-$default_mask}"
  while true; do
    answer=$(whiptail --backtitle "$BACKTITLE" \
      --title "Gateway and Subnet" \
      --inputbox "IPv4 gateway and mask for the containers, e.g. 10.0.0.1/24:" 10 70 \
      "$answer" 3>&1 1>&2 2>&3) || cancelled "gateway prompt"

    local gw="${answer%%/*}" mask="${answer##*/}"

    if [[ "$answer" != */* ]] || ! is_valid_ipv4 "$gw"; then
      whiptail --backtitle "$BACKTITLE" --title "Invalid" \
        --msgbox "Enter an address and mask together, like 10.0.0.1/24.\n\nNot valid: ${answer}" 10 64
      continue
    fi

    if ! [[ "$mask" =~ ^[0-9]+$ ]] || (( mask < 1 || mask > 32 )); then
      whiptail --backtitle "$BACKTITLE" --title "Invalid" \
        --msgbox "Mask must be an integer between 1 and 32.\n\nGot: /${mask}" 10 64
      continue
    fi

    var_gateway="$gw"
    var_cidr="$mask"
    break
  done

  msg_info "Bridge ${var_bridge} | gateway ${var_gateway} | mask /${var_cidr}"
}

pick_apps() {
  while true; do
    local choice
    choice=$(whiptail --backtitle "$BACKTITLE" \
      --title "Pick *arr Apps" \
      --checklist "Prowlarr is always installed. Pick additional apps:" 18 70 7 \
      "sonarr" "Sonarr (TV)" ON \
      "radarr" "Radarr (Movies)" ON \
      "lidarr" "Lidarr (Music)" OFF \
      "bazarr" "Bazarr (Subtitles)" OFF \
      "seerr"  "Seerr (Requests)" OFF \
      3>&1 1>&2 2>&3) || cancelled "*arr app pick"

    SELECTED_ARRS=$(echo "$choice" | tr -d '"')

    if [[ -z "$SELECTED_ARRS" ]]; then
      if whiptail --backtitle "$BACKTITLE" --title "Confirm" \
        --yesno "You picked no *arr apps. Only Prowlarr will be installed and there will be nothing to wire. Continue anyway?" 10 70; then
        return
      fi
      continue
    fi
    return
  done
}

pick_clients() {
  local choice
  choice=$(whiptail --backtitle "$BACKTITLE" \
    --title "Pick Download Clients" \
    --checklist "Optional download clients to install + wire:" 14 70 4 \
    "qbittorrent" "qBittorrent (Torrents)" ON \
    "sabnzbd"     "SABnzbd (Usenet)" OFF \
    3>&1 1>&2 2>&3) || cancelled "download client pick"

  SELECTED_CLIENTS=$(echo "$choice" | tr -d '"')
}

pick_verbose() {
  if whiptail --backtitle "$BACKTITLE" \
    --title "Verbose Mode" \
    --defaultno \
    --yesno "Show full installation output?\n\nNo  - progress bar only (details in ${SILENT_LOGFILE})\nYes - stream every command as it runs" 12 70; then
    VERBOSE="yes"
  else
    VERBOSE="no"
  fi
  set_std_mode
}

pick_jellyfin() {
  # whiptail draws its UI on stdout, so this must not be captured in a
  # command substitution or the dialog is never painted to the terminal.
  if whiptail --backtitle "$BACKTITLE" \
    --title "Media Server" \
    --yesno "Install Jellyfin (media player/server)?" 10 70; then
    SELECTED_MEDIA="jellyfin"
  fi
}

pick_example_indexer() {
  if whiptail --backtitle "$BACKTITLE" \
    --title "Example Indexer" \
    --yesno "Add example public indexer to Prowlarr?\n\n⚠ WARNING: Public indexers can contain malicious content.\nIt will be DISABLED by default. You must verify and enable manually." 13 70; then
    EXAMPLE_INDEXER="yes"
  fi
}

_gen_password() {
  local p
  p=$(openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-16)
  [[ -z "$p" ]] && p="ChangeMe${RANDOM}${RANDOM}"
  printf '%s' "$p"
}

pick_qbittorrent_password() {
  # `return` with no argument inherits the failed test's status, which under
  # `set -e` kills the whole run when qBittorrent is deselected. Be explicit.
  [[ " $SELECTED_CLIENTS " == *" qbittorrent "* ]] || return 0
  [[ -n "$var_qbt_password" ]] && { msg_info "qBittorrent password (from env) will be used."; return; }

  local choice
  choice=$(whiptail --backtitle "$BACKTITLE" \
    --title "qBittorrent WebUI Password" \
    --menu "Set the qBittorrent admin password:" 15 70 2 \
    "generate" "Auto-generate a strong random password (recommended)" \
    "manual"   "Enter my own password" \
    3>&1 1>&2 2>&3) || cancelled "qBittorrent password pick"

  if [[ "$choice" == "generate" ]]; then
    var_qbt_password=$(_gen_password)
    msg_info "A random qBittorrent password was generated (shown in the final summary)."
    return
  fi

  local pw1 pw2
  while true; do
    pw1=$(whiptail --backtitle "$BACKTITLE" --title "qBittorrent Password" \
      --passwordbox "Enter a WebUI password (min 6 chars):" 10 60 \
      3>&1 1>&2 2>&3) || cancelled "qBittorrent password entry"
    pw2=$(whiptail --backtitle "$BACKTITLE" --title "Confirm Password" \
      --passwordbox "Re-enter the password:" 10 60 \
      3>&1 1>&2 2>&3) || cancelled "qBittorrent password confirm"

    if [[ "$pw1" != "$pw2" ]]; then
      whiptail --backtitle "$BACKTITLE" --title "Mismatch" \
        --msgbox "Passwords do not match. Try again." 8 50
      continue
    fi
    if (( ${#pw1} < 6 )); then
      whiptail --backtitle "$BACKTITLE" --title "Too short" \
        --msgbox "Password must be at least 6 characters." 8 50
      continue
    fi
    var_qbt_password="$pw1"
    return
  done
}

compute_ordered_slugs() {
  ORDERED_SLUGS=("prowlarr")
  local s
  for s in $SELECTED_ARRS; do
    [[ "$s" == "seerr" ]] && continue
    ORDERED_SLUGS+=("$s")
  done
  for s in $SELECTED_CLIENTS; do
    ORDERED_SLUGS+=("$s")
  done
  for s in $SELECTED_ARRS; do
    [[ "$s" == "seerr" ]] && ORDERED_SLUGS+=("seerr")
  done
  [[ -n "$SELECTED_MEDIA" ]] && ORDERED_SLUGS+=("$SELECTED_MEDIA")
  # A false trailing [[ ]] && would return 1 and trip `set -e` in main.
  return 0
}

pick_ip_mode_and_ips() {
  while true; do
    local mode
    mode=$(whiptail --backtitle "$BACKTITLE" \
      --title "IP Entry Mode" \
      --menu "How would you like to enter IP addresses?" 15 75 2 \
      "list" "Enter all IPs at once (space- or comma-separated)" \
      "form" "Enter each IP in a form" \
      3>&1 1>&2 2>&3) || cancelled "IP entry mode pick"

    case "$mode" in
      list) _collect_ips_list_mode; return ;;
      form)
        if _collect_ips_one_by_one; then
          return
        fi
        ;;
    esac
  done
}

_collect_ips_list_mode() {
  local expected_n=${#ORDERED_SLUGS[@]}
  local hint="" s
  for s in "${ORDERED_SLUGS[@]}"; do hint+="  ${s}"$'\n'; done

  while true; do
    local raw
    raw=$(whiptail --backtitle "$BACKTITLE" \
      --title "Enter ${expected_n} IPv4 addresses" \
      --inputbox "Enter ${expected_n} IPs separated by spaces or commas, in this order:"$'\n\n'"${hint}" \
      22 78 "" 3>&1 1>&2 2>&3) || cancelled "IP list entry"

    local normalized="${raw//,/ }"
    local -a ips=()
    # shellcheck disable=SC2206
    ips=( $normalized )

    if (( ${#ips[@]} != expected_n )); then
      whiptail --backtitle "$BACKTITLE" --title "Wrong count" \
        --msgbox "Expected ${expected_n} IPs, got ${#ips[@]}. Please re-enter." 8 60
      continue
    fi

    local ok=1 i
    for i in "${!ips[@]}"; do
      if ! is_valid_ipv4 "${ips[$i]}"; then
        whiptail --backtitle "$BACKTITLE" --title "Invalid" \
          --msgbox "Entry $((i+1)) is not a valid IPv4: ${ips[$i]}" 8 60
        ok=0; break
      fi
      if [[ "${ips[$i]}" == "$var_gateway" ]]; then
        whiptail --backtitle "$BACKTITLE" --title "Invalid" \
          --msgbox "Entry $((i+1)) collides with the gateway: ${ips[$i]}" 8 60
        ok=0; break
      fi
    done
    (( ok == 0 )) && continue

    local dup
    dup=$(printf '%s\n' "${ips[@]}" | sort | uniq -d | head -n1)
    if [[ -n "$dup" ]]; then
      whiptail --backtitle "$BACKTITLE" --title "Duplicate IP" \
        --msgbox "IP appears more than once: ${dup}" 8 60
      continue
    fi

    for i in "${!ORDERED_SLUGS[@]}"; do
      APP[${ORDERED_SLUGS[$i]}.ip]=${ips[$i]}
    done
    return
  done
}

_collect_ips_one_by_one() {
  local ui
  ui=$(form_input_program)

  if [[ "$ui" == "dialog" ]]; then
    local expected_n=${#ORDERED_SLUGS[@]}
    local -a form_fields=()
    local slug

    for slug in "${ORDERED_SLUGS[@]}"; do
      form_fields+=("$slug" "")
    done

    while true; do
      local raw_values
      if ! raw_values=$(dialog --backtitle "$BACKTITLE" \
        --title "Container IP Addresses" \
        --form "Enter an IPv4 address for each container:" 22 78 0 \
        "${form_fields[@]}" 2>&1 >/dev/tty); then
        msg_warn "IP form entry cancelled."
        return 1
      fi

      local -a ips=()
      mapfile -t ips <<< "$raw_values"

      if (( ${#ips[@]} != expected_n )); then
        whiptail --backtitle "$BACKTITLE" --title "Wrong count" \
          --msgbox "Expected ${expected_n} IPs, got ${#ips[@]}. Please re-enter." 8 60
        continue
      fi

      local ok=1 i
      for i in "${!ips[@]}"; do
        local ip="${ips[$i]}"
        if ! is_valid_ipv4 "$ip"; then
          whiptail --backtitle "$BACKTITLE" --title "Invalid" \
            --msgbox "Entry $((i+1)) is not a valid IPv4: ${ip}" 8 60
          ok=0
          break
        fi
        if [[ "$ip" == "$var_gateway" ]]; then
          whiptail --backtitle "$BACKTITLE" --title "Invalid" \
            --msgbox "Entry $((i+1)) collides with the gateway: ${ip}" 8 60
          ok=0
          break
        fi
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
          whiptail --backtitle "$BACKTITLE" --title "IP In Use" \
            --msgbox "Entry $((i+1)) is already in use by another device: ${ip}" 8 60
          ok=0
          break
        fi
      done
      (( ok == 0 )) && continue

      local dup
      dup=$(printf '%s\n' "${ips[@]}" | sort | uniq -d | head -n1)
      if [[ -n "$dup" ]]; then
        whiptail --backtitle "$BACKTITLE" --title "Duplicate IP" \
          --msgbox "IP appears more than once: ${dup}" 8 60
        continue
      fi

      for i in "${!ORDERED_SLUGS[@]}"; do
        APP[${ORDERED_SLUGS[$i]}.ip]=${ips[$i]}
      done
      return 0
    done
  fi

  if [[ "$ui" == "whiptail" ]]; then
    local expected_n=${#ORDERED_SLUGS[@]}
    local -a form_fields=()
    local slug

    for slug in "${ORDERED_SLUGS[@]}"; do
      form_fields+=("$slug" "")
    done

    while true; do
      local raw_values
      if ! raw_values=$(whiptail --backtitle "$BACKTITLE" \
        --title "Container IP Addresses" \
        --separate-output \
        --form "Enter an IPv4 address for each container:" 22 78 "$((expected_n + 4))" \
        "${form_fields[@]}" 3>&1 1>&2 2>&3); then
        msg_warn "IP form entry cancelled."
        return 1
      fi

      local -a ips=()
      mapfile -t ips <<< "$raw_values"

      if (( ${#ips[@]} != expected_n )); then
        whiptail --backtitle "$BACKTITLE" --title "Wrong count" \
          --msgbox "Expected ${expected_n} IPs, got ${#ips[@]}. Please re-enter." 8 60
        continue
      fi

      local ok=1 i
      for i in "${!ips[@]}"; do
        local ip="${ips[$i]}"
        if ! is_valid_ipv4 "$ip"; then
          whiptail --backtitle "$BACKTITLE" --title "Invalid" \
            --msgbox "Entry $((i+1)) is not a valid IPv4: ${ip}" 8 60
          ok=0
          break
        fi
        if [[ "$ip" == "$var_gateway" ]]; then
          whiptail --backtitle "$BACKTITLE" --title "Invalid" \
            --msgbox "Entry $((i+1)) collides with the gateway: ${ip}" 8 60
          ok=0
          break
        fi
        if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
          whiptail --backtitle "$BACKTITLE" --title "IP In Use" \
            --msgbox "Entry $((i+1)) is already in use by another device: ${ip}" 8 60
          ok=0
          break
        fi
      done
      (( ok == 0 )) && continue

      local dup
      dup=$(printf '%s\n' "${ips[@]}" | sort | uniq -d | head -n1)
      if [[ -n "$dup" ]]; then
        whiptail --backtitle "$BACKTITLE" --title "Duplicate IP" \
          --msgbox "IP appears more than once: ${dup}" 8 60
        continue
      fi

      for i in "${!ORDERED_SLUGS[@]}"; do
        APP[${ORDERED_SLUGS[$i]}.ip]=${ips[$i]}
      done
      return 0
    done
  fi

  local slug ip running="" last_ip="" default_ip=""
  for slug in "${ORDERED_SLUGS[@]}"; do
    if [[ -n "$last_ip" ]]; then
      local prefix="${last_ip%.*}"
      local host="${last_ip##*.}"
      if [[ "$host" =~ ^[0-9]+$ ]] && (( host < 254 )); then
        default_ip="${prefix}.$((host + 1))"
      fi
    fi
    while true; do
      local prompt="Enter IPv4 for ${slug}:"
      [[ -n "$running" ]] && prompt+=$'\n\nAlready assigned:'"$running"
      ip=$(whiptail --backtitle "$BACKTITLE" \
        --title "Container IP Addresses" \
        --inputbox "$prompt" 16 60 "$default_ip" 3>&1 1>&2 2>&3) || { msg_warn "IP entry cancelled."; return 1; }

      if ! is_valid_ipv4 "$ip"; then
        whiptail --backtitle "$BACKTITLE" --title "Invalid" \
          --msgbox "Not a valid IPv4: ${ip}" 8 60
        continue
      fi
      if [[ "$ip" == "$var_gateway" ]]; then
        whiptail --backtitle "$BACKTITLE" --title "Invalid" \
          --msgbox "Collides with the gateway: ${ip}" 8 60
        continue
      fi

      local dup=0 other_slug other_ip
      for other_slug in "${ORDERED_SLUGS[@]}"; do
        [[ "$other_slug" == "$slug" ]] && continue
        other_ip="${APP[${other_slug}.ip]:-}"
        [[ -n "$other_ip" && "$other_ip" == "$ip" ]] && { dup=1; break; }
      done
      if (( dup )); then
        whiptail --backtitle "$BACKTITLE" --title "Duplicate" \
          --msgbox "Already used by another container: ${ip}" 8 60
        continue
      fi

      APP[$slug.ip]=$ip
      running+=$'\n  '"${slug} -> ${ip}"
      last_ip=$ip
      break
    done
  done

  return 0
}

pick_ctids() {
  local default_start id s
  if [[ -n "$var_start_ctid" ]]; then
    default_start="$var_start_ctid"
  else
    default_start=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
  fi
  [[ "$default_start" =~ ^[0-9]+$ ]] || default_start=100

  # Sequential IDs, skipping ones already taken. These only prefill the prompt;
  # the user is free to replace any of them with non-sequential values.
  local -a defaults=()
  id=$default_start
  for s in "${ORDERED_SLUGS[@]}"; do
    while pct status "$id" >/dev/null 2>&1; do
      id=$((id + 1))
      (( id > 999999 )) && { msg_error "Ran out of CTID space."; exit 1; }
    done
    defaults+=("$id")
    id=$((id + 1))
  done

  local expected_n=${#ORDERED_SLUGS[@]}
  local hint=""
  for s in "${ORDERED_SLUGS[@]}"; do hint+="  ${s}"; done

  local answer="${defaults[*]}"
  while true; do
    answer=$(whiptail --backtitle "$BACKTITLE" \
      --title "Container IDs" \
      --inputbox "Assign a CTID to each container, in this order:"$'\n\n'"${hint}" \
      14 78 "$answer" 3>&1 1>&2 2>&3) || cancelled "CTID entry"

    local -a ids=()
    # shellcheck disable=SC2206
    ids=( ${answer//,/ } )

    if (( ${#ids[@]} != expected_n )); then
      whiptail --backtitle "$BACKTITLE" --title "Wrong count" \
        --msgbox "Expected ${expected_n} IDs, got ${#ids[@]}. Please re-enter." 8 60
      continue
    fi

    local ok=1 i
    for i in "${!ids[@]}"; do
      if ! [[ "${ids[$i]}" =~ ^[0-9]+$ ]] || (( ids[i] < 100 )); then
        whiptail --backtitle "$BACKTITLE" --title "Invalid" \
          --msgbox "Entry $((i+1)) must be a number >= 100: ${ids[$i]}" 8 64
        ok=0; break
      fi
      if pct status "${ids[$i]}" >/dev/null 2>&1; then
        whiptail --backtitle "$BACKTITLE" --title "CTID In Use" \
          --msgbox "CTID ${ids[$i]} is already in use on this node." 8 60
        ok=0; break
      fi
    done
    (( ok == 0 )) && continue

    local dup
    dup=$(printf '%s\n' "${ids[@]}" | sort | uniq -d | head -n1)
    if [[ -n "$dup" ]]; then
      whiptail --backtitle "$BACKTITLE" --title "Duplicate CTID" \
        --msgbox "CTID appears more than once: ${dup}" 8 60
      continue
    fi

    for i in "${!ORDERED_SLUGS[@]}"; do
      APP[${ORDERED_SLUGS[$i]}.ctid]=${ids[$i]}
    done
    return 0
  done
}

confirm_summary() {
  local lines="" s
  for s in "${ORDERED_SLUGS[@]}"; do
    lines+="  $(printf '%-12s ctid=%-5s ip=%-16s port=%s' \
      "$s" "${APP[$s.ctid]}" "${APP[$s.ip]}" "${APP[$s.port]}")"$'\n'
  done

  local body="About to create these containers and wire them together:"$'\n\n'"${lines}"$'\n'"Storage: ${var_container_storage} | Bridge: ${var_bridge} | Gateway: ${var_gateway} | Mask: /${var_cidr}"

  whiptail --backtitle "$BACKTITLE" --title "Confirm" \
    --yesno "$body" 22 78 || { msg_warn "User cancelled."; exit 0; }
}

orphan_report() {
  if (( ${#INSTALLED_SLUGS[@]} == 0 )); then return; fi
  msg_error "Containers already created (to clean up, run):"
  local s
  for s in "${INSTALLED_SLUGS[@]}"; do
    echo "  pct stop ${APP[$s.ctid]} && pct destroy ${APP[$s.ctid]}   # ${s}"
  done
}

# The gauge is fullscreen, so it would paint over streamed output. In verbose
# mode it is never opened and there is no fd 4 to write to.
progress() {
  local pct=$1 text=$2
  if [[ "$VERBOSE" == "yes" ]]; then
    msg_step "$text"
  else
    echo -e "XXX\n${pct}\n${text}\nXXX" >&4
  fi
}

install_loop() {
  local total=${#ORDERED_SLUGS[@]} idx=0
  local s script_file ip ctid port

  # Upstream's diagnostics_check() opens a whiptail prompt when this file is
  # absent. $STD swallows stderr, so that prompt paints into the log and blocks
  # on a keypress nobody can see. Seed the opt-out; an existing file is kept.
  mkdir -p /usr/local/community-scripts
  [[ -f /usr/local/community-scripts/diagnostics ]] || echo "DIAGNOSTICS=no" > /usr/local/community-scripts/diagnostics

  if [[ "$VERBOSE" != "yes" ]]; then
    exec 4> >(whiptail --backtitle "$BACKTITLE" --title "Installing Containers" --gauge "Starting installation..." 10 70 0)
  fi

  for s in "${ORDERED_SLUGS[@]}"; do
    idx=$((idx + 1))
    ip="${APP[$s.ip]}"
    ctid="${APP[$s.ctid]}"
    port="${APP[$s.port]}"
    script_file="$TEMP_DIR/${s}.sh"

    local base_pct=$(( (idx - 1) * 100 / total ))
    local half_pct=$(( base_pct + (50 / total) ))
    local full_pct=$(( idx * 100 / total ))

    progress "$base_pct" "[${idx}/${total}] Downloading ct/${s}.sh..."

    $STD curl -fsSL \
      "https://raw.githubusercontent.com/community-scripts/${var_repo}/main/ct/${s}.sh" \
      -o "$script_file"

    if [[ ! -s "$script_file" ]]; then
      exec 4>&-
      msg_error "Empty/failed download for ${s}"
      exit 1
    fi

    progress "$half_pct" "[${idx}/${total}] Installing ${s} -> ctid=${ctid} ip=${ip}/${var_cidr}"

    # stdin from /dev/null: any prompt upstream adds in future fails fast and
    # visibly instead of hanging forever behind the gauge.
    $STD env \
      MODE=generated mode=generated PHS_SILENT=1 \
      VERBOSE="$VERBOSE" var_verbose="$VERBOSE" \
      var_ctid="$ctid" \
      var_hostname="$s" \
      var_brg="$var_bridge" \
      var_net="${ip}/${var_cidr}" \
      var_gateway="$var_gateway" \
      var_container_storage="$var_container_storage" \
      var_template_storage="$var_template_storage" \
      bash "$script_file" </dev/null

    INSTALLED_SLUGS+=("$s")

    if [[ "${APP[$s.kind]}" == "arr" || "${APP[$s.kind]}" == "indexer" ]]; then
      progress "$half_pct" "[${idx}/${total}] Waiting for ${s} to listen on ${port}..."
      if ! wait_for_port "$ip" "$port" 90; then
        # Handled silently; warning is re-issued during extraction
        :
      fi
    fi

    progress "$full_pct" "[${idx}/${total}] Installed ${s}"
  done

  exec 4>&-
  sleep 0.1

  for s in "${ORDERED_SLUGS[@]}"; do
    msg_ok "Installed ${s}"
  done
}

extract_arr_key() {
  local slug=$1 ctid=$2 ip=$3 port=$4
  local config_dir="/var/lib/${slug}/config.xml"

  msg_info "Waiting for ${slug} on ${ip}:${port}..."
  wait_for_port "$ip" "$port" 240 || { msg_error "${slug} never opened ${port}"; return 1; }

  local i
  for ((i=0; i<60; i++)); do
    if pct exec "$ctid" -- test -f "$config_dir" 2>/dev/null; then break; fi
    sleep 2
  done

  local key
  key=$(pct exec "$ctid" -- sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$config_dir" 2>/dev/null | head -n1 || true)
  if [[ -z "$key" ]]; then
    msg_error "Failed to extract API key for ${slug} (config: ${config_dir})"
    return 1
  fi
  APP[$slug.apikey]="$key"
  msg_ok "${slug} apikey extracted (${key:0:6}…)"
}

extract_qbittorrent_password() {
  local ctid=$1 ip=$2
  APP[qbittorrent.user]="admin"

  msg_info "Waiting for qbittorrent on ${ip}:8090..."
  if ! wait_for_port "$ip" 8090 240; then
    msg_warn "qbittorrent never opened 8090; assuming legacy default admin/adminadmin."
    APP[qbittorrent.pass]="adminadmin"
    return 1
  fi

  # The community-script installs qBittorrent with a hardcoded adminadmin password.
  # We skip searching for a temporary password to prevent a 60s hang,
  # since we will overwrite the password with the user's custom one anyway.
  APP[qbittorrent.pass]="adminadmin"
}

qbt_password_hash() {
  # qBittorrent WebUI password format: @ByteArray(<b64 salt>:<b64 key>)
  # PBKDF2-HMAC-SHA512, 100000 iterations, 16-byte salt, 64-byte derived key.
  # Pure Perl (Digest::SHA + MIME::Base64 are core modules, always present on PVE).
  local plain=$1
  PW="$plain" perl -e '
    use strict; use warnings;
    use Digest::SHA qw(hmac_sha512);
    use MIME::Base64 qw(encode_base64);
    my $pw = $ENV{PW};
    open(my $r, "<", "/dev/urandom") or die "urandom: $!";
    my $salt; read($r, $salt, 16) == 16 or die "salt read"; close($r);
    my $iter = 100000;
    # dkLen (64) == hLen (64), so only block T_1 is needed.
    my $u = hmac_sha512($salt . pack("N", 1), $pw);
    my $t = $u;
    for (2 .. $iter) { $u = hmac_sha512($u, $pw); $t ^= $u; }
    print "\@ByteArray(" . encode_base64($salt, "") . ":" . encode_base64($t, "") . ")";
  ' 2>/dev/null
}

set_qbittorrent_permanent_password() {
  local ctid=$1 plain=$2
  local conf hashval localconf edited meta uid gid perms pushed=1

  conf=$(pct exec "$ctid" -- bash -c 'find /root /home /opt /var/lib -name qBittorrent.conf 2>/dev/null | head -n1' 2>/dev/null || true)
  if [[ -z "$conf" ]]; then
    msg_warn "qBittorrent.conf not found in ctid ${ctid}; keeping temporary password."
    return 1
  fi

  hashval=$(qbt_password_hash "$plain")
  if [[ -z "$hashval" ]]; then
    msg_warn "Could not compute qBittorrent password hash; keeping temporary password."
    return 1
  fi

  localconf="$TEMP_DIR/qBittorrent.conf"
  if ! pct pull "$ctid" "$conf" "$localconf" >/dev/null 2>&1; then
    msg_warn "Could not read ${conf} from ctid ${ctid}; keeping temporary password."
    return 1
  fi

  meta=$(pct exec "$ctid" -- stat -c '%u %g %a' "$conf" 2>/dev/null || true)
  read -r uid gid perms <<<"$meta"

  # qbittorrent-nox rewrites its conf on shutdown, so stop it before editing.
  pct exec "$ctid" -- systemctl stop qbittorrent-nox >/dev/null 2>&1 || true

  # Insert/replace WebUI\Password_PBKDF2 under [Preferences], preserving the rest.
  # Done in Perl so the literal backslash in the key is unambiguous.
  edited="$TEMP_DIR/qBittorrent.conf.new"
  if ! QBT_HASH="$hashval" QBT_SRC="$localconf" QBT_DST="$edited" perl -e '
    use strict; use warnings;
    my $key  = q{WebUI\Password_PBKDF2};
    my $hash = $ENV{QBT_HASH};
    open(my $in, "<", $ENV{QBT_SRC}) or die "read: $!";
    my @lines = <$in>; close($in);
    my @out; my $inprefs = 0; my $done = 0;
    for my $ln (@lines) {
      if ($ln =~ /^\[/) {
        if ($inprefs && !$done) { push @out, qq{$key="$hash"\n}; $done = 1; }
        $inprefs = ($ln =~ /^\[Preferences\]\s*$/) ? 1 : 0;
      }
      if ($inprefs && index($ln, "$key=") == 0) {
        if (!$done) { push @out, qq{$key="$hash"\n}; $done = 1; }
        next;
      }
      push @out, $ln;
    }
    unless ($done) {
      push @out, "[Preferences]\n" unless $inprefs;
      push @out, qq{$key="$hash"\n};
    }
    open(my $o, ">", $ENV{QBT_DST}) or die "write: $!";
    print $o @out; close($o);
  '; then
    msg_warn "Failed to edit qBittorrent.conf; restarting service with temporary password."
    pct exec "$ctid" -- systemctl start qbittorrent-nox >/dev/null 2>&1 || true
    return 1
  fi

  if [[ -n "$uid" && -n "$gid" && -n "$perms" ]]; then
    pct push "$ctid" "$edited" "$conf" --user "$uid" --group "$gid" --perms "$perms" >/dev/null 2>&1 || pushed=0
  else
    pct push "$ctid" "$edited" "$conf" >/dev/null 2>&1 || pushed=0
  fi

  pct exec "$ctid" -- systemctl start qbittorrent-nox >/dev/null 2>&1 || true

  if (( pushed == 0 )); then
    msg_warn "Could not write updated qBittorrent.conf to ctid ${ctid}; keeping temporary password."
    return 1
  fi

  PASS_BY_SLUG[qbittorrent]="$plain"
  APP[qbittorrent.pass]="$plain"
  QBT_PERMANENT=1
  msg_ok "qBittorrent permanent WebUI password set."
}

extract_sabnzbd_key() {
  local ctid=$1 ip=$2

  msg_info "Waiting for sabnzbd on ${ip}:7777..."
  wait_for_port "$ip" 7777 240 || { msg_warn "sabnzbd never opened 7777"; return 1; }

  local ini="" candidate
  for candidate in /opt/sabnzbd/sabnzbd.ini /root/.sabnzbd/sabnzbd.ini /etc/sabnzbd/sabnzbd.ini; do
    if pct exec "$ctid" -- test -f "$candidate" 2>/dev/null; then
      ini="$candidate"; break
    fi
  done
  if [[ -z "$ini" ]]; then
    msg_warn "Could not locate sabnzbd.ini inside ctid ${ctid}; SABnzbd will need manual setup."
    return 1
  fi

  local key="" i
  for ((i=0; i<60; i++)); do
    key=$(pct exec "$ctid" -- awk -F' *= *' '/^api_key/ {print $2; exit}' "$ini" 2>/dev/null || true)
    [[ -n "$key" ]] && break
    sleep 2
  done

  if [[ -z "$key" ]]; then
    msg_warn "sabnzbd api_key not yet written. Open the web wizard once at http://${ip}:7777 and rerun wiring."
    return 1
  fi
  APP[sabnzbd.apikey]="$key"
  msg_ok "sabnzbd apikey extracted (${key:0:6}…)"
}

wait_and_extract_keys() {
  msg_step "Extracting credentials & API keys"
  local s ctid ip port
  for s in "${ORDERED_SLUGS[@]}"; do
    ctid="${APP[$s.ctid]}"
    ip="${APP[$s.ip]}"
    port="${APP[$s.port]}"
    case "${APP[$s.kind]}" in
      indexer|arr)
        extract_arr_key "$s" "$ctid" "$ip" "$port" || true
        ;;
      client)
        if [[ "$s" == "qbittorrent" ]]; then
          extract_qbittorrent_password "$ctid" "$ip" || true
          [[ -z "$var_qbt_password" ]] && var_qbt_password=$(_gen_password)
          set_qbittorrent_permanent_password "$ctid" "$var_qbt_password" || true
        elif [[ "$s" == "sabnzbd" ]]; then
          extract_sabnzbd_key "$ctid" "$ip" || true
        fi
        ;;
      requests)
        msg_warn "Seerr requires the web first-run wizard. URL + keys will be in the summary."
        ;;
      media)
        msg_info "${s} installed and listening on ${ip}:${port}"
        ;;
    esac
  done
}

record_wiring()  { WIRING_RESULTS+=("$1"); }
record_failure() { WIRING_FAILURES+=("$1"); }

api_post() {
  local url=$1 apikey=$2 payload=$3 label=$4
  local resp status=""
  resp=$(curl -fsS --max-time 30 --retry 2 \
    -H "X-Api-Key: $apikey" \
    -H "Content-Type: application/json" \
    -X POST "$url" -d "$payload" \
    -w '\n__HTTP__%{http_code}' 2>&1) || status="curl_fail"

  local code=""
  if [[ "$resp" =~ __HTTP__([0-9]+)$ ]]; then
    code="${BASH_REMATCH[1]}"
  fi

  if [[ "$status" == "curl_fail" || -z "$code" || "$code" -ge 400 ]]; then
    record_failure "${label}  FAIL (http ${code:-?})"
    msg_warn "${label} failed (http ${code:-?})"
    return 1
  fi
  record_wiring "${label}  OK"
  msg_ok "${label}"
}

probe_lidarr_api_version() {
  if [[ -z "${APP[lidarr.apikey]:-}" ]]; then return; fi
  local ip="${APP[lidarr.ip]}" key="${APP[lidarr.apikey]}"
  if curl -fsS --max-time 10 -H "X-Api-Key: $key" \
       "http://${ip}:8686/api/v3/system/status" >/dev/null 2>&1; then
    APP[lidarr.apiver]="v3"
    msg_info "Lidarr supports /api/v3 — using v3 for wiring."
  fi
}

add_example_indexer_to_prowlarr() {
  [[ "$EXAMPLE_INDEXER" != "yes" ]] && return

  local prowlarr_ip="${APP[prowlarr.ip]}"
  local prowlarr_key="${APP[prowlarr.apikey]:-}"
  local label="Prowlarr example indexer (1337x, DISABLED)"
  if [[ -z "$prowlarr_key" ]]; then
    record_failure "${label}  FAIL (no prowlarr apikey)"
    return 1
  fi

  # Ask Prowlarr for the definition's own schema rather than hand-writing the
  # payload. Definitions migrate between native and Cardigann implementations
  # upstream, and a stale implementation/configContract pair is just a 400.
  local schema
  schema=$(curl -fsS --max-time 30 -H "X-Api-Key: $prowlarr_key" \
    "http://${prowlarr_ip}:9696/api/v1/indexer/schema" 2>/dev/null) || {
    record_failure "${label}  FAIL (could not read indexer schema)"
    msg_warn "${label} failed (could not read indexer schema)"
    return 1
  }

  # A fresh Prowlarr ships exactly one app profile ("Standard"), but read it
  # rather than assuming the id.
  local profile_id
  profile_id=$(curl -fsS --max-time 30 -H "X-Api-Key: $prowlarr_key" \
    "http://${prowlarr_ip}:9696/api/v1/appprofile" 2>/dev/null \
    | jq -r '.[0].id // 1')
  [[ "$profile_id" =~ ^[0-9]+$ ]] || profile_id=1

  local payload
  payload=$(jq -n --argjson schema "$schema" --argjson profile "$profile_id" '
    ($schema | map(select(.definitionName == "1337x")) | first) as $s
    | if $s == null then empty
      else $s + { enable: false, appProfileId: $profile, tags: [] }
      end')

  if [[ -z "$payload" ]]; then
    record_failure "${label}  FAIL (1337x not offered by this Prowlarr)"
    msg_warn "${label} failed (1337x not in this Prowlarr's definitions)"
    return 1
  fi

  api_post "http://${prowlarr_ip}:9696/api/v1/indexer?forceSave=true" \
    "$prowlarr_key" "$payload" "$label" || true
}

wire_arrs_into_prowlarr() {
  local prowlarr_ip="${APP[prowlarr.ip]}"
  local prowlarr_key="${APP[prowlarr.apikey]:-}"
  if [[ -z "$prowlarr_key" ]]; then
    msg_warn "Skipping Prowlarr wiring — no Prowlarr API key."
    return
  fi

  local s sync_cats payload
  for s in $SELECTED_ARRS; do
    [[ "$s" == "seerr" ]] && continue
    local key="${APP[$s.apikey]:-}"
    if [[ -z "$key" ]]; then
      record_failure "Prowlarr -> ${APP[$s.name]}  FAIL (no apikey)"
      continue
    fi

    case "$s" in
      sonarr) sync_cats="$SYNC_CATEGORIES_SONARR" ;;
      radarr) sync_cats="$SYNC_CATEGORIES_RADARR" ;;
      lidarr) sync_cats="$SYNC_CATEGORIES_LIDARR" ;;
      *)      sync_cats='[]' ;;
    esac

    payload=$(jq -n \
      --arg name "${APP[$s.name]}" \
      --arg impl "${APP[$s.impl]}" \
      --arg contract "${APP[$s.contract]}" \
      --arg prowlarr_url "http://${prowlarr_ip}:9696" \
      --arg base_url "http://${APP[$s.ip]}:${APP[$s.port]}" \
      --arg apikey "$key" \
      --argjson sync_cats "$sync_cats" \
      '{
        name: $name,
        syncLevel: "fullSync",
        implementation: $impl,
        implementationName: $impl,
        configContract: $contract,
        tags: [],
        fields: [
          { name: "prowlarrUrl",    value: $prowlarr_url },
          { name: "baseUrl",        value: $base_url },
          { name: "apiKey",         value: $apikey },
          { name: "syncCategories", value: $sync_cats }
        ]
      }')

    api_post "http://${prowlarr_ip}:9696/api/v1/applications" \
      "$prowlarr_key" "$payload" \
      "Prowlarr -> ${APP[$s.name]}" || true
  done
}

wire_clients_into_arrs() {
  local arr client arr_key arr_ip arr_port api_ver category_field category_name payload url sab_key

  for arr in $SELECTED_ARRS; do
    [[ "$arr" == "seerr" ]] && continue
    arr_key="${APP[$arr.apikey]:-}"
    if [[ -z "$arr_key" ]]; then
      msg_warn "Skipping download-client wiring for ${arr} — no API key."
      continue
    fi
    arr_ip="${APP[$arr.ip]}"
    arr_port="${APP[$arr.port]}"
    api_ver="${APP[$arr.apiver]}"

    case "$arr" in
      sonarr) category_field="tvCategory";    category_name="tv-sonarr" ;;
      radarr) category_field="movieCategory"; category_name="radarr"    ;;
      lidarr) category_field="musicCategory"; category_name="lidarr"    ;;
    esac

    for client in $SELECTED_CLIENTS; do
      url="http://${arr_ip}:${arr_port}/api/${api_ver}/downloadclient?forceSave=true"

      if [[ "$client" == "qbittorrent" ]]; then
        payload=$(jq -n \
          --arg host "${APP[qbittorrent.ip]}" \
          --argjson port 8090 \
          --arg user "${APP[qbittorrent.user]}" \
          --arg pass "${APP[qbittorrent.pass]}" \
          --arg category_field "$category_field" \
          --arg category_name "$category_name" \
          '{
            enable: true, protocol: "torrent", priority: 1,
            name: "qBittorrent",
            implementation: "QBittorrent",
            implementationName: "qBittorrent",
            configContract: "QBittorrentSettings",
            tags: [],
            fields: [
              { name: "host",     value: $host },
              { name: "port",     value: $port },
              { name: "useSsl",   value: false },
              { name: "username", value: $user },
              { name: "password", value: $pass },
              { name: $category_field, value: $category_name }
            ]
          }')
        api_post "$url" "$arr_key" "$payload" \
          "${APP[$arr.name]} -> qBittorrent" || true

      elif [[ "$client" == "sabnzbd" ]]; then
        sab_key="${APP[sabnzbd.apikey]:-}"
        if [[ -z "$sab_key" ]]; then
          record_failure "${APP[$arr.name]} -> SABnzbd  FAIL (no sab apikey)"
          continue
        fi
        payload=$(jq -n \
          --arg host "${APP[sabnzbd.ip]}" \
          --argjson port 7777 \
          --arg apikey "$sab_key" \
          --arg category_field "$category_field" \
          --arg category_name "$category_name" \
          '{
            enable: true, protocol: "usenet", priority: 1,
            name: "SABnzbd",
            implementation: "Sabnzbd",
            implementationName: "SABnzbd",
            configContract: "SabnzbdSettings",
            tags: [],
            fields: [
              { name: "host",   value: $host },
              { name: "port",   value: $port },
              { name: "apiKey", value: $apikey },
              { name: "useSsl", value: false },
              { name: $category_field, value: $category_name }
            ]
          }')
        api_post "$url" "$arr_key" "$payload" \
          "${APP[$arr.name]} -> SABnzbd" || true
      fi
    done
  done
}

wire_bazarr_into_arrs() {
  [[ " $SELECTED_ARRS " != *" bazarr "* ]] && return

  local bazarr_ip="${APP[bazarr.ip]:-}"
  local bazarr_key="${APP[bazarr.apikey]:-}"
  if [[ -z "$bazarr_ip" ]] || [[ -z "$bazarr_key" ]]; then
    msg_warn "Skipping Bazarr wiring — missing IP or API key."
    return
  fi

  local arr arr_key arr_ip arr_port api_ver url payload
  for arr in $SELECTED_ARRS; do
    [[ "$arr" == "seerr" || "$arr" == "bazarr" ]] && continue
    arr_key="${APP[$arr.apikey]:-}"
    if [[ -z "$arr_key" ]]; then
      record_failure "${APP[$arr.name]} -> Bazarr  FAIL (no apikey)"
      continue
    fi
    arr_ip="${APP[$arr.ip]}"
    arr_port="${APP[$arr.port]}"
    api_ver="${APP[$arr.apiver]}"

    url="http://${arr_ip}:${arr_port}/api/${api_ver}/notification?forceSave=true"

    payload=$(jq -n \
      --arg name "Bazarr" \
      --arg baseUrl "http://${bazarr_ip}:6767" \
      '{
        enable: true, priority: 1,
        name: $name,
        implementation: "Webhook",
        implementationName: "Webhook",
        configContract: "WebhookSettings",
        tags: [],
        fields: [
          { name: "url", value: ($baseUrl + "/api/webhooks/series/wanted-cutoff") }
        ]
      }')

    api_post "$url" "$arr_key" "$payload" \
      "${APP[$arr.name]} -> Bazarr" || true
  done
}

wire_apis() {
  msg_step "Wiring apps together via HTTP APIs"
  probe_lidarr_api_version
  add_example_indexer_to_prowlarr
  wire_arrs_into_prowlarr
  wire_clients_into_arrs
  wire_bazarr_into_arrs

  if [[ " $SELECTED_ARRS " == *" seerr "* ]]; then
    record_wiring "Seerr -> (manual via web wizard)"
    msg_warn "Seerr can't be wired headlessly. URLs and keys are in the summary."
  fi
}

write_summary() {
  msg_step "Writing summary"
  local now host
  now=$(date '+%Y-%m-%d %H:%M:%S %Z')
  host=$(hostname)
  local lines=()
  lines+=( "\e[1;36m============================================================\e[0m" )
  lines+=( "" )
  lines+=( "\e[1;33m[Shared settings]\e[0m" )
  lines+=( "  Bridge:     ${var_bridge}" )
  lines+=( "  Gateway:    ${var_gateway}" )
  lines+=( "  CIDR:       /${var_cidr}" )
  lines+=( "  CT storage: ${var_container_storage}" )
  lines+=( "  Template:   ${var_template_storage}" )
  lines+=( "" )

  lines+=( "\e[1;33m[Containers]\e[0m" )
  local s
  for s in "${ORDERED_SLUGS[@]}"; do
    lines+=( "$(printf '  \e[1m%-12s\e[0m ctid=%-5s ip=%-16s \e[4murl=http://%s:%s\e[0m' \
      "$s" "${APP[$s.ctid]}" "${APP[$s.ip]}" "${APP[$s.ip]}" "${APP[$s.port]}")" )
  done
  lines+=( "" )

  lines+=( "\e[1;33m[Credentials & API keys]\e[0m" )
  for s in "${ORDERED_SLUGS[@]}"; do
    case "${APP[$s.kind]}" in
      indexer|arr)
        if [[ -n "${APP[$s.apikey]:-}" ]]; then
          lines+=( "$(printf '  %-12s apikey: \e[32m%s\e[0m' "$s" "${APP[$s.apikey]}")" )
        else
          lines+=( "$(printf '  %-12s apikey: \e[31m(not extracted)\e[0m' "$s")" )
        fi
        ;;
      client)
        if [[ "$s" == "qbittorrent" ]]; then
          lines+=( "$(printf '  %-12s user:   \e[32m%s\e[0m' "$s" "${APP[qbittorrent.user]:-admin}")" )
          if [[ -n "${APP[qbittorrent.pass]:-}" ]]; then
            lines+=( "$(printf '  %-12s pass:   \e[32m%s\e[0m' "" "${APP[qbittorrent.pass]}")" )
          fi
        elif [[ "$s" == "sabnzbd" ]]; then
          if [[ -n "${APP[sabnzbd.apikey]:-}" ]]; then
            lines+=( "$(printf '  %-12s apikey: \e[32m%s\e[0m' "$s" "${APP[sabnzbd.apikey]}")" )
          else
            lines+=( "$(printf '  %-12s apikey: \e[33m(open web wizard at http://%s:7777 once)\e[0m' "$s" "${APP[sabnzbd.ip]}")" )
          fi
        fi
        ;;
      requests)
        lines+=( "$(printf '  %-12s \e[33m(set during first-run web wizard)\e[0m' "$s")" )
        ;;
      media)
        lines+=( "$(printf '  %-12s \e[33m(set during first-run web wizard at http://%s:%s)\e[0m' "$s" "${APP[$s.ip]}" "${APP[$s.port]}")" )
        ;;
    esac
  done
  lines+=( "" )

  lines+=( "\e[1;33m[Wired automatically]\e[0m" )
  if (( ${#WIRING_RESULTS[@]} == 0 )); then
    lines+=( "  (nothing)" )
  else
    local w
    for w in "${WIRING_RESULTS[@]}"; do lines+=( "  \e[32m✔ ${w}\e[0m" ); done
  fi
  lines+=( "" )

  if [[ "$EXAMPLE_INDEXER" == "yes" ]]; then
    lines+=( "\e[1;33m[⚠ Example Indexer Added]\e[0m" )
    lines+=( "  An example public indexer (1337x) was added to Prowlarr as DISABLED." )
    lines+=( "  \e[31mWARNING: Public indexers can contain malicious content.\e[0m" )
    lines+=( "  Before enabling it, verify it is a legitimate indexer you trust." )
    lines+=( "  To enable: Prowlarr → Settings → Indexers → 1337x → Enable" )
    lines+=( "" )
  fi

  if (( ${#WIRING_FAILURES[@]} > 0 )); then
    lines+=( "\e[1;31m[Wiring failures]\e[0m" )
    local f
    for f in "${WIRING_FAILURES[@]}"; do lines+=( "  \e[31m✖ ${f}\e[0m" ); done
    lines+=( "" )
  fi

  lines+=( "\e[1;41;37m !!! MANUAL STEPS STILL REQUIRED !!! \e[0m" )
  lines+=( "\e[1;31m------------------------------------------------------------\e[0m" )
  lines+=( "  - \e[1mProwlarr:\e[0m Add indexers (none ship by default)." )
  lines+=( "  - \e[1mSonarr/Radarr/Lidarr:\e[0m Set root folders and at least one quality profile." )
  if [[ " $SELECTED_ARRS " == *" bazarr "* ]]; then
    lines+=( "  - \e[1mBazarr:\e[0m Open \e[4mhttp://${APP[bazarr.ip]}:6767\e[0m, configure subtitle providers & languages." )
    lines+=( "         (Webhook notifications are auto-wired. Add connection to each arr app in Bazarr settings if desired.)" )
  fi
  if [[ " $SELECTED_CLIENTS " == *" sabnzbd "* ]]; then
    lines+=( "  - \e[1mSABnzbd:\e[0m Open \e[4mhttp://${APP[sabnzbd.ip]}:7777\e[0m and complete the web wizard." )
  fi
  if [[ " $SELECTED_MEDIA " == *" jellyfin "* ]]; then
    lines+=( "  - \e[1mJellyfin:\e[0m Open \e[4mhttp://${APP[jellyfin.ip]}:8096\e[0m and complete the setup wizard, configure library paths." )
  fi
  if [[ " $SELECTED_ARRS " == *" seerr "* ]]; then
    lines+=( "  - \e[1mSeerr:\e[0m Open \e[4mhttp://${APP[seerr.ip]}:5055\e[0m, complete the wizard, then add:" )
    for s in $SELECTED_ARRS; do
      [[ "$s" == "seerr" ]] || [[ "$s" == "lidarr" ]] && continue
      lines+=( "       -> \e[1m${APP[$s.name]}\e[0m at \e[4mhttp://${APP[$s.ip]}:${APP[$s.port]}\e[0m  (API Key: \e[32m${APP[$s.apikey]:-<missing>}\e[0m)" )
    done
  fi
  lines+=( "\e[1;31m------------------------------------------------------------\e[0m" )
  lines+=( "" )
  lines+=( "Summary written to \e[36m${SUMMARY_FILE}\e[0m (chmod 600)." )
  lines+=( "\e[1;36m============================================================\e[0m" )

  local body
  body=$(printf '%s\n' "${lines[@]}")

  echo
  echo -e "$body"

  # Write raw summary without colors
  ( umask 077; echo -e "$body" | sed 's/\x1b\[[0-9;]*m//g' > "$SUMMARY_FILE" )
  chmod 600 "$SUMMARY_FILE" 2>/dev/null || true

  msg_ok "Wrote ${SUMMARY_FILE}"
}

main() {
  header_info
  check_root
  check_pve_tools
  ensure_dependencies curl whiptail jq iputils-ping
  seed_catalog
  pick_storage
  pick_network_defaults
  pick_apps
  pick_clients
  pick_jellyfin
  pick_qbittorrent_password
  pick_example_indexer
  compute_ordered_slugs
  pick_ip_mode_and_ips
  pick_ctids
  pick_verbose
  confirm_summary
  prepare_templates
  install_loop
  wait_and_extract_keys
  wire_apis
  write_summary
  msg_ok "Installarr provisioning finished."
}

main "$@"
