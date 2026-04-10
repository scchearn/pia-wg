#!/usr/bin/env bash
# pia-wg — PIA VPN connection manager via NetworkManager
#
# Manages PIA WireGuard connections through NetworkManager. Each connect
# generates a fresh ephemeral key pair, registers it with PIA's API, and
# reimports the connection into NM — no wg-quick, no PIA app required.
#
# Credentials: /etc/pia/credentials (root:root, mode 600)
#   PIA_USER=p1234567
#   PIA_PASS=yourpassword
#   PREFERRED_REGION=pt     # optional default region
#
# See: pia-wg --help

set -euo pipefail

VERSION="0.1.0"

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
NM_CONNECTION="pia"
CONF_FILE="/etc/wireguard/pia.conf"
CREDS_FILE="/etc/pia/credentials"
TOKEN_FILE="/opt/piavpn-manual/token"
PF_STATE_DIR="/var/run/pia"
TOKEN_MAX_AGE_MINS=1200  # 20 hours (token valid for 24h)
MAX_LATENCY="${MAX_LATENCY:-0.5}"

REGION=""
AUTO=false
DIP_TOKEN=""
PORT_FORWARD=false
PF_ONLY=false

# ── output ────────────────────────────────────────────────────────────────────

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _reset=$'\033[0m'
  _bold=$'\033[1m'
  _dim=$'\033[2m'
  _green=$'\033[32m'
  _red=$'\033[31m'
  _yellow=$'\033[33m'
  _cyan=$'\033[36m'
else
  _reset='' _bold='' _dim='' _green='' _red='' _yellow='' _cyan=''
fi

step()   { echo "${_bold}${_cyan}[ ${1}/${2} ]${_reset}${_bold} ${3}${_reset}"; }
detail() { echo "  ${_dim}→${_reset} ${_dim}${*}${_reset}"; }
ok()     { echo "  ${_green}✓${_reset} ${*}"; }
warn()   { echo "  ${_yellow}⚠${_reset}  ${*}" >&2; }
die()    { echo "${_red}✗${_reset} Error: ${*}" >&2; exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────

check_tool() {
  command -v "$1" >/dev/null || die "$1 is required (install ${2:-$1})"
}

fetch_serverlist() {
  local list
  list=$(curl -s 'https://serverlist.piaservers.net/vpninfo/servers/v6' | head -1)
  (( ${#list} > 1000 )) || die "Failed to fetch server list"
  echo "$list"
}

probe_server() {
  local ip=$1 region_id=$2 name=$3
  local t
  t=$(LC_NUMERIC=en_US.utf8 curl -o /dev/null -s \
    --connect-timeout "$MAX_LATENCY" \
    --write-out "%{time_connect}" \
    "http://$ip:443" 2>/dev/null)
  if [[ $? -eq 0 && "$t" != "0.000000" ]]; then
    printf "%s\t%s\t%s\t%s\n" "$t" "$region_id" "$ip" "$name"
  fi
}
export -f probe_server
export MAX_LATENCY

stop_port_forward() {
  local pid_file="$PF_STATE_DIR/pf.pid"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null && ok "Port forwarding keepalive stopped"
    fi
    rm -f "$pid_file" "$PF_STATE_DIR/pf.port" "$PF_STATE_DIR/pf.payload"
  fi
}

# ── flags ─────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-V)
      echo "pia-wg $VERSION"
      exit 0
      ;;
    --help|-h)
      cat <<EOF
${_bold}Usage:${_reset} pia-wg [OPTIONS]

PIA VPN connection manager via NetworkManager WireGuard.

${_bold}Connection options:${_reset}
  ${_cyan}-r, --region <id>${_reset}     Connect to a specific region
      ${_cyan}--auto${_reset}            Auto-select lowest latency region
      ${_cyan}--dip <token>${_reset}     Use a dedicated IP token

${_bold}Features:${_reset}
      ${_cyan}--port-forward${_reset}    Enable port forwarding after connecting
      ${_cyan}--pf-status${_reset}       Show current port forwarding status

${_bold}Information:${_reset}
      ${_cyan}--list${_reset}            List all available regions
      ${_cyan}--list --pf${_reset}       List only port-forwarding capable regions
      ${_cyan}--latency${_reset}         List regions sorted by latency
      ${_cyan}--latency --pf${_reset}    Latency list filtered to PF-capable regions

${_bold}Control:${_reset}
      ${_cyan}--down${_reset}            Disconnect VPN (and stop port forwarding)
  ${_cyan}-h, --help${_reset}            Show this help
  ${_cyan}-V, --version${_reset}         Show version

${_bold}Credentials:${_reset} /etc/pia/credentials ${_dim}(root:root, mode 600)${_reset}
  PIA_USER=p1234567
  PIA_PASS=yourpassword
  PREFERRED_REGION=pt    ${_dim}# optional default region${_reset}

${_bold}Environment:${_reset}
  MAX_LATENCY   Probe timeout for --latency/--auto ${_dim}(default: 0.5s)${_reset}
  NO_COLOR      Disable colored output when set

${_bold}Examples:${_reset}
  sudo pia-wg --region pt
  sudo pia-wg --auto
  sudo pia-wg --region us_chicago --port-forward
  sudo pia-wg --dip DIP1a2b3c4d...
  sudo pia-wg --latency --pf
  sudo pia-wg --down
EOF
      exit 0
      ;;
    --down)
      echo "${_bold}Disconnecting${_reset} ${NM_CONNECTION}..."
      stop_port_forward
      nmcli connection down "$NM_CONNECTION" 2>/dev/null \
        && ok "Disconnected" \
        || warn "Not connected"
      exit 0
      ;;
    --pf-status)
      pid_file="$PF_STATE_DIR/pf.pid"
      port_file="$PF_STATE_DIR/pf.port"
      if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        port=$(cat "$port_file" 2>/dev/null || echo "unknown")
        ok "Port forwarding active — port ${_bold}${port}${_reset} ${_dim}(PID $(cat "$pid_file"))${_reset}"
      else
        warn "Port forwarding is not active"
      fi
      exit 0
      ;;
    --list)
      PF_FILTER=false
      [[ "${2:-}" == "--pf" ]] && { PF_FILTER=true; shift; }
      detail "Fetching server list..."
      serverlist=$(fetch_serverlist)
      echo
      if [[ "$PF_FILTER" == true ]]; then
        echo "${_dim}Showing port-forwarding capable regions only${_reset}"
        echo
        jq_filter='.regions[] | select(.servers.wg | length > 0) | select(.port_forward==true) | [.id, .name] | @tsv'
      else
        jq_filter='.regions[] | select(.servers.wg | length > 0) | [.id, (.name + (if .port_forward then " [PF]" else "" end))] | @tsv'
      fi
      printf "${_bold}%-30s %s${_reset}\n" "REGION ID" "NAME"
      printf "${_dim}%-30s %s${_reset}\n" "──────────────────────────────" "────────────────────────────────────"
      echo "$serverlist" | jq -r "$jq_filter" \
        | sort | awk -F'\t' '{ printf "%-30s %s\n", $1, $2 }'
      exit 0
      ;;
    --latency)
      PF_FILTER=false
      [[ "${2:-}" == "--pf" ]] && { PF_FILTER=true; shift; }
      detail "Fetching server list..."
      serverlist=$(fetch_serverlist)
      detail "Probing latency (timeout: ${MAX_LATENCY}s) — this may take a moment..."
      if [[ "$PF_FILTER" == true ]]; then
        jq_filter='.regions[] | select(.servers.wg | length > 0) | select(.port_forward==true) | [.servers.meta[0].ip, .id, .name] | @tsv'
      else
        jq_filter='.regions[] | select(.servers.wg | length > 0) | [.servers.meta[0].ip, .id, .name] | @tsv'
      fi
      echo
      results=$(echo "$serverlist" \
        | jq -r "$jq_filter" \
        | xargs -P50 -I{} bash -c 'probe_server {}' \
        | sort -t$'\t' -k1 -n)
      printf "${_bold}%-10s %-30s %s${_reset}\n" "LATENCY" "REGION ID" "NAME"
      printf "${_dim}%-10s %-30s %s${_reset}\n" "─────────" "──────────────────────────────" "────────────────────────────────────"
      echo "$results" | awk -F'\t' '{ printf "%-10s %-30s %s\n", $1"s", $2, $4 }'
      exit 0
      ;;
    --auto)
      AUTO=true
      ;;
    --region|-r)
      REGION="${2:-}"
      [[ -n "$REGION" ]] || die "--region requires a value"
      shift
      ;;
    --dip)
      DIP_TOKEN="${2:-}"
      [[ -n "$DIP_TOKEN" ]] || die "--dip requires a token value"
      shift
      ;;
    --port-forward|--pf)
      PORT_FORWARD=true
      ;;
    *)
      die "Unknown flag: $1. Run 'pia-wg --help' for usage."
      ;;
  esac
  shift
done

# ── prerequisites ─────────────────────────────────────────────────────────────

check_tool wg wireguard-tools
check_tool curl curl
check_tool jq jq
check_tool nmcli NetworkManager

(( EUID == 0 )) || die "Run as root: sudo $0"

# ── credentials ───────────────────────────────────────────────────────────────

if [[ -z "${PIA_USER:-}" || -z "${PIA_PASS:-}" ]]; then
  if [[ -f "$CREDS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CREDS_FILE"
  else
    die "No credentials found. Create $CREDS_FILE with PIA_USER and PIA_PASS."
  fi
fi

[[ -n "${PIA_USER:-}" ]] || die "PIA_USER is not set"
[[ -n "${PIA_PASS:-}" ]] || die "PIA_PASS is not set"

# Flag takes precedence; fall back to credentials file, then env var
[[ -n "$REGION" ]] || REGION="${PREFERRED_REGION:-}"

# ── ipv6 leak check ───────────────────────────────────────────────────────────

if [[ -f /proc/net/if_inet6 ]]; then
  ipv6_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
  ipv6_def=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 0)
  if [[ "$ipv6_all" -ne 1 || "$ipv6_def" -ne 1 ]]; then
    warn "IPv6 is enabled. PIA WireGuard does not support IPv6 — traffic may leak."
    warn "To disable: sysctl -w net.ipv6.conf.all.disable_ipv6=1"
  fi
fi

# ── token ─────────────────────────────────────────────────────────────────────

TOTAL_STEPS=4
[[ -n "$DIP_TOKEN" ]] && TOTAL_STEPS=4  # DIP replaces step 2

step 1 $TOTAL_STEPS "Token"
if [[ -f "$TOKEN_FILE" ]] && [[ -n "$(find "$TOKEN_FILE" -mmin "-$TOKEN_MAX_AGE_MINS" 2>/dev/null)" ]]; then
  PIA_TOKEN=$(head -1 "$TOKEN_FILE")
  ok "Reusing existing token (< 20h old)"
else
  detail "Authenticating with PIA..."
  mkdir -p /opt/piavpn-manual
  response=$(curl -s --location --request POST \
    'https://www.privateinternetaccess.com/api/client/v2/token' \
    --form "username=$PIA_USER" \
    --form "password=$PIA_PASS")
  PIA_TOKEN=$(echo "$response" | jq -r '.token // empty')
  [[ -n "$PIA_TOKEN" ]] || die "Authentication failed. Check PIA_USER and PIA_PASS."
  echo "$PIA_TOKEN" > "$TOKEN_FILE"
  ok "Token acquired"
fi

# ── server selection ──────────────────────────────────────────────────────────

step 2 $TOTAL_STEPS "Server"

if [[ -n "$DIP_TOKEN" ]]; then
  # Dedicated IP flow — resolve server from DIP token
  detail "Resolving dedicated IP..."
  dip_response=$(curl -s --location --request POST \
    'https://www.privateinternetaccess.com/api/client/v2/dedicated_ip' \
    --header 'Content-Type: application/json' \
    --header "Authorization: Token $PIA_TOKEN" \
    --data-raw "{\"tokens\":[\"$DIP_TOKEN\"]}")

  dip_status=$(echo "$dip_response" | jq -r '.[0].status // "error"')
  [[ "$dip_status" == "active" ]] || die "Dedicated IP token is invalid or inactive."

  WG_SERVER_IP=$(echo "$dip_response" | jq -r '.[0].ip')
  WG_HOSTNAME=$(echo "$dip_response" | jq -r '.[0].cn')
  dip_expiry=$(echo "$dip_response" | jq -r '.[0].dip_expire')
  dip_expiry_fmt=$(date -d "@$dip_expiry" 2>/dev/null || date -r "$dip_expiry" 2>/dev/null || echo "$dip_expiry")
  ok "Dedicated IP: ${_bold}${WG_SERVER_IP}${_reset} ${_dim}(${WG_HOSTNAME}, expires ${dip_expiry_fmt})${_reset}"

  # Port forwarding not available on all DIP regions
  if [[ "$PORT_FORWARD" == true ]]; then
    dip_id=$(echo "$dip_response" | jq -r '.[0].id')
    if [[ "$dip_id" == us_* ]]; then
      warn "Port forwarding is not available for this dedicated IP location."
      PORT_FORWARD=false
    fi
  fi
else
  # Standard flow — region-based server selection
  detail "Fetching server list..."
  serverlist=$(fetch_serverlist)

  if [[ "$AUTO" == true ]]; then
    detail "Probing latency to select best region (timeout: ${MAX_LATENCY}s)..."
    REGION=$(echo "$serverlist" \
      | jq -r '.regions[] | select(.servers.wg | length > 0) | [.servers.meta[0].ip, .id, .name] | @tsv' \
      | xargs -P50 -I{} bash -c 'probe_server {}' \
      | sort -t$'\t' -k1 -n \
      | head -1 \
      | cut -f2)
    [[ -n "$REGION" ]] || die "No regions responded within ${MAX_LATENCY}s. Try: MAX_LATENCY=1 sudo pia-wg --auto"
    ok "Selected region: ${_bold}${REGION}${_reset}"
  fi

  [[ -n "$REGION" ]] || die "No region set. Use --region <id>, --auto, --dip, or set PREFERRED_REGION in $CREDS_FILE."

  regionData=$(echo "$serverlist" | jq --arg r "$REGION" '.regions[] | select(.id==$r)')
  [[ -n "$regionData" ]] || die "Region '${REGION}' not found. Run 'pia-wg --list' for valid IDs."

  # Warn if port forwarding requested but region doesn't support it
  if [[ "$PORT_FORWARD" == true ]]; then
    pf_capable=$(echo "$regionData" | jq -r '.port_forward')
    if [[ "$pf_capable" != "true" ]]; then
      warn "Region '${REGION}' does not support port forwarding."
      warn "Run 'pia-wg --list --pf' to see compatible regions."
      PORT_FORWARD=false
    fi
  fi

  WG_SERVER_IP=$(echo "$regionData" | jq -r '.servers.wg[0].ip')
  WG_HOSTNAME=$(echo "$regionData" | jq -r '.servers.wg[0].cn')
  ok "Region ${_bold}${REGION}${_reset} → ${WG_HOSTNAME} ${_dim}(${WG_SERVER_IP})${_reset}"
fi

# ── key generation and API registration ───────────────────────────────────────

step 3 $TOTAL_STEPS "Keys + registration"
detail "Generating ephemeral WireGuard key pair..."
privKey=$(wg genkey)
pubKey=$(echo "$privKey" | wg pubkey)

detail "Registering with PIA API..."
if [[ -n "$DIP_TOKEN" ]]; then
  wg_json=$(curl -s -G \
    --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
    --cacert "$SCRIPT_DIR/ca.rsa.4096.crt" \
    --user "dedicated_ip_$DIP_TOKEN:$WG_SERVER_IP" \
    --data-urlencode "pubkey=$pubKey" \
    "https://${WG_HOSTNAME}:1337/addKey")
else
  wg_json=$(curl -s -G \
    --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
    --cacert "$SCRIPT_DIR/ca.rsa.4096.crt" \
    --data-urlencode "pt=$PIA_TOKEN" \
    --data-urlencode "pubkey=$pubKey" \
    "https://${WG_HOSTNAME}:1337/addKey")
fi

status=$(echo "$wg_json" | jq -r '.status // "error"')
[[ "$status" == "OK" ]] || die "PIA API returned: $wg_json"

serverKey=$(echo "$wg_json" | jq -r '.server_key')
serverPort=$(echo "$wg_json" | jq -r '.server_port')
peerIP=$(echo "$wg_json" | jq -r '.peer_ip')
dnsServer=$(echo "$wg_json" | jq -r '.dns_servers[0]')
ok "Tunnel IP: ${_bold}${peerIP}${_reset}  ${_dim}DNS: ${dnsServer}${_reset}"

# ── write conf and update NM ──────────────────────────────────────────────────

step 4 $TOTAL_STEPS "NetworkManager"

detail "Writing ${CONF_FILE}..."
mkdir -p "$(dirname "$CONF_FILE")"
cat > "$CONF_FILE" <<EOF

[Interface]
Address = $peerIP
PrivateKey = $privKey
DNS = $dnsServer

[Peer]
PersistentKeepalive = 25
PublicKey = $serverKey
AllowedIPs = 0.0.0.0/0
Endpoint = $WG_SERVER_IP:$serverPort
EOF

detail "Replacing NM connection..."
nmcli connection delete "$NM_CONNECTION" &>/dev/null || true
nmcli connection import type wireguard file "$CONF_FILE" >/dev/null
nmcli connection modify "$NM_CONNECTION" \
  wireguard.ip4-auto-default-route yes \
  connection.autoconnect no

detail "Bringing up connection..."
nmcli connection up "$NM_CONNECTION" >/dev/null

public_ip=$(curl -s --max-time 10 https://ifconfig.me)

echo
ok "${_bold}Connected${_reset}  ${_dim}|${_reset}  Region: ${_bold}${REGION:-DIP}${_reset}  ${_dim}|${_reset}  Public IP: ${_bold}${public_ip}${_reset}"

# ── port forwarding ───────────────────────────────────────────────────────────

if [[ "$PORT_FORWARD" == true ]]; then
  echo
  step "+" $TOTAL_STEPS "Port forwarding"
  mkdir -p "$PF_STATE_DIR"

  # Reuse existing payload+signature if available (port persists ~2 months)
  pf_payload_file="$PF_STATE_DIR/pf.payload"
  if [[ -f "$pf_payload_file" ]]; then
    detail "Reusing saved port forwarding payload..."
    payload_and_sig=$(cat "$pf_payload_file")
  else
    detail "Requesting port forwarding signature..."
    payload_and_sig=$(curl -s -m 5 \
      --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
      --cacert "$SCRIPT_DIR/ca.rsa.4096.crt" \
      -G --data-urlencode "token=${PIA_TOKEN}" \
      "https://${WG_HOSTNAME}:19999/getSignature")
  fi

  pf_status=$(echo "$payload_and_sig" | jq -r '.status // "error"')
  [[ "$pf_status" == "OK" ]] || die "Port forwarding API error: $payload_and_sig"

  signature=$(echo "$payload_and_sig" | jq -r '.signature')
  payload=$(echo "$payload_and_sig" | jq -r '.payload')
  pf_port=$(echo "$payload" | base64 -d | jq -r '.port')
  pf_expires=$(echo "$payload" | base64 -d | jq -r '.expires_at')

  echo "$payload_and_sig" > "$pf_payload_file"

  # Bind the port
  detail "Binding port ${pf_port}..."
  bind_response=$(curl -Gs -m 5 \
    --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
    --cacert "$SCRIPT_DIR/ca.rsa.4096.crt" \
    --data-urlencode "payload=${payload}" \
    --data-urlencode "signature=${signature}" \
    "https://${WG_HOSTNAME}:19999/bindPort")

  [[ $(echo "$bind_response" | jq -r '.status') == "OK" ]] || die "Port bind failed: $bind_response"
  echo "$pf_port" > "$PF_STATE_DIR/pf.port"

  ok "Port forwarded: ${_bold}${pf_port}${_reset}  ${_dim}(expires ${pf_expires})${_reset}"

  # Start keepalive in background (rebinds every 15 min)
  detail "Starting keepalive in background..."
  (
    while true; do
      sleep 900
      curl -Gs -m 5 \
        --connect-to "$WG_HOSTNAME::$WG_SERVER_IP:" \
        --cacert "$SCRIPT_DIR/ca.rsa.4096.crt" \
        --data-urlencode "payload=${payload}" \
        --data-urlencode "signature=${signature}" \
        "https://${WG_HOSTNAME}:19999/bindPort" >/dev/null 2>&1 || true
    done
  ) &
  echo $! > "$PF_STATE_DIR/pf.pid"
  ok "Keepalive running ${_dim}(PID $!)${_reset}"
fi

echo
