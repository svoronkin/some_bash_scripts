#!/usr/bin/env bash
# netbox_inventory.sh — инвентаризация Linux-хоста в NetBox.
# Зависимости: bash 4+, curl, jq, iproute2 (ip -j), util-linux (lsblk, lscpu).
# Опционально: dmidecode (модули RAM, серийники; нужен root), smartctl (диски за USB-мостами).
# Ничего не устанавливает сам. Справка: ./netbox_inventory.sh --help

set -euo pipefail
export LC_ALL=C

SCRIPT_VERSION=2.1.0

# ---------- настройки (env или параметры) ----------
NETBOX_URL=${NETBOX_URL:-https://netbox.p4el.net}
NETBOX_TOKEN=${NETBOX_TOKEN:-}
NETBOX_TOKEN_FILE=${NETBOX_TOKEN_FILE:-}
NETBOX_CACERT=${NETBOX_CACERT:-}
# host:port:address — как curl --resolve, если NetBox недоступен по адресу из DNS
NETBOX_RESOLVE=${NETBOX_RESOLVE:-}
NETBOX_TAG=${NETBOX_TAG:-auto-inventory}
DEVICE_NAME=${DEVICE_NAME:-}
DEVICE_ROLE=${DEVICE_ROLE:-server}
SITE_NAME=${SITE_NAME:-}
TENANT_NAME=${TENANT_NAME:-}
PLATFORM=${PLATFORM:-}
RACK_NAME=${RACK_NAME:-}
LOCATION_NAME=${LOCATION_NAME:-}
# Интерфейсы, которые не попадают в NetBox (дополнительно к встроенным правилам)
SKIP_IF_REGEX=${SKIP_IF_REGEX:-}
MIN_DISK_GB=${MIN_DISK_GB:-1}
INSECURE=0
DRY_RUN=0
COLLECT_ONLY=0
NO_IPV6=0
DEBUG=${DEBUG:-0}

# ---------- вывод ----------
if [[ -t 2 ]]; then C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[36m' C_0=$'\e[0m'; else C_R= C_G= C_Y= C_B= C_0=; fi
log()   { printf '%s\n' "$*" >&2; }
ok()    { printf '%s%s%s\n' "$C_G" "$*" "$C_0" >&2; }
warn()  { printf '%sWARN: %s%s\n' "$C_Y" "$*" "$C_0" >&2; }
err()   { printf '%sERROR: %s%s\n' "$C_R" "$*" "$C_0" >&2; }
die()   { err "$*"; exit 1; }
dbg()   { if [[ $DEBUG == 1 ]]; then printf '%sDEBUG: %s%s\n' "$C_B" "$*" "$C_0" >&2; fi; }
change(){ printf '%s%s %s%s\n' "$C_B" "$([[ $DRY_RUN == 1 ]] && echo '[dry-run]' || echo '*')" "$*" "$C_0" >&2; }

usage() {
    cat <<EOF
netbox_inventory.sh $SCRIPT_VERSION — добавляет/обновляет текущий Linux-хост в NetBox.

Использование: $0 [опции]

Подключение:
  -u, --url URL            URL NetBox (по умолчанию: $NETBOX_URL)
      --token-file FILE    файл с API-токеном (права 600). Либо env NETBOX_TOKEN.
      --cacert FILE        CA-сертификат для проверки TLS
      --resolve H:P:ADDR   подключаться к ADDR вместо адреса из DNS (как curl --resolve),
                           например netbox.example.com:443:192.168.32.7
      --insecure           не проверять TLS-сертификат (не рекомендуется)

Устройство:
  -n, --name NAME          имя устройства (по умолчанию: hostname -s)
  -s, --site SITE          сайт (обязателен только при создании устройства)
  -r, --role ROLE          роль (по умолчанию: $DEVICE_ROLE)
      --tenant TENANT      арендатор
  -p, --platform NAME      платформа (по умолчанию: определяется по ОС)
      --rack RACK          стойка (только при создании; позиция не задаётся)
      --location LOCATION  локация (только при создании)

Режимы:
      --dry-run            только читать NetBox и показать, что будет изменено
      --collect-only       только собрать данные о хосте и вывести JSON (без NetBox)
      --no-ipv6            не добавлять IPv6-адреса
      --debug              подробный вывод
  -h, --help               эта справка

Сайт, арендатор, стойка и локация только ищутся и никогда не создаются.
Всё, что скрипт создаёт, помечается тегом '$NETBOX_TAG'.

Примеры:
  NETBOX_TOKEN=... $0 --dry-run
  $0 --token-file /root/.netbox-token --site LED --tenant LAB --role "Proxmox node"
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--url)        NETBOX_URL=$2; shift 2 ;;
            --token-file)    NETBOX_TOKEN_FILE=$2; shift 2 ;;
            -t|--token)      die "--token небезопасен (виден в ps и истории). Используйте --token-file или env NETBOX_TOKEN" ;;
            --cacert)        NETBOX_CACERT=$2; shift 2 ;;
            --resolve)       NETBOX_RESOLVE=$2; shift 2 ;;
            --insecure)      INSECURE=1; shift ;;
            -n|--name)       DEVICE_NAME=$2; shift 2 ;;
            -s|--site)       SITE_NAME=$2; shift 2 ;;
            -r|--role)       DEVICE_ROLE=$2; shift 2 ;;
            --tenant)        TENANT_NAME=$2; shift 2 ;;
            -p|--platform)   PLATFORM=$2; shift 2 ;;
            --rack)          RACK_NAME=$2; shift 2 ;;
            --location)      LOCATION_NAME=$2; shift 2 ;;
            --dry-run)       DRY_RUN=1; shift ;;
            --collect-only)  COLLECT_ONLY=1; shift ;;
            --no-ipv6)       NO_IPV6=1; shift ;;
            --debug)         DEBUG=1; shift ;;
            -h|--help)       usage; exit 0 ;;
            *)               usage >&2; die "неизвестный параметр: $1" ;;
        esac
    done
}

check_deps() {
    local missing=() c
    for c in curl jq ip lsblk awk sed; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "не найдены: ${missing[*]}. Установите их пакетным менеджером (скрипт сам ничего не ставит)."
    fi
    if (( BASH_VERSINFO[0] < 4 )); then die "нужен bash 4+"; fi
    if [[ $EUID -ne 0 ]]; then
        warn "запущено не от root: серийные номера и модули RAM (dmidecode) будут недоступны"
    fi
}

# ---------- утилиты ----------
trim()    { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }
uri()     { jq -rn --arg v "$1" '$v|@uri'; }
slugify() {
    local s
    s=$(printf '%s' "${1,,}" | sed -E 's/[^a-z0-9_]+/-/g; s/^-+//; s/-+$//')
    printf '%s' "${s:0:100}"
}
# Пустые/мусорные значения из DMI и SMBIOS
is_junk() {
    local l=${1,,}
    l=$(trim "$l")
    case $l in
        ''|unknown|none|'n/a'|na|'not specified'|'not available'|'default string'|'system manufacturer'|\
        'system product name'|'system serial number'|'to be filled by o.e.m.'|'to be filled by o.e.m'|\
        'o.e.m.'|oem|'base board serial number'|'chassis serial number'|0|'0000000000'|'123456789'|\
        'not present'|'no module installed'|'dimm_vendor'|'manufacturer'*|ata) return 0 ;;
    esac
    [[ $l =~ ^0x?0+$ ]] && return 0
    return 1
}
clean() { local v; v=$(trim "$1"); if is_junk "$v"; then printf ''; else printf '%s' "$v"; fi; }

# Нормализация производителей: одно имя на вендора, чтобы не плодить дубли
normalize_vendor() {
    local v; v=$(clean "$1")
    [[ -z $v ]] && return 0
    case ${v,,} in
        intel*|genuineintel)                     echo "Intel" ;;
        amd*|'advanced micro devices'*|authenticamd) echo "AMD" ;;
        samsung*)                                echo "Samsung" ;;
        kingston*)                               echo "Kingston" ;;
        'sk hynix'*|hynix*|skhynix*|'hyundai'*)  echo "SK Hynix" ;;
        micron*)                                 echo "Micron" ;;
        crucial*)                                echo "Crucial" ;;
        wdc|wd|'western digital'*|wdc\ *)        echo "Western Digital" ;;
        seagate*)                                echo "Seagate" ;;
        toshiba*|kioxia*)                        echo "Toshiba" ;;
        hgst*|hitachi*)                          echo "HGST" ;;
        sandisk*)                                echo "SanDisk" ;;
        asustek*|asus*)                          echo "ASUS" ;;
        'giga-byte'*|gigabyte*)                  echo "Gigabyte" ;;
        'micro-star'*|msi)                       echo "MSI" ;;
        asrock*)                                 echo "ASRock" ;;
        supermicro*|'super micro'*)              echo "Supermicro" ;;
        'dell'*)                                 echo "Dell" ;;
        'hewlett'*|hp|hpe)                       echo "HPE" ;;
        lenovo*)                                 echo "Lenovo" ;;
        fujitsu*)                                echo "Fujitsu" ;;
        qemu*)                                   echo "QEMU" ;;
        jmicron*)                                echo "JMicron" ;;
        realtek*)                                echo "Realtek" ;;
        corsair*)                                echo "Corsair" ;;
        'g skill'*|g.skill*|gskill*)             echo "G.Skill" ;;
        teamgroup*|'team group'*)                echo "TeamGroup" ;;
        adata*|a-data*)                          echo "ADATA" ;;
        *)                                       echo "$v" ;;
    esac
}

# Производитель диска по модели (у SATA-дисков vendor обычно 'ATA')
disk_vendor_from_model() {
    local m=$1
    case ${m^^} in
        SAMSUNG*|MZ*)                 echo "Samsung" ;;
        KINGSTON*|SA400*|SKC*|SNV*)   echo "Kingston" ;;
        WDC*|WD[0-9A-Z]*)             echo "Western Digital" ;;
        ST[0-9]*|SEAGATE*)            echo "Seagate" ;;
        CT[0-9]*|CRUCIAL*)            echo "Crucial" ;;
        MICRON*|MTFD*)                echo "Micron" ;;
        INTEL*|SSDSC*|SSDPE*)         echo "Intel" ;;
        TOSHIBA*|KIOXIA*|KXG*|THN*)   echo "Toshiba" ;;
        HGST*|HUS*|HUH*|HDS*)         echo "HGST" ;;
        SANDISK*)                     echo "SanDisk" ;;
        'SK HYNIX'*|HFS*|HFM*)        echo "SK Hynix" ;;
        *BRIDGE*|'')                  echo "" ;;   # USB-SATA мост без smartctl: модель неизвестна
        *)                            normalize_vendor "${m%% *}" ;;
    esac
}

# Производитель RAM: SMBIOS часто отдаёт JEDEC-код ("1315", "80CE") вместо имени — тогда по партномеру
ram_vendor() {
    local v=$1 part=${2^^}
    case $part in
        CT[0-9]*|BL[0-9]*)              echo "Crucial"; return ;;
        KHX*|KF[0-9]*|KVR*|9905*|ACR*|KCP*|KSM*) echo "Kingston"; return ;;
        M471*|M378*|M393*|M391*|M474*)  echo "Samsung"; return ;;
        HMA*|HMT*|HMCG*)                echo "SK Hynix"; return ;;
        MTA*|MT[0-9]*)                  echo "Micron"; return ;;
        F4-*|F5-*|F3-*)                 echo "G.Skill"; return ;;
        CMK*|CMW*|CMSX*|CMT*)           echo "Corsair"; return ;;
    esac
    v=$(normalize_vendor "$v")
    if [[ $v =~ ^(0x)?[0-9A-Fa-f]+$ ]]; then v=""; fi
    printf '%s' "$v"
}

# ======================================================================
#  Сбор данных о хосте -> JSON
# ======================================================================
dmi() { local f=/sys/class/dmi/id/$1; if [[ -r $f ]]; then clean "$(tr -d '\0' <"$f" 2>/dev/null || true)"; fi; }

collect_system() {
    local virt=none hostname fqdn
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null || true)
    elif grep -q '^flags.* hypervisor' /proc/cpuinfo 2>/dev/null; then
        virt=unknown
    fi
    [[ -z $virt ]] && virt=none
    hostname=$(hostname -s 2>/dev/null || hostname)
    fqdn=$(hostname -f 2>/dev/null || true)
    [[ $fqdn == *.* ]] || fqdn=""
    jq -n \
        --arg hostname "$hostname" --arg fqdn "$fqdn" --arg virt "$virt" \
        --arg sys_vendor "$(dmi sys_vendor)" --arg product "$(dmi product_name)" \
        --arg serial "$(dmi product_serial)" --arg board_vendor "$(dmi board_vendor)" \
        --arg board_name "$(dmi board_name)" --arg board_serial "$(dmi board_serial)" \
        --arg chassis_serial "$(dmi chassis_serial)" \
        '{hostname:$hostname, fqdn:$fqdn, virtual:($virt!="none"), virt_type:$virt,
          system:{vendor:$sys_vendor, product:$product, serial:$serial,
                  board_vendor:$board_vendor, board_name:$board_name,
                  board_serial:$board_serial, chassis_serial:$chassis_serial}}'
}

collect_os() {
    local id="" name="" ver="" pretty="" platform=""
    if [[ -r /etc/os-release ]]; then
        id=$(. /etc/os-release; echo "${ID:-}")
        name=$(. /etc/os-release; echo "${NAME:-}")
        ver=$(. /etc/os-release; echo "${VERSION_ID:-}")
        pretty=$(. /etc/os-release; echo "${PRETTY_NAME:-}")
    fi
    if command -v pveversion >/dev/null 2>&1; then
        platform="Proxmox"
        pretty="Proxmox VE $(pveversion 2>/dev/null | sed -nE 's#^pve-manager/([0-9.]+).*#\1#p') ($pretty)"
    elif [[ -e /etc/version && $id == *truenas* ]] || command -v midclt >/dev/null 2>&1; then
        platform="TrueNAS"
    else
        case $id in
            debian) platform="Debian" ;; ubuntu) platform="Ubuntu" ;; almalinux) platform="AlmaLinux" ;;
            rocky) platform="Rocky Linux" ;; centos) platform="CentOS" ;; rhel) platform="RHEL" ;;
            fedora) platform="Fedora" ;; opensuse*|sles) platform="openSUSE" ;; arch) platform="Arch Linux" ;;
            alpine) platform="Alpine" ;; *) platform=${name:-Linux} ;;
        esac
    fi
    jq -n --arg id "$id" --arg name "$name" --arg version "$ver" --arg pretty "$pretty" \
        --arg platform "$platform" --arg kernel "$(uname -r)" \
        '{id:$id, name:$name, version:$version, pretty:$pretty, platform:$platform, kernel:$kernel}'
}

collect_cpu() {
    local model="" vendor="" sockets=0 cores=0 threads speed="" arch lsout
    arch=$(uname -m)
    threads=$(nproc --all 2>/dev/null || nproc)
    if command -v lscpu >/dev/null 2>&1; then
        lsout=$(lscpu 2>/dev/null || true)
        model=$(awk -F: '/^Model name:/{sub(/^[ \t]+/,"",$2); print $2; exit}' <<<"$lsout")
        vendor=$(awk -F: '/^Vendor ID:/{sub(/^[ \t]+/,"",$2); print $2; exit}' <<<"$lsout")
        sockets=$(awk -F: '/^Socket\(s\):/{gsub(/[ \t]/,"",$2); print $2; exit}' <<<"$lsout")
        cores=$(awk -F: '/^Core\(s\) per (socket|cluster):/{gsub(/[ \t]/,"",$2); print $2; exit}' <<<"$lsout")
        speed=$(awk -F: '/^CPU max MHz:/{gsub(/[ \t]/,"",$2); printf "%.2f", $2/1000; exit}' <<<"$lsout")
    fi
    if [[ -z $model ]]; then
        model=$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
    fi
    if [[ -z $vendor ]]; then
        vendor=$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
    fi
    [[ $sockets =~ ^[0-9]+$ && $sockets -gt 0 ]] || \
        sockets=$(awk -F': ' '/^physical id/{a[$2]=1} END{n=length(a); print (n?n:1)}' /proc/cpuinfo 2>/dev/null || echo 1)
    [[ $cores =~ ^[0-9]+$ && $cores -gt 0 ]] || \
        cores=$(awk -F': ' '/^cpu cores/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
    [[ $cores =~ ^[0-9]+$ && $cores -gt 0 ]] || cores=$(( threads / sockets ))
    # Частота из названия модели точнее, чем 'CPU max MHz' (turbo)
    if [[ $model =~ @[[:space:]]*([0-9]+\.[0-9]+)[[:space:]]*GHz ]]; then speed=${BASH_REMATCH[1]}; fi
    jq -n --arg model "$model" --arg vendor "$(normalize_vendor "$vendor")" --arg arch "$arch" \
        --argjson sockets "$sockets" --argjson cores "$cores" --argjson threads "$threads" \
        --arg speed "$speed" \
        '{model:$model, vendor:$vendor, arch:$arch, sockets:$sockets, cores_per_socket:$cores,
          threads:$threads, speed_ghz:(if $speed=="" then null else ($speed|tonumber) end)}'
}

collect_memory() {
    local total_kb total_gb ecc=null modules='[]'
    total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    total_gb=$(( (total_kb + 524288) / 1048576 ))
    if [[ $EUID -eq 0 ]] && command -v dmidecode >/dev/null 2>&1; then
        local ect
        ect=$(dmidecode -t 16 2>/dev/null | awk -F': ' '/Error Correction Type/{print $2; exit}' || true)
        case $ect in
            ''|Unknown|'Not Provided') ecc=null ;;
            None) ecc=false ;;
            *) ecc=true ;;
        esac
        # Один DIMM-слот на строку: index \t size_gb \t locator \t bank \t vendor \t part \t serial \t type \t speed
        modules=$(dmidecode -t 17 2>/dev/null | awk '
            BEGIN { RS=""; FS="\n"; OFS="\t"; idx=0 }
            /Memory Device/ {
                size=0; loc=""; bank=""; man=""; part=""; ser=""; typ=""; spd=0; cspd=0
                for (i=1; i<=NF; i++) {
                    line=$i; sub(/^[ \t]+/, "", line)
                    p=index(line, ": "); if (!p) continue
                    k=substr(line, 1, p-1); v=substr(line, p+2)
                    if (k=="Size") {
                        if (v ~ /TB/) size=v*1024; else if (v ~ /GB/) size=v+0; else if (v ~ /MB/) size=v/1024; else size=0
                    }
                    else if (k=="Locator") loc=v
                    else if (k=="Bank Locator") bank=v
                    else if (k=="Manufacturer") man=v
                    else if (k=="Part Number") part=v
                    else if (k=="Serial Number") ser=v
                    else if (k=="Type") typ=v
                    else if (k=="Speed") spd=v+0
                    else if (k=="Configured Memory Speed" || k=="Configured Clock Speed") cspd=v+0
                }
                idx++
                print idx, size, loc, bank, man, part, ser, typ, (spd ? spd : cspd)
            }' | while IFS=$'\t' read -r idx size loc bank man part ser typ spd; do
                jq -cn --argjson idx "$idx" --arg size "$size" --arg loc "$(trim "$loc")" \
                    --arg bank "$(trim "$bank")" --arg vendor "$(ram_vendor "$man" "$(clean "$part")")" \
                    --arg part "$(clean "$part")" --arg serial "$(clean "$ser")" \
                    --arg type "$(clean "$typ")" --arg speed "$spd" \
                    '{slot:$idx, size_gb:($size|tonumber|floor), locator:$loc, bank:$bank, vendor:$vendor,
                      part:$part, serial:$serial, type:$type, speed:($speed|tonumber? // 0)}'
            done | jq -cs '[.[] | select(.size_gb > 0)]')
        [[ -n $modules ]] || modules='[]'
    fi
    jq -n --argjson total "$total_gb" --argjson ecc "$ecc" --argjson modules "$modules" \
        '{total_gb:$total, ecc:$ecc, modules:$modules}'
}

collect_disks() {
    local raw base out="" d name model vendor sj
    raw=$(lsblk -J -b -d -o NAME,SIZE,TYPE,MODEL,SERIAL,VENDOR,TRAN,ROTA 2>/dev/null) || { echo '[]'; return 0; }
    base=$(jq -c --argjson min "$MIN_DISK_GB" '
        [ .blockdevices[]
          | select(.type == "disk")
          | select(.name | test("^(loop|ram|zram|zd|nbd|rbd|drbd|md|dm-|sr|fd)") | not)
          | (.size | tonumber? // 0) as $b
          | select($b >= ($min * 1073741824))
          | { name, size_gb: (($b / 1000000000) | floor),
              model: ((.model // "") | gsub("^\\s+|\\s+$"; "")),
              serial: ((.serial // "") | gsub("^\\s+|\\s+$"; "")),
              vendor: ((.vendor // "") | gsub("^\\s+|\\s+$"; "")),
              tran: (.tran // ""),
              type: (if .tran == "nvme" or (.name|startswith("nvme")) then "NVME"
                     elif (.rota == false or .rota == "0" or .rota == 0) then "SSD" else "HD" end) } ]' <<<"$raw")
    while IFS= read -r d; do
        name=$(jq -r .name <<<"$d")
        # smartctl видит реальную модель/серийник за USB-SATA мостом
        if [[ $EUID -eq 0 ]] && command -v smartctl >/dev/null 2>&1; then
            sj=$(smartctl -i -j "/dev/$name" 2>/dev/null || true)
            if [[ -n $sj ]] && jq -e '.model_name' >/dev/null 2>&1 <<<"$sj"; then
                d=$(jq -c --argjson s "$sj" '
                    .model = ($s.model_name // .model) |
                    .serial = ($s.serial_number // .serial) |
                    if ($s.rotation_rate? == 0 and .type == "HD") then .type = "SSD" else . end' <<<"$d")
            fi
        fi
        model=$(jq -r .model <<<"$d")
        vendor=$(disk_vendor_from_model "$model")
        if [[ -z $vendor ]]; then vendor=$(normalize_vendor "$(jq -r .vendor <<<"$d")"); fi
        out+=$(jq -c --arg v "$vendor" '.vendor_norm = $v' <<<"$d")$'\n'
    done < <(jq -c '.[]' <<<"$base")
    printf '%s' "$out" | jq -cs .
}

collect_network() {
    local links addrs defdev
    links=$(ip -j -d link show 2>/dev/null) || die "ip -j не поддерживается (нужен iproute2 >= 4.13)"
    addrs=$(ip -j addr show 2>/dev/null)
    defdev=$(ip -j route show default 2>/dev/null | jq -r '.[0].dev // empty' || true)
    local result='[]' ifname
    while IFS= read -r ifname; do
        local phys=false wifi=false speed=0
        if [[ -e /sys/class/net/$ifname/device ]]; then phys=true; fi
        if [[ -d /sys/class/net/$ifname/wireless || -d /sys/class/net/$ifname/phy80211 ]]; then wifi=true; fi
        if [[ -r /sys/class/net/$ifname/speed ]]; then
            speed=$(cat "/sys/class/net/$ifname/speed" 2>/dev/null || echo 0)
            [[ $speed =~ ^[0-9]+$ ]] || speed=0
        fi
        result=$(jq -c --arg n "$ifname" --argjson phys "$phys" --argjson wifi "$wifi" \
            --argjson speed "$speed" --argjson links "$links" --argjson addrs "$addrs" --argjson noipv6 "$NO_IPV6" '
            ($links[] | select(.ifname == $n)) as $l
            | ([$addrs[] | select(.ifname == $n) | .addr_info[]?
                | select(.scope == "global")
                | select(.family == "inet" or ($noipv6 == 0 and .family == "inet6"))
                | select((.local | startswith("127.")) | not)
                | "\(.local)/\(.prefixlen)"]) as $ips
            | . + [{ name: $n,
                     kind: ($l.linkinfo.info_kind // (if $l.link_type == "loopback" then "loopback" else "" end)),
                     slave_kind: ($l.linkinfo.info_slave_kind // ""),
                     master: ($l.master // ""),
                     link: ($l.link // ""),
                     vlan_id: ($l.linkinfo.info_data.id // null),
                     mac: (if ($l.link_type == "ether") then ($l.address // "") else "" end),
                     mtu: $l.mtu,
                     up: any(($l.flags // [])[]; . == "UP"),
                     # ether-интерфейс без linkinfo.kind — физический порт (в т.ч. порты встроенного
                     # коммутатора DSA, у которых нет /sys/class/net/X/device)
                     physical: ($phys or ((($l.linkinfo.info_kind // "") == "") and $l.link_type == "ether" and ($wifi | not))),
                     wireless: $wifi, speed: $speed,
                     addresses: $ips }]' <<<"$result")
    done < <(jq -r '.[].ifname' <<<"$links")
    jq -c --arg def "$defdev" '{default_iface:$def, interfaces:.}' <<<"$result"
}

# Какие интерфейсы не нужны в NetBox
skip_iface() {
    local name=$1 kind=$2
    # tun не исключаем по типу: на нём работают VPN (OpenVPN tun0, AmneziaWG awg0); tap-интерфейсы ВМ
    # Proxmox отсекаются по имени ниже
    case $kind in loopback|veth|dummy|ipip|sit|ip6tnl|gre|gretap|ip6gre|ip6gretap|erspan|ip6erspan|vti|vti6|nlmon|ifb|vxlan|geneve) return 0 ;; esac
    case $name in
        lo|docker[0-9]*|virbr*|veth*|tap*|fwbr*|fwpr*|fwln*|cni*|flannel*|cali*|tunl*|kube-*|cilium*|lxc*|vnet*|weave*|podman*) return 0 ;;
        ip_vti*|ip6_vti*|ip6tnl*|sit[0-9]*|gre[0-9]*|gretap*|erspan*|miireg|imq*|teql*|bonding_masters|ifb*) return 0 ;;
    esac
    [[ $name =~ ^br-[0-9a-f]{12}$ ]] && return 0          # docker compose сети
    if [[ -n $SKIP_IF_REGEX && $name =~ $SKIP_IF_REGEX ]]; then return 0; fi
    return 1
}

collect_facts() {
    local sys os cpu mem disks net
    sys=$(collect_system); os=$(collect_os); cpu=$(collect_cpu)
    mem=$(collect_memory); disks=$(collect_disks); net=$(collect_network)
    [[ -n $disks ]] || disks='[]'
    jq -n --argjson sys "$sys" --argjson os "$os" --argjson cpu "$cpu" --argjson mem "$mem" \
        --argjson disks "$disks" --argjson net "$net" \
        '$sys + {os:$os, cpu:$cpu, memory:$mem, disks:$disks} + $net'
}

# ======================================================================
#  NetBox API
# ======================================================================
TMPDIR_NB=""
AUTH_HEADER_FILE=""
NB_VERSION=""
TAG_JSON='[]'
cleanup() { if [[ -n $TMPDIR_NB ]]; then rm -rf "$TMPDIR_NB"; fi; }
trap cleanup EXIT

setup_api() {
    if [[ -z $NETBOX_TOKEN && -n $NETBOX_TOKEN_FILE ]]; then
        [[ -r $NETBOX_TOKEN_FILE ]] || die "не удаётся прочитать $NETBOX_TOKEN_FILE"
        NETBOX_TOKEN=$(tr -d '\r\n' <"$NETBOX_TOKEN_FILE")
    fi
    # Допускаем, что в файл/переменную скопировали заголовок целиком: "Bearer nbt_..." / "Token ..."
    NETBOX_TOKEN=$(sed -E 's/^[[:space:]]*(Bearer|Token)[[:space:]]+//I; s/[[:space:]]//g' <<<"$NETBOX_TOKEN")
    [[ -n $NETBOX_TOKEN ]] || die "нет API-токена: задайте NETBOX_TOKEN или --token-file"
    TMPDIR_NB=$(mktemp -d)
    chmod 700 "$TMPDIR_NB"
    # Токен в файле заголовков, а не в аргументах curl: не виден в ps.
    # v2-токены (NetBox 4.5+, вид nbt_<key>.<secret>) передаются как Bearer, v1 — как Token.
    local scheme=Token
    if [[ $NETBOX_TOKEN == nbt_* ]]; then scheme=Bearer; fi
    dbg "схема авторизации: $scheme"
    AUTH_HEADER_FILE=$TMPDIR_NB/auth
    ( umask 077; printf 'Authorization: %s %s\n' "$scheme" "$NETBOX_TOKEN" >"$AUTH_HEADER_FILE" )
    CURL_OPTS=(--silent --show-error --connect-timeout 10 --max-time 60 --retry 2 --retry-delay 2
               -H "@$AUTH_HEADER_FILE" -H 'Accept: application/json' -H 'Content-Type: application/json')
    if [[ -n $NETBOX_CACERT ]]; then CURL_OPTS+=(--cacert "$NETBOX_CACERT"); fi
    if [[ -n $NETBOX_RESOLVE ]]; then CURL_OPTS+=(--resolve "$NETBOX_RESOLVE"); fi
    if [[ $INSECURE == 1 ]]; then warn "проверка TLS отключена (--insecure)"; CURL_OPTS+=(-k); fi
}

# nb METHOD PATH [JSON] -> тело ответа в stdout; код возврата 1 при ошибке
nb() {
    local method=$1 path=${2#/} data=${3:-} out code
    if [[ $method != GET && $DRY_RUN == 1 ]]; then
        dbg "$method /api/$path $data"
        printf '{"id":0}'
        return 0
    fi
    out=$TMPDIR_NB/resp
    dbg "$method /api/$path ${data:0:300}"
    if [[ -n $data ]]; then
        code=$(curl "${CURL_OPTS[@]}" -o "$out" -w '%{http_code}' -X "$method" --data "$data" "${NETBOX_URL%/}/api/$path") || { err "curl: $method /api/$path"; return 1; }
    else
        code=$(curl "${CURL_OPTS[@]}" -o "$out" -w '%{http_code}' -X "$method" "${NETBOX_URL%/}/api/$path") || { err "curl: $method /api/$path"; return 1; }
    fi
    if [[ $code -eq 401 || $code -eq 403 ]] && grep -qiE 'token|credentials' "$out"; then
        err "HTTP $code: токен не принят ($(head -c 200 "$out")). Проверьте токен и его права."
        return 2
    fi
    if [[ $code -ge 400 || $code -eq 0 ]]; then
        err "HTTP $code: $method /api/$path: $(head -c 500 "$out")"
        return 1
    fi
    cat "$out"
}

# Первый объект по фильтру (или пусто). Предупреждает, если найдено несколько.
nb_find() {
    local path=$1 query=$2 resp count
    resp=$(nb GET "${path}?${query}&limit=2") || return 1
    count=$(jq -r '.count' <<<"$resp")
    if [[ $count -gt 1 ]]; then warn "найдено $count объектов $path?$query, беру первый"; fi
    jq -c '.results[0] // empty' <<<"$resp"
}
nb_find_id() { local o; o=$(nb_find "$@") || return 1; jq -r '.id // empty' <<<"$o"; }

# Найти по name/slug, иначе создать. Печатает id.
nb_ensure_named() {
    local path=$1 name=$2 extra=${3:-'{}'} id slug obj
    slug=$(slugify "$name")
    id=$(nb_find_id "$path" "slug=$(uri "$slug")") || return 1
    [[ -n $id ]] || id=$(nb_find_id "$path" "name__ie=$(uri "$name")") || return 1
    if [[ -n $id ]]; then echo "$id"; return 0; fi
    obj=$(jq -cn --arg n "$name" --arg s "$slug" --argjson e "$extra" --argjson t "$TAG_JSON" \
        '{name:$n, slug:$s, tags:$t} + $e')
    change "создать ${path%/} '$name'"
    nb POST "$path" "$obj" | jq -r '.id'
}

# Только найти (сайт/арендатор/стойка/локация не создаются никогда)
nb_lookup_named() {
    local path=$1 name=$2 extra_q=${3:-} id
    id=$(nb_find_id "$path" "name__ie=$(uri "$name")${extra_q:+&$extra_q}") || return 1
    [[ -n $id ]] || id=$(nb_find_id "$path" "slug=$(uri "$(slugify "$name")")${extra_q:+&$extra_q}") || return 1
    echo "$id"
}

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

check_netbox() {
    local status rc=0
    status=$(nb GET "status/") || rc=$?
    if [[ $rc -eq 2 ]]; then exit 1; fi
    if [[ $rc -ne 0 ]]; then die "NetBox недоступен: $NETBOX_URL"; fi
    NB_VERSION=$(jq -r '."netbox-version" // empty' <<<"$status")
    NB_VERSION=${NB_VERSION%%-*}
    nb GET "dcim/sites/?limit=1" >/dev/null || die "токен не принят или нет прав на чтение"
    ok "NetBox $NB_VERSION ($NETBOX_URL)"
    if [[ $DRY_RUN == 1 ]]; then
        TAG_JSON=$(jq -cn --arg s "$(slugify "$NETBOX_TAG")" '[{slug:$s}]')
    else
        nb_ensure_named "extras/tags/" "$NETBOX_TAG" '{"color":"9e9e9e","description":"Создано netbox_inventory.sh"}' >/dev/null
        TAG_JSON=$(jq -cn --arg s "$(slugify "$NETBOX_TAG")" '[{slug:$s}]')
    fi
}

# ======================================================================
#  Устройство
# ======================================================================
DEVICE_ID=""
DEVICE_JSON=""

ensure_device_type() {
    local facts=$1 vendor model mfr_id id
    model=$(jq -r '.system.board_name' <<<"$facts")
    vendor=$(jq -r '.system.board_vendor' <<<"$facts")
    if [[ -z $model ]]; then
        model=$(jq -r '.system.product' <<<"$facts")
        vendor=$(jq -r '.system.vendor' <<<"$facts")
    fi
    [[ -n $model ]] || model="Generic server"
    vendor=$(normalize_vendor "$vendor"); [[ -n $vendor ]] || vendor="Generic"
    # Сначала ищем модель у любого производителя: не плодим дубль, если тип уже заведён вручную
    id=$(nb_find_id "dcim/device-types/" "model__ie=$(uri "$model")") || return 1
    if [[ -z $id ]]; then
        mfr_id=$(nb_ensure_named "dcim/manufacturers/" "$vendor") || return 1
        change "создать тип устройства '$vendor $model'"
        id=$(nb POST "dcim/device-types/" "$(jq -cn --argjson m "${mfr_id:-0}" --arg model "$model" \
            --arg slug "$(slugify "$vendor-$model")" --argjson t "$TAG_JSON" \
            '{manufacturer:$m, model:$model, slug:$slug, tags:$t}')" | jq -r .id) || return 1
    fi
    echo "$id"
}

ensure_platform() {
    local facts=$1 name
    name=${PLATFORM:-$(jq -r '.os.platform' <<<"$facts")}
    [[ -n $name ]] || return 0
    nb_ensure_named "dcim/platforms/" "$name"
}

# Платформа может быть ограничена производителем (platform.manufacturer): NetBox не даст
# назначить её устройству другого производителя. Печатает platform_id или пусто.
platform_for_type() {
    local pid=$1 type_id=$2 pl dt_mfr
    if [[ ! $pid =~ ^[1-9] || ! $type_id =~ ^[1-9] ]]; then echo "$pid"; return 0; fi
    pl=$(nb GET "dcim/platforms/$pid/") || return 1
    if [[ -n $(jq -r '.manufacturer.id // empty' <<<"$pl") ]]; then
        dt_mfr=$(nb GET "dcim/device-types/$type_id/" | jq -r '.manufacturer.id') || return 1
        if [[ $(jq -r '.manufacturer.id' <<<"$pl") != "$dt_mfr" ]]; then
            warn "платформа '$(jq -r .name <<<"$pl")' ограничена производителем '$(jq -r .manufacturer.name <<<"$pl")' — не назначаю. Уберите manufacturer у платформы в NetBox, если это ОС."
            return 0
        fi
    fi
    echo "$pid"
}

# Hostname может не совпадать с именем в NetBox (GW-CGMax vs CGMax). Ищем устройство по серийнику,
# затем по IP-адресам хоста; берём результат, только если он однозначен.
find_device_fallback() {
    local facts=$1 serial=$2 found ids addr
    if [[ -n $serial ]]; then
        found=$(nb GET "dcim/devices/?serial=$(uri "$serial")&limit=2") || return 1
        if [[ $(jq -r .count <<<"$found") == 1 ]]; then
            jq -c '.results[0]' <<<"$found"
            log "  найдено по серийному номеру $serial"
            return 0
        fi
    fi
    ids=""
    while IFS= read -r addr; do
        found=$(nb_find "ipam/ip-addresses/" "address=$(uri "$addr")&vrf_id=null") || return 1
        ids+=$(jq -r '.assigned_object.device.id // empty' <<<"$found")$'\n'
    done < <(jq -r '.interfaces[].addresses[] | select(contains(":") | not)' <<<"$facts")
    ids=$(grep -v '^$' <<<"$ids" | sort -u || true)
    if [[ -n $ids && $(wc -l <<<"$ids") -eq 1 ]]; then
        nb GET "dcim/devices/$ids/" || return 1
        log "  найдено по IP-адресам хоста"
    fi
}

ensure_device() {
    local facts=$1 name platform_id serial patch site_id tenant_id role_id type_id body explicit=0
    [[ -n $DEVICE_NAME ]] && explicit=1
    name=${DEVICE_NAME:-$(jq -r .hostname <<<"$facts")}
    DEVICE_NAME=$name
    serial=$(jq -r '.system.serial // empty' <<<"$facts")
    [[ -n $serial ]] || serial=$(jq -r '.system.board_serial // empty' <<<"$facts")
    platform_id=$(ensure_platform "$facts") || return 1
    tenant_id=""
    if [[ -n $TENANT_NAME ]]; then
        tenant_id=$(nb_lookup_named "tenancy/tenants/" "$TENANT_NAME") || return 1
        [[ -n $tenant_id ]] || die "арендатор '$TENANT_NAME' не найден"
    fi

    DEVICE_JSON=$(nb_find "dcim/devices/" "name=$(uri "$name")") || return 1
    if [[ -z $DEVICE_JSON && $explicit == 0 ]]; then
        DEVICE_JSON=$(find_device_fallback "$facts" "$serial") || return 1
        if [[ -n $DEVICE_JSON ]]; then
            DEVICE_NAME=$(jq -r .name <<<"$DEVICE_JSON")
            warn "hostname '$name' не совпадает с именем в NetBox '$DEVICE_NAME' — использую его (имя в NetBox не меняю; чтобы не искать, укажите --name)"
            name=$DEVICE_NAME
        fi
    fi
    if [[ -n $DEVICE_JSON ]]; then
        DEVICE_ID=$(jq -r .id <<<"$DEVICE_JSON")
        ok "устройство '$name' найдено (id $DEVICE_ID)"
        platform_id=$(platform_for_type "$platform_id" "$(jq -r .device_type.id <<<"$DEVICE_JSON")") || return 1
        # Обновляем только то, что безопасно: серийник (если пуст), платформу, арендатора
        patch=$(jq -cn --argjson d "$DEVICE_JSON" --arg serial "$serial" --arg p "${platform_id:-}" --arg t "${tenant_id:-}" '
            {}
            + (if $serial != "" and ($d.serial // "") == "" then {serial:$serial} else {} end)
            + (if $p != "" and $p != "0" and (($d.platform.id // 0)|tostring) != $p then {platform:($p|tonumber)} else {} end)
            + (if $t != "" and (($d.tenant.id // 0)|tostring) != $t then {tenant:($t|tonumber)} else {} end)')
        if [[ $patch != '{}' ]]; then
            change "обновить устройство $name: $patch"
            nb PATCH "dcim/devices/$DEVICE_ID/" "$patch" >/dev/null || return 1
        fi
        if [[ -n $RACK_NAME || -n $LOCATION_NAME ]]; then
            warn "--rack/--location применяются только при создании; размещение существующего устройства не меняю"
        fi
        return 0
    fi

    [[ -n $SITE_NAME ]] || die "устройства '$name' нет в NetBox; для создания укажите --site"
    site_id=$(nb_lookup_named "dcim/sites/" "$SITE_NAME") || return 1
    [[ -n $site_id ]] || die "сайт '$SITE_NAME' не найден"
    role_id=$(nb_ensure_named "dcim/device-roles/" "$DEVICE_ROLE" '{"color":"9e9e9e"}') || return 1
    type_id=$(ensure_device_type "$facts") || return 1
    platform_id=$(platform_for_type "$platform_id" "$type_id") || return 1
    body=$(jq -cn --arg name "$name" --argjson type "${type_id:-0}" --argjson role "${role_id:-0}" \
        --argjson site "$site_id" --arg serial "$serial" --arg p "${platform_id:-}" --arg t "${tenant_id:-}" \
        --argjson tags "$TAG_JSON" \
        '{name:$name, device_type:$type, role:$role, site:$site, status:"active", tags:$tags}
         + (if $serial != "" then {serial:$serial} else {} end)
         + (if $p != "" then {platform:($p|tonumber)} else {} end)
         + (if $t != "" then {tenant:($t|tonumber)} else {} end)')
    if [[ -n $LOCATION_NAME ]]; then
        local loc_id; loc_id=$(nb_lookup_named "dcim/locations/" "$LOCATION_NAME" "site_id=$site_id") || return 1
        [[ -n $loc_id ]] || die "локация '$LOCATION_NAME' не найдена на сайте '$SITE_NAME'"
        body=$(jq -c --argjson l "$loc_id" '. + {location:$l}' <<<"$body")
    fi
    if [[ -n $RACK_NAME ]]; then
        local rack_id; rack_id=$(nb_lookup_named "dcim/racks/" "$RACK_NAME" "site_id=$site_id") || return 1
        [[ -n $rack_id ]] || die "стойка '$RACK_NAME' не найдена на сайте '$SITE_NAME'"
        body=$(jq -c --argjson r "$rack_id" '. + {rack:$r}' <<<"$body")
    fi
    change "создать устройство '$name'"
    DEVICE_ID=$(nb POST "dcim/devices/" "$body" | jq -r .id) || return 1
    DEVICE_JSON=$(jq -c --argjson id "$DEVICE_ID" '. + {id:$id}' <<<"$body")
}

# ======================================================================
#  Модули: CPU, RAM, диски
# ======================================================================
declare -A PROFILE_ID=()
MODULES_JSON='[]'
BAYS_JSON='[]'

load_profiles() {
    if ! version_ge "$NB_VERSION" "4.3"; then
        warn "NetBox $NB_VERSION < 4.3: профили модулей недоступны, атрибуты не заполняются"
        return 0
    fi
    local resp
    resp=$(nb GET "dcim/module-type-profiles/?limit=100") || return 0
    while IFS=$'\t' read -r name id; do PROFILE_ID[$name]=$id; done < <(jq -r '.results[] | [.name, .id] | @tsv' <<<"$resp")
}

load_device_modules() {
    [[ $DEVICE_ID =~ ^[1-9] ]] || return 0
    MODULES_JSON=$(nb GET "dcim/modules/?device_id=$DEVICE_ID&limit=1000" | jq -c '.results') || return 1
    BAYS_JSON=$(nb GET "dcim/module-bays/?device_id=$DEVICE_ID&limit=1000" | jq -c '.results') || return 1
}

# ensure_module_type <manufacturer> <model> <profile> <attributes-json>
ensure_module_type() {
    local vendor=$1 model=$2 profile=$3 attrs=$4 mfr_id id body pid
    [[ -n $vendor ]] || vendor="Generic"
    mfr_id=$(nb_ensure_named "dcim/manufacturers/" "$vendor") || return 1
    if [[ $mfr_id =~ ^[1-9] ]]; then
        id=$(nb_find_id "dcim/module-types/" "manufacturer_id=$mfr_id&model=$(uri "$model")") || return 1
        if [[ -n $id ]]; then echo "$id"; return 0; fi
    fi
    pid=${PROFILE_ID[$profile]:-}
    body=$(jq -cn --argjson m "${mfr_id:-0}" --arg model "$model" --arg pid "$pid" --argjson a "$attrs" \
        --argjson t "$TAG_JSON" \
        '{manufacturer:$m, model:$model, tags:$t}
         + (if $pid != "" then {profile:($pid|tonumber), attributes:($a | with_entries(select(.value != null)))} else {} end)')
    change "создать тип модуля '$vendor $model'"
    nb POST "dcim/module-types/" "$body" | jq -r .id
}

# place_module <bay-prefix> <preferred-bay-name> <bay-label> <module_type_id> <serial>
# Находит модуль по серийнику; иначе занимает модуль без серийника в слоте с тем же префиксом
# (миграция со старого скрипта); иначе свободный/новый слот.
place_module() {
    local prefix=$1 bay_name=$2 label=$3 mt_id=$4 serial=$5 mod bay_id
    [[ $DEVICE_ID =~ ^[1-9] ]] || { change "модуль $bay_name (устройство ещё не создано)"; return 0; }
    if [[ -n $serial ]]; then
        mod=$(jq -c --arg s "$serial" 'map(select(.serial == $s)) | .[0] // empty' <<<"$MODULES_JSON")
    fi
    if [[ -z ${mod:-} ]]; then
        mod=$(jq -c --arg b "$bay_name" 'map(select(.module_bay.name == $b)) | .[0] // empty' <<<"$MODULES_JSON")
        if [[ -n $mod && -n $serial && -n $(jq -r '.serial // empty' <<<"$mod") ]]; then mod=""; fi
    fi
    if [[ -z ${mod:-} ]]; then
        mod=$(jq -c --arg p "$prefix" 'map(select((.module_bay.name | startswith($p)) and ((.serial // "") == ""))) | .[0] // empty' <<<"$MODULES_JSON")
    fi
    if [[ -n ${mod:-} ]]; then
        local mid patch
        mid=$(jq -r .id <<<"$mod")
        patch=$(jq -cn --argjson m "$mod" --argjson mt "$mt_id" --arg s "$serial" '
            {} + (if ($m.module_type.id) != $mt then {module_type:$mt} else {} end)
               + (if $s != "" and ($m.serial // "") != $s then {serial:$s} else {} end)')
        if [[ $patch != '{}' ]]; then
            change "обновить модуль ${prefix}…(${mid}) в слоте $(jq -r .module_bay.name <<<"$mod"): $patch"
            nb PATCH "dcim/modules/$mid/" "$patch" >/dev/null || return 1
        fi
        MODULES_JSON=$(jq -c --argjson id "$mid" 'map(select(.id != $id))' <<<"$MODULES_JSON")
        return 0
    fi
    # Свободный слот с нужным именем или новый
    bay_id=$(jq -r --arg b "$bay_name" 'map(select(.name == $b and (.installed_module == null))) | .[0].id // empty' <<<"$BAYS_JSON")
    if [[ -z $bay_id ]]; then
        if jq -e --arg b "$bay_name" 'any(.[]; .name == $b)' >/dev/null <<<"$BAYS_JSON"; then
            local n=1
            while jq -e --arg b "$prefix$n" 'any(.[]; .name == $b)' >/dev/null <<<"$BAYS_JSON"; do n=$((n+1)); done
            bay_name="$prefix$n"
        fi
        change "создать слот $bay_name"
        bay_id=$(nb POST "dcim/module-bays/" "$(jq -cn --argjson d "$DEVICE_ID" --arg n "$bay_name" --arg l "$label" \
            --argjson t "$TAG_JSON" '{device:$d, name:$n, label:$l, tags:$t}')" | jq -r .id) || return 1
        BAYS_JSON=$(jq -c --argjson id "$bay_id" --arg n "$bay_name" '. + [{id:$id, name:$n, installed_module:{id:-1}}]' <<<"$BAYS_JSON")
    else
        BAYS_JSON=$(jq -c --argjson id "$bay_id" 'map(if .id == $id then .installed_module = {id:-1} else . end)' <<<"$BAYS_JSON")
    fi
    change "установить модуль в $bay_name${serial:+ (s/n $serial)}"
    nb POST "dcim/modules/" "$(jq -cn --argjson d "$DEVICE_ID" --argjson b "$bay_id" --argjson mt "$mt_id" \
        --arg s "$serial" --argjson t "$TAG_JSON" \
        '{device:$d, module_bay:$b, module_type:$mt, status:"active", tags:$t} + (if $s != "" then {serial:$s} else {} end)')" >/dev/null
}

sync_cpu() {
    local facts=$1 model vendor clean_model sockets attrs mt_id i bay
    model=$(jq -r '.cpu.model' <<<"$facts")
    vendor=$(jq -r '.cpu.vendor' <<<"$facts")
    [[ -n $model ]] || return 0
    # "Intel(R) Core(TM) i7-6770HQ CPU @ 2.60GHz" -> "Core i7-6770HQ"
    clean_model=$(sed -E 's/\((R|TM|tm|r)\)//g; s/@.*$//; s/ (CPU|Processor)( |$)/ /g; s/[0-9]+-Core//; s/^(Intel|AMD) +//; s/ +/ /g; s/^ //; s/ $//' <<<"$model")
    attrs=$(jq -c '{cores:.cpu.cores_per_socket, speed:.cpu.speed_ghz, architecture:.cpu.arch}' <<<"$facts")
    mt_id=$(ensure_module_type "$vendor" "$clean_model" "CPU" "$attrs") || return 1
    sockets=$(jq -r '.cpu.sockets' <<<"$facts")
    for (( i=1; i<=sockets; i++ )); do
        if (( sockets == 1 )); then bay="CPU"; else bay="CPU$i"; fi
        place_module "CPU" "$bay" "CPU socket $i" "${mt_id:-0}" "" || return 1
    done
}

sync_memory() {
    local facts=$1 count
    count=$(jq '.memory.modules | length' <<<"$facts")
    if [[ $count -eq 0 ]]; then
        log "  модули RAM: нет данных dmidecode (нужен root и dmidecode), пропускаю"
        return 0
    fi
    local ecc
    ecc=$(jq -c '.memory.ecc' <<<"$facts")
    while IFS= read -r m; do
        local vendor part size type speed serial model attrs mt_id slot loc
        vendor=$(jq -r .vendor <<<"$m"); part=$(jq -r .part <<<"$m"); size=$(jq -r .size_gb <<<"$m")
        type=$(jq -r .type <<<"$m"); serial=$(jq -r .serial <<<"$m"); slot=$(jq -r .slot <<<"$m")
        loc=$(jq -r '[.bank, .locator] | map(select(. != "")) | join(" / ")' <<<"$m")
        model=${part:-"${size}GB ${type:-RAM}"}
        attrs=$(jq -c --argjson ecc "$ecc" '{size:.size_gb, ecc:$ecc,
            class:(if (.type|test("^DDR[345]$")) then .type else null end),
            data_rate:(if .speed > 0 then .speed else null end)}' <<<"$m")
        mt_id=$(ensure_module_type "$vendor" "$model" "Memory" "$attrs") || return 1
        place_module "RAM-" "RAM-$slot" "$loc" "${mt_id:-0}" "$serial" || return 1
    done < <(jq -c '.memory.modules[]' <<<"$facts")
}

sync_disks() {
    local facts=$1 i=0
    while IFS= read -r d; do
        local vendor model size type serial attrs mt_id name
        i=$((i+1))
        vendor=$(jq -r .vendor_norm <<<"$d"); model=$(jq -r .model <<<"$d"); size=$(jq -r .size_gb <<<"$d")
        type=$(jq -r .type <<<"$d"); serial=$(jq -r .serial <<<"$d"); name=$(jq -r .name <<<"$d")
        [[ -n $model ]] || model="${size}GB ${type}"
        attrs=$(jq -c '{size:.size_gb, type:.type}' <<<"$d")
        mt_id=$(ensure_module_type "$vendor" "$model" "Hard disk" "$attrs") || return 1
        place_module "Disk-" "Disk-$i" "$name" "${mt_id:-0}" "$serial" || return 1
    done < <(jq -c '.disks[]' <<<"$facts")
}

# ======================================================================
#  Интерфейсы, MAC, IP
# ======================================================================
declare -A IFACE_ID=()

iface_type() {
    local kind=$1 phys=$2 wifi=$3 speed=$4
    if [[ $kind == bridge ]]; then echo bridge; return; fi
    if [[ $kind == bond || $kind == team ]]; then echo lag; return; fi
    if [[ $wifi == true ]]; then echo ieee802.11ac; return; fi
    if [[ $phys == true ]]; then
        case $speed in
            10) echo 10base-t ;; 100) echo 100base-tx ;; 1000) echo 1000base-t ;;
            2500) echo 2.5gbase-t ;; 5000) echo 5gbase-t ;; 10000) echo 10gbase-t ;;
            25000) echo 25gbase-x-sfp28 ;; 40000) echo 40gbase-x-qsfpp ;;
            *) echo other ;;
        esac
        return
    fi
    echo virtual
}

sync_interfaces() {
    local facts=$1 existing
    if [[ $DEVICE_ID =~ ^[1-9] ]]; then
        existing=$(nb GET "dcim/interfaces/?device_id=$DEVICE_ID&limit=1000" | jq -c '.results') || return 1
    else
        existing='[]'
    fi
    local new_mac_api=0
    version_ge "$NB_VERSION" "4.2" && new_mac_api=1

    # Проход 1: интерфейсы
    while IFS= read -r i; do
        local name kind phys wifi speed mtu up type cur id mac patch
        name=$(jq -r .name <<<"$i"); kind=$(jq -r .kind <<<"$i")
        skip_iface "$name" "$kind" && { dbg "пропуск интерфейса $name ($kind)"; continue; }
        phys=$(jq -r .physical <<<"$i"); wifi=$(jq -r .wireless <<<"$i"); speed=$(jq -r .speed <<<"$i")
        mtu=$(jq -r '.mtu // empty' <<<"$i"); up=$(jq -r .up <<<"$i"); mac=$(jq -r .mac <<<"$i")
        type=$(iface_type "$kind" "$phys" "$wifi" "$speed")
        cur=$(jq -c --arg n "$name" 'map(select(.name == $n)) | .[0] // empty' <<<"$existing")
        if [[ -n $cur ]]; then
            id=$(jq -r .id <<<"$cur")
            # Тип меняем, только если в NetBox он 'other' (ручные правки не трогаем).
            # К виртуальным типам (bridge/lag/virtual) NetBox не допускает кабель — такие не трогаем.
            if [[ $(jq -r '.type.value' <<<"$cur") == other && $(jq -r '.cable // empty' <<<"$cur") != "" ]] && \
               [[ $type == bridge || $type == lag || $type == virtual ]]; then
                warn "интерфейс $name: в NetBox к нему подключён кабель, тип '$type' не ставлю — перенесите кабель на физический порт"
                type=other
            fi
            patch=$(jq -cn --argjson c "$cur" --arg type "$type" --arg mtu "$mtu" '
                {} + (if $c.type.value == "other" and $type != "other" then {type:$type} else {} end)
                   + (if $mtu != "" and (($c.mtu // 0)|tostring) != $mtu then {mtu:($mtu|tonumber)} else {} end)')
            if [[ $patch != '{}' ]]; then
                change "обновить интерфейс $name: $patch"
                nb PATCH "dcim/interfaces/$id/" "$patch" >/dev/null || return 1
            fi
        else
            change "создать интерфейс $name ($type)"
            id=$(nb POST "dcim/interfaces/" "$(jq -cn --argjson d "${DEVICE_ID:-0}" --arg n "$name" --arg type "$type" \
                --arg mtu "$mtu" --argjson up "$up" --argjson t "$TAG_JSON" \
                '{device:$d, name:$n, type:$type, enabled:$up, tags:$t} + (if $mtu != "" then {mtu:($mtu|tonumber)} else {} end)')" | jq -r .id) || return 1
            cur='{}'
        fi
        IFACE_ID[$name]=$id
        if [[ -n $mac ]]; then sync_mac "$id" "$mac" "$cur" "$new_mac_api"; fi
    done < <(jq -c '.interfaces[]' <<<"$facts")

    # Проход 2: связи bridge / lag (через master) и parent (VLAN через link) — независимо:
    # VLAN-интерфейс может одновременно иметь родителя и состоять в мосту (switch0.10 -> br10)
    while IFS= read -r i; do
        local name master slave_kind link kind cur id rel field target_name target
        name=$(jq -r .name <<<"$i"); [[ -n ${IFACE_ID[$name]:-} ]] || continue
        master=$(jq -r .master <<<"$i"); slave_kind=$(jq -r .slave_kind <<<"$i")
        link=$(jq -r .link <<<"$i"); kind=$(jq -r .kind <<<"$i")
        id=${IFACE_ID[$name]}
        cur=$(jq -c --arg n "$name" 'map(select(.name == $n)) | .[0] // {}' <<<"$existing")
        local rels=()
        if [[ -n $master ]]; then
            case $slave_kind in bridge) rels+=("bridge:$master") ;; bond|team) rels+=("lag:$master") ;; esac
        fi
        if [[ $kind == vlan && -n $link ]]; then rels+=("parent:$link"); fi
        for rel in ${rels[@]+"${rels[@]}"}; do
            field=${rel%%:*}; target_name=${rel#*:}; target=${IFACE_ID[$target_name]:-}
            [[ $target =~ ^[1-9] && $id =~ ^[1-9] ]] || continue
            if [[ $(jq -r --arg f "$field" '.[$f].id // 0' <<<"$cur") != "$target" ]]; then
                change "интерфейс $name: $field -> $target_name"
                nb PATCH "dcim/interfaces/$id/" "{\"$field\":$target}" >/dev/null || return 1
            fi
        done
    done < <(jq -c '.interfaces[]' <<<"$facts")
}

sync_mac() {
    local iid=$1 mac=$2 cur=$3 new_api=$4 found mid
    mac=${mac^^}
    [[ $iid =~ ^[1-9] ]] || { change "MAC $mac (интерфейс ещё не создан)"; return 0; }
    if [[ $new_api == 0 ]]; then
        if [[ $(jq -r '.mac_address // "" | ascii_upcase' <<<"$cur") != "$mac" ]]; then
            change "MAC $mac на интерфейс $iid"
            nb PATCH "dcim/interfaces/$iid/" "{\"mac_address\":\"$mac\"}" >/dev/null
        fi
        return 0
    fi
    # NetBox 4.2+: MAC — отдельный объект, интерфейс ссылается на primary_mac_address
    found=$(nb_find "dcim/mac-addresses/" "mac_address=$(uri "$mac")&interface_id=$iid") || return 0
    if [[ -n $found ]]; then
        mid=$(jq -r .id <<<"$found")
    else
        change "MAC $mac -> интерфейс $iid"
        mid=$(nb POST "dcim/mac-addresses/" "$(jq -cn --arg m "$mac" --argjson i "$iid" --argjson t "$TAG_JSON" \
            '{mac_address:$m, assigned_object_type:"dcim.interface", assigned_object_id:$i, tags:$t}')" | jq -r .id) || return 0
    fi
    if [[ $(jq -r '.primary_mac_address.id // 0' <<<"$cur") == 0 && $mid =~ ^[1-9] ]]; then
        nb PATCH "dcim/interfaces/$iid/" "{\"primary_mac_address\":$mid}" >/dev/null || true
    fi
}

sync_ips() {
    local facts=$1 defdev fqdn primary4=""
    defdev=$(jq -r '.default_iface' <<<"$facts")
    fqdn=$(jq -r '.fqdn' <<<"$facts")
    while IFS=$'\t' read -r ifname addr; do
        local iid=${IFACE_ID[$ifname]:-} found ip_id owner_dev owner_if body is_primary=0
        [[ -n $iid ]] || continue
        if [[ $ifname == "$defdev" && $addr != *:* && -z $primary4 ]]; then is_primary=1; fi
        found=$(nb_find "ipam/ip-addresses/" "address=$(uri "$addr")&vrf_id=null") || return 1
        if [[ -n $found ]]; then
            ip_id=$(jq -r .id <<<"$found")
            owner_dev=$(jq -r '.assigned_object.device.id // .assigned_object.virtual_machine.id // empty' <<<"$found")
            owner_if=$(jq -r '.assigned_object_id // empty' <<<"$found")
            if [[ -n $owner_dev && $owner_dev != "$DEVICE_ID" ]]; then
                warn "IP $addr уже назначен другому устройству ($(jq -r '.assigned_object.device.name // .assigned_object.virtual_machine.name' <<<"$found")) — не трогаю"
                continue
            fi
            if [[ $owner_if != "$iid" ]]; then
                change "IP $addr -> $ifname"
                nb PATCH "ipam/ip-addresses/$ip_id/" "{\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$iid}" >/dev/null || return 1
            fi
            if [[ $is_primary == 1 && -n $fqdn && -z $(jq -r '.dns_name // empty' <<<"$found") ]]; then
                change "DNS-имя $fqdn для $addr"
                nb PATCH "ipam/ip-addresses/$ip_id/" "$(jq -cn --arg f "$fqdn" '{dns_name:$f}')" >/dev/null || true
            fi
        else
            body=$(jq -cn --arg a "$addr" --argjson i "${iid:-0}" --argjson t "$TAG_JSON" --arg f "$fqdn" --argjson p "$is_primary" \
                '{address:$a, status:"active", assigned_object_type:"dcim.interface", assigned_object_id:$i, tags:$t}
                 + (if $p == 1 and $f != "" then {dns_name:$f} else {} end)')
            change "создать IP $addr на $ifname"
            ip_id=$(nb POST "ipam/ip-addresses/" "$body" | jq -r .id) || return 1
        fi
        if [[ $is_primary == 1 ]]; then primary4=$ip_id; fi
    done < <(jq -r '.interfaces[] | .name as $n | .addresses[] | [$n, .] | @tsv' <<<"$facts")

    # primary_ip4 ставим, только если он не задан (ручной выбор не перезаписываем)
    local cur_primary=0
    if [[ -n $DEVICE_JSON ]]; then cur_primary=$(jq -r '.primary_ip4.id // 0' <<<"$DEVICE_JSON"); fi
    if [[ $primary4 =~ ^[1-9] && $DEVICE_ID =~ ^[1-9] && $cur_primary == 0 ]]; then
        change "primary IPv4 устройства -> $primary4"
        nb PATCH "dcim/devices/$DEVICE_ID/" "{\"primary_ip4\":$primary4}" >/dev/null || true
    fi
}

# ======================================================================
print_summary() {
    local facts=$1
    jq -r '
      "Хост:      \(.hostname)\(if .fqdn != "" then " (\(.fqdn))" else "" end)\(if .virtual then "  [VM: \(.virt_type)]" else "" end)",
      "Система:   \([.system.vendor, .system.product] | map(select(. != "")) | join(" ") | if . == "" then "-" else . end)  плата: \(.system.board_vendor) \(.system.board_name)  s/n: \([.system.serial, .system.board_serial, "-"] | map(select(. != "")) | first)",
      "ОС:        \(.os.pretty)  → платформа \(.os.platform)",
      "CPU:       \(.cpu.sockets)× \(.cpu.model)  (\(.cpu.cores_per_socket) ядер/сокет, \(.cpu.threads) потоков)",
      "RAM:       \(.memory.total_gb) GB\(if (.memory.modules|length) > 0 then "  [" + ([.memory.modules[] | "\(.size_gb)G \(.vendor) \(.part)"] | join(", ")) + "]" else "" end)",
      "Диски:     \([.disks[] | "\(.name) \(.size_gb)GB \(.type) \(.model)"] | join("; "))",
      "Сеть:      \([.interfaces[] | select(.addresses|length>0) | "\(.name) \(.addresses|join(","))"] | join("; "))"
    ' <<<"$facts" >&2
}

main() {
    parse_args "$@"
    check_deps
    log "Сбор данных о хосте..."
    local facts
    facts=$(collect_facts)
    if [[ $COLLECT_ONLY == 1 ]]; then
        jq . <<<"$facts"
        return 0
    fi
    print_summary "$facts"
    if [[ $(jq -r .virtual <<<"$facts") == true ]]; then
        warn "это виртуальная машина ($(jq -r .virt_type <<<"$facts")): её правильнее вести в Virtualization, а не в Devices"
    fi
    if [[ $DRY_RUN == 1 ]]; then warn "режим --dry-run: изменения только выводятся"; fi

    setup_api
    check_netbox
    load_profiles
    ensure_device "$facts"
    load_device_modules
    log "Модули..."
    sync_cpu "$facts"
    sync_memory "$facts"
    sync_disks "$facts"
    log "Интерфейсы и адреса..."
    sync_interfaces "$facts"
    sync_ips "$facts"
    ok "Готово: $DEVICE_NAME$([[ $DRY_RUN == 1 ]] && echo ' (dry-run, ничего не изменено)')"
}

# Позволяет подключать скрипт через source (для тестов) без запуска
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
