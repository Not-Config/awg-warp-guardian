# AWG WARP Guardian

[![CI](https://github.com/Not-Config/awg-warp-guardian/actions/workflows/ci.yml/badge.svg)](https://github.com/Not-Config/awg-warp-guardian/actions/workflows/ci.yml)

Установщик и watchdog для Cloudflare WARP-туннеля через AmneziaWG на
Ubuntu-сервере. Проект проверяет не только состояние systemd-службы, но и
реальное прохождение трафика через интерфейс, доступность заданных сайтов,
свежий handshake и `warp=on` в Cloudflare Trace.

Репозиторий публичный и распространяется по лицензии MIT: установка и
клонирование доступны всем без GitHub-аккаунта.

> Это клиентский WARP-туннель для сервера, а не установка собственного
> AmneziaVPN-сервера для подключения других устройств. Именно такой профиль
> выдаёт [warp-gen.github.io](https://warp-gen.github.io/).

## Что происходит при сбое

1. Одна ошибка ничего не переключает: по умолчанию нужны три неудачные
   проверки подряд.
2. Guardian повторно применяет текущий конфиг без опускания интерфейса.
3. Если это не помогло, перезапускает `awg-quick@<interface>.service`.
4. Затем создаёт новую регистрацию Cloudflare WARP с помощью локальной копии
   генератора, проверяет полученный конфиг через `awg-quick strip` и переносит
   в него локальные правила маршрутизации и AWG 2.0-параметры маскировки из
   действующего профиля.
5. Новый профиль сначала пробуется через live sync. При необходимости он
   активируется перезапуском службы.
6. Если проверки не прошли, предыдущий `.conf` автоматически возвращается.

Ротация ограничена cooldown и дневным лимитом, чтобы временная проблема с
одним сайтом не создавала бесконечные WARP-регистрации. Старые конфиги хранятся
с правами `0600` в `/var/lib/awg-warp-guardian/backups`.

## Установка одной командой

На Ubuntu-сервере выполните:

```bash
curl -fsSL https://raw.githubusercontent.com/Not-Config/awg-warp-guardian/main/bootstrap.sh | sudo bash
```

Bootstrap установит `git`, если он отсутствует, скачает проект в
`/opt/awg-warp-guardian` и откроет интерактивное меню. Повторный запуск этой же
команды безопасно обновит checkout через `git pull --ff-only`, после чего снова
запустит установщик.

Если хочется сначала проверить исполняемый код:

```bash
curl -fsSLO https://raw.githubusercontent.com/Not-Config/awg-warp-guardian/main/bootstrap.sh
less bootstrap.sh
sudo bash bootstrap.sh
```

Для полностью автоматической установки аргументы передаются после `--`:

```bash
curl -fsSL https://raw.githubusercontent.com/Not-Config/awg-warp-guardian/main/bootstrap.sh \
  | sudo bash -s -- --no-tui --interface awg-warp
```

## Ручная интерактивная установка

При обычном запуске в терминале автоматически открывается русскоязычный TUI:

```bash
git clone https://github.com/Not-Config/awg-warp-guardian.git
cd awg-warp-guardian
sudo ./install.sh
```

В нём можно:

- подключить найденный профиль из `/etc/amnezia/amneziawg` или
  `/etc/amneziawg`;
- создать новый стандартный Cloudflare WARP-профиль;
- создать профиль со своими WARP endpoint-ами или вручную указать готовый
  `.conf`;
- выбрать официальный API генерации, независимый прокси или совместимое
  HTTPS-зеркало;
- выбрать GitHub, Telegram, YouTube, Discord, Google, Cloudflare Trace и
  добавить собственные HTTP/HTTPS-адреса;
- считать VPN рабочим, когда доступен каждый сайт, строгое большинство или
  хотя бы один из выбранных адресов;
- выбрать частоту проверки: от 30 секунд до часа или указать собственный
  интервал в формате `30s`, `2min`, `1h`.

При повторном запуске первым пунктом можно обновить файлы программы, не меняя
действующий профиль и настройки проверок. Отмена на любом экране происходит до
записи VPN-настроек. Для автоматизации и серверов без интерактивного терминала
все прежние аргументы командной строки сохранены; TUI можно явно отключить:

```bash
sudo ./install.sh --no-tui --interface awg-warp
```

## Быстрый запуск на существующем `tg-bt`

На сервере уже используется профиль `awg-new`, поэтому команда будет такой:

```bash
git clone https://github.com/Not-Config/awg-warp-guardian.git
cd awg-warp-guardian
sudo ./install.sh \
  --interface awg-new \
  --config /etc/amnezia/amneziawg/awg-new.conf
```

Установщик не перезаписывает существующий профиль при первой установке. Он
копирует guardian, добавляет systemd timer и проверяет текущий туннель. Перед
первой установкой всё равно лучше иметь открытой консоль Proxmox: любой
full-tunnel меняет маршрутизацию сервера.

Для чистой Ubuntu без готового конфига:

```bash
git clone https://github.com/Not-Config/awg-warp-guardian.git
cd awg-warp-guardian
sudo ./install.sh --interface awg-warp
```

Скрипт установит официальный пакет `amneziawg` из PPA Amnezia, создаст
стандартный WARP-профиль и запустит его. Если первая проверка не пройдёт,
новый туннель будет остановлен, а timer не включится.

Можно только положить файлы и не менять активный маршрут:

```bash
sudo ./install.sh \
  --interface awg-new \
  --config /etc/amnezia/amneziawg/awg-new.conf \
  --no-start
```

## Заданные сайты

Настройки лежат в `/etc/awg-warp-guardian/guardian.env`:

```ini
CHECK_URLS="https://github.com/ https://telegram.org/ https://example.org/health"
CHECK_QUORUM=2
CHECK_INTERVAL=2min
```

Запросы выполняются с `curl --interface awg-new`, поэтому доступ напрямую не
маскирует упавший VPN. Отдельная проверка Cloudflare Trace требует
`warp=on`. После изменения адресов или порога не нужно перезапускать timer:
следующий запуск прочитает файл заново.

`CHECK_INTERVAL` применяется установщиком через systemd timer. Чтобы изменить
его без TUI, повторно запустите установщик с явной реконфигурацией:

```bash
sudo ./install.sh --no-tui --check-interval 5min --reconfigure
```

Команды диагностики:

```bash
sudo awg-warp-guardian check
sudo awg-warp-guardian status
sudo awg-warp-guardian repair
sudo awg-warp-guardian rotate --force
systemctl list-timers awg-warp-guardian.timer
journalctl -u awg-warp-guardian.service -n 100 --no-pager
```

## Защита SSH и маршрутов

Новый WARP-конфиг содержит `AllowedIPs = 0.0.0.0/0, ::/0`. Guardian сохраняет
из старого `[Interface]` следующие директивы:

```ini
PRESERVE_DIRECTIVES=Table,PreUp,PostUp,PreDown,PostDown,S1,S2,S3,S4,Jc,Jmin,Jmax,H1,H2,H3,H4,I1,I2,I3,I4,I5
```

Так не теряются уже настроенные исключения LAN/SSH. Список также сохраняет
точный вариант AWG 2.0-маскировки из профиля `warp-gen.github.io`. PrivateKey,
адреса и peer из старого профиля намеренно не переносятся. Если конфиг лежит вне
`/etc/amnezia/amneziawg` или `/etc/amneziawg`, добавьте его каталог в
`ReadWritePaths` файла `awg-warp-guardian.service`.

Жёсткий restart можно отключить, оставив только live sync и ротацию:

```ini
ALLOW_HARD_RESTART=0
```

## Endpoint-ы и ротация

Для нового профиля по умолчанию используется стандартный WARP endpoint. При
подключении существующего профиля установщик сохраняет его текущий endpoint —
например, `nl.tribukvy.ltd`, если профиль был создан на указанном тобой сайте:

```ini
WARP_ENDPOINTS=162.159.192.1:500
ROTATION_COOLDOWN=1800
MAX_ROTATIONS_PER_DAY=4
```

Несколько проверенных endpoint-ов можно указать через запятую; на каждой
ротации будет выбран следующий. Не добавляйте случайные адреса или
«премиальные» серверы, для которых владелец требует отдельной регистрации.

При установке список можно задать сразу:

```bash
sudo ./install.sh --interface awg-new \
  --config /etc/amnezia/amneziawg/awg-new.conf \
  --endpoint nl.tribukvy.ltd:500 \
  --endpoint nl.tribukvy.ltd:2408 \
  --reconfigure
```

## Источник перевыпуска конфигурации

`warp-gen.github.io` не используется во время автоматической ротации: новый
PrivateKey создаётся локально на сервере, а регистрация выполняется через API
Cloudflare. По умолчанию используется:

```ini
GENERATOR_API_URL=https://api.cloudflareclient.com/v0i1909051800
GENERATOR_HTTPS_PROXY=
```

Если официальный домен недоступен, безопаснее направить только запрос
регистрации через независимый прокси. Это можно выбрать в TUI или настроить
через CLI:

```bash
sudo ./install.sh --no-tui \
  --generator-proxy http://127.0.0.1:8080 \
  --reconfigure
```

Также поддерживается собственное совместимое HTTPS-зеркало, которое реализует
те же маршруты `/reg` и `/reg/<id>`:

```bash
sudo ./install.sh --no-tui \
  --generator-api https://mirror.example/v0i1909051800 \
  --no-generator-proxy \
  --reconfigure
```

Приватный ключ зеркалу не передаётся, но оно может вернуть собственные
параметры peer. Поэтому нельзя указывать случайный публичный «генератор» —
используйте только своё или доверенное зеркало. URL принимается только по
HTTPS, без логина, query-параметров и fragment.

Новая регистрация обращается к API Cloudflare. Пока старый туннель хотя бы
частично работает, запрос уйдёт через него. Если одновременно недоступны и
туннель, и API напрямую, ротация физически невозможна: старый конфиг останется
на месте, а timer повторит попытку позже. Прокси при этом не должен зависеть от
того же WARP-туннеля.

## Обновление и удаление

Для обновления получите изменения и снова запустите установщик. Существующий
`guardian.env` останется без изменений:

```bash
git pull --ff-only
sudo ./install.sh
```

Удаление watchdog без удаления AmneziaWG и VPN-профиля:

```bash
sudo ./uninstall.sh
```

`sudo ./uninstall.sh --purge` дополнительно удалит настройки guardian, его
состояние и резервные копии, но также оставит сам `.conf` туннеля.

## Разработка

```bash
bash -n bootstrap.sh install.sh uninstall.sh src/generate-warp-config src/install-tui.sh tests/test_generator_wrapper.sh
python3 -m compileall -q src tests
python3 -m unittest discover -s tests -v
bash tests/test_tui_helpers.sh
bash tests/test_generator_wrapper.sh
```

Основной проект распространяется по MIT. Для локальной перевыдачи ключей
встроен `ImMALWARE/bash-warp-generator` под MIT-лицензией; это отдельный
CLI-генератор, а не копия исходников сайта `warp-gen.github.io`. Атрибуция и
исходная лицензия сохранены в `THIRD_PARTY_NOTICES.md` и
`vendor/LICENSE.ImMALWARE`. Из vendored-копии удалён исходный вывод
PrivateKey-bearing конфига во внешнюю download-ссылку: ключи записываются
только локально в временный файл с правами `0600`.
