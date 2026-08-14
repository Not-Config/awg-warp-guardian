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

systemctl disable --now awg-warp-guardian.timer >/dev/null 2>&1 || true
rm -f -- \
  /etc/systemd/system/awg-warp-guardian.service \
  /etc/systemd/system/awg-warp-guardian.timer \
  /etc/systemd/system/awg-warp-guardian.timer.d/10-interval.conf \
  /usr/local/sbin/awg-warp-guardian
rmdir /etc/systemd/system/awg-warp-guardian.timer.d 2>/dev/null || true
rm -rf -- /usr/local/lib/awg-warp-guardian
systemctl daemon-reload

lan_helper_in_use=0
for config_dir in /etc/amnezia/amneziawg /etc/amneziawg; do
  if [[ -d ${config_dir} ]] && \
    grep -RqsF '/usr/local/sbin/awg-warp-lan-rules' "${config_dir}"; then
    lan_helper_in_use=1
  fi
done
if ((lan_helper_in_use == 0)); then
  rm -f -- /usr/local/sbin/awg-warp-lan-rules
fi

if ((purge == 1)); then
  rm -rf -- /etc/awg-warp-guardian /var/lib/awg-warp-guardian
fi

echo "AWG WARP Guardian was removed."
echo "The AmneziaWG package, tunnel service, and VPN .conf file were left intact."
if ((lan_helper_in_use == 1)); then
  echo "The LAN route helper was retained because an existing VPN profile uses it."
fi
