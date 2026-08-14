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

if ((purge == 1)); then
  rm -rf -- /etc/awg-warp-guardian /var/lib/awg-warp-guardian
fi

echo "AWG WARP Guardian was removed."
echo "The AmneziaWG package, tunnel service, and VPN .conf file were left intact."
