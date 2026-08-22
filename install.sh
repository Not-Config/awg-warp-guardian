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
generator_site_url="https://warp-gen.github.io"
generator_data_urls=""
generator_https_proxy=""
awg_variant=1
dns_preset=cf
server_preset=def
warp_ipv6=1
warp_keepalive=0
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
generator_site_option_set=0
generator_proxy_option_set=0
warp_parameters_option_set=0
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
  --generator-site URL   warp-gen site or compatible mirror
  --generator-data URL   Override identity API; repeat for fallbacks
  --awg-variant N        AWG 2.0 variant published by warp-gen: 1, 2, or 3
  --dns-preset NAME      warp-gen DNS preset (default: cf)
  --server-preset NAME   warp-gen server preset (default: def)
  --ipv6 / --no-ipv6     Include or omit IPv6 in the generated profile
  --keepalive SECONDS    PersistentKeepalive; 0 disables it (default: 0)
  --generator-proxy URL  HTTP/HTTPS proxy used only to reach warp-gen
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
    --generator-site)
      generator_site_url=${2:?missing value for --generator-site}
      settings_option_set=1
      generator_site_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --generator-data)
      generator_data_urls+=" ${2:?missing value for --generator-data}"
      settings_option_set=1
      warp_parameters_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --awg-variant)
      awg_variant=${2:?missing value for --awg-variant}
      settings_option_set=1
      warp_parameters_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --dns-preset)
      dns_preset=${2:?missing value for --dns-preset}
      settings_option_set=1
      warp_parameters_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --server-preset)
      server_preset=${2:?missing value for --server-preset}
      settings_option_set=1
      warp_parameters_option_set=1
      configuration_args_seen=1
      shift 2
      ;;
    --ipv6)
      warp_ipv6=1
      settings_option_set=1
      warp_parameters_option_set=1
      configuration_args_seen=1
      shift
      ;;
    --no-ipv6)
      warp_ipv6=0
      settings_option_set=1
      warp_parameters_option_set=1
      configuration_args_seen=1
      shift
      ;;
    --keepalive)
      warp_keepalive=${2:?missing value for --keepalive}
      settings_option_set=1
      warp_parameters_option_set=1
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
  "${PROJECT_DIR}/src/route-endpoint"; do
  if [[ ! -f "${required}" ]]; then
    echo "Incomplete checkout; missing ${required}" >&2
    exit 66
  fi
done

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
    existing_initial_attempts=$(sed -n 's/^CANDIDATE_ATTEMPTS=//p' "${guardian_config}" | head -n 1)
    if [[ -z ${existing_initial_attempts} ]]; then
      existing_initial_attempts=$(sed -n 's/^INITIAL_GENERATION_ATTEMPTS=//p' "${guardian_config}" | head -n 1)
    fi
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
  if ((generator_site_option_set == 0)); then
    existing_generator_site=$(sed -n 's/^GENERATOR_SITE_URL=//p' "${guardian_config}" | head -n 1)
    existing_generator_site=${existing_generator_site%\"}
    existing_generator_site=${existing_generator_site#\"}
    if [[ -n ${existing_generator_site} ]]; then
      generator_site_url=${existing_generator_site}
    fi
  fi
  if ((warp_parameters_option_set == 0)); then
    for parameter_name in GENERATOR_DATA_URLS WARP_AWG_VARIANT WARP_DNS_PRESET WARP_SERVER_PRESET WARP_IPV6 WARP_KEEPALIVE; do
      parameter_value=$(sed -n "s/^${parameter_name}=//p" "${guardian_config}" | head -n 1)
      parameter_value=${parameter_value%\"}
      parameter_value=${parameter_value#\"}
      [[ -n ${parameter_value} ]] || continue
      case ${parameter_name} in
        GENERATOR_DATA_URLS) generator_data_urls=${parameter_value} ;;
        WARP_AWG_VARIANT) awg_variant=${parameter_value} ;;
        WARP_DNS_PRESET) dns_preset=${parameter_value} ;;
        WARP_SERVER_PRESET) server_preset=${parameter_value} ;;
        WARP_IPV6) warp_ipv6=${parameter_value} ;;
        WARP_KEEPALIVE) warp_keepalive=${parameter_value} ;;
      esac
    done
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
if [[ ${exclude_lan} != 0 && ${exclude_lan} != 1 ]]; then
  echo "LAN routing mode must be 0 (include) or 1 (exclude)" >&2
  exit 65
fi
generator_site_url=${generator_site_url%/}
if [[ ! ${generator_site_url} =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]+)*$ ]]; then
  echo "--generator-site must be an HTTPS URL without credentials, query, or fragment" >&2
  exit 65
fi
read -r -a generator_data_array <<<"${generator_data_urls}"
for generator_data_url in "${generator_data_array[@]}"; do
  if [[ ! ${generator_data_url} =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]+)*/?$ ]]; then
    echo "--generator-data must be an HTTPS URL without credentials, query, or fragment" >&2
    exit 65
  fi
done
if [[ ! ${awg_variant} =~ ^[123]$ ]]; then
  echo "--awg-variant must be 1, 2, or 3" >&2
  exit 65
fi
if [[ ! ${dns_preset} =~ ^[A-Za-z0-9_-]{1,32}$ || ! ${server_preset} =~ ^[A-Za-z0-9_-]{1,32}$ ]]; then
  echo "DNS and server preset names contain unsupported characters" >&2
  exit 65
fi
if [[ ${warp_ipv6} != 0 && ${warp_ipv6} != 1 ]]; then
  echo "IPv6 mode must be 0 or 1" >&2
  exit 65
fi
if [[ ! ${warp_keepalive} =~ ^[0-9]+$ ]] || ((10#${warp_keepalive} > 65535)); then
  echo "--keepalive must be between 0 and 65535" >&2
  exit 65
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

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates curl iproute2 iptables jq python3 resolvconf util-linux \
    wireguard-tools
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
install -D -m 755 "${PROJECT_DIR}/src/route-endpoint" \
  /usr/local/sbin/awg-warp-route-endpoint
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
CANDIDATE_ATTEMPTS=${initial_generation_attempts}
EXCLUDE_LAN=${exclude_lan}
WARP_AWG_VARIANT=${awg_variant}
WARP_DNS_PRESET=${dns_preset}
WARP_SERVER_PRESET=${server_preset}
WARP_IPV6=${warp_ipv6}
WARP_KEEPALIVE=${warp_keepalive}
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
GENERATOR_PATH=/usr/local/lib/awg-warp-guardian/generate-warp-config
GENERATOR_TIMEOUT=90
GENERATOR_SITE_URL=${generator_site_url}
GENERATOR_DATA_URLS="${generator_data_urls}"
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

# Keep the selected public endpoint reachable over the physical route when
# warp-gen's "Exclude LAN" split-route profile is used. This is deliberately a
# systemd hook so the downloaded/generated .conf is not rewritten.
endpoint_dropin_dir="/etc/systemd/system/awg-quick@${interface}.service.d"
install -d -m 755 "${endpoint_dropin_dir}"
endpoint_dropin_tmp=$(mktemp "${endpoint_dropin_dir}/.10-endpoint-route.conf.XXXXXX")
cat >"${endpoint_dropin_tmp}" <<EOF
[Service]
TimeoutStartSec=60s
ExecStartPre=/usr/local/sbin/awg-warp-route-endpoint up-config ${config_path} /run/awg-warp-guardian/${interface}.endpoint
ExecStopPost=/usr/local/sbin/awg-warp-route-endpoint down-state /run/awg-warp-guardian/${interface}.endpoint
EOF
chmod 644 "${endpoint_dropin_tmp}"
mv -f -- "${endpoint_dropin_tmp}" "${endpoint_dropin_dir}/10-endpoint-route.conf"
systemctl daemon-reload

install -d -m 700 "$(dirname -- "${config_path}")"
systemctl enable "awg-quick@${interface}.service" >/dev/null

if ((no_start == 1)); then
  if [[ ! -s ${config_path} ]]; then
    echo "[installer] Downloading one untested warp-gen profile (--no-start)."
    WARP_GENERATOR_SITE_URL="${generator_site_url}" \
    WARP_GENERATOR_DATA_URLS="${generator_data_urls}" \
    WARP_AWG_VARIANT="${awg_variant}" \
    WARP_DNS_PRESET="${dns_preset}" \
    WARP_SERVER_PRESET="${server_preset}" \
    WARP_IPV6="${warp_ipv6}" \
    WARP_KEEPALIVE="${warp_keepalive}" \
    WARP_EXCLUDE_LAN="${exclude_lan}" \
    HTTPS_PROXY="${generator_https_proxy}" \
    https_proxy="${generator_https_proxy}" \
    ALL_PROXY="" \
    all_proxy="" \
      /usr/local/lib/awg-warp-guardian/generate-warp-config "${config_path}"
  fi
  awg-quick strip "${config_path}" >/dev/null
  systemctl enable awg-warp-guardian.timer >/dev/null
  echo "Installed without starting or health-checking the tunnel."
  echo "Start it manually: systemctl start awg-quick@${interface}.service"
  exit 0
fi

installation_healthy=0
if [[ -s ${config_path} ]]; then
  chmod 600 "${config_path}"
  echo "[installer] Checking the existing AWG profile before any replacement."
  if ! awg-quick strip "${config_path}" >/dev/null; then
    echo "awg-quick rejected ${config_path}; requesting a fresh warp-gen profile." >&2
    systemctl stop "awg-quick@${interface}.service" 2>/dev/null || true
  else
    if ! timeout 60s systemctl restart "awg-quick@${interface}.service"; then
      echo "[installer] Tunnel start timed out; cancelling it before profile replacement." >&2
      systemctl stop "awg-quick@${interface}.service" 2>/dev/null || true
    fi
    echo "[installer] Waiting ${REPAIR_WAIT:-12} seconds for a handshake..."
    sleep 12
    if /usr/local/sbin/awg-warp-guardian check; then
      installation_healthy=1
    fi
  fi
fi

if ((installation_healthy == 0)); then
  echo
  echo "[installer] The service will now request and test up to ${initial_generation_attempts} fresh warp-gen profiles."
  echo "[installer] Every attempt is visible below; private keys remain hidden."
  if /usr/local/sbin/awg-warp-guardian rotate --force; then
    installation_healthy=1
  fi
fi

if ((installation_healthy == 1)); then
  # The first successful installation should not reduce the automatic daily
  # repair budget.
  rm -f -- /var/lib/awg-warp-guardian/state.json
  systemctl enable awg-warp-guardian.timer >/dev/null
  systemctl restart awg-warp-guardian.timer
  echo
  echo "AWG WARP Guardian is installed and the tunnel is healthy."
  echo "Source: ${generator_site_url}"
  echo "Check interval: ${check_interval}"
  echo "Status: awg-warp-guardian status"
  echo "Logs:   journalctl -u awg-warp-guardian.service -f"
  exit 0
fi

echo "No warp-gen profile passed the configured health checks." >&2
echo "The guardian timer was not started. The previous profile was restored when available." >&2
echo "Inspect: journalctl -u awg-quick@${interface}.service -n 100 --no-pager" >&2
exit 1
