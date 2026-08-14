#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
cleanup() {
  rm -rf -- "${TEST_DIR}"
}
trap cleanup EXIT

assert_rejected_api() {
  local api_url=$1
  local status

  set +e
  WARP_API_BASE_URL="${api_url}" \
    "${PROJECT_DIR}/src/generate-warp-config" "${TEST_DIR}/invalid.conf" \
    >/dev/null 2>"${TEST_DIR}/error.log"
  status=$?
  set -e
  if [[ ${status} -ne 65 ]]; then
    echo "expected invalid API URL to exit 65, got ${status}" >&2
    sed -n '1,5p' "${TEST_DIR}/error.log" >&2
    exit 1
  fi
}

assert_rejected_api "http://mirror.example/v0i1909051800"
assert_rejected_api "https://mirror.example/api?target=other"
assert_rejected_api "https://mirror.example:99999/api"

if [[ -e ${TEST_DIR}/invalid.conf ]]; then
  echo "invalid API URL unexpectedly produced a config" >&2
  exit 1
fi

mkdir -p "${TEST_DIR}/fixture/src" "${TEST_DIR}/fixture/vendor"
cp "${PROJECT_DIR}/src/generate-warp-config" \
  "${TEST_DIR}/fixture/src/generate-warp-config"
cp "${PROJECT_DIR}/src/route-policy.sh" \
  "${TEST_DIR}/fixture/src/route-policy.sh"
chmod 755 "${TEST_DIR}/fixture/src/generate-warp-config"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -Eeuo pipefail' \
  'printf "[generator] POST /reg: successful HTTP response received.\n" >&2' \
  'printf "%s\n" "[Interface]" "PrivateKey = LOCAL_TEST_SECRET" "Address = 172.16.0.2/32" "" "[Peer]" "PublicKey = TEST_PEER" "AllowedIPs = 0.0.0.0/0" "Endpoint = 162.159.192.1:500" > warp.conf' \
  >"${TEST_DIR}/fixture/vendor/warp_generator.sh"
chmod 755 "${TEST_DIR}/fixture/vendor/warp_generator.sh"

WARP_API_BASE_URL=https://mirror.example/v0i1909051800 \
  "${TEST_DIR}/fixture/src/generate-warp-config" \
  "${TEST_DIR}/generated.conf" \
  >"${TEST_DIR}/stdout.log" 2>"${TEST_DIR}/progress.log"

grep -Fq '[generator] Registration API: https://mirror.example/v0i1909051800' \
  "${TEST_DIR}/progress.log"
grep -Fq '[generator] POST /reg: successful HTTP response received.' \
  "${TEST_DIR}/progress.log"
grep -Fq '[generator] Configuration assembled locally and saved' \
  "${TEST_DIR}/progress.log"
if grep -Fq 'LOCAL_TEST_SECRET' "${TEST_DIR}/progress.log"; then
  echo "generator progress leaked a private key" >&2
  exit 1
fi
grep -Fq 'PrivateKey = LOCAL_TEST_SECRET' "${TEST_DIR}/generated.conf"
grep -Fq 'AllowedIPs = 0.0.0.0/0, 2000::/3' "${TEST_DIR}/generated.conf"
grep -Fq 'PreUp = /usr/local/sbin/awg-warp-lan-rules up' \
  "${TEST_DIR}/generated.conf"
grep -Fq 'PostDown = /usr/local/sbin/awg-warp-lan-rules down' \
  "${TEST_DIR}/generated.conf"
if grep -Fq 'AllowedIPs = 0.0.0.0/0, ::/0' "${TEST_DIR}/generated.conf"; then
  echo "LAN-excluded config still contains a full IPv6 tunnel" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${PROJECT_DIR}/src/route-policy.sh"
awg_apply_route_policy \
  "${TEST_DIR}/generated.conf" "${TEST_DIR}/reapplied.conf" 1
asserted_hooks=$(grep -Fc '/awg-warp-lan-rules' \
  "${TEST_DIR}/reapplied.conf")
if [[ ${asserted_hooks} -ne 2 ]]; then
  echo "LAN policy reapplication duplicated or removed managed hooks" >&2
  exit 1
fi

WARP_EXCLUDE_LAN=0 \
WARP_API_BASE_URL=https://mirror.example/v0i1909051800 \
  "${TEST_DIR}/fixture/src/generate-warp-config" \
  "${TEST_DIR}/full-tunnel.conf" \
  >/dev/null 2>"${TEST_DIR}/full-tunnel-progress.log"
grep -Fq 'AllowedIPs = 0.0.0.0/0, ::/0' "${TEST_DIR}/full-tunnel.conf"
if grep -Fq '/awg-warp-lan-rules' "${TEST_DIR}/full-tunnel.conf"; then
  echo "full-tunnel config unexpectedly contains LAN policy hooks" >&2
  exit 1
fi
grep -Fq '[generator] LAN exclusion: disabled' \
  "${TEST_DIR}/full-tunnel-progress.log"

set +e
WARP_EXCLUDE_LAN=2 \
  "${PROJECT_DIR}/src/generate-warp-config" "${TEST_DIR}/bad-lan-mode.conf" \
  >/dev/null 2>"${TEST_DIR}/bad-lan-mode.log"
status=$?
set -e
if [[ ${status} -ne 65 ]]; then
  echo "expected invalid LAN mode to exit 65, got ${status}" >&2
  exit 1
fi

echo "Generator wrapper tests passed"
