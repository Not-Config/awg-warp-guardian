#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
cleanup() {
  rm -rf -- "${TEST_DIR}"
}
trap cleanup EXIT

cat >"${TEST_DIR}/script.js" <<'EOF'
function generateRandomEndpoint() {
  const ports = [500];
  if (selectedServer === 'def') {
    const prefixes = ["162.159.192."];
  }
  const serverMap = {'NL': 'nl.example.test', 'ltePL': 'lte.example.test'};
}
const fetchFullConfig = async () => {
  const endpoints = ['https://data.example.test/identity'];
};
const fetchFullConfigMSQ = async () => {};
// AWGm1
if (custom) {i1Value = custom} else {i1Value = 'I1 = <b 0x0102>'}
// AWGm2
if (custom) {i1Value = custom} else {i1Value = 'I1 = <b 0x0304>'}
// AWGm3
if (custom) {i1Value = custom} else {i1Value = 'I1 = <b 0x0506>\nI2 = <b 0x0708>'}
function getSelectedDNS() {
  if (document.getElementById('cf').checked) { return "1.1.1.1, 1.0.0.1, 2606:4700:4700::1111"; }
  else if (document.getElementById('google').checked) { return "8.8.8.8, 2001:4860:4860::8888"; }
}
function getSelectedSites() {
  const toggleCheckbox = document.getElementById('rules');
  if (toggleCheckbox && toggleCheckbox.checked) {
    return "1.0.0.0/8, 2.0.0.0/7, ::/1, 8000::/2";
  }
  return "0.0.0.0/0, ::/0";
}
const modal = null;
EOF

cat >"${TEST_DIR}/identity.json" <<'EOF'
{
  "privKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  "peer_pub": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=",
  "client_ipv4": "172.16.0.2",
  "client_ipv6": "2606:4700:110:8bc6::2"
}
EOF

cat >"${TEST_DIR}/registration.json" <<'EOF'
{
  "result": {
    "config": {
      "peers": [
        {"public_key": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="}
      ],
      "interface": {
        "addresses": {
          "v4": "172.16.0.2/32",
          "v6": "2606:4700:110:8bc6::2/128"
        }
      }
    }
  }
}
EOF

cat >"${TEST_DIR}/fake-wg" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
  genkey) printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' ;;
  pubkey)
    read -r private_key
    [[ ${private_key} == AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= ]]
    printf '%s\n' 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC='
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "${TEST_DIR}/fake-wg"

assert_rejected_site() {
  local site_url=$1
  local status
  set +e
  WARP_GENERATOR_SITE_URL="${site_url}" \
  WARP_GENERATOR_SCRIPT_FILE="${TEST_DIR}/script.js" \
  WARP_GENERATOR_DATA_FILE="${TEST_DIR}/identity.json" \
    "${PROJECT_DIR}/src/generate-warp-config" "${TEST_DIR}/invalid.conf" \
    >/dev/null 2>"${TEST_DIR}/error.log"
  status=$?
  set -e
  [[ ${status} -eq 65 ]] || {
    echo "expected invalid site URL to exit 65, got ${status}" >&2
    exit 1
  }
}

assert_rejected_site "http://warp-gen.example"
assert_rejected_site "https://warp-gen.example/page?unsafe=1"

WARP_GENERATOR_SITE_URL=https://warp-gen.example \
WARP_GENERATOR_SCRIPT_FILE="${TEST_DIR}/script.js" \
WARP_GENERATOR_DATA_FILE="${TEST_DIR}/identity.json" \
WARP_AWG_VARIANT=3 \
WARP_DNS_PRESET=google \
WARP_SERVER_PRESET=def \
WARP_IPV6=0 \
WARP_KEEPALIVE=25 \
WARP_EXCLUDE_LAN=1 \
  "${PROJECT_DIR}/src/generate-warp-config" "${TEST_DIR}/generated.conf" \
  >"${TEST_DIR}/stdout.log" 2>"${TEST_DIR}/progress.log"

grep -Fq '[generator] Generator site: https://warp-gen.example' "${TEST_DIR}/progress.log"
grep -Fq '[generator] Requesting a fresh identity bundle (1/1): fixture' "${TEST_DIR}/progress.log"
grep -Eq '\[generator\] Endpoint selected by current warp-gen rules: 162\.159\.192\.([1-9]|10):500' "${TEST_DIR}/progress.log"
if grep -Fq 'AAAAAAAAAAAAAAAA' "${TEST_DIR}/progress.log"; then
  echo "generator progress leaked a private key" >&2
  exit 1
fi
grep -Fq 'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "${TEST_DIR}/generated.conf"
grep -Fq 'Address = 172.16.0.2' "${TEST_DIR}/generated.conf"
! grep -Fq '2606:4700:110:8bc6::2' "${TEST_DIR}/generated.conf"
grep -Fq 'DNS = 8.8.8.8' "${TEST_DIR}/generated.conf"
! grep -Fq '2001:4860:4860::8888' "${TEST_DIR}/generated.conf"
grep -Fq 'I1 = <b 0x0506>' "${TEST_DIR}/generated.conf"
grep -Fq 'I2 = <b 0x0708>' "${TEST_DIR}/generated.conf"
grep -Fq 'AllowedIPs = 1.0.0.0/8, 2.0.0.0/7, ::/1, 8000::/2' "${TEST_DIR}/generated.conf"
grep -Eq '^Endpoint = 162\.159\.192\.([1-9]|10):500$' "${TEST_DIR}/generated.conf"
grep -Fq 'PersistentKeepalive = 25' "${TEST_DIR}/generated.conf"
if grep -Eq 'PreUp|PostDown|awg-warp-route-endpoint' "${TEST_DIR}/generated.conf"; then
  echo "generator modified the warp-gen profile with local route hooks" >&2
  exit 1
fi
[[ $(stat -c %a "${TEST_DIR}/generated.conf") == 600 ]]

WARP_GENERATOR_SITE_URL=https://warp-gen.example \
WARP_GENERATOR_SCRIPT_FILE="${TEST_DIR}/script.js" \
WARP_REGISTRATION_FILE="${TEST_DIR}/registration.json" \
WARP_KEY_COMMAND="${TEST_DIR}/fake-wg" \
WARP_AWG_VARIANT=1 \
WARP_DNS_PRESET=cf \
WARP_SERVER_PRESET=NL \
WARP_IPV6=1 \
WARP_KEEPALIVE=0 \
WARP_EXCLUDE_LAN=1 \
  "${PROJECT_DIR}/src/generate-warp-config" "${TEST_DIR}/locally-registered.conf" \
  >"${TEST_DIR}/local.stdout.log" 2>"${TEST_DIR}/local.progress.log"

grep -Fq '[generator] Fresh identity received from registration fixture; secrets hidden' \
  "${TEST_DIR}/local.progress.log"
grep -Fq 'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
  "${TEST_DIR}/locally-registered.conf"
grep -Fq 'PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' \
  "${TEST_DIR}/locally-registered.conf"
grep -Fq 'Address = 172.16.0.2/32, 2606:4700:110:8bc6::2/128' \
  "${TEST_DIR}/locally-registered.conf"
grep -Fq 'Endpoint = nl.example.test:500' "${TEST_DIR}/locally-registered.conf"
if grep -Fq 'CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=' \
  "${TEST_DIR}/local.progress.log"; then
  echo "generator progress leaked a locally generated public key" >&2
  exit 1
fi

echo "Generator wrapper tests passed"
