#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

interface="awg-warp"
config_path=""
check_urls="https://github.com/ https://telegram.org/ https://www.cloudflare.com/cdn-cgi/trace"
check_quorum=2
skip_package_install=0
no_start=0
reconfigure=0
identity_option_set=0
settings_option_set=0
custom_endpoints=()

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
  --endpoint HOST:PORT   WARP endpoint; repeat to add rotation alternatives
  --skip-package-install Do not use apt or add the Amnezia PPA
  --no-start             Install files but do not start the tunnel/timer
  --reconfigure          Replace the existing guardian.env
  -h, --help             Show this help

For the existing tg-bt profile:
  sudo ./install.sh --interface awg-new \
    --config /etc/amnezia/amneziawg/awg-new.conf
EOF
}

custom_urls=()
while (($#)); do
  case "$1" in
    --interface)
      interface=${2:?missing value for --interface}
      identity_option_set=1
      shift 2
      ;;
    --config)
      config_path=${2:?missing value for --config}
      identity_option_set=1
      shift 2
      ;;
    --check-url)
      custom_urls+=("${2:?missing value for --check-url}")
      settings_option_set=1
      shift 2
      ;;
    --quorum)
      check_quorum=${2:?missing value for --quorum}
      settings_option_set=1
      shift 2
      ;;
    --endpoint)
      custom_endpoints+=("${2:?missing value for --endpoint}")
      settings_option_set=1
      shift 2
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
fi
if [[ ! "${interface}" =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]]; then
  echo "Invalid Linux interface name: ${interface}" >&2
  exit 65
fi
if [[ ! "${check_quorum}" =~ ^[1-9][0-9]*$ ]]; then
  echo "--quorum must be a positive integer" >&2
  exit 65
fi
if ((${#custom_urls[@]})); then
  check_urls="${custom_urls[*]}"
fi
read -r -a url_array <<<"${check_urls}"
if ((check_quorum > ${#url_array[@]})); then
  echo "--quorum cannot exceed the number of check URLs" >&2
  exit 65
fi

for required in \
  "${PROJECT_DIR}/src/guardian.py" \
  "${PROJECT_DIR}/src/generate-warp-config" \
  "${PROJECT_DIR}/vendor/warp_generator.sh" \
  "${PROJECT_DIR}/vendor/LICENSE.ImMALWARE"; do
  if [[ ! -f "${required}" ]]; then
    echo "Incomplete checkout; missing ${required}" >&2
    exit 66
  fi
done

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
GENERATOR_HTTPS_PROXY=
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
systemctl daemon-reload

generated_config=0
if [[ ! -s "${config_path}" ]]; then
  install -d -m 700 "$(dirname -- "${config_path}")"
  echo "Generating the initial Cloudflare WARP configuration..."
  initial_endpoint=${warp_endpoints%%,*}
  WARP_ENDPOINT="${initial_endpoint}" \
    /usr/local/lib/awg-warp-guardian/generate-warp-config "${config_path}"
  generated_config=1
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
systemctl enable --now "awg-quick@${interface}.service"
sleep 12
if /usr/local/sbin/awg-warp-guardian check; then
  systemctl enable --now awg-warp-guardian.timer
  echo
  echo "AWG WARP Guardian is installed and the tunnel is healthy."
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
