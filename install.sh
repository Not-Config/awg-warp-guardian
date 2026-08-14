#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

interface="awg-warp"
config_path=""
check_urls="https://github.com/ https://telegram.org/ https://www.cloudflare.com/cdn-cgi/trace"
check_quorum=2
check_interval="2min"
initial_generation_attempts=10
exclude_lan=1
generator_api_url="https://api.cloudflareclient.com/v0i1909051800"
generator_https_proxy=""
skip_package_install=0
no_start=0
reconfigure=0
identity_option_set=0
settings_option_set=0
urls_option_set=0
quorum_option_set=0
interval_option_set=0
initial_attempts_option_set=0
lan_option_set=0
endpoints_option_set=0
generator_api_option_set=0
generator_proxy_option_set=0
custom_endpoints=()
tui_mode=auto
configuration_args_seen=0

usage() {
  cat <<'EOF'
Install AWG WARP Guardian on an Ubuntu server.

Usage:
  sudo ./install.sh [options]

Options:
  --interface NAME       AWG interface/service instance (default: awg-warp)
  --config PATH          Existing or new awg-quick configuration path
  --check-url URL        Replace defaults; repeat to add multiple URLs
  --quorum NUMBER        Required successful site checks (default: 2)
  --check-interval TIME  Timer interval: 30s, 1min, 2min, 1h (default: 2min)
  --initial-attempts N   New-profile attempts: 1-20 (default: 10)
  --exclude-lan          Keep private/local networks outside VPN (default)
  --include-lan          Route private networks through VPN
  --endpoint HOST:PORT   WARP endpoint; repeat to add rotation alternatives
  --generator-api URL    Compatible HTTPS WARP registration API base URL
  --generator-proxy URL  HTTP/HTTPS proxy used only for WARP registration
  --no-generator-proxy   Clear a previously configured registration proxy
  --tui                  Force the interactive installer
  --no-tui               Disable the interactive installer
  --skip-package-install Do not use apt or add the Amnezia PPA
  --no-start             Install files but do not start the tunnel/timer
  --reconfigure          Replace the existing guardian.env
  -h, --help             Show this help

For an existing profile:
  sudo ./install.sh --interface awg-existing \
    --config /etc/amnezia/amneziawg/awg-existing.conf
EOF
}

custom_urls=()
while (($#)); do
  case "$1" in
    --interface)
      interface=${2:?missing value for --interface}
      identity_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --config)
      config_path=${2:?missing value for --config}
      identity_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --check-url)
      custom_urls+=("${2:?missing value for --check-url}")
      settings_option_set=1
      urls_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --quorum)
      check_quorum=${2:?missing value for --quorum}
      settings_option_set=1
      quorum_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --check-interval)
      check_interval=${2:?missing value for --check-interval}
      settings_option_set=1
      interval_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --initial-attempts)
      initial_generation_attempts=${2:?missing value for --initial-attempts}
      settings_option_set=1
      initial_attempts_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --exclude-lan)
      exclude_lan=1
      settings_option_set=1
      lan_option_set=1
      configuration_args_seen=1
      shift
      ;;
    --include-lan)
      exclude_lan=0
      settings_option_set=1
      lan_option_set=1
      configuration_args_seen=1
      shift
      ;;
    --endpoint)
      custom_endpoints+=("${2:?missing value for --endpoint}")
      settings_option_set=1
      endpoints_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --generator-api)
      generator_api_url=${2:?missing value for --generator-api}
      settings_option_set=1
      generator_api_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --generator-proxy)
      generator_https_proxy=${2:?missing value for --generator-proxy}
      settings_option_set=1
      generator_proxy_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --no-generator-proxy)
      generator_https_proxy=""
      settings_option_set=1
      generator_proxy_option_set=1
      configuration_args_seen=1
      shift
      ;;
    --tui)
      tui_mode=force
      shift
      ;;
    --no-tui)
      tui_mode=off
      shift
      ;;
    --skip-package-install)
      skip_package_install=1
      shift
      ;;
    --no-start)
      no_start=1
      shift
      ;;
    --reconfigure)
      reconfigure=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if ((EUID != 0)); then
  echo "Run this installer as root (sudo ./install.sh)." >&2
  exit 77
fi

guardian_config=/etc/awg-warp-guardian/guardian.env

for required in \
  "${PROJECT_DIR}/src/guardian.py" \
  "${PROJECT_DIR}/src/generate-warp-config" \
  "${PROJECT_DIR}/src/install-tui.sh" \
  "${PROJECT_DIR}/src/lan-rules" \
  "${PROJECT_DIR}/src/route-policy.sh" \
  "${PROJECT_DIR}/vendor/warp_generator.sh" \
  "${PROJECT_DIR}/vendor/LICENSE.ImMALWARE"; do
  if [[ ! -f "${required}" ]]; then
    echo "Incomplete checkout; missing ${required}" >&2
    exit 66
  fi
done

# shellcheck disable=SC1091
source "${PROJECT_DIR}/src/route-policy.sh"

run_tui=0
if [[ ${tui_mode} == force ]]; then
  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "--tui requires an interactive terminal." >&2
    exit 64
  fi
  run_tui=1
elif [[ ${tui_mode} == auto && ${configuration_args_seen} -eq 0 && -t 0 && -t 1 ]]; then
  run_tui=1
fi

if ((run_tui == 1)); then
  if ! command -v whiptail >/dev/null 2>&1; then
    if ((skip_package_install == 1)); then
      echo "The interactive installer requires whiptail." >&2
      echo "Install it first or rerun with --no-tui." >&2
      exit 69
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y whiptail
  fi
  # shellcheck disable=SC1091
  source "${PROJECT_DIR}/src/install-tui.sh"
  if run_install_tui; then
    :
  else
    tui_status=$?
    echo "Installation cancelled; no VPN settings were changed." >&2
    exit "${tui_status}"
  fi
fi

if [[ -s "${guardian_config}" ]]; then
  if ((reconfigure == 0 && (identity_option_set == 1 || settings_option_set == 1))); then
    echo "Guardian is already configured in ${guardian_config}." >&2
    echo "Use --reconfigure to replace its tunnel/check settings." >&2
    exit 65
  fi
  if ((identity_option_set == 0)); then
    existing_interface=$(sed -n 's/^INTERFACE=//p' "${guardian_config}" | head -n 1)
    existing_config_path=$(sed -n 's/^CONFIG_PATH=//p' "${guardian_config}" | head -n 1)
    if [[ -z "${existing_interface}" || -z "${existing_config_path}" ]]; then
      echo "Existing guardian.env is missing INTERFACE or CONFIG_PATH." >&2
      exit 65
    fi
    interface=${existing_interface%\"}
    interface=${interface#\"}
    config_path=${existing_config_path%\"}
    config_path=${config_path#\"}
  fi
  if ((urls_option_set == 0)); then
    existing_check_urls=$(sed -n 's/^CHECK_URLS=//p' "${guardian_config}" | head -n 1)
    existing_check_urls=${existing_check_urls%\"}
    existing_check_urls=${existing_check_urls#\"}
    if [[ -n ${existing_check_urls} ]]; then
      check_urls=${existing_check_urls}
    fi
  fi
  if ((quorum_option_set == 0)); then
    existing_check_quorum=$(sed -n 's/^CHECK_QUORUM=//p' "${guardian_config}" | head -n 1)
    existing_check_quorum=${existing_check_quorum%\"}
    existing_check_quorum=${existing_check_quorum#\"}
    if [[ -n ${existing_check_quorum} ]]; then
      check_quorum=${existing_check_quorum}
    fi
  fi
  if ((interval_option_set == 0)); then
    existing_check_interval=$(sed -n 's/^CHECK_INTERVAL=//p' "${guardian_config}" | head -n 1)
    existing_check_interval=${existing_check_interval%\"}
    existing_check_interval=${existing_check_interval#\"}
    if [[ -n ${existing_check_interval} ]]; then
      check_interval=${existing_check_interval}
    fi
  fi
  if ((initial_attempts_option_set == 0)); then
    existing_initial_attempts=$(sed -n 's/^INITIAL_GENERATION_ATTEMPTS=//p' "${guardian_config}" | head -n 1)
    existing_initial_attempts=${existing_initial_attempts%\"}
    existing_initial_attempts=${existing_initial_attempts#\"}
    if [[ -n ${existing_initial_attempts} ]]; then
      initial_generation_attempts=${existing_initial_attempts}
    fi
  fi
  if ((lan_option_set == 0)); then
    existing_exclude_lan=$(sed -n 's/^EXCLUDE_LAN=//p' "${guardian_config}" | head -n 1)
    existing_exclude_lan=${existing_exclude_lan%\"}
    existing_exclude_lan=${existing_exclude_lan#\"}
    if [[ -n ${existing_exclude_lan} ]]; then
      exclude_lan=${existing_exclude_lan}
    fi
  fi
  if ((endpoints_option_set == 0 && identity_option_set == 0)); then
    existing_endpoints=$(sed -n 's/^WARP_ENDPOINTS=//p' "${guardian_config}" | head -n 1)
    existing_endpoints=${existing_endpoints%\"}
    existing_endpoints=${existing_endpoints#\"}
    if [[ -n ${existing_endpoints} ]]; then
      IFS=, read -r -a custom_endpoints <<<"${existing_endpoints}"
    fi
  fi
  if ((generator_api_option_set == 0)); then
    existing_generator_api=$(sed -n 's/^GENERATOR_API_URL=//p' "${guardian_config}" | head -n 1)
    existing_generator_api=${existing_generator_api%\"}
    existing_generator_api=${existing_generator_api#\"}
    if [[ -n ${existing_generator_api} ]]; then
      generator_api_url=${existing_generator_api}
    fi
  fi
  if ((generator_proxy_option_set == 0)); then
    existing_generator_proxy=$(sed -n 's/^GENERATOR_HTTPS_PROXY=//p' "${guardian_config}" | head -n 1)
    existing_generator_proxy=${existing_generator_proxy%\"}
    existing_generator_proxy=${existing_generator_proxy#\"}
    generator_https_proxy=${existing_generator_proxy}
  fi
fi
if [[ ! "${interface}" =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]]; then
  echo "Invalid Linux interface name: ${interface}" >&2
  exit 65
fi
if [[ ! "${check_quorum}" =~ ^[1-9][0-9]*$ ]]; then
  echo "--quorum must be a positive integer" >&2
  exit 65
fi
if [[ ${check_interval} =~ ^([1-9][0-9]*)(s|min|h)$ ]]; then
  interval_amount=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in
    s) interval_seconds=${interval_amount} ;;
    min) interval_seconds=$((interval_amount * 60)) ;;
    h) interval_seconds=$((interval_amount * 3600)) ;;
  esac
else
  echo "--check-interval must use the format 30s, 2min, or 1h" >&2
  exit 65
fi
if ((interval_seconds < 30)); then
  echo "--check-interval cannot be shorter than 30 seconds" >&2
  exit 65
fi
if [[ ! ${initial_generation_attempts} =~ ^[1-9][0-9]*$ ]] || \
  ((initial_generation_attempts > 20)); then
  echo "--initial-attempts must be an integer between 1 and 20" >&2
  exit 65
fi
if ! awg_valid_lan_mode "${exclude_lan}"; then
  echo "LAN routing mode must be 0 (include) or 1 (exclude)" >&2
  exit 65
fi
generator_api_url=${generator_api_url%/}
if [[ ! ${generator_api_url} =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]+)*$ ]]; then
  echo "--generator-api must be an HTTPS base URL without credentials, query, or fragment" >&2
  exit 65
fi
generator_api_authority=${generator_api_url#https://}
generator_api_authority=${generator_api_authority%%/*}
if [[ ${generator_api_authority} == *:* ]]; then
  generator_api_port=${generator_api_authority##*:}
  generator_api_port_number=$((10#${generator_api_port}))
  if ((generator_api_port_number < 1 || generator_api_port_number > 65535)); then
    echo "--generator-api port must be between 1 and 65535" >&2
    exit 65
  fi
fi
if [[ -n ${generator_https_proxy} && ! ${generator_https_proxy} =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]]; then
  echo "--generator-proxy must look like http://host:port or https://host:port" >&2
  exit 65
fi
if [[ -n ${generator_https_proxy} ]]; then
  generator_proxy_authority=${generator_https_proxy#*://}
  generator_proxy_authority=${generator_proxy_authority%/}
  if [[ ${generator_proxy_authority} == *:* ]]; then
    generator_proxy_port=${generator_proxy_authority##*:}
    generator_proxy_port_number=$((10#${generator_proxy_port}))
    if ((generator_proxy_port_number < 1 || generator_proxy_port_number > 65535)); then
      echo "--generator-proxy port must be between 1 and 65535" >&2
      exit 65
    fi
  fi
fi
if ((${#custom_urls[@]})); then
  check_urls="${custom_urls[*]}"
fi
read -r -a url_array <<<"${check_urls}"
for check_url in "${url_array[@]}"; do
  if [[ ! ${check_url} =~ ^https?://[A-Za-z0-9:/?\&._=%+#@~-]+$ ]]; then
    echo "Invalid check URL (only HTTP/HTTPS URLs without spaces are supported): ${check_url}" >&2
    exit 65
  fi
done
if ((check_quorum > ${#url_array[@]})); then
  echo "--quorum cannot exceed the number of check URLs" >&2
  exit 65
fi

if [[ -z "${config_path}" ]]; then
  if [[ -f "/etc/amnezia/amneziawg/${interface}.conf" ]]; then
    config_path="/etc/amnezia/amneziawg/${interface}.conf"
  elif [[ -f "/etc/amneziawg/${interface}.conf" ]]; then
    config_path="/etc/amneziawg/${interface}.conf"
  elif [[ -d /etc/amneziawg && ! -d /etc/amnezia/amneziawg ]]; then
    config_path="/etc/amneziawg/${interface}.conf"
  else
    config_path="/etc/amnezia/amneziawg/${interface}.conf"
  fi
fi
if [[ "${config_path}" != /* || "${config_path}" != *.conf ]]; then
  echo "--config must be an absolute .conf path" >&2
  exit 65
fi
if [[ $(basename -- "${config_path}") != "${interface}.conf" ]]; then
  echo "The config filename must match the interface: ${interface}.conf" >&2
  exit 65
fi

warp_endpoints=162.159.192.1:500
if ((${#custom_endpoints[@]})); then
  for endpoint in "${custom_endpoints[@]}"; do
    if [[ ! "${endpoint}" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}$ ]]; then
      echo "Invalid --endpoint value: ${endpoint}" >&2
      exit 65
    fi
    endpoint_port=${endpoint##*:}
    endpoint_port_number=$((10#${endpoint_port}))
    if ((endpoint_port_number < 1 || endpoint_port_number > 65535)); then
      echo "Endpoint port must be between 1 and 65535: ${endpoint}" >&2
      exit 65
    fi
  done
  warp_endpoints=$(IFS=,; echo "${custom_endpoints[*]}")
elif [[ -s "${config_path}" ]]; then
  existing_endpoint=$(sed -n -E \
    's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
    "${config_path}" | head -n 1)
  if [[ "${existing_endpoint}" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}$ ]]; then
    warp_endpoints=${existing_endpoint}
  fi
fi

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates curl iproute2 iptables jq python3 resolvconf util-linux \
    whiptail wireguard-tools
  if command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1; then
    return
  fi
  if [[ ! -r /etc/os-release ]]; then
    echo "Cannot detect the operating system; install AmneziaWG manually." >&2
    exit 69
  fi
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ ${ID:-} != ubuntu ]]; then
    echo "Automatic AmneziaWG installation currently supports Ubuntu only." >&2
    echo "Install awg and awg-quick, then rerun with --skip-package-install." >&2
    exit 69
  fi
  apt-get install -y \
    gnupg2 \
    "linux-headers-$(uname -r)" \
    python3-launchpadlib \
    software-properties-common
  add-apt-repository -y ppa:amnezia/ppa
  apt-get update
  apt-get install -y amneziawg
}

if ((skip_package_install == 0)); then
  install_packages
fi
for command_name in python3 curl jq wg awg awg-quick ip systemctl flock; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command is missing: ${command_name}" >&2
    exit 69
  fi
done

install -D -m 755 "${PROJECT_DIR}/src/guardian.py" \
  /usr/local/lib/awg-warp-guardian/guardian.py
install -D -m 755 "${PROJECT_DIR}/src/generate-warp-config" \
  /usr/local/lib/awg-warp-guardian/generate-warp-config
install -D -m 755 "${PROJECT_DIR}/src/lan-rules" \
  /usr/local/sbin/awg-warp-lan-rules
install -D -m 644 "${PROJECT_DIR}/src/route-policy.sh" \
  /usr/local/lib/awg-warp-guardian/route-policy.sh
install -D -m 755 "${PROJECT_DIR}/vendor/warp_generator.sh" \
  /usr/local/lib/awg-warp-guardian/vendor/warp_generator.sh
install -D -m 644 "${PROJECT_DIR}/vendor/LICENSE.ImMALWARE" \
  /usr/local/lib/awg-warp-guardian/vendor/LICENSE.ImMALWARE
ln -sfn /usr/local/lib/awg-warp-guardian/guardian.py \
  /usr/local/sbin/awg-warp-guardian

install -d -m 700 /etc/awg-warp-guardian /var/lib/awg-warp-guardian
if [[ ! -e "${guardian_config}" || ${reconfigure} -eq 1 ]]; then
  guardian_tmp=$(mktemp /etc/awg-warp-guardian/.guardian.env.XXXXXX)
  cat >"${guardian_tmp}" <<EOF
INTERFACE=${interface}
CONFIG_PATH=${config_path}
SERVICE=awg-quick@${interface}.service
CHECK_URLS="${check_urls}"
CHECK_QUORUM=${check_quorum}
CHECK_INTERVAL=${check_interval}
INITIAL_GENERATION_ATTEMPTS=${initial_generation_attempts}
EXCLUDE_LAN=${exclude_lan}
CURL_TIMEOUT=12
BIND_TO_INTERFACE=1
REQUIRE_WARP=1
WARP_TRACE_URL=https://www.cloudflare.com/cdn-cgi/trace
MAX_HANDSHAKE_AGE=300
FAILURES_BEFORE_REPAIR=3
REPAIR_WAIT=12
ALLOW_HARD_RESTART=1
ROTATION_COOLDOWN=1800
MAX_ROTATIONS_PER_DAY=4
BACKUPS_KEEP=10
WARP_ENDPOINTS=${warp_endpoints}
PRESERVE_DIRECTIVES=Table,PreUp,PostUp,PreDown,PostDown,S1,S2,S3,S4,Jc,Jmin,Jmax,H1,H2,H3,H4,I1,I2,I3,I4,I5
GENERATOR_PATH=/usr/local/lib/awg-warp-guardian/generate-warp-config
GENERATOR_TIMEOUT=90
GENERATOR_API_URL=${generator_api_url}
GENERATOR_HTTPS_PROXY=${generator_https_proxy}
STATE_DIR=/var/lib/awg-warp-guardian
EOF
  chmod 600 "${guardian_tmp}"
  mv -f -- "${guardian_tmp}" "${guardian_config}"
else
  echo "Keeping existing ${guardian_config}; use --reconfigure to replace it."
fi

install -D -m 644 "${PROJECT_DIR}/systemd/awg-warp-guardian.service" \
  /etc/systemd/system/awg-warp-guardian.service
install -D -m 644 "${PROJECT_DIR}/systemd/awg-warp-guardian.timer" \
  /etc/systemd/system/awg-warp-guardian.timer
install -d -m 755 /etc/systemd/system/awg-warp-guardian.timer.d
timer_dropin_tmp=$(mktemp /etc/systemd/system/awg-warp-guardian.timer.d/.10-interval.conf.XXXXXX)
cat >"${timer_dropin_tmp}" <<EOF
[Timer]
OnBootSec=
OnBootSec=${check_interval}
OnUnitActiveSec=
OnUnitActiveSec=${check_interval}
EOF
chmod 644 "${timer_dropin_tmp}"
mv -f -- "${timer_dropin_tmp}" \
  /etc/systemd/system/awg-warp-guardian.timer.d/10-interval.conf
systemctl daemon-reload

route_policy_changed=0
if [[ -s ${config_path} && ${lan_option_set} -eq 1 ]]; then
  route_policy_backup="/var/lib/awg-warp-guardian/backups/$(basename -- "${config_path}").before-route-policy.$(date -u +%Y%m%dT%H%M%SZ).$$"
  install -D -m 600 "${config_path}" "${route_policy_backup}"
  route_policy_tmp=$(mktemp "$(dirname -- "${config_path}")/.route-policy.XXXXXX")
  if ! awg_apply_route_policy \
    "${config_path}" "${route_policy_tmp}" "${exclude_lan}"; then
    rm -f -- "${route_policy_tmp}"
    echo "Could not apply the selected LAN route policy; the profile was not changed." >&2
    exit 65
  fi
  chmod 600 "${route_policy_tmp}"
  mv -f -- "${route_policy_tmp}" "${config_path}"
  route_policy_changed=1
  if [[ ${exclude_lan} == 1 ]]; then
    echo "[installer] LAN exclusion applied; previous profile backed up to ${route_policy_backup}"
  else
    echo "[installer] Full-tunnel LAN routing applied; previous profile backed up to ${route_policy_backup}"
  fi
fi

generated_config=0
initial_generation_attempt=1
if [[ ! -s "${config_path}" ]]; then
  install -d -m 700 "$(dirname -- "${config_path}")"
  initial_endpoint=${warp_endpoints%%,*}
  while ((initial_generation_attempt <= initial_generation_attempts)); do
    echo
    echo "=== WARP configuration attempt ${initial_generation_attempt}/${initial_generation_attempts} ==="
    echo "[installer] Registration API: ${generator_api_url}"
    if [[ -n ${generator_https_proxy} ]]; then
      echo "[installer] Registration transport: configured HTTP/HTTPS proxy"
    else
      echo "[installer] Registration transport: direct HTTPS connection"
    fi
    if WARP_ENDPOINT="${initial_endpoint}" \
      WARP_API_BASE_URL="${generator_api_url}" \
      WARP_EXCLUDE_LAN="${exclude_lan}" \
      HTTPS_PROXY="${generator_https_proxy}" \
      https_proxy="${generator_https_proxy}" \
      /usr/local/lib/awg-warp-guardian/generate-warp-config "${config_path}"; then
      echo "[installer] Checking the received configuration with awg-quick..."
      if awg-quick strip "${config_path}" >/dev/null; then
        echo "[installer] Configuration syntax is valid."
        generated_config=1
        break
      fi
      echo "[installer] API returned parameters, but awg-quick rejected the configuration." >&2
    else
      echo "[installer] Registration/configuration generation failed on this attempt." >&2
    fi
    rm -f -- "${config_path}"
    initial_generation_attempt=$((initial_generation_attempt + 1))
  done
  if ((generated_config == 0)); then
    echo "Could not generate a valid initial WARP config after ${initial_generation_attempts} attempts." >&2
    exit 70
  fi
else
  chmod 600 "${config_path}"
  echo "Adopting existing AWG profile: ${config_path}"
fi

if ! awg-quick strip "${config_path}" >/dev/null; then
  echo "awg-quick rejected ${config_path}; nothing was started." >&2
  exit 65
fi

if ((no_start == 1)); then
  systemctl enable awg-warp-guardian.timer >/dev/null
  echo "Installed without starting the tunnel."
  echo "Start it manually: systemctl start awg-quick@${interface}.service"
  exit 0
fi

tunnel_was_active=0
if systemctl is-active --quiet "awg-quick@${interface}.service"; then
  tunnel_was_active=1
fi
systemctl enable "awg-quick@${interface}.service" >/dev/null
if ((route_policy_changed == 1 && tunnel_was_active == 1)); then
  systemctl restart "awg-quick@${interface}.service"
else
  systemctl start "awg-quick@${interface}.service"
fi
echo "[installer] Tunnel service started; waiting 12 seconds for a handshake..."
sleep 12
installation_healthy=0
echo "[installer] Checking the tunnel, selected sites, WARP status, and handshake..."
if /usr/local/sbin/awg-warp-guardian check; then
  installation_healthy=1
elif ((generated_config == 1)); then
  initial_generation_attempt=$((initial_generation_attempt + 1))
  while ((initial_generation_attempt <= initial_generation_attempts)); do
    echo >&2
    echo "=== WARP configuration attempt ${initial_generation_attempt}/${initial_generation_attempts} ===" >&2
    echo "[installer] Previous configuration failed health checks; requesting a new registration." >&2
    systemctl stop "awg-quick@${interface}.service" || true
    if /usr/local/sbin/awg-warp-guardian rotate --force; then
      installation_healthy=1
      break
    fi
    initial_generation_attempt=$((initial_generation_attempt + 1))
  done
fi

if ((installation_healthy == 1)); then
  if ((generated_config == 1)); then
    # Forced retries during first-time setup must not consume the daily
    # automatic-rotation budget after a working profile has been found.
    rm -f -- /var/lib/awg-warp-guardian/state.json
  fi
  systemctl enable awg-warp-guardian.timer >/dev/null
  systemctl restart awg-warp-guardian.timer
  echo
  echo "AWG WARP Guardian is installed and the tunnel is healthy."
  echo "Check interval: ${check_interval}"
  echo "Status: awg-warp-guardian status"
  echo "Logs:   journalctl -u awg-warp-guardian.service -f"
  exit 0
fi

echo "Initial tunnel health check failed." >&2
if ((generated_config == 1 || tunnel_was_active == 0)); then
  echo "Stopping the newly activated tunnel to restore the previous route." >&2
  systemctl stop "awg-quick@${interface}.service" || true
fi
echo "The guardian timer was not started. Inspect:" >&2
echo "  journalctl -u awg-quick@${interface}.service -n 100 --no-pager" >&2
exit 1
