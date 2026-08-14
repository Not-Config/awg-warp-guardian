#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
cleanup() {
  rm -rf -- "${TEST_DIR}"
}
trap cleanup EXIT

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >>"${IP_LOG}"' \
  >"${TEST_DIR}/ip"
chmod 755 "${TEST_DIR}/ip"

IP_LOG="${TEST_DIR}/ip.log" \
IP_COMMAND="${TEST_DIR}/ip" \
  "${PROJECT_DIR}/src/lan-rules" up

grep -Fq -- '-4 rule add pref 10000 to 10.0.0.0/8 lookup main' \
  "${TEST_DIR}/ip.log"
grep -Fq -- '-4 rule add pref 10003 to 172.16.0.0/12 lookup main' \
  "${TEST_DIR}/ip.log"
grep -Fq -- '-4 rule add pref 10004 to 192.168.0.0/16 lookup main' \
  "${TEST_DIR}/ip.log"

: >"${TEST_DIR}/ip.log"
IP_LOG="${TEST_DIR}/ip.log" \
IP_COMMAND="${TEST_DIR}/ip" \
  "${PROJECT_DIR}/src/lan-rules" down

grep -Fq -- '-4 rule del pref 10000 to 10.0.0.0/8 lookup main' \
  "${TEST_DIR}/ip.log"
grep -Fq -- '-4 rule del pref 10004 to 192.168.0.0/16 lookup main' \
  "${TEST_DIR}/ip.log"
if grep -Fq -- ' rule add ' "${TEST_DIR}/ip.log"; then
  echo "down unexpectedly added a policy rule" >&2
  exit 1
fi

echo "LAN rule tests passed"
