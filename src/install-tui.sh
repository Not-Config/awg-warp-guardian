#!/usr/bin/env bash

# Interactive frontend for install.sh. This file only defines functions and is
# intentionally safe to source from tests.

tui_dialog() {
  local title="AWG WARP Guardian" yes_label="Да" no_label="Нет"
  local widget="" prompt="" default_value="" answer token
  local input_device=/dev/stdin output_device=/dev/stderr
  local -a tags=() labels=() states=() selected=()
  local index default_index=1 item_count

  # A numbered line interface is intentionally used instead of whiptail.
  # whiptail treats the first byte of some Windows SSH arrow sequences as
  # Escape, exits, and leaves a stale window on the screen. Plain line input
  # works identically in Windows Terminal, PuTTY, tmux and a Linux console.
  if (: </dev/tty) 2>/dev/null && (: >/dev/tty) 2>/dev/null; then
    input_device=/dev/tty
    output_device=/dev/tty
  fi

  while (($#)); do
    case "$1" in
      --title)
        title=$2
        shift 2
        ;;
      --yes-button)
        yes_label=$2
        shift 2
        ;;
      --no-button)
        no_label=$2
        shift 2
        ;;
      --notags)
        shift
        ;;
      --menu|--radiolist|--checklist|--inputbox|--yesno|--msgbox)
        widget=$1
        shift
        break
        ;;
      *)
        return 64
        ;;
    esac
  done
  [[ -n ${widget} && $# -ge 3 ]] || return 64

  prompt=$1
  shift 3 # prompt, height and width
  case "${widget}" in
    --menu|--radiolist|--checklist)
      (($# >= 1)) || return 64
      shift # list height
      ;;
    --inputbox)
      default_value=${1:-}
      ;;
  esac

  {
    printf '\n============================================================\n'
    printf '%s\n' "${title}"
    printf '%b\n' "${prompt}"
    printf '============================================================\n'
  } >"${output_device}"

  case "${widget}" in
    --menu)
      while (($# >= 2)); do
        tags+=("$1")
        labels+=("$2")
        shift 2
      done
      item_count=${#tags[@]}
      ((item_count > 0)) || return 64
      for index in "${!tags[@]}"; do
        printf '  %d) %s\n' "$((index + 1))" "${labels[index]}" >"${output_device}"
      done
      while true; do
        printf 'Введите номер [1], 0 — отмена: ' >"${output_device}"
        IFS= read -r answer <"${input_device}" || return 1
        answer=${answer:-1}
        [[ ${answer} == 0 ]] && return 1
        if [[ ${answer} =~ ^[0-9]+$ ]] && ((10#${answer} >= 1 && 10#${answer} <= item_count)); then
          printf '%s\n' "${tags[10#${answer}-1]}"
          return 0
        fi
        printf 'Нужен номер от 1 до %d.\n' "${item_count}" >"${output_device}"
      done
      ;;
    --radiolist)
      while (($# >= 3)); do
        tags+=("$1")
        labels+=("$2")
        states+=("$3")
        [[ $3 == ON ]] && default_index=$((${#tags[@]}))
        shift 3
      done
      item_count=${#tags[@]}
      ((item_count > 0)) || return 64
      for index in "${!tags[@]}"; do
        if ((index + 1 == default_index)); then
          printf '  %d) %s [по умолчанию]\n' "$((index + 1))" "${labels[index]}" >"${output_device}"
        else
          printf '  %d) %s\n' "$((index + 1))" "${labels[index]}" >"${output_device}"
        fi
      done
      while true; do
        printf 'Введите номер [%d], 0 — отмена: ' "${default_index}" >"${output_device}"
        IFS= read -r answer <"${input_device}" || return 1
        answer=${answer:-${default_index}}
        [[ ${answer} == 0 ]] && return 1
        if [[ ${answer} =~ ^[0-9]+$ ]] && ((10#${answer} >= 1 && 10#${answer} <= item_count)); then
          printf '%s\n' "${tags[10#${answer}-1]}"
          return 0
        fi
        printf 'Нужен номер от 1 до %d.\n' "${item_count}" >"${output_device}"
      done
      ;;
    --checklist)
      while (($# >= 3)); do
        tags+=("$1")
        labels+=("$2")
        states+=("$3")
        shift 3
      done
      item_count=${#tags[@]}
      ((item_count > 0)) || return 64
      default_value=""
      for index in "${!tags[@]}"; do
        if [[ ${states[index]} == ON ]]; then
          printf '  %d) [x] %s\n' "$((index + 1))" "${labels[index]}" >"${output_device}"
          default_value+="${default_value:+,}$((index + 1))"
        else
          printf '  %d) [ ] %s\n' "$((index + 1))" "${labels[index]}" >"${output_device}"
        fi
      done
      while true; do
        printf 'Номера через запятую [%s], 0 — ничего, q — отмена: ' \
          "${default_value:-0}" >"${output_device}"
        IFS= read -r answer <"${input_device}" || return 1
        answer=${answer:-${default_value:-0}}
        [[ ${answer} == q || ${answer} == Q ]] && return 1
        [[ ${answer} == 0 ]] && return 0
        answer=${answer//,/ }
        selected=()
        for token in ${answer}; do
          if [[ ! ${token} =~ ^[0-9]+$ ]] || ((10#${token} < 1 || 10#${token} > item_count)); then
            selected=()
            break
          fi
          selected+=("${tags[10#${token}-1]}")
        done
        if ((${#selected[@]} > 0)); then
          printf '%s\n' "${selected[*]}"
          return 0
        fi
        printf 'Укажите номера от 1 до %d через запятую.\n' "${item_count}" >"${output_device}"
      done
      ;;
    --inputbox)
      printf 'Значение [%s]: ' "${default_value}" >"${output_device}"
      IFS= read -r answer <"${input_device}" || return 1
      printf '%s\n' "${answer:-${default_value}}"
      ;;
    --yesno)
      while true; do
        printf '%s/%s [%s]: ' "${yes_label}" "${no_label}" "${yes_label}" >"${output_device}"
        IFS= read -r answer <"${input_device}" || return 1
        case "${answer,,}" in
          ""|y|yes|д|да) return 0 ;;
          n|no|н|нет) return 1 ;;
          *) printf 'Введите да или нет.\n' >"${output_device}" ;;
        esac
      done
      ;;
    --msgbox)
      printf 'Нажмите Enter, чтобы продолжить.' >"${output_device}"
      IFS= read -r _ <"${input_device}" || true
      printf '\n' >"${output_device}"
      ;;
  esac
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

tui_valid_generator_site_url() {
  [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]+)*/?$ ]] || return 1
  tui_valid_url_port "$1"
}

tui_valid_generator_proxy() {
  [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]] || return 1
  tui_valid_url_port "$1"
}

tui_valid_url_port() {
  local authority port

  authority=${1#*://}
  authority=${authority%%/*}
  [[ ${authority} == *:* ]] || return 0
  port=${authority##*:}
  ((10#${port} >= 1 && 10#${port} <= 65535))
}

tui_interval_seconds() {
  local interval=$1
  local amount unit

  [[ ${interval} =~ ^([1-9][0-9]*)(s|min|h)$ ]] || return 1
  amount=$((10#${BASH_REMATCH[1]}))
  unit=${BASH_REMATCH[2]}
  case "${unit}" in
    s) printf '%s\n' "${amount}" ;;
    min) printf '%s\n' "$((amount * 60))" ;;
    h) printf '%s\n' "$((amount * 3600))" ;;
  esac
}

tui_valid_interval() {
  local seconds

  seconds=$(tui_interval_seconds "$1") || return 1
  ((seconds >= 30))
}

tui_valid_initial_attempts() {
  [[ $1 =~ ^[1-9][0-9]*$ ]] && ((10#$1 <= 20))
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

  endpoint=$(sed -n -E \
    's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p' \
    "${profile}" | head -n 1)
  if [[ -n ${endpoint} ]]; then
    printf '%s — %s' "${profile}" "${endpoint}"
  else
    printf '%s' "${profile}"
  fi
}

tui_select_discovered_profile() {
  local -a menu_items=()
  local current_config candidate choice description index

  tui_profiles=()
  if [[ -s ${guardian_config} ]]; then
    current_config=$(sed -n 's/^CONFIG_PATH=//p' "${guardian_config}" | head -n 1)
    current_config=${current_config%\"}
    current_config=${current_config#\"}
    [[ -n ${current_config} ]] && tui_add_unique_path "${current_config}"
  fi
  for candidate in /etc/amnezia/amneziawg/*.conf /etc/amneziawg/*.conf; do
    tui_add_unique_path "${candidate}"
  done

  if ((${#tui_profiles[@]} == 0)); then
    tui_dialog --title "Старые профили не найдены" \
      --msgbox "В стандартных каталогах нет готовых .conf. Выберите получение нового профиля с warp-gen." \
      10 82
    return 2
  fi

  for index in "${!tui_profiles[@]}"; do
    description=$(tui_profile_description "${tui_profiles[index]}")
    menu_items+=("profile_${index}" "${description}")
  done

  if ! choice=$(tui_dialog --title "Найденные профили" --notags \
    --menu "Какой существующий .conf использовать? Полный путь позволяет отличить дубликаты." \
    22 100 12 "${menu_items[@]}"); then
    return 2
  fi

  index=${choice#profile_}
  [[ ${index} =~ ^[0-9]+$ && -n ${tui_profiles[index]+x} ]] || return 2
  config_path=${tui_profiles[index]}
  interface=$(basename -- "${config_path}" .conf)
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
  local choice

  menu_items+=("new" "Получить и проверить новый профиль с warp-gen (рекомендуется)")
  if [[ -s ${guardian_config} ]]; then
    menu_items+=("keep" "Только обновить программу, сохранить текущий VPN")
  fi
  menu_items+=(
    "existing" "Выбрать один из найденных на сервере старых .conf"
    "import" "Указать путь к существующему .conf вручную"
  )

  if ! choice=$(tui_dialog --title "AWG WARP Guardian — профиль" --notags \
    --menu "Какую конфигурацию установить и контролировать?" \
    17 92 8 "${menu_items[@]}"); then
    return 130
  fi

  case "${choice}" in
    keep)
      tui_confirm_keep_settings
      return $?
      ;;
    existing)
      tui_select_discovered_profile || return $?
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
      ;;
    new)
      force_new_profile=1
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
      ;;
  esac

  identity_option_set=1
  settings_option_set=1
  urls_option_set=1
  quorum_option_set=1
  interval_option_set=1
  initial_attempts_option_set=1
  lan_option_set=1
  generator_site_option_set=1
  generator_proxy_option_set=1
  warp_parameters_option_set=1
  reconfigure=1
  return 1
}

tui_select_sites() {
  local selection token custom_text url invalid_url
  local -a selected_urls=()

  if ! selection=$(tui_dialog --title "Проверка доступности" \
    --checklist "Какие сайты должны открываться именно через VPN?" \
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

tui_select_interval() {
  local interval_choice custom_interval

  if ! interval_choice=$(tui_dialog --title "Частота проверки" \
    --radiolist "Как часто проверять VPN и выбранные сайты?" \
    21 82 8 \
    30s "Каждые 30 секунд" OFF \
    1min "Каждую минуту" OFF \
    2min "Каждые 2 минуты (рекомендуется)" ON \
    5min "Каждые 5 минут" OFF \
    10min "Каждые 10 минут" OFF \
    30min "Каждые 30 минут" OFF \
    1h "Каждый час" OFF \
    custom "Указать свой интервал" OFF); then
    return 130
  fi

  if [[ ${interval_choice} == custom ]]; then
    while true; do
      if ! custom_interval=$(tui_dialog --title "Свой интервал" \
        --inputbox "Формат: 30s, 2min или 1h. Минимум — 30s:" \
        11 76 "2min"); then
        return 130
      fi
      if tui_valid_interval "${custom_interval}"; then
        interval_choice=${custom_interval}
        break
      fi
      tui_dialog --title "Некорректный интервал" \
        --msgbox "Используйте целое число и единицу s, min или h. Интервал должен быть не короче 30 секунд." 10 82
    done
  fi
  check_interval=${interval_choice}
}

tui_select_initial_attempts() {
  local attempts_choice custom_attempts

  if ! attempts_choice=$(tui_dialog --title "Попытки получения профиля" \
    --radiolist "Сколько новых конфигураций запросить у warp-gen, если предыдущие не проходят проверку?" \
    18 92 6 \
    5 "До 5 попыток" OFF \
    10 "До 10 попыток (рекомендуется)" ON \
    20 "До 20 попыток" OFF \
    infinite "До победного — без ограничения количества" OFF \
    custom "Указать количество" OFF); then
    return 130
  fi

  if [[ ${attempts_choice} == custom ]]; then
    while true; do
      if ! custom_attempts=$(tui_dialog --title "Количество попыток" \
        --inputbox "Введите число от 1 до 20:" \
        10 62 "10"); then
        return 130
      fi
      if tui_valid_initial_attempts "${custom_attempts}"; then
        attempts_choice=${custom_attempts}
        break
      fi
      tui_dialog --title "Некорректное количество" \
        --msgbox "Допустимо целое число от 1 до 20." 9 58
    done
  fi
  initial_generation_attempts=${attempts_choice}
  initial_attempts_option_set=1
}

tui_select_lan_mode() {
  local lan_choice

  if ! lan_choice=$(tui_dialog --title "Доступ к локальной сети" \
    --radiolist "Должны ли частные и локальные адреса оставаться вне VPN? Это защищает доступ к серверу по LAN." \
    17 94 5 \
    exclude "Исключить LAN из VPN (рекомендуется)" ON \
    include "Направлять LAN через VPN (риск потери доступа)" OFF); then
    return 130
  fi

  case "${lan_choice}" in
    exclude) exclude_lan=1 ;;
    include) exclude_lan=0 ;;
    *) return 64 ;;
  esac
  lan_option_set=1
}

tui_select_warp_parameters() {
  local ipv6_choice keepalive_choice keepalive_value

  awg_variant=$(tui_dialog --title "Вариант AWG" \
    --radiolist "Какой вариант AWG 2.0 с warp-gen использовать?" \
    16 88 5 \
    1 "Вариант 1 (рекомендуется)" ON \
    2 "Вариант 2" OFF \
    3 "Вариант 3" OFF \
    random "Случайный вариант 1/2/3 при каждой попытке" OFF) || return 130

  dns_preset=$(tui_dialog --title "DNS из warp-gen" \
    --radiolist "Какой DNS подставлять при каждой новой попытке?" \
    20 88 7 \
    cf "Cloudflare" ON \
    google "Google" OFF \
    malw "MALW" OFF \
    xbox "Xbox DNS" OFF \
    geohide "GeoHide" OFF \
    comss "COMSS" OFF) || return 130

  server_preset=$(tui_dialog --title "Сервер из warp-gen" \
    --radiolist "Какой сервер выбирать при генерации?" \
    22 88 11 \
    def "Стандартный Cloudflare (рекомендуется)" ON \
    FL "Финляндия" OFF \
    NL "Нидерланды" OFF \
    PL "Польша" OFF \
    LV "Латвия" OFF \
    DE "Германия" OFF \
    EE "Эстония" OFF \
    RU "Россия" OFF \
    lteFL "Финляндия LTE" OFF \
    ltePL "Польша LTE" OFF \
    lteDE "Германия LTE" OFF) || return 130

  ipv6_choice=$(tui_dialog --title "IPv6" \
    --radiolist "Добавлять IPv6 как на странице warp-gen?" \
    13 76 3 \
    yes "Да (на сайте включено по умолчанию)" ON \
    no "Нет" OFF) || return 130
  [[ ${ipv6_choice} == yes ]] && warp_ipv6=1 || warp_ipv6=0

  keepalive_choice=$(tui_dialog --title "PersistentKeepalive" \
    --radiolist "Добавлять PersistentKeepalive?" \
    13 76 3 \
    off "Не добавлять (как на сайте по умолчанию)" ON \
    on "Добавить" OFF) || return 130
  warp_keepalive=0
  if [[ ${keepalive_choice} == on ]]; then
    while true; do
      keepalive_value=$(tui_dialog --title "PersistentKeepalive" \
        --inputbox "Секунды, от 1 до 65535:" 10 62 "25") || return 130
      if [[ ${keepalive_value} =~ ^[1-9][0-9]*$ ]] && ((10#${keepalive_value} <= 65535)); then
        warp_keepalive=${keepalive_value}
        break
      fi
      tui_dialog --title "Некорректное значение" \
        --msgbox "Введите целое число от 1 до 65535." 9 60
    done
  fi
  warp_parameters_option_set=1
}

tui_select_generator_source() {
  local source_choice custom_site proxy_url

  while true; do
    if ! source_choice=$(tui_dialog --title "Источник генерации" \
      --radiolist "С какой страницы брать правила и параметры генерации?" \
      17 92 5 \
      default "warp-gen.github.io напрямую (рекомендуется)" ON \
      proxy "warp-gen.github.io через HTTP/HTTPS-прокси" OFF \
      custom "Совместимое зеркало сайта warp-gen" OFF); then
      return 130
    fi

    case "${source_choice}" in
      default)
        generator_site_url="https://warp-gen.github.io"
        generator_https_proxy=""
        return 0
        ;;
      proxy)
        while true; do
          if ! proxy_url=$(tui_dialog --title "Прокси генератора" \
            --inputbox "Независимый HTTP/HTTPS-прокси, например http://127.0.0.1:8080:" \
            12 90 "http://127.0.0.1:8080"); then
            return 130
          fi
          if tui_valid_generator_proxy "${proxy_url}"; then
            generator_site_url="https://warp-gen.github.io"
            generator_https_proxy=${proxy_url%/}
            return 0
          fi
          tui_dialog --title "Некорректный прокси" \
            --msgbox "Используйте адрес вида http://host:port или https://host:port без пути." 9 78
        done
        ;;
      custom)
        if ! tui_dialog --title "Доверие к зеркалу" \
          --yes-button "Понимаю" --no-button "Назад" \
          --yesno "warp-gen и его зеркало возвращают готовый приватный ключ. Источник может его знать — используйте только доверенное зеркало." \
          13 88; then
          continue
        fi
        while true; do
          if ! custom_site=$(tui_dialog --title "HTTPS-зеркало warp-gen" \
            --inputbox "URL страницы, рядом с которой доступен script.js:" \
            12 90 "https://generator-config-warp.vercel.app"); then
            return 130
          fi
          if tui_valid_generator_site_url "${custom_site}"; then
            generator_site_url=${custom_site%/}
            generator_https_proxy=""
            return 0
          fi
          tui_dialog --title "Некорректный URL" \
            --msgbox "Нужен HTTPS URL без логина, query и fragment." 10 80
        done
        ;;
    esac
  done
}

tui_confirm_install() {
  local generator_summary site_lines summary url attempts_summary lan_summary ipv6_summary

  generator_summary=${generator_site_url}
  if [[ -n ${generator_https_proxy} ]]; then
    generator_summary+=" через ${generator_https_proxy}"
  fi
  site_lines=""
  for url in "${custom_urls[@]}"; do
    site_lines+="\n • ${url}"
  done
  if [[ -n ${config_path} && -s ${config_path} ]]; then
    attempts_summary="существующий профиль не перевыпускается при установке"
  elif [[ ${initial_generation_attempts} == infinite ]]; then
    attempts_summary="без ограничения — до первого рабочего профиля"
  else
    attempts_summary="до ${initial_generation_attempts} новых конфигураций с warp-gen"
  fi
  if [[ ${exclude_lan} == 1 ]]; then
    lan_summary="исключён из VPN (рекомендуется)"
  else
    lan_summary="направляется через VPN"
  fi
  [[ ${warp_ipv6} == 1 ]] && ipv6_summary="включён" || ipv6_summary="выключен"
  summary=$(printf \
    'Интерфейс: %s\nПрофиль: %s\nИсточник: %s\nПараметры warp-gen: вариант %s, DNS %s, сервер %s, IPv6 %s, keepalive %s\nLAN: %s\nПопытки: %s\nЧастота проверки: %s\n\nПроверяемые адреса:%b\n\nДля успеха нужно: %s из %s' \
    "${interface}" "${config_path:-будет создан автоматически}" \
    "${generator_summary}" "${awg_variant}" "${dns_preset}" "${server_preset}" \
    "${ipv6_summary}" "${warp_keepalive:-0}" "${lan_summary}" "${attempts_summary}" \
    "${check_interval}" "${site_lines}" \
    "${check_quorum}" "${#custom_urls[@]}")

  if tui_dialog --title "Подтверждение установки" \
    --yes-button "Установить" --no-button "Назад" \
    --yesno "${summary}" 27 96; then
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
  tui_select_interval || return $?
  tui_select_lan_mode || return $?
  tui_select_warp_parameters || return $?
  tui_select_generator_source || return $?
  if [[ -z ${config_path} || ! -s ${config_path} ]]; then
    tui_select_initial_attempts || return $?
  fi
  tui_confirm_install
}

run_install_tui() {
  local result

  while true; do
    if tui_install_once; then
      return 0
    else
      result=$?
    fi
    [[ ${result} -eq 2 ]] || return "${result}"
  done
}
