#!/usr/bin/env bash

# This is the complement used by the known-working warp-gen "exclude LAN"
# profile: no default route, RFC1918, loopback, IPv4 link-local, or 240/4.
# A separate /32 main-table route keeps the WARP endpoint outside the tunnel.
AWG_LAN_EXCLUDED_ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/3, 96.0.0.0/4, 112.0.0.0/5, 120.0.0.0/6, 124.0.0.0/7, 126.0.0.0/8, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/8, 169.0.0.0/9, 169.128.0.0/10, 169.192.0.0/11, 169.224.0.0/12, 169.240.0.0/13, 169.248.0.0/14, 169.252.0.0/15, 169.255.0.0/16, 170.0.0.0/7, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 224.0.0.0/4"
AWG_FULL_TUNNEL_ALLOWED_IPS="0.0.0.0/0, ::/0"
AWG_LAN_RULES_COMMAND="/usr/local/sbin/awg-warp-lan-rules"
AWG_ENDPOINT_ROUTE_COMMAND="/usr/local/sbin/awg-warp-route-endpoint"
readonly AWG_LAN_EXCLUDED_ALLOWED_IPS AWG_FULL_TUNNEL_ALLOWED_IPS
readonly AWG_LAN_RULES_COMMAND AWG_ENDPOINT_ROUTE_COMMAND

awg_valid_lan_mode() {
  [[ $1 == 0 || $1 == 1 ]]
}

awg_apply_route_policy() {
  local input=$1
  local output=$2
  local exclude_lan=$3
  local allowed_ips allowed_count endpoint endpoint_count endpoint_host peer_count

  awg_valid_lan_mode "${exclude_lan}" || return 64
  allowed_count=$(grep -Ec '^[[:space:]]*AllowedIPs[[:space:]]*=' "${input}")
  peer_count=$(grep -Eic '^[[:space:]]*\[Peer\][[:space:]]*$' "${input}")
  endpoint_count=$(grep -Ec '^[[:space:]]*Endpoint[[:space:]]*=' "${input}")
  [[ ${allowed_count} -eq 1 && ${peer_count} -ge 1 && ${endpoint_count} -eq 1 ]] || return 65
  endpoint=$(sed -n -E \
    's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
    "${input}" | head -n 1)
  if [[ ${endpoint} =~ ^([A-Za-z0-9.-]+):[0-9]{1,5}$ ]]; then
    endpoint_host=${BASH_REMATCH[1]}
  elif [[ ${endpoint} =~ ^\[[0-9A-Fa-f:]+\]:[0-9]{1,5}$ ]]; then
    endpoint_host=""
  else
    return 65
  fi

  if [[ ${exclude_lan} == 1 ]]; then
    allowed_ips=${AWG_LAN_EXCLUDED_ALLOWED_IPS}
  else
    allowed_ips=${AWG_FULL_TUNNEL_ALLOWED_IPS}
  fi
  awk \
    -v allowed_ips="${allowed_ips}" \
    -v exclude_lan="${exclude_lan}" \
    -v endpoint_command="${AWG_ENDPOINT_ROUTE_COMMAND}" \
    -v endpoint_host="${endpoint_host}" \
    -v lan_command="${AWG_LAN_RULES_COMMAND}" '
      $0 ~ "^[[:space:]]*PreUp[[:space:]]*=[[:space:]]*" lan_command "[[:space:]]+up[[:space:]]*$" { next }
      $0 ~ "^[[:space:]]*PostDown[[:space:]]*=[[:space:]]*" lan_command "[[:space:]]+down[[:space:]]*$" { next }
      $0 ~ "^[[:space:]]*PreUp[[:space:]]*=[[:space:]]*" endpoint_command "[[:space:]]+up[[:space:]]+" { next }
      $0 ~ "^[[:space:]]*PostDown[[:space:]]*=[[:space:]]*" endpoint_command "[[:space:]]+down[[:space:]]+" { next }
      /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
        print "AllowedIPs = " allowed_ips
        next
      }
      !inserted && /^[[:space:]]*\[Peer\][[:space:]]*$/ {
        if (exclude_lan == "1" && endpoint_host != "") {
          print "PreUp = " endpoint_command " up " endpoint_host
          print "PostDown = " endpoint_command " down " endpoint_host
          print ""
        }
        inserted = 1
      }
      { print }
    ' "${input}" >"${output}"
}
