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
4. Перед новой регистрацией останавливает неисправный туннель: поэтому запрос
   к API идёт через физическое подключение и не зацикливается внутри сломанного
   VPN.
5. Создаёт новую регистрацию Cloudflare WARP с помощью локальной копии
   генератора, проверяет полученный конфиг через `awg-quick strip` и переносит
   в него пользовательские локальные хуки. AWG 2.0-параметры берутся из
   проверенного шаблона генератора, а не из неисправного профиля.
6. За один цикл восстановления последовательно пробует настроенные endpoint-ы.
   Если очередной вариант не прошёл проверки, предыдущий `.conf`
   автоматически возвращается перед следующей попыткой.

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
- выбрать до 5, 10 или 20 попыток получения рабочего профиля; для новой
  установки по умолчанию выполняется до 10 попыток.
- оставить LAN вне VPN (включено по умолчанию) или явно разрешить full-tunnel
  для частных сетей.

При повторном запуске первым пунктом можно обновить файлы программы, не меняя
действующий профиль и настройки проверок. Отмена на любом экране происходит до
записи VPN-настроек. Для автоматизации и серверов без интерактивного терминала
все прежние аргументы командной строки сохранены; TUI можно явно отключить:

```bash
sudo ./install.sh --no-tui --interface awg-warp
```

## Подключение существующего профиля

Если на сервере уже есть рабочий профиль AmneziaWG, укажите его имя и путь:

```bash
git clone https://github.com/Not-Config/awg-warp-guardian.git
cd awg-warp-guardian
sudo ./install.sh \
  --interface awg-existing \
  --config /etc/amnezia/amneziawg/awg-existing.conf
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
установщик по умолчанию сделает до 10 отдельных регистраций и проверит каждую
конфигурацию. В TUI можно выбрать 5, 10 или 20 попыток, а в CLI — указать число
от 1 до 20 через `--initial-attempts`. Если ни один вариант не пройдёт проверки,
новый туннель будет остановлен, а timer не включится.

Во время установки в терминале показываются безопасные этапы каждой попытки:
адрес API, прямое или проксированное соединение, успешный ответ `/reg`, получение
параметров peer, локальная сборка файла, проверка `awg-quick`, запуск службы и
результаты проверок сайтов. Приватный ключ, регистрационный токен и содержимое
конфигурации в вывод не попадают.

```bash
sudo ./install.sh --no-tui --interface awg-warp --initial-attempts 15
```

Можно только положить файлы и не менять активный маршрут:

```bash
sudo ./install.sh \
  --interface awg-existing \
  --config /etc/amnezia/amneziawg/awg-existing.conf \
  --no-start
```

## Заданные сайты

Настройки лежат в `/etc/awg-warp-guardian/guardian.env`:

```ini
CHECK_URLS="https://github.com/ https://telegram.org/ https://example.org/health"
CHECK_QUORUM=2
CHECK_INTERVAL=2min
INITIAL_GENERATION_ATTEMPTS=10
EXCLUDE_LAN=1
```

Запросы выполняются с `curl --interface awg-existing`, поэтому доступ напрямую не
маскирует упавший VPN. Отдельная проверка Cloudflare Trace требует
`warp=on`. После изменения адресов или порога не нужно перезапускать timer:
следующий запуск прочитает файл заново.

Проверки сайтов и Cloudflare Trace запускаются параллельно, поэтому полностью
нерабочий туннель ждёт один `CURL_TIMEOUT`, а не сумму таймаутов всех сайтов.
В журнале также видны код выхода `curl` и безопасный текст сетевой ошибки.

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

По умолчанию TUI включает «Исключить LAN». В этом режиме `AllowedIPs` повторяет
проверенную схему `warp-gen`: содержит внешние IPv4-диапазоны, но не содержит
маршрута по умолчанию, RFC1918 (`10/8`, `172.16/12`, `192.168/16`), loopback,
link-local и IPv6. Поэтому `wg-quick` не создаёт отдельную default-таблицу
`51820`, а ответы SSH в другую частную сеть продолжают идти через обычный
маршрут сервера.

Поскольку публичный IPv4 endpoint WARP входит в разрешённые внешние диапазоны,
для него перед запуском создаётся более точный `/32`-маршрут через физический
gateway из таблицы `main`. Это не позволяет UDP-соединению WARP зациклиться в
собственный туннель.

Правила устанавливаются и удаляются хуками профиля:

```ini
PreUp = /usr/local/sbin/awg-warp-route-endpoint up 162.159.192.1
PostDown = /usr/local/sbin/awg-warp-route-endpoint down 162.159.192.1
```

Это снижает риск потерять SSH и доступ к локальным сервисам при запуске
full-tunnel на удалённом сервере.

Для уже установленного профиля режим можно применить повторным запуском:

```bash
sudo ./install.sh --no-tui --exclude-lan --reconfigure
```

Перед изменением существующего `.conf` установщик сохраняет его копию в
`/var/lib/awg-warp-guardian/backups`. Вернуть полный IPv4/IPv6-туннель, включая
частные адреса, можно только явным параметром `--include-lan`.

Guardian также сохраняет из старого `[Interface]` следующие директивы:

```ini
PRESERVE_DIRECTIVES=Table,PreUp,PostUp,PreDown,PostDown
```

Так не теряются пользовательские хуки. Собственные хуки Guardian для endpoint
и прежние `awg-warp-lan-rules` при этом не копируются: они заново создаются под
новый endpoint и выбранный режим LAN. PrivateKey, адреса, peer и AWG-параметры
из старого профиля намеренно не переносятся. Если конфиг лежит вне
`/etc/amnezia/amneziawg` или `/etc/amneziawg`, добавьте его каталог в
`ReadWritePaths` файла `awg-warp-guardian.service`.

Жёсткий restart можно отключить, оставив только live sync и ротацию:

```ini
ALLOW_HARD_RESTART=0
```

## Endpoint-ы и ротация

Для нового профиля по умолчанию последовательно используются стандартный порт
WireGuard WARP и три fallback-порта, перечисленные в документации Cloudflare.
При подключении существующего consumer WARP-профиля его адрес и текущий порт
ставятся первыми, а остальные поддерживаемые порты добавляются как резервные:

```ini
WARP_ENDPOINTS=162.159.192.1:2408,162.159.192.1:500,162.159.192.1:1701,162.159.192.1:4500
ROTATION_COOLDOWN=1800
MAX_ROTATIONS_PER_DAY=4
```

В одном автоматическом восстановлении каждый адрес пробуется по очереди, пока
один из профилей не пройдёт проверку. Не добавляйте случайные адреса или
«премиальные» серверы, для которых владелец требует отдельной регистрации.

При установке список можно задать сразу:

```bash
sudo ./install.sh --interface awg-existing \
  --config /etc/amnezia/amneziawg/awg-existing.conf \
  --endpoint 162.159.192.1:2408 \
  --endpoint 162.159.192.1:500 \
  --endpoint 162.159.192.1:1701 \
  --endpoint 162.159.192.1:4500 \
  --reconfigure
```

## Источник перевыпуска конфигурации

`warp-gen.github.io` не используется во время автоматической ротации. Готовый
конфиг вообще не скачивается с сайта: новый PrivateKey создаётся локально на
сервере, в API отправляется публичный ключ, а в ответ приходят параметры
регистрации и WARP-peer. Из них конфигурация собирается локально. По умолчанию
используется:

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

Новая регистрация обращается к API Cloudflare. Guardian сначала останавливает
неисправный туннель и выполняет регистрацию через обычный маршрут сервера. Если
API напрямую недоступен, ротация физически невозможна: старый конфиг будет
возвращён и запущен снова, а timer повторит попытку позже. Прокси при этом не
должен зависеть от того же WARP-туннеля.

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
Если профиль использует хук защиты маршрута, соответствующий маленький helper в
`/usr/local/sbin` также остаётся на месте, чтобы последующий запуск или
остановка VPN не сломались.

## Разработка

```bash
bash -n bootstrap.sh install.sh uninstall.sh src/generate-warp-config src/install-tui.sh src/lan-rules src/route-endpoint src/route-policy.sh tests/test_generator_wrapper.sh tests/test_lan_rules.sh tests/test_route_endpoint.sh
python3 -m compileall -q src tests
python3 -m unittest discover -s tests -v
bash tests/test_tui_helpers.sh
bash tests/test_generator_wrapper.sh
bash tests/test_lan_rules.sh
bash tests/test_route_endpoint.sh
```

Основной проект распространяется по MIT. Для локальной перевыдачи ключей
встроен `ImMALWARE/bash-warp-generator` под MIT-лицензией; это отдельный
CLI-генератор, а не копия исходников сайта `warp-gen.github.io`. Атрибуция и
исходная лицензия сохранены в `THIRD_PARTY_NOTICES.md` и
`vendor/LICENSE.ImMALWARE`. Из vendored-копии удалён исходный вывод
PrivateKey-bearing конфига во внешнюю download-ссылку: ключи записываются
только локально в временный файл с правами `0600`.
