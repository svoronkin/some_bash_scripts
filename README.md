# Some bash scripts
A set of small and simple scripts for solving various and specific problems
## Sys_info script

Works on this time only CentOS / Fedora / Debian.

* this script does not make any changes to your system
* during operation, temporary files can be created in `/tmp` catalog

## Features list

* System info
  * Hostname
  * Distributive
  * Lical IP
  * External IP
  * SELinux status
  * Kernel / Architecture
  * Load average
  * Active user
* CPU
  * Model name
  * Vendor
  * Cores / MHz
  * Hypervizor vendor
  * CPU usage
* Memory usage
  * Total / Usage
  * Swap total / Usage
* Boot information
  * Last boot
  * Uptime
  * Active user
  * Last 3 reboot
  * Last logons info
* Disk Usage
  * Mount information
  * Disk utilization
  * Disc IO speed (Read / Write)
  * Show read-only mounted devices
* Average information
  * Top 5 memory usage processes
  * Top 5 CPU usage processes
* Speedtest
  * Washington, D.C. (east)
  * San Jose, California (west)
  * Frankfurt, DE, JP
* Checking systemd services status
  * You can define services list
  * Show information form default list (nginx, mongo, rsyslog and etc)
* Bash users
* Who logged
* Listen ports
* Unowned files
* User list from processes

## Parameters

* `-sn` - Skip speedtest
* `-sd` - Skip disk test
* `-ss` - Show all running services
* `-e` - Extra info (Bash users, Who logged, All running services, Listen ports, UnOwned files, User list from processes)

## Usage
You can use this script with several parameters:
```
./system-check.sh -sn -sd -e
```
```
./system-check.sh -ss
```

## How to run?

You can run script directly:
```bash
wget -O - https://raw.githubusercontent.com/svoronkin/sys_prep/main/sys_check.sh | bash
```

Or you can clone repository:

```bash
git clone https://github.com/svoronkin/sys_prep.git
```

After clone go to folder and run script:
```bash
cd sys_prep && ./sys_check.sh
```
# DB Copy

## Перед началом работы необходимо задать в скрипте IP адреса серверов баз данных в указанных переменных
```bash
SOURCE='SOURCE'
DESTINATION='DESTINATION'
```

## Необходимо подготовить файл в данными для подключения к БД
Файл должен содержать актуальные пароли доступа, ip адреса для подключения, соответствовать формату.
Примерный список БД для переноса по формату файла настроек подключения для psql:
```
IP:port:db_name:db_user:pass
127.0.0.1:5432:dapi:user:12345678
127.0.0.1:5432:dp_test:user:12345678

```
В этом примере необходимо заменить креды и ip адрес для подключения

## Подготовленный файл с настройками и данными для подключения к БД нужно сохранить в ~/.pgpass
назначить файлу маску доступа 600
```bash
chmod 600 ~/.pgpass
```

## Если в vault лежит ссылка на подключение к БД и символы закодированы urlencode, то можно воспользоваться bash функцией для декодирования

```bash
function urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }
```
# kcmerge
## позволяет склеивать контексты куберкластеров в один и переключаться между ними используя kubectl ctx

# NetBox inventory

`netbox_inventory.sh` — инвентаризация Linux-хоста в [NetBox](https://netbox.dev): собирает данные о железе, ОС и сети и создаёт или обновляет устройство в NetBox через REST API. Скрипт можно запускать повторно: если ничего не изменилось, он ничего не меняет в NetBox.

## Что собирается

* **Устройство**: тип по модели материнской платы или системы, серийный номер, платформа (Proxmox, TrueNAS, Debian, Ubuntu, AlmaLinux и т. д.)
* **CPU**: модель, сокеты, ядра, частота, архитектура → модуль `CPU`
* **RAM**: каждый модуль с производителем, партномером, серийником, типом (DDR3/4/5), частотой, ECC → модули `RAM-N`
* **Диски**: модель, серийник, размер, тип (HD/SSD/NVME) → модули `Disk-N`. Диски за USB-SATA мостом распознаются через `smartctl`
* **Сеть**: физические порты (тип по скорости), Wi-Fi, мосты, bond, VLAN, связи порт → мост/bond, MAC-адреса, IPv4/IPv6, DNS-имя и primary IP

Типы модулей создаются с [профилями](https://netboxlabs.com/docs/netbox/models/dcim/moduletypeprofile/) `CPU`, `Memory` и `Hard disk` (NetBox 4.3+). Всё, что создаёт скрипт, помечается тегом `auto-inventory`.

## Требования

* `bash` 4+, `curl` 7.55+, `jq`, `iproute2` (с поддержкой `ip -j`), `util-linux` (`lsblk`, `lscpu`)
* опционально: `dmidecode` (модули RAM и серийники, нужен root), `smartctl` (диски за USB-мостами)
* NetBox 4.x и API-токен с правами на чтение и запись

Скрипт ничего не устанавливает сам: если чего-то не хватает, он сообщает об этом и завершается.

```bash
# Debian / Ubuntu / Proxmox
apt install -y curl jq dmidecode smartmontools
# RHEL / AlmaLinux / Rocky
dnf install -y curl jq dmidecode smartmontools
```

## Подготовка токена

Создайте токен в NetBox (*профиль пользователя → API Tokens*) и сохраните его в файл, доступный только root:

```bash
install -m 600 /dev/null /root/.netbox-token
nano /root/.netbox-token        # вставить токен
```

Поддерживаются токены v2 (`nbt_<key>.<secret>`, NetBox 4.5+) и v1. Если вместе с токеном скопировался префикс `Bearer ` или `Token `, скрипт его отбросит.

> Не передавайте токен аргументом командной строки: он будет виден в `ps` и истории shell. Параметр `--token` специально запрещён.

## Использование

```bash
# 1. Посмотреть, что собрано о хосте (NetBox не нужен)
./netbox_inventory.sh --collect-only

# 2. Пробный прогон: только чтение NetBox, все изменения выводятся на экран
./netbox_inventory.sh --token-file /root/.netbox-token --dry-run

# 3. Применить
./netbox_inventory.sh --token-file /root/.netbox-token
```

Создание нового устройства (сайт обязателен, роль по умолчанию `server`):

```bash
./netbox_inventory.sh --token-file /root/.netbox-token \
    --site LED --tenant LAB --role "Proxmox node" --rack Rack-01 --location "Saint Petersburg"
```

Запуск на удалённом хосте без копирования скрипта и токена (токен передаётся через stdin и не попадает в `ps`):

```bash
{ cat /root/.netbox-token; echo; cat netbox_inventory.sh; } |
  ssh root@lab02 "bash -c 'read -r NETBOX_TOKEN; export NETBOX_TOKEN; exec bash -s -- --dry-run'"
```

Регулярный запуск по cron (раз в сутки):

```bash
echo '30 3 * * * root /root/netbox_inventory.sh --token-file /root/.netbox-token >>/var/log/netbox-inventory.log 2>&1' \
  > /etc/cron.d/netbox-inventory
```

## Параметры

| Параметр | Переменная окружения | Описание |
|---|---|---|
| `-u`, `--url URL` | `NETBOX_URL` | URL NetBox (по умолчанию `https://netbox.p4el.net`) |
| `--token-file FILE` | `NETBOX_TOKEN_FILE` / `NETBOX_TOKEN` | файл с токеном или сам токен в переменной |
| `--cacert FILE` | `NETBOX_CACERT` | CA-сертификат для проверки TLS |
| `--insecure` | | не проверять TLS-сертификат (не рекомендуется) |
| `-n`, `--name NAME` | `DEVICE_NAME` | имя устройства (по умолчанию `hostname -s`) |
| `-s`, `--site SITE` | `SITE_NAME` | сайт (обязателен только при создании) |
| `-r`, `--role ROLE` | `DEVICE_ROLE` | роль (по умолчанию `server`) |
| `--tenant TENANT` | `TENANT_NAME` | арендатор |
| `-p`, `--platform NAME` | `PLATFORM` | платформа (по умолчанию определяется по ОС) |
| `--rack RACK` | `RACK_NAME` | стойка (только при создании, позиция не задаётся) |
| `--location LOCATION` | `LOCATION_NAME` | локация (только при создании) |
| `--dry-run` | | только показать изменения |
| `--collect-only` | | вывести собранные данные в JSON и выйти |
| `--no-ipv6` | | не добавлять IPv6-адреса |
| `--debug` | `DEBUG=1` | подробный вывод, включая запросы к API |
| | `SKIP_IF_REGEX` | дополнительные интерфейсы, которые не нужно добавлять |
| | `MIN_DISK_GB` | минимальный размер диска (по умолчанию 1 ГБ) |
| | `NETBOX_TAG` | тег для созданных объектов (по умолчанию `auto-inventory`) |

## Что скрипт делает и чего не делает

* **Ищет, но никогда не создаёт** сайт, арендатора, стойку и локацию: опечатка в имени не создаст мусорный объект.
* **Не перезаписывает ручные правки**: тип интерфейса меняется, только если в NetBox он `other`; `primary_ip4` ставится, только если пуст; у существующего устройства не меняются тип, стойка и позиция.
* **Не забирает чужие IP**: если адрес уже назначен другому устройству, скрипт выдаёт предупреждение и пропускает его.
* **Пропускает служебные интерфейсы**: `lo`, `docker*`, `br-<id>`, `veth*`, `tap*`, `fwbr*`/`fwpr*`/`fwln*` (Proxmox), `virbr*`, CNI-интерфейсы Kubernetes, а также ZFS-тома `zd*` среди дисков.
* **Нормализует производителей**: `Intel Corporation` → `Intel`, `Samsung Electronics Co Ltd` → `Samsung`. Производитель диска определяется по модели, производитель RAM при необходимости — по партномеру.
* **Ничего не удаляет**: интерфейсы и модули, которых больше нет на хосте, нужно убирать вручную.
* Если платформа в NetBox ограничена производителем (поле *Manufacturer* у платформы), а устройство другого производителя, платформа не назначается, и выводится предупреждение.

Виртуальные машины скрипт добавляет как устройства и выводит предупреждение: в NetBox их правильнее вести в разделе *Virtualization*.
