#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${PROJECT_DIR}/src/install-tui.sh"

assert_equal() {
  local expected=$1
  local actual=$2

  if [[ ${actual} != "${expected}" ]]; then
    echo "expected '${expected}', got '${actual}'" >&2
    exit 1
  fi
}

assert_equal 1 "$(tui_calculate_quorum one 6)"
assert_equal 6 "$(tui_calculate_quorum all 6)"
assert_equal 2 "$(tui_calculate_quorum majority 3)"
assert_equal 3 "$(tui_calculate_quorum majority 4)"
assert_equal 3 "$(tui_calculate_quorum majority 5)"

tui_valid_interface awg-warp
! tui_valid_interface interface-name-too-long
tui_valid_endpoint 162.159.192.1:500
tui_valid_endpoint '[2606:4700:d0::a29f:c001]:2408'
! tui_valid_endpoint host.example:0
! tui_valid_endpoint host.example:65536
tui_valid_url 'https://example.org/health?source=tui&ok=1'
! tui_valid_url 'ftp://example.org/'
! tui_valid_url 'https://example.org/bad path'

tui_dialog() {
  case "$*" in
    *--checklist*) printf '"github" "youtube" "cloudflare"\n' ;;
    *--radiolist*) printf 'majority\n' ;;
    *) return 1 ;;
  esac
}

custom_urls=()
tui_select_sites
assert_equal 3 "${#custom_urls[@]}"
assert_equal 'https://github.com/' "${custom_urls[0]}"
assert_equal 'https://www.youtube.com/generate_204' "${custom_urls[1]}"
assert_equal 'https://www.cloudflare.com/cdn-cgi/trace' "${custom_urls[2]}"
tui_select_quorum
assert_equal 2 "${check_quorum}"

if tui_calculate_quorum unsupported 3 >/dev/null 2>&1; then
  echo "unsupported quorum mode was accepted" >&2
  exit 1
fi

echo "TUI helper tests passed"
