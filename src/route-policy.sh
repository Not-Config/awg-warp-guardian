#!/usr/bin/env bash

# Non-local IPv4 ranges are the complement of 0/8, RFC1918, loopback,
# IPv4 link-local, and 240/4. Global IPv6 uses 2000::/3, leaving ULA and
# link-local ranges outside the tunnel.
AWG_LAN_EXCLUDED_ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/3, 96.0.0.0/4, 112.0.0.0/5, 120.0.0.0/6, 124.0.0.0/7, 126.0.0.0/8, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/8, 169.0.0.0/9, 169.128.0.0/10, 169.192.0.0/11, 169.224.0.0/12, 169.240.0.0/13, 169.248.0.0/14, 169.252.0.0/15, 169.255.0.0/16, 170.0.0.0/7, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 224.0.0.0/4, 2000::/3"
AWG_FULL_TUNNEL_ALLOWED_IPS="0.0.0.0/0, ::/0"
readonly AWG_LAN_EXCLUDED_ALLOWED_IPS AWG_FULL_TUNNEL_ALLOWED_IPS

awg_valid_lan_mode() {
  [[ $1 == 0 || $1 == 1 ]]
}

awg_apply_route_policy() {
  local input=$1
  local output=$2
  local exclude_lan=$3
  local allowed_ips count

  awg_valid_lan_mode "${exclude_lan}" || return 64
  count=$(grep -Ec '^[[:space:]]*AllowedIPs[[:space:]]*=' "${input}")
  [[ ${count} -eq 1 ]] || return 65

  if [[ ${exclude_lan} == 1 ]]; then
    allowed_ips=${AWG_LAN_EXCLUDED_ALLOWED_IPS}
  else
    allowed_ips=${AWG_FULL_TUNNEL_ALLOWED_IPS}
  fi
  sed -E \
    "s|^[[:space:]]*AllowedIPs[[:space:]]*=.*$|AllowedIPs = ${allowed_ips}|" \
    "${input}" >"${output}"
}
