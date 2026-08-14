#!/usr/bin/env bash

# IPv4 stays a wg-quick full tunnel so its fwmark keeps the WARP endpoint
# reachable through the physical route. PreUp policy rules send private/local
# IPv4 destinations to the unsuppressed main table before wg-quick's rules.
# Global IPv6 uses 2000::/3, leaving ULA and link-local ranges outside WARP.
AWG_LAN_EXCLUDED_ALLOWED_IPS="0.0.0.0/0, 2000::/3"
AWG_FULL_TUNNEL_ALLOWED_IPS="0.0.0.0/0, ::/0"
AWG_LAN_RULES_COMMAND="/usr/local/sbin/awg-warp-lan-rules"
readonly AWG_LAN_EXCLUDED_ALLOWED_IPS AWG_FULL_TUNNEL_ALLOWED_IPS
readonly AWG_LAN_RULES_COMMAND

awg_valid_lan_mode() {
  [[ $1 == 0 || $1 == 1 ]]
}

awg_apply_route_policy() {
  local input=$1
  local output=$2
  local exclude_lan=$3
  local allowed_ips allowed_count peer_count

  awg_valid_lan_mode "${exclude_lan}" || return 64
  allowed_count=$(grep -Ec '^[[:space:]]*AllowedIPs[[:space:]]*=' "${input}")
  peer_count=$(grep -Eic '^[[:space:]]*\[Peer\][[:space:]]*$' "${input}")
  [[ ${allowed_count} -eq 1 && ${peer_count} -ge 1 ]] || return 65

  if [[ ${exclude_lan} == 1 ]]; then
    allowed_ips=${AWG_LAN_EXCLUDED_ALLOWED_IPS}
  else
    allowed_ips=${AWG_FULL_TUNNEL_ALLOWED_IPS}
  fi
  awk \
    -v allowed_ips="${allowed_ips}" \
    -v exclude_lan="${exclude_lan}" \
    -v command="${AWG_LAN_RULES_COMMAND}" '
      $0 ~ "^[[:space:]]*PreUp[[:space:]]*=[[:space:]]*" command "[[:space:]]+up[[:space:]]*$" { next }
      $0 ~ "^[[:space:]]*PostDown[[:space:]]*=[[:space:]]*" command "[[:space:]]+down[[:space:]]*$" { next }
      /^[[:space:]]*AllowedIPs[[:space:]]*=/ {
        print "AllowedIPs = " allowed_ips
        next
      }
      !inserted && /^[[:space:]]*\[Peer\][[:space:]]*$/ {
        if (exclude_lan == "1") {
          print "PreUp = " command " up"
          print "PostDown = " command " down"
          print ""
        }
        inserted = 1
      }
      { print }
    ' "${input}" >"${output}"
}
