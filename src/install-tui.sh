#!/usr/bin/env bash

# Interactive frontend for install.sh. This file only defines functions and is
# intentionally safe to source from tests.

tui_dialog() {
  whiptail "$@" 3>&1 1>&2 2>&3
}

tui_calculate_quorum() {
  local mode=$1
  local count=$2

  case "${mode}" in
    all)
      printf '%s\n' "${count}"
      ;;
    one)
      printf '1\n'
      ;;
    majority)
      printf '%s\n' "$((count / 2 + 1))"
      ;;
    *)
      return 64
      ;;
  esac
}

tui_valid_interface() {
  [[ $1 =~ ^[A-Za-z0-9_=+.-]{1,15}$ ]]
}

tui_valid_endpoint() {
  local endpoint=$1
  local port

  [[ ${endpoint} =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9.-]+):[0-9]{1,5}$ ]] || return 1
  port=${endpoint##*:}
  ((10#${port} >= 1 && 10#${port} <= 65535))
}

tui_valid_url() {
  [[ $1 =~ ^https?://[A-Za-z0-9:/?\&._=%+#@~-]+$ ]]
}

tui_add_unique_path() {
  local candidate=$1
  local existing

  [[ -f ${candidate} ]] || return 0
  for existing in "${tui_profiles[@]}"; do
    [[ ${existing} == "${candidate}" ]] && return 0
  done
  tui_profiles+=("${candidate}")
}

tui_profile_description() {
  local profile=$1
  local endpoint
  local name

  name=$(basename -- "${profile}" .conf)
  endpoint=$(sed -n -E \
    's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
    "${profile}" | head -n 1)
  if [[ -n ${endpoint} ]]; then
    printf '%s — %s' "${name}" "${endpoint}"
  else
    printf '%s — %s' "${name}" "${profile}"
  fi
}

tui_confirm_keep_settings() {
  local current_interface current_config summary

  current_interface=$(sed -n 's/^INTERFACE=//p' "${guardian_config}" | head -n 1)
  current_config=$(sed -n 's/^CONFIG_PATH=//p' "${guardian_config}" | head -n 1)
  current_interface=${current_interface%\"}
  current_interface=${current_interface#\"}
  current_config=${current_config%\"}
  current_config=${current_config#\"}
  summary=$(printf \
    'Будут обновлены файлы AWG WARP Guardian.\n\nИнтерфейс: %s\nПрофиль: %s\nСайты и остальные настройки останутся без изменений.' \
    "${current_interface:-не определён}" "${current_config:-не определён}")

  if tui_dialog --title "Обновление AWG WARP Guardian" \
    --yes-button "Продолжить" --no-button "Назад" \
    --yesno "${summary}" 15 82; then
    identity_option_set=0
    settings_option_set=0
    reconfigure=0
    return 0
  fi
  return 2
}

tui_select_profile() {
  local -a menu_items=()
  local current_config candidate description choice index

  tui_profiles=()
  if [[ -s ${guardian_config} ]]; then
    current_config=$(sed -n 's/^CONFIG_PATH=//p' "${guardian_config}" | head -n 1)
    current_config=${current_config%\"}
    current_config=${current_config#\"}
    [[ -n ${current_config} ]] && tui_add_unique_path "${current_config}"
    menu_items+=("keep" "Обновить программу, сохранить текущие настройки (рекомендуется)")
  fi

  for candidate in /etc/amnezia/amneziawg/*.conf /etc/amneziawg/*.conf; do
    tui_add_unique_path "${candidate}"
  done
  for index in "${!tui_profiles[@]}"; do
    description=$(tui_profile_description "${tui_profiles[index]}")
    menu_items+=("profile_${index}" "Использовать: ${description}")
  done
  menu_items+=(
    "new" "Создать новый стандартный профиль Cloudflare WARP"
    "custom_endpoint" "Создать WARP-профиль со своими endpoint-ами"
    "import" "Указать существующий .conf вручную"
  )

  if ! choice=$(tui_dialog --title "AWG WARP Guardian — профиль" \
    --menu "Какую конфигурацию установить и контролировать?" \
    22 92 12 "${menu_items[@]}"); then
    return 130
  fi

  case "${choice}" in
    keep)
      tui_confirm_keep_settings
      return $?
      ;;
    profile_*)
      index=${choice#profile_}
      config_path=${tui_profiles[index]}
      interface=$(basename -- "${config_path}" .conf)
      custom_endpoints=()
      ;;
    import)
      if ! config_path=$(tui_dialog --title "Существующий профиль" \
        --inputbox "Введите абсолютный путь к файлу .conf:" \
        11 86 "/etc/amnezia/amneziawg/awg-warp.conf"); then
        return 130
      fi
      interface=$(basename -- "${config_path}" .conf)
      if [[ ${config_path} != /* || ${config_path} != *.conf || ! -s ${config_path} ]]; then
        tui_dialog --title "Профиль не найден" \
          --msgbox "Нужен существующий непустой .conf с абсолютным путём:\n${config_path}" 11 84
        return 2
      fi
      if ! tui_valid_interface "${interface}"; then
        tui_dialog --title "Некорректное имя интерфейса" \
          --msgbox "Имя файла без .conf должно содержать не более 15 символов: A-Z, a-z, 0-9, _=+.-" 10 80
        return 2
      fi
      custom_endpoints=()
      ;;
    new|custom_endpoint)
      while true; do
        if ! interface=$(tui_dialog --title "Новый WARP-профиль" \
          --inputbox "Имя сетевого интерфейса (до 15 символов):" \
          11 72 "awg-warp"); then
          return 130
        fi
        if tui_valid_interface "${interface}"; then
          break
        fi
        tui_dialog --title "Некорректное имя интерфейса" \
          --msgbox "Допустимы 1–15 символов: A-Z, a-z, 0-9, _=+.-" 9 66
      done
      config_path=""
      custom_endpoints=()
      if [[ ${choice} == custom_endpoint ]]; then
        local endpoint_text endpoint endpoints_valid
        while true; do
          if ! endpoint_text=$(tui_dialog --title "WARP endpoint-ы" \
            --inputbox "Введите HOST:PORT через пробел или запятую:" \
            12 86 "162.159.192.1:500"); then
            return 130
          fi
          endpoint_text=${endpoint_text//,/ }
          read -r -a custom_endpoints <<<"${endpoint_text}"
          endpoints_valid=1
          ((${#custom_endpoints[@]})) || endpoints_valid=0
          for endpoint in "${custom_endpoints[@]}"; do
            tui_valid_endpoint "${endpoint}" || endpoints_valid=0
          done
          ((endpoints_valid == 1)) && break
          tui_dialog --title "Некорректный endpoint" \
            --msgbox "Используйте формат HOST:PORT, например 162.159.192.1:500. Порт: 1–65535." 10 80
        done
      fi
      ;;
  esac

  identity_option_set=1
  settings_option_set=1
  reconfigure=1
  return 1
}

tui_select_sites() {
  local selection token custom_text url invalid_url
  local -a selected_urls=()

  if ! selection=$(tui_dialog --title "Проверка доступности" \
    --checklist "Какие сайты должны открываться именно через VPN?\nПробел — выбрать, Enter — продолжить." \
    22 92 10 \
    github "GitHub" ON \
    telegram "Telegram" ON \
    youtube "YouTube" OFF \
    discord "Discord" OFF \
    google "Google" OFF \
    cloudflare "Cloudflare Trace (также проверяет warp=on)" ON \
    custom "Добавить свои URL" OFF); then
    return 130
  fi

  for token in ${selection}; do
    token=${token//\"/}
    case "${token}" in
      github) selected_urls+=("https://github.com/") ;;
      telegram) selected_urls+=("https://telegram.org/") ;;
      youtube) selected_urls+=("https://www.youtube.com/generate_204") ;;
      discord) selected_urls+=("https://discord.com/") ;;
      google) selected_urls+=("https://www.google.com/generate_204") ;;
      cloudflare) selected_urls+=("https://www.cloudflare.com/cdn-cgi/trace") ;;
      custom)
        if ! custom_text=$(tui_dialog --title "Свои адреса" \
          --inputbox "Введите полные URL через пробел или запятую:" \
          12 92 "https://example.org/"); then
          return 130
        fi
        custom_text=${custom_text//,/ }
        for url in ${custom_text}; do
          selected_urls+=("${url}")
        done
        ;;
    esac
  done

  if ((${#selected_urls[@]} == 0)); then
    tui_dialog --title "Нужен хотя бы один сайт" \
      --msgbox "Выберите минимум один адрес для проверки." 9 58
    return 3
  fi
  invalid_url=""
  for url in "${selected_urls[@]}"; do
    if ! tui_valid_url "${url}"; then
      invalid_url=${url}
      break
    fi
  done
  if [[ -n ${invalid_url} ]]; then
    tui_dialog --title "Некорректный URL" \
      --msgbox "Нужен полный HTTP/HTTPS URL без пробелов:\n${invalid_url}" 10 84
    return 3
  fi
  custom_urls=("${selected_urls[@]}")
  check_urls="${custom_urls[*]}"
}

tui_select_quorum() {
  local quorum_mode

  if ! quorum_mode=$(tui_dialog --title "Условие работоспособности" \
    --radiolist "Когда считать VPN работоспособным?" \
    17 88 6 \
    majority "Работает большинство выбранных сайтов (рекомендуется)" ON \
    all "Работают все выбранные сайты" OFF \
    one "Работает хотя бы один выбранный сайт" OFF); then
    return 130
  fi
  check_quorum=$(tui_calculate_quorum "${quorum_mode}" "${#custom_urls[@]}")
}

tui_confirm_install() {
  local endpoint_summary site_lines summary url

  if ((${#custom_endpoints[@]})); then
    endpoint_summary=$(IFS=,; printf '%s' "${custom_endpoints[*]}")
  else
    endpoint_summary="из профиля или стандартный Cloudflare"
  fi
  site_lines=""
  for url in "${custom_urls[@]}"; do
    site_lines+="\n • ${url}"
  done
  summary=$(printf \
    'Интерфейс: %s\nПрофиль: %s\nEndpoint: %s\n\nПроверяемые адреса:%b\n\nДля успеха нужно: %s из %s' \
    "${interface}" "${config_path:-будет создан автоматически}" \
    "${endpoint_summary}" "${site_lines}" "${check_quorum}" "${#custom_urls[@]}")

  if tui_dialog --title "Подтверждение установки" \
    --yes-button "Установить" --no-button "Назад" \
    --yesno "${summary}" 24 94; then
    return 0
  fi
  return 2
}

tui_install_once() {
  local result

  if tui_select_profile; then
    return 0
  else
    result=$?
  fi
  [[ ${result} -eq 1 ]] || return "${result}"

  while true; do
    if tui_select_sites; then
      break
    else
      result=$?
    fi
    [[ ${result} -eq 3 ]] || return "${result}"
  done
  tui_select_quorum || return $?
  tui_confirm_install
}

run_install_tui() {
  local result

  command -v whiptail >/dev/null 2>&1 || return 69
  while true; do
    if tui_install_once; then
      return 0
    else
      result=$?
    fi
    [[ ${result} -eq 2 ]] || return "${result}"
  done
}
