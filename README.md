# AWG WARP Guardian

Установщик и сторожевой сервис для AmneziaWG-профилей, получаемых по правилам
[warp-gen](https://warp-gen.github.io/).

Guardian запоминает выбранные параметры, получает свежий профиль, запускает его
только на время проверки и сохраняет лишь тот кандидат, у которого есть
handshake, `warp=on` и доступ к нужным сайтам. Если работающий VPN позже
сломается, тот же цикл запускается автоматически.

## Быстрая установка

Ubuntu-сервер с `sudo`:

```bash
curl -fsSL https://raw.githubusercontent.com/Not-Config/awg-warp-guardian/main/bootstrap.sh | sudo bash
```

В интерактивном текстовом меню можно выбрать всё цифрами, без стрелок и
зависимости от типа SSH-терминала:

- новый профиль с warp-gen или существующий `.conf`;
- вариант AWG 2.0: 1, 2 или 3;
- DNS и сервер из списка warp-gen;
- IPv6 и `PersistentKeepalive`;
- «Исключить LAN»;
- сайты, которые обязаны открываться через VPN;
- кворум успешных сайтов;
- частоту проверки;
- число свежих кандидатов: от 1 до 20;
- основной сайт warp-gen, совместимое зеркало или прокси.

Для повторного открытия меню:

```bash
cd /opt/awg-warp-guardian
sudo ./install.sh --tui --reconfigure
```

## Что именно происходит

На сайте готовый `.conf` не лежит по постоянной ссылке. Страница делает две
операции в браузере:

1. получает свежие `PrivateKey`, адреса клиента и `PublicKey` peer из одного из
   своих API;
2. собирает полный AWG-конфиг по текущему `script.js` и выбранным настройкам.

Guardian повторяет именно этот протокол на сервере, не запуская удалённый
JavaScript:

1. скачивает `script.js` с выбранного сайта;
2. безопасно извлекает только известные списки источников, endpoint-ов, DNS,
   маршрутов и AWG-шаблонов — код страницы не исполняется;
3. запрашивает новый набор параметров у первого доступного API;
4. собирает цельный кандидат с сохранёнными параметрами;
5. проверяет его через `awg-quick strip`;
6. запускает профиль и ждёт handshake;
7. параллельно проверяет выбранные сайты и Cloudflare trace;
8. при неудаче откатывает прежний профиль и запрашивает следующий;
9. при успехе оставляет новый профиль активным.

Guardian не подставляет собственный `Endpoint`, не заменяет `AllowedIPs` и не
переносит строки из старого конфига. Каждый кандидат формируется целиком по
текущим правилам выбранного сайта.

### Зачем остаётся отдельный маршрут endpoint

При включённом на warp-gen переключателе «Исключить LAN» получается большой
набор split-маршрутов. Публичный IP самого endpoint тоже может попасть в этот
набор и замкнуть туннель на себя. Поэтому systemd перед запуском читает endpoint
из текущего `.conf` и добавляет один `/32`-маршрут через физический шлюз. После
остановки маршрут удаляется.

Этот механизм расположен в systemd drop-in и не изменяет файл профиля.

## Автоматическое восстановление

Таймер запускает проверку с выбранной частотой. По умолчанию:

- проверки — каждые 2 минуты;
- ремонт начинается после 3 подряд неудачных проверок;
- сначала выполняется обычный перезапуск;
- затем тестируется до 10 свежих профилей с теми же параметрами warp-gen;
- один сеанс перевыпуска разрешён не чаще раза в 30 минут;
- не более 4 автоматических сеансов в сутки;
- рабочий старый конфиг сохраняется в резервной копии и возвращается, если ни
  один кандидат не прошёл проверку.

Проверки кандидатов используют туннельный интерфейс напрямую. Неработающий VPN
не будет ошибочно признан рабочим из-за выхода в интернет через обычный маршрут.

## Журнал и ручные команды

```bash
# Текущее здоровье и состояние восстановления
sudo awg-warp-guardian status

# Только проверка, без изменений
sudo awg-warp-guardian check

# Перезапуск, затем при необходимости свежие кандидаты
sudo awg-warp-guardian repair

# Сразу запросить и проверить свежие профили
sudo awg-warp-guardian rotate --force

# Живой журнал сторожевого сервиса
sudo journalctl -u awg-warp-guardian.service -f

# Журнал самого туннеля
sudo journalctl -u awg-quick@awg-warp.service -n 100 --no-pager
```

В журнале видны:

- номер попытки;
- адрес выбранного сайта-источника;
- какой API сейчас запрашивается;
- выбранный правилами warp-gen endpoint;
- результат проверки синтаксиса, handshake, `warp=on` и каждого сайта;
- откат или успешная установка.

Приватные ключи и содержимое конфигов в журнал не выводятся.

## Неинтерактивная установка

```bash
sudo ./install.sh --no-tui --reconfigure \
  --interface awg-warp \
  --check-url https://github.com/ \
  --check-url https://telegram.org/ \
  --quorum 2 \
  --check-interval 2min \
  --initial-attempts 10 \
  --exclude-lan \
  --awg-variant 1 \
  --dns-preset cf \
  --server-preset def \
  --ipv6 \
  --keepalive 0 \
  --generator-site https://warp-gen.github.io
```

Дополнительные параметры:

```text
--generator-data https://trusted.example/api
--generator-proxy http://127.0.0.1:8080
--include-lan
--no-ipv6
--no-start
```

`--generator-data` можно повторить: адреса будут использоваться как fallback.
Если он не указан, список API каждый раз читается из `script.js` выбранного
сайта.

## Конфигурация

Основной файл: `/etc/awg-warp-guardian/guardian.env`.

```dotenv
INTERFACE=awg-warp
CONFIG_PATH=/etc/amnezia/amneziawg/awg-warp.conf
SERVICE=awg-quick@awg-warp.service

CHECK_URLS="https://github.com/ https://telegram.org/ https://www.cloudflare.com/cdn-cgi/trace"
CHECK_QUORUM=2
CHECK_INTERVAL=2min
CANDIDATE_ATTEMPTS=10

GENERATOR_SITE_URL=https://warp-gen.github.io
GENERATOR_DATA_URLS=
GENERATOR_HTTPS_PROXY=
WARP_AWG_VARIANT=1
WARP_DNS_PRESET=cf
WARP_SERVER_PRESET=def
WARP_IPV6=1
WARP_KEEPALIVE=0
EXCLUDE_LAN=1
```

После ручного изменения файла перезапустите таймер. Если изменился интервал,
проще снова запустить установщик с `--tui --reconfigure`, чтобы обновился и
systemd drop-in.

## Безопасность источника

API warp-gen возвращает уже созданный приватный ключ. Это означает, что сайт или
зеркало технически может знать этот ключ. Это свойство самого протокола warp-gen,
а не Guardian. Используйте только доверенный источник и помните, что WARP — не
замена VPN-серверу, которым управляете только вы.

Если сайт или его `script.js` изменится неожиданным образом, строгий парсер
откажется создавать профиль. Текущий рабочий конфиг при этом останется на месте.

## Удаление

```bash
cd /opt/awg-warp-guardian
sudo ./uninstall.sh
```

Сервис, таймер и systemd-хук Guardian будут удалены. Пакет AmneziaWG, активный
VPN-профиль и его `.conf` сохраняются. Для удаления состояния и резервных копий:

```bash
sudo ./uninstall.sh --purge
```

## Разработка

```bash
python3 -m unittest -v tests/test_guardian.py
bash tests/test_generator_wrapper.sh
bash tests/test_route_endpoint.sh
bash tests/test_tui_helpers.sh
bash -n bootstrap.sh install.sh uninstall.sh src/install-tui.sh src/route-endpoint tests/*.sh
python3 -m py_compile src/guardian.py src/generate-warp-config
```

Лицензия проекта: MIT.
