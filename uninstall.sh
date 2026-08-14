#!/usr/bin/env bash
set -Eeuo pipefail

purge=0
if [[ ${1:-} == "--purge" ]]; then
  purge=1
elif (($#)); then
  echo "Usage: sudo ./uninstall.sh [--purge]" >&2
  exit 64
fi
if ((EUID != 0)); then
  echo "Run this uninstaller as root." >&2
  exit 77
fi

guardian_interface=""
if [[ -r /etc/awg-warp-guardian/guardian.env ]]; then
  guardian_interface=$(sed -n 's/^INTERFACE=//p' /etc/awg-warp-guardian/guardian.env | head -n 1)
  guardian_interface=${guardian_interface%\"}
  guardian_interface=${guardian_interface#\"}
fi

systemctl disable --now awg-warp-guardian.timer >/dev/null 2>&1 || true
rm -f -- \
  /etc/systemd/system/awg-warp-guardian.service \
  /etc/systemd/system/awg-warp-guardian.timer \
  /etc/systemd/system/awg-warp-guardian.timer.d/10-interval.conf \
  /usr/local/sbin/awg-warp-guardian
rmdir /etc/systemd/system/awg-warp-guardian.timer.d 2>/dev/null || true
if [[ ${guardian_interface} =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]]; then
  endpoint_dropin_dir="/etc/systemd/system/awg-quick@${guardian_interface}.service.d"
  rm -f -- "${endpoint_dropin_dir}/10-endpoint-route.conf"
  rmdir "${endpoint_dropin_dir}" 2>/dev/null || true
  /usr/local/sbin/awg-warp-route-endpoint down-state \
    "/run/awg-warp-guardian/${guardian_interface}.endpoint" 2>/dev/null || true
fi
rm -rf -- /usr/local/lib/awg-warp-guardian
systemctl daemon-reload

lan_helper_in_use=0
endpoint_helper_in_use=0
for config_dir in /etc/amnezia/amneziawg /etc/amneziawg; do
  if [[ -d ${config_dir} ]] && \
    grep -RqsF '/usr/local/sbin/awg-warp-lan-rules' "${config_dir}"; then
    lan_helper_in_use=1
  fi
  if [[ -d ${config_dir} ]] && \
    grep -RqsF '/usr/local/sbin/awg-warp-route-endpoint' "${config_dir}"; then
    endpoint_helper_in_use=1
  fi
done
if ((lan_helper_in_use == 0)); then
  rm -f -- /usr/local/sbin/awg-warp-lan-rules
fi
if ((endpoint_helper_in_use == 0)); then
  rm -f -- /usr/local/sbin/awg-warp-route-endpoint
fi

if ((purge == 1)); then
  rm -rf -- /etc/awg-warp-guardian /var/lib/awg-warp-guardian
fi

echo "AWG WARP Guardian was removed."
echo "The AmneziaWG package, tunnel service, and VPN .conf file were left intact."
if ((lan_helper_in_use == 1)); then
  echo "The LAN route helper was retained because an existing VPN profile uses it."
fi
if ((endpoint_helper_in_use == 1)); then
  echo "The endpoint route helper was retained because an existing VPN profile uses it."
fi
