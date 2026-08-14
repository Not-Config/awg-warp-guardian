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
  'if [[ $* == *" route get "* ]]; then' \
  '  printf "%s\n" "$4 via 192.168.1.1 dev ens18 src 192.168.1.251"' \
  'fi' \
  >"${TEST_DIR}/ip"
chmod 755 "${TEST_DIR}/ip"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "162.159.192.2 STREAM example.test"' \
  >"${TEST_DIR}/getent"
chmod 755 "${TEST_DIR}/getent"

IP_LOG="${TEST_DIR}/ip.log" \
IP_COMMAND="${TEST_DIR}/ip" \
GETENT_COMMAND="${TEST_DIR}/getent" \
  "${PROJECT_DIR}/src/route-endpoint" up 162.159.192.1
grep -Fq -- '-4 route get 162.159.192.1' "${TEST_DIR}/ip.log"
grep -Fq -- '-4 route replace 162.159.192.1/32 via 192.168.1.1 dev ens18 table main proto 186' \
  "${TEST_DIR}/ip.log"

: >"${TEST_DIR}/ip.log"
IP_LOG="${TEST_DIR}/ip.log" \
IP_COMMAND="${TEST_DIR}/ip" \
GETENT_COMMAND="${TEST_DIR}/getent" \
  "${PROJECT_DIR}/src/route-endpoint" down 162.159.192.1
grep -Fq -- '-4 route del 162.159.192.1/32 table main proto 186' \
  "${TEST_DIR}/ip.log"

: >"${TEST_DIR}/ip.log"
IP_LOG="${TEST_DIR}/ip.log" \
IP_COMMAND="${TEST_DIR}/ip" \
GETENT_COMMAND="${TEST_DIR}/getent" \
  "${PROJECT_DIR}/src/route-endpoint" up example.test
grep -Fq -- '-4 route replace 162.159.192.2/32 via 192.168.1.1 dev ens18 table main proto 186' \
  "${TEST_DIR}/ip.log"

printf '%s\n' \
  '[Interface]' \
  'PrivateKey = hidden' \
  '' \
  '[Peer]' \
  'Endpoint = example.test:500' \
  >"${TEST_DIR}/candidate.conf"
: >"${TEST_DIR}/ip.log"
IP_LOG="${TEST_DIR}/ip.log" \
IP_COMMAND="${TEST_DIR}/ip" \
GETENT_COMMAND="${TEST_DIR}/getent" \
  "${PROJECT_DIR}/src/route-endpoint" up-config \
  "${TEST_DIR}/candidate.conf" "${TEST_DIR}/endpoint.state"
grep -Fq '162.159.192.2' "${TEST_DIR}/endpoint.state"
grep -Fq -- '-4 route replace 162.159.192.2/32 via 192.168.1.1 dev ens18 table main proto 186' \
  "${TEST_DIR}/ip.log"

: >"${TEST_DIR}/ip.log"
IP_LOG="${TEST_DIR}/ip.log" \
IP_COMMAND="${TEST_DIR}/ip" \
GETENT_COMMAND="${TEST_DIR}/getent" \
  "${PROJECT_DIR}/src/route-endpoint" down-state "${TEST_DIR}/endpoint.state"
grep -Fq -- '-4 route del 162.159.192.2/32 table main proto 186' \
  "${TEST_DIR}/ip.log"
[[ ! -e ${TEST_DIR}/endpoint.state ]]

echo "Endpoint route tests passed"
