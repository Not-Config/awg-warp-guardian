#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "${PROJECT_DIR}/src/install-tui.sh"

if ! declare -f tui_dialog | grep -q 'TERM=linux whiptail'; then
  echo "TUI must use normal cursor-key sequences for SSH compatibility" >&2
  exit 1
fi

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
tui_valid_generator_site_url 'https://mirror.example/warp-gen'
! tui_valid_generator_site_url 'http://mirror.example/warp-gen'
! tui_valid_generator_site_url 'https://user:secret@mirror.example/warp-gen'
! tui_valid_generator_site_url 'https://mirror.example:99999/warp-gen'
tui_valid_generator_proxy 'http://127.0.0.1:8080'
! tui_valid_generator_proxy 'http://127.0.0.1:99999'
! tui_valid_generator_proxy 'socks5://127.0.0.1:1080'
assert_equal 30 "$(tui_interval_seconds 30s)"
assert_equal 120 "$(tui_interval_seconds 2min)"
assert_equal 3600 "$(tui_interval_seconds 1h)"
tui_valid_interval 30s
! tui_valid_interval 29s
! tui_valid_interval '2 minutes'
tui_valid_initial_attempts 1
tui_valid_initial_attempts 10
tui_valid_initial_attempts 20
! tui_valid_initial_attempts 0
! tui_valid_initial_attempts 21
! tui_valid_initial_attempts invalid

tui_dialog() {
  case "$*" in
    *"AWG WARP Guardian — профиль"*)
      [[ " $* " == *" --notags "* ]] || return 1
      [[ "$*" == *"Получить и проверить новый профиль с warp-gen (рекомендуется)"* ]] || return 1
      [[ "$*" == *"Выбрать один из найденных на сервере старых .conf"* ]] || return 1
      [[ "$*" != *"profile_0"* ]] || return 1
      printf 'new\n'
      ;;
    *"Новый WARP-профиль"*) printf 'awg-warp\n' ;;
    *) return 1 ;;
  esac
}

guardian_config=/nonexistent/guardian.env
if tui_select_profile; then
  echo "new profile selection unexpectedly skipped configuration" >&2
  exit 1
else
  profile_result=$?
fi
assert_equal 1 "${profile_result}"
assert_equal awg-warp "${interface}"
assert_equal '' "${config_path}"

tui_dialog() {
  case "$*" in
    *--checklist*) printf '"github" "youtube" "cloudflare"\n' ;;
    *"Частота проверки"*) printf '5min\n' ;;
    *"Попытки получения профиля"*) printf '10\n' ;;
    *"Доступ к локальной сети"*) printf 'exclude\n' ;;
    *"Вариант AWG"*) printf '1\n' ;;
    *"DNS из warp-gen"*) printf 'cf\n' ;;
    *"Сервер из warp-gen"*) printf 'def\n' ;;
    *"IPv6"*) printf 'yes\n' ;;
    *"PersistentKeepalive"*) printf 'off\n' ;;
    *"Источник генерации"*) printf 'default\n' ;;
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
tui_select_interval
assert_equal 5min "${check_interval}"
tui_select_lan_mode
assert_equal 1 "${exclude_lan}"
tui_select_warp_parameters
assert_equal 1 "${awg_variant}"
assert_equal cf "${dns_preset}"
assert_equal def "${server_preset}"
assert_equal 1 "${warp_ipv6}"
assert_equal 0 "${warp_keepalive}"
tui_select_generator_source
assert_equal 'https://warp-gen.github.io' "${generator_site_url}"
assert_equal '' "${generator_https_proxy}"
tui_select_initial_attempts
assert_equal 10 "${initial_generation_attempts}"

if tui_calculate_quorum unsupported 3 >/dev/null 2>&1; then
  echo "unsupported quorum mode was accepted" >&2
  exit 1
fi

echo "TUI helper tests passed"
