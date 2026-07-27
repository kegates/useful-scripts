#!/usr/bin/env bash
# Apply a network scenario from profiles/<device>.json to this Linux machine.
# Supports both NetworkManager (nmcli) and systemd-networkd backends, auto-detected.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${SCRIPT_DIR}/../profiles"
DRY_RUN=0
DEVICE_NAME=""
PROFILE_NAME=""
NMCLI_UP_TIMEOUT=20

usage() {
  cat <<'EOF'
Usage: apply-profile.sh <device> <scenario-name> [options]

<device> selects which profiles/<device>.json file to use — it's just a
label you choose, not required to match this machine's actual hostname.
Devices that want identical settings (e.g. every Raspberry Pi) can share
one file; pass its name explicitly instead of relying on hostname lookup.

Options:
  --profiles-dir PATH  Directory containing profile JSON files
                        (default: ../profiles relative to this script)
  --dry-run            Show current state and planned changes, apply nothing
  -h, --help           Show this help

Example:
  ./apply-profile.sh kevin-laptop ssh-link
  ./apply-profile.sh raspberrypi home
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profiles-dir) PROFILES_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [ -z "$DEVICE_NAME" ]; then
        DEVICE_NAME="$1"; shift
      elif [ -z "$PROFILE_NAME" ]; then
        PROFILE_NAME="$1"; shift
      else
        echo "Unexpected extra argument: $1" >&2; exit 1
      fi
      ;;
  esac
done

if [ -z "$DEVICE_NAME" ] || [ -z "$PROFILE_NAME" ]; then
  echo "Error: both <device> and <scenario-name> are required." >&2
  usage >&2
  exit 1
fi

# WSL can't manage the physical NICs of the Windows host it runs on.
if grep -qi microsoft /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
  echo "Error: this looks like WSL. WSL cannot manage the Windows host's network" >&2
  echo "adapters. Run windows/Apply-Profile.ps1 from a native Windows PowerShell" >&2
  echo "(as Administrator) instead." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed. Install it with:" >&2
  echo "  sudo apt install jq" >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Error: this script changes network configuration and must be run as root (sudo)." >&2
  exit 1
fi

DEVICE_NAME="$(echo "$DEVICE_NAME" | tr '[:upper:]' '[:lower:]')"
PROFILE_PATH="${PROFILES_DIR}/${DEVICE_NAME}.json"

if [ ! -f "$PROFILE_PATH" ]; then
  echo "Error: profile file not found: $PROFILE_PATH" >&2
  echo "Available device profiles:" >&2
  ls "${PROFILES_DIR}"/*.json 2>/dev/null >&2 || echo "  (none found)" >&2
  exit 1
fi

if ! jq empty "$PROFILE_PATH" >/dev/null 2>&1; then
  echo "Error: $PROFILE_PATH is not valid JSON." >&2
  exit 1
fi

if ! jq -e --arg s "$PROFILE_NAME" 'has($s)' "$PROFILE_PATH" >/dev/null 2>&1; then
  echo "Error: scenario '$PROFILE_NAME' not found in $PROFILE_PATH" >&2
  echo "Available scenarios for $DEVICE_NAME:" >&2
  jq -r 'keys[]' "$PROFILE_PATH" | sed 's/^/  /' >&2
  exit 1
fi

SCENARIO="$(jq -c --arg s "$PROFILE_NAME" '.[$s]' "$PROFILE_PATH")"

echo "Using profile: $PROFILE_PATH (scenario: $PROFILE_NAME)"

# --- Backend detection -------------------------------------------------

BACKEND=""
if command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager 2>/dev/null; then
  BACKEND="nmcli"
elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
  BACKEND="networkd"
else
  echo "Error: couldn't detect a supported network backend (NetworkManager or systemd-networkd active)." >&2
  exit 1
fi
echo "Detected backend: $BACKEND"

# --- Small validation helpers -----------------------------------------------

is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
    [ "$((10#$o))" -le 255 ] || return 1
  done
  return 0
}

ip_to_int() {
  local ip="$1" a b c d
  IFS='.' read -r a b c d <<< "$ip"
  echo $(( (10#$a<<24) + (10#$b<<16) + (10#$c<<8) + 10#$d ))
}

same_subnet() {
  local a="$1" b="$2" prefix="$3" ai bi mask
  is_valid_ipv4 "$a" || return 2
  is_valid_ipv4 "$b" || return 2
  ai="$(ip_to_int "$a")"
  bi="$(ip_to_int "$b")"
  if [ "$prefix" -eq 0 ]; then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  fi
  [ $(( ai & mask )) -eq $(( bi & mask )) ]
}

# --- Interface discovery -------------------------------------------------

find_interfaces() {
  local role="$1" iface
  for iface in /sys/class/net/*; do
    iface="$(basename "$iface")"
    [ "$iface" = "lo" ] && continue
    case "$iface" in
      docker*|br-*|veth*|virbr*|tun*|tap*|wg*) continue ;;
    esac
    if [ "$role" = "wifi" ]; then
      [ -d "/sys/class/net/$iface/wireless" ] && echo "$iface"
    else
      [ ! -d "/sys/class/net/$iface/wireless" ] && [ -d "/sys/class/net/$iface/device" ] && echo "$iface"
    fi
  done
  return 0
}

find_interface() {
  find_interfaces "$1" | head -1
}

# --- State inspection (backend-specific "configured" view) -----------------

nmcli_conn_for() {
  local iface="$1" conn
  conn="$(nmcli -t -f GENERAL.CONNECTION device show "$iface" 2>/dev/null | cut -d: -f2)"
  if [ -z "$conn" ]; then
    conn="$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | awk -F: -v d="$iface" '$2==d {print $1; exit}')"
  fi
  echo "$conn"
}

describe_nmcli_config() {
  local iface="$1" conn
  conn="$(nmcli_conn_for "$iface")"
  if [ -z "$conn" ]; then
    echo "    NetworkManager connection: <none found>"
    return
  fi
  echo "    NetworkManager connection: $conn"
  echo "    configured method: $(nmcli -g ipv4.method connection show "$conn" 2>/dev/null || echo unknown)"
  echo "    configured address: $(nmcli -g ipv4.addresses connection show "$conn" 2>/dev/null || echo '<none>')"
  echo "    configured gateway: $(nmcli -g ipv4.gateway connection show "$conn" 2>/dev/null || echo '<none>')"
  echo "    configured dns: $(nmcli -g ipv4.dns connection show "$conn" 2>/dev/null || echo '<none>')"
}

find_matching_network_file() {
  local iface="$1" f name_match
  for f in /etc/systemd/network/*.network; do
    [ -e "$f" ] || continue
    name_match="$(awk -F= '/^\[Match\]/{m=1;next} /^\[/{m=0} m && $1=="Name"{print $2}' "$f")"
    if [ -z "$name_match" ] || [ "$name_match" = "$iface" ]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

describe_networkd_config() {
  local iface="$1" f
  f="$(find_matching_network_file "$iface" || true)"
  if [ -z "$f" ]; then
    echo "    matching .network file: <none found>"
    return
  fi
  echo "    matching .network file: $f"
  awk '/^\[Network\]/{p=1;next} /^\[/{p=0} p' "$f" | sed 's/^/    configured: /'
}

# --- Live state (kernel-level, works regardless of backend) ----------------

describe_live() {
  local iface="$1" role="$2" state addrs gw dns
  state="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown)"
  addrs="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}')"
  gw="$(ip -4 route show default dev "$iface" 2>/dev/null | awk '{print $3; exit}')"
  if command -v resolvectl >/dev/null 2>&1; then
    dns="$(resolvectl dns "$iface" 2>/dev/null | sed 's/^[^:]*: *//')"
  else
    dns="$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | paste -sd' ' -)"
  fi

  echo "    link state: $state"
  echo "    address(es): ${addrs:-<none>}"
  echo "    default gateway: ${gw:-<none>}"
  echo "    dns: ${dns:-<none>}"

  if [ "$BACKEND" = "nmcli" ]; then
    describe_nmcli_config "$iface"
  else
    describe_networkd_config "$iface"
  fi

  if echo "$addrs" | grep -q '^169\.254\.'; then
    echo "    WARNING: address looks like APIPA (169.254.x.x) - DHCP may not be getting a lease." >&2
  fi
  if [ "$state" != "up" ]; then
    echo "    note: link is not up ($state) - config can still be applied but won't be active until connected."
  fi
}

print_snapshot() {
  local label="$1" role="$2" iface="$3"
  echo "--- $label: $role ($iface) ---"
  describe_live "$iface" "$role"
}

# --- nmcli backend ---------------------------------------------------------

apply_nmcli() {
  local iface="$1" mode="$2" address="$3" prefix="$4" gateway="$5" dns_csv="$6"
  local conn
  conn="$(nmcli_conn_for "$iface")"
  if [ -z "$conn" ]; then
    echo "  Warning: no NetworkManager connection profile found for $iface, skipping." >&2
    return
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] nmcli connection modify \"$conn\" -> mode=$mode address=$address/$prefix gateway=$gateway dns=$dns_csv"
    return
  fi

  if [ "$mode" = "dhcp" ]; then
    nmcli connection modify "$conn" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
  else
    local args=(ipv4.method manual ipv4.addresses "${address}/${prefix}")
    if [ -n "$gateway" ]; then
      args+=(ipv4.gateway "$gateway")
    else
      args+=(ipv4.gateway "")
    fi
    args+=(ipv4.dns "$dns_csv")
    nmcli connection modify "$conn" "${args[@]}"
  fi

  echo "  Activating \"$conn\" (up to ${NMCLI_UP_TIMEOUT}s)..."
  if ! nmcli connection up "$conn" --wait "$NMCLI_UP_TIMEOUT" >/dev/null; then
    echo "  WARNING: \"$conn\" did not fully activate within ${NMCLI_UP_TIMEOUT}s." >&2
    if [ "$mode" = "dhcp" ]; then
      echo "  This usually means no DHCP server is reachable on this link yet (e.g. the" >&2
      echo "  cable is still plugged into a direct point-to-point peer, not a router)." >&2
    fi
    echo "  The config was saved and NetworkManager will keep retrying in the background." >&2
  fi
}

# --- systemd-networkd backend ----------------------------------------------

apply_networkd() {
  local iface="$1" mode="$2" address="$3" prefix="$4" gateway="$5" dns_csv="$6" role="$7"
  local conf_path="/etc/systemd/network/00-profile-${role}.network"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] would write $conf_path -> mode=$mode address=$address/$prefix gateway=$gateway dns=$dns_csv"
    return
  fi

  {
    echo "[Match]"
    echo "Name=$iface"
    echo
    echo "[Network]"
    if [ "$mode" = "dhcp" ]; then
      echo "DHCP=yes"
    else
      echo "Address=${address}/${prefix}"
      if [ -n "$gateway" ]; then
        echo "Gateway=$gateway"
      fi
      if [ -n "$dns_csv" ]; then
        IFS=',' read -ra dns_arr <<< "$dns_csv"
        for d in "${dns_arr[@]}"; do
          echo "DNS=$d"
        done
      fi
    fi
  } > "$conf_path"

  networkctl reload
  networkctl reconfigure "$iface" >/dev/null 2>&1 || true
}

# --- Post-apply verification -------------------------------------------------

verify_role() {
  local role="$1" iface="$2" mode="$3" address="$4" prefix="$5" gateway="$6" addrs gw

  addrs="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}')"
  gw="$(ip -4 route show default dev "$iface" 2>/dev/null | awk '{print $3; exit}')"

  if [ "$mode" = "static" ]; then
    if printf '%s\n' "$addrs" | grep -qx "${address}/${prefix}"; then
      echo "    OK: $role has expected address ${address}/${prefix}"
    else
      echo "    WARNING: expected address ${address}/${prefix} not found on $iface (got: ${addrs:-<none>})" >&2
    fi
    if [ -n "$gateway" ]; then
      if [ "$gw" = "$gateway" ]; then
        echo "    OK: default gateway is $gateway"
      else
        echo "    WARNING: expected gateway $gateway, got '${gw:-<none>}'" >&2
      fi
    fi
  else
    if printf '%s\n' "$addrs" | grep -q '^169\.254\.'; then
      echo "    WARNING: still showing an APIPA address after switching to dhcp - may not have a lease yet." >&2
    else
      echo "    OK: dhcp mode set (address: ${addrs:-<none, lease pending>})"
    fi
  fi
}

# --- Main ------------------------------------------------------------------

for role in ethernet wifi; do
  block="$(echo "$SCENARIO" | jq -c --arg r "$role" '.[$r] // empty')"
  if [ -z "$block" ]; then
    echo
    echo "Leaving $role alone (not in profile)."
    continue
  fi

  mode="$(echo "$block" | jq -r '.mode')"
  address="$(echo "$block" | jq -r '.address // ""')"
  prefix="$(echo "$block" | jq -r '.prefix // ""')"
  gateway="$(echo "$block" | jq -r '.gateway // ""')"
  dns_csv="$(echo "$block" | jq -r '(.dns // []) | join(",")')"

  if [ "$mode" = "static" ] && { [ -z "$address" ] || [ -z "$prefix" ]; }; then
    echo "Error: $role.mode is 'static' but address/prefix missing in $PROFILE_PATH" >&2
    exit 1
  fi

  # Pre-checks on the requested config itself.
  if [ "$mode" = "static" ] && [ -n "$gateway" ]; then
    if ! same_subnet "$address" "$gateway" "$prefix"; then
      echo "WARNING: $role gateway $gateway does not appear to be in the same subnet as ${address}/${prefix}" >&2
    fi
  fi
  if [ -n "$dns_csv" ]; then
    IFS=',' read -ra _dns_check <<< "$dns_csv"
    for d in "${_dns_check[@]}"; do
      is_valid_ipv4 "$d" || echo "WARNING: '$d' in $role.dns doesn't look like a valid IPv4 address" >&2
    done
  fi

  candidates="$(find_interfaces "$role")"
  if [ -z "$candidates" ]; then
    echo
    echo "Warning: no $role interface found on this machine, skipping." >&2
    continue
  fi
  iface="$(printf '%s\n' "$candidates" | head -1)"
  if [ "$(printf '%s\n' "$candidates" | grep -c .)" -gt 1 ]; then
    echo "WARNING: multiple candidate $role interfaces found ($(printf '%s' "$candidates" | tr '\n' ' ')); using '$iface'." >&2
  fi

  echo
  print_snapshot "BEFORE" "$role" "$iface"

  echo "Configuring $role ($iface): mode=$mode"
  if [ "$BACKEND" = "nmcli" ]; then
    apply_nmcli "$iface" "$mode" "$address" "$prefix" "$gateway" "$dns_csv"
  else
    apply_networkd "$iface" "$mode" "$address" "$prefix" "$gateway" "$dns_csv" "$role"
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    sleep 1
    print_snapshot "AFTER" "$role" "$iface"
    verify_role "$role" "$iface" "$mode" "$address" "$prefix" "$gateway"
  fi
done

echo
echo "Done."
