#!/bin/bash

# Скрипт для добавления серверов Linux в Netbox
# Использование: ./netbox_inventory.sh [OPTIONS]

set -euo pipefail

# Конфигурация (можно задать через переменные окружения или параметры)
NETBOX_URL="${NETBOX_URL:-https://netbox.homeinfra.su:8900}"
NETBOX_TOKEN="${NETBOX_TOKEN:-}"
DEVICE_NAME="${DEVICE_NAME:-}"
DEVICE_TYPE="${DEVICE_TYPE:-}"  # virtual или physical
MANUFACTURER="${MANUFACTURER:-}"
DEVICE_ROLE="${DEVICE_ROLE:-}"
SITE_NAME="${SITE_NAME:-}"
PLATFORM="${PLATFORM:-}"  # Например: linux
RACK_NAME="${RACK_NAME:-}"
LOCATION_NAME="${LOCATION_NAME:-}"
TENANT_NAME="${TENANT_NAME:-}"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция для вывода ошибок
error() {
    echo -e "${RED}Ошибка: $1${NC}" >&2
}

# Функция для вывода успешных сообщений
success() {
    echo -e "${GREEN}$1${NC}"
}

# Функция для вывода предупреждений
warning() {
    echo -e "${YELLOW}Предупреждение: $1${NC}"
}

# Функция для вывода информации
info() {
    echo -e "$1"
}

# Функция для выполнения API запросов к Netbox
netbox_api() {
    local method=$1
    local endpoint=$2
    local data="${3:-}"
    
    # Убеждаемся, что endpoint начинается с /
    if [[ ! "$endpoint" =~ ^/ ]]; then
        endpoint="/${endpoint}"
    fi
    
    # Убираем завершающий слэш из URL если есть, чтобы избежать двойных слэшей
    local base_url="${NETBOX_URL%/}"
    local url="${base_url}/api${endpoint}"
    
    local headers=(
        -H "Authorization: Token ${NETBOX_TOKEN}"
        -H "Content-Type: application/json"
        -H "Accept: application/json"
    )
    
    # Опции curl для улучшенной обработки ошибок
    # --connect-timeout: таймаут подключения (30 секунд, можно изменить через NETBOX_CONNECT_TIMEOUT)
    # --max-time: максимальное время выполнения запроса (60 секунд, можно изменить через NETBOX_MAX_TIME)
    # --retry: количество попыток при временных ошибках (2 попытки)
    # --retry-delay: задержка между попытками (1 секунда)
    # -k: игнорировать ошибки SSL сертификата (по умолчанию включено)
    # -L: следовать редиректам
    # -s: тихий режим (не показывать прогресс)
    local connect_timeout="${NETBOX_CONNECT_TIMEOUT:-30}"
    local max_time="${NETBOX_MAX_TIME:-60}"
    
    local curl_opts=(
        -s
        -L
        --connect-timeout "$connect_timeout"
        --max-time "$max_time"
        --retry 2
        --retry-delay 1
        -w "\n%{http_code}"
    )
    
    # Управление проверкой SSL через переменную окружения
    # По умолчанию игнорируем ошибки SSL (-k), но можно отключить через NETBOX_VERIFY_SSL=1
    if [ "${NETBOX_VERIFY_SSL:-0}" != "1" ]; then
        curl_opts+=(-k)
    fi
    
    # Опционально: использование конкретной версии TLS (если поддерживается curl)
    # Можно включить через NETBOX_TLS_VERSION=1.2
    if [ -n "${NETBOX_TLS_VERSION:-}" ]; then
        case "${NETBOX_TLS_VERSION}" in
            1.0|1.1|1.2|1.3)
                curl_opts+=(--tlsv${NETBOX_TLS_VERSION})
                ;;
        esac
    fi
    
    # Управление proxy через переменную окружения
    # NETBOX_NO_PROXY=1 - отключить proxy для всех запросов
    # NETBOX_NO_PROXY="host1,host2" - отключить proxy для конкретных хостов
    if [ -n "${NETBOX_NO_PROXY:-}" ]; then
        if [ "${NETBOX_NO_PROXY}" = "1" ] || [ "${NETBOX_NO_PROXY}" = "yes" ] || [ "${NETBOX_NO_PROXY}" = "true" ]; then
            # Отключить proxy для всех хостов
            curl_opts+=(--noproxy "*")
        else
            # Отключить proxy для конкретных хостов (список через запятую)
            curl_opts+=(--noproxy "${NETBOX_NO_PROXY}")
        fi
    fi
    
    local response
    local http_code
    
    local curl_exit_code=0
    local curl_stderr=""
    if [ -n "$data" ]; then
        curl_stderr=$(curl "${curl_opts[@]}" -X "$method" "$url" "${headers[@]}" -d "$data" 2>&1) || curl_exit_code=$?
        response="$curl_stderr"
    else
        curl_stderr=$(curl "${curl_opts[@]}" -X "$method" "$url" "${headers[@]}" 2>&1) || curl_exit_code=$?
        response="$curl_stderr"
    fi
    
    # Проверка на ошибку выполнения curl
    if [ $curl_exit_code -ne 0 ]; then
        error "Ошибка выполнения curl (код $curl_exit_code) при запросе к $endpoint"
        error "URL: $url"
        
        # Расшифровка кодов ошибок curl
        case $curl_exit_code in
            6)
                error "Не удалось разрешить имя хоста. Проверьте правильность URL: $base_url"
                ;;
            7)
                error "Не удалось подключиться к серверу. Проверьте доступность сервера и порт."
                ;;
            28)
                error "Таймаут соединения. Сервер не отвечает в течение установленного времени."
                ;;
            35)
                error "Ошибка SSL/TLS handshake. Проблема с сертификатом или шифрованием."
                ;;
            56)
                error "Ошибка получения данных по сети (код 56)."
                error "Возможные причины:"
                error "  - Проблемы с SSL/TLS соединением"
                error "  - Разрыв соединения во время передачи данных"
                error "  - Проблемы с прокси или файрволом"
                error "  - Нестабильное сетевое соединение"
                error "  - Несовместимость версий TLS между клиентом и сервером"
                local host_port=$(echo "$base_url" | sed 's|https\?://||' | cut -d/ -f1)
                error "Попробуйте:"
                error "  1. Проверить доступность сервера: curl -k -I $base_url"
                if [ -n "$host_port" ]; then
                    error "  2. Проверить SSL соединение: openssl s_client -connect $host_port"
                    error "  3. Проверить доступность порта: nc -zv $(echo $host_port | tr ':' ' ')"
                fi
                error "  4. Попробовать с явным указанием TLS версии:"
                error "     export NETBOX_VERIFY_SSL=0"
                error "     curl -k --tlsv1.2 $base_url/api/"
                ;;
            *)
                error "Неизвестная ошибка curl. Код: $curl_exit_code"
                ;;
        esac
        
        # Извлекаем только сообщение об ошибке (все кроме последней строки с HTTP кодом)
        local error_msg=$(echo "$response" | sed '$d')
        if [ -n "$error_msg" ]; then
            error "Сообщение curl: $error_msg"
        fi
        return 1
    fi
    
    # Разделяем ответ и HTTP код
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')
    
    # Проверка на пустой ответ или ошибку curl
    if [ -z "$http_code" ]; then
        error "Не удалось получить HTTP код при запросе к $endpoint"
        error "URL: $url"
        error "Ответ curl: $response"
        return 1
    fi
    
    # Проверка HTTP кода
    if [ "$http_code" -ge 400 ]; then
        error "HTTP ошибка ${http_code} при запросе к $endpoint"
        error "URL: $url"
        if [ -n "$response" ]; then
            error "Ответ сервера: $response"
        fi
        return 1
    fi
    
    # Для GET запросов проверяем, что ответ не пустой (Netbox API всегда возвращает JSON)
    # Проверяем не только на пустую строку, но и на строку, содержащую только пробелы
    local response_trimmed=$(echo "$response" | tr -d '[:space:]')
    if [ "$method" = "GET" ] && [ -z "$response_trimmed" ]; then
        error "Пустое тело ответа от сервера при GET запросе к $endpoint"
        error "HTTP код: $http_code"
        error "URL: $url"
        error "Netbox API должен возвращать JSON даже если объект не найден."
        warning "Возможно, проблема с подключением или конфигурацией сервера."
        if [ "${DEBUG:-0}" = "1" ]; then
            info "Отладочная информация: длина ответа: ${#response}, первые 100 символов: $(echo "$response" | head -c 100)"
        fi
        return 1
    fi
    
    # Если ответ пустой, но HTTP код успешный - это нормально для некоторых endpoints
    # (например, DELETE запросы могут возвращать пустое тело)
    echo "$response"
}

# Функция для получения или создания объекта
get_or_create() {
    local endpoint=$1
    local name_field=$2
    local name_value=$3
    local create_data=$4
    
    # URL encoding для значения параметра (расширенная версия)
    local encoded_value=$(echo "$name_value" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g' | sed 's/#/%23/g' | sed 's/\[/%5B/g' | sed 's/\]/%5D/g' | sed 's/@/%40/g')
    
    # Формируем URL запроса с учетом того, что endpoint может уже содержать параметры
    local query_param="${name_field}=${encoded_value}"
    if [[ "$endpoint" == *"?"* ]]; then
        local search_url="${endpoint}&${query_param}"
    else
        local search_url="${endpoint}?${query_param}"
    fi
    
    # Попытка найти существующий объект
    local response
    local api_exit_code=0
    response=$(netbox_api "GET" "$search_url" 2>/dev/null) || api_exit_code=$?
    
    # Проверка на ошибку выполнения netbox_api
    if [ $api_exit_code -ne 0 ]; then
        # Сообщение об ошибке уже выведено функцией netbox_api в stderr
        # Дополнительно выводим информацию для диагностики
        error "Не удалось выполнить запрос к API: endpoint=$search_url"
        return 1
    fi
    
    # Проверка на пустой ответ
    # Для GET запросов Netbox API всегда должен возвращать JSON, даже если объект не найден
    # Пустой ответ может означать проблему с подключением или конфигурацией
    if [ -z "$response" ]; then
        error "Пустой ответ от API при поиске объекта: endpoint=$search_url"
        error "Netbox API должен возвращать JSON (даже если объект не найден)."
        error "Проверьте:"
        error "  1. Доступность Netbox сервера: $NETBOX_URL"
        error "  2. Правильность API токена"
        error "  3. Сетевое подключение к серверу"
        return 1
    fi
    
    # Проверка на ошибки API
    if echo "$response" | grep -q '"error"'; then
        error "Ошибка API при поиске объекта: $response"
        return 1
    fi
    
    local count=$(echo "$response" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
    
    if [ "$count" -gt 0 ]; then
        local id=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
        if [ -n "$id" ] && [ "$id" -gt 0 ] 2>/dev/null; then
            echo "$id"
            return 0
        fi
    fi
    
    # Создание нового объекта
    local create_response=$(netbox_api "POST" "$endpoint" "$create_data")
    
    # Проверка на ошибки при создании
    if echo "$create_response" | grep -q '"error"'; then
        # Проверяем, не связана ли ошибка с уже существующим slug
        if echo "$create_response" | grep -qi "slug.*already exists"; then
            # Пытаемся найти объект по slug из create_data
            # Извлекаем slug из create_data (он может быть в формате "slug":"value")
            local slug_value=""
            if echo "$create_data" | grep -q '"slug"'; then
                slug_value=$(echo "$create_data" | grep -o '"slug":"[^"]*"' | cut -d'"' -f4)
            fi
            
            # Если slug найден, ищем по нему
            if [ -n "$slug_value" ]; then
                local slug_encoded=$(echo "$slug_value" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g')
                local slug_search_url="${endpoint}?slug=${slug_encoded}"
                local slug_response=$(netbox_api "GET" "$slug_search_url")
                local slug_count=$(echo "$slug_response" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
                if [ "$slug_count" -gt 0 ]; then
                    local id=$(echo "$slug_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                    if [ -n "$id" ] && [ "$id" -gt 0 ] 2>/dev/null; then
                        echo "$id"
                        return 0
                    fi
                fi
            fi
            
            # Если не нашли по slug, пробуем найти еще раз по имени (возможно, имя немного отличается)
            local retry_response=$(netbox_api "GET" "$search_url")
            local retry_count=$(echo "$retry_response" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
            if [ "$retry_count" -gt 0 ]; then
                local id=$(echo "$retry_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                if [ -n "$id" ] && [ "$id" -gt 0 ] 2>/dev/null; then
                    echo "$id"
                    return 0
                fi
            fi
        else
            # Для других ошибок тоже пробуем найти еще раз
            local retry_response=$(netbox_api "GET" "$search_url")
            local retry_count=$(echo "$retry_response" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
            if [ "$retry_count" -gt 0 ]; then
                local id=$(echo "$retry_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                if [ -n "$id" ] && [ "$id" -gt 0 ] 2>/dev/null; then
                    echo "$id"
                    return 0
                fi
            fi
        fi
        error "Не удалось создать объект: $create_response"
        return 1
    fi
    
    local id=$(echo "$create_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
    if [ -z "$id" ] || [ "$id" -le 0 ] 2>/dev/null; then
        error "Не удалось получить ID созданного объекта: $create_response"
        return 1
    fi
    echo "$id"
}

# Функция для установки lshw если он не установлен
install_lshw_if_needed() {
    if command -v lshw >/dev/null 2>&1; then
        return 0  # lshw уже установлен
    fi
    
    info "lshw не установлен. Попытка автоматической установки..."
    
    # Определяем дистрибутив Linux
    local distro=""
    local package_manager=""
    
    if [ -f /etc/os-release ]; then
        distro=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
    fi
    
    # Определяем менеджер пакетов
    if command -v apt-get >/dev/null 2>&1; then
        package_manager="apt"
    elif command -v yum >/dev/null 2>&1; then
        package_manager="yum"
    elif command -v dnf >/dev/null 2>&1; then
        package_manager="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        package_manager="pacman"
    elif command -v zypper >/dev/null 2>&1; then
        package_manager="zypper"
    else
        warning "Не удалось определить менеджер пакетов. Установите lshw вручную."
        return 1
    fi
    
    # Пробуем установить lshw
    local install_cmd=""
    case "$package_manager" in
        apt)
            if [ "$EUID" -eq 0 ]; then
                install_cmd="apt-get update -qq && apt-get install -y lshw"
            else
                install_cmd="sudo apt-get update -qq && sudo apt-get install -y lshw"
            fi
            ;;
        yum)
            if [ "$EUID" -eq 0 ]; then
                install_cmd="yum install -y lshw"
            else
                install_cmd="sudo yum install -y lshw"
            fi
            ;;
        dnf)
            if [ "$EUID" -eq 0 ]; then
                install_cmd="dnf install -y lshw"
            else
                install_cmd="sudo dnf install -y lshw"
            fi
            ;;
        pacman)
            if [ "$EUID" -eq 0 ]; then
                install_cmd="pacman -Sy --noconfirm lshw"
            else
                install_cmd="sudo pacman -Sy --noconfirm lshw"
            fi
            ;;
        zypper)
            if [ "$EUID" -eq 0 ]; then
                install_cmd="zypper install -y lshw"
            else
                install_cmd="sudo zypper install -y lshw"
            fi
            ;;
    esac
    
    if [ -n "$install_cmd" ]; then
        info "Установка lshw через $package_manager..."
        if eval "$install_cmd" 2>/dev/null; then
            if command -v lshw >/dev/null 2>&1; then
                success "lshw успешно установлен"
                return 0
            else
                warning "lshw установлен, но команда недоступна. Возможно, требуется обновить PATH."
                return 1
            fi
        else
            warning "Не удалось установить lshw автоматически. Возможно, требуются root права."
            warning "Попробуйте установить вручную: sudo $package_manager install lshw"
            return 1
        fi
    fi
    
    return 1
}

# Функция для исправления некорректного JSON от lshw
fix_lshw_json() {
    local json_input="$1"
    
    # Исправляем отсутствующие запятые между объектами
    # Паттерн: }    { или }    "id" -> },    {
    echo "$json_input" | sed -E 's/\}\s*\{/},{/g' | \
    sed -E 's/\}\s*"id"/},"id"/g' | \
    sed -E 's/\}\s*"class"/},"class"/g' | \
    sed -E 's/\}\s*"description"/},"description"/g' | \
    sed -E 's/\}\s*"product"/},"product"/g' | \
    sed -E 's/\}\s*"vendor"/},"vendor"/g' | \
    sed -E 's/\}\s*"serial"/},"serial"/g' | \
    sed -E 's/\}\s+\{/},{/g' | \
    sed -E 's/"children"\s*:\s*\[\s*\{/"children":[{/g'
}

# Функция для получения информации о системе через lshw
get_system_info() {
    info "Сбор информации о системе..."
    
    # Проверяем наличие lshw и пытаемся установить если нужно
    if ! command -v lshw >/dev/null 2>&1; then
        if ! install_lshw_if_needed; then
            warning "lshw недоступен. Используется упрощенный метод сбора информации."
            get_system_info_fallback
            return
        fi
    fi
    
    # Имя хоста
    if [ -z "$DEVICE_NAME" ]; then
        DEVICE_NAME=$(hostname)
    fi
    
    # Получаем информацию через lshw (может потребоваться sudo)
    local lshw_output=""
    local lshw_json_available=true
    
    # Проверяем, поддерживает ли lshw формат JSON
    if ! lshw -json -version >/dev/null 2>&1 && ! lshw -json >/dev/null 2>&1; then
        # Проверяем версию lshw
        local lshw_version=$(lshw -version 2>&1 | head -1 || echo "")
        if [ -n "$lshw_version" ]; then
            warning "lshw может не поддерживать формат JSON. Версия: $lshw_version"
        fi
    fi
    
    if [ "$EUID" -eq 0 ]; then
        lshw_output=$(lshw -json 2>/dev/null || echo "")
    else
        # Пробуем без sudo, если не получится - используем fallback
        lshw_output=$(lshw -json 2>/dev/null || echo "")
        if [ -z "$lshw_output" ]; then
            # Пробуем с sudo, если доступен
            if command -v sudo >/dev/null 2>&1; then
                lshw_output=$(sudo lshw -json 2>/dev/null || echo "")
            fi
            if [ -z "$lshw_output" ]; then
                warning "lshw требует root прав для полной информации. Используется упрощенный метод."
                get_system_info_fallback
                return
            fi
        fi
    fi
    
    # Если lshw не вернул данные, используем fallback
    if [ -z "$lshw_output" ] || [ "$lshw_output" = "[]" ] || [ "$lshw_output" = "null" ]; then
        warning "lshw не вернул данные. Используется упрощенный метод."
        get_system_info_fallback
        return
    fi
    
    # Проверяем, что вывод действительно JSON
    # Убираем пробелы и переносы строк в начале для проверки
    local lshw_first_chars=$(echo "$lshw_output" | head -c 10 | tr -d '[:space:]')
    
    # Проверяем, начинается ли вывод с [ или { (признаки JSON)
    if [ -z "$lshw_first_chars" ] || ([ "${lshw_first_chars:0:1}" != "[" ] && [ "${lshw_first_chars:0:1}" != "{" ]); then
        # Проверяем, не является ли это текстовым форматом (начинается с имени хоста или описания)
        local first_line=$(echo "$lshw_output" | head -1 | tr -d '[:space:]')
        if [ -n "$first_line" ] && ! echo "$first_line" | grep -qE '^[\[\{]'; then
            warning "lshw вернул данные в текстовом формате вместо JSON."
            if [ "${DEBUG:-0}" = "1" ]; then
                info "Первая строка вывода: $(echo "$lshw_output" | head -1)"
            fi
            
            # Пробуем получить JSON формат с другими опциями
            local lshw_cmd=""
            if [ "$EUID" -eq 0 ]; then
                lshw_cmd="lshw"
            elif command -v sudo >/dev/null 2>&1; then
                lshw_cmd="sudo lshw"
            else
                lshw_cmd="lshw"
            fi
            
            # Пробуем разные варианты команды lshw
            lshw_output=$($lshw_cmd -json -quiet 2>/dev/null || echo "")
            if [ -z "$lshw_output" ]; then
                lshw_output=$($lshw_cmd -json -sanitize 2>/dev/null || echo "")
            fi
            
            # Проверяем результат еще раз
            lshw_first_chars=$(echo "$lshw_output" | head -c 10 | tr -d '[:space:]')
            if [ -z "$lshw_first_chars" ] || ([ "${lshw_first_chars:0:1}" != "[" ] && [ "${lshw_first_chars:0:1}" != "{" ]); then
                warning "Не удалось получить JSON формат от lshw. Возможно, версия lshw не поддерживает JSON."
                warning "Используется упрощенный метод сбора информации."
                get_system_info_fallback
                return
            fi
        fi
    fi
    
    # Проверяем наличие jq для парсинга JSON (приоритет)
    if ! command -v jq >/dev/null 2>&1; then
        # Пытаемся установить jq
        info "jq не найден. Попытка установки..."
        local jq_install_cmd=""
        if command -v apt-get >/dev/null 2>&1; then
            if [ "$EUID" -eq 0 ]; then
                jq_install_cmd="apt-get update -qq && apt-get install -y jq"
            else
                jq_install_cmd="sudo apt-get update -qq && sudo apt-get install -y jq"
            fi
        elif command -v yum >/dev/null 2>&1; then
            if [ "$EUID" -eq 0 ]; then
                jq_install_cmd="yum install -y jq"
            else
                jq_install_cmd="sudo yum install -y jq"
            fi
        elif command -v dnf >/dev/null 2>&1; then
            if [ "$EUID" -eq 0 ]; then
                jq_install_cmd="dnf install -y jq"
            else
                jq_install_cmd="sudo dnf install -y jq"
            fi
        elif command -v pacman >/dev/null 2>&1; then
            if [ "$EUID" -eq 0 ]; then
                jq_install_cmd="pacman -Sy --noconfirm jq"
            else
                jq_install_cmd="sudo pacman -Sy --noconfirm jq"
            fi
        elif command -v zypper >/dev/null 2>&1; then
            if [ "$EUID" -eq 0 ]; then
                jq_install_cmd="zypper install -y jq"
            else
                jq_install_cmd="sudo zypper install -y jq"
            fi
        fi
        
        if [ -n "$jq_install_cmd" ]; then
            if eval "$jq_install_cmd" 2>/dev/null; then
                if command -v jq >/dev/null 2>&1; then
                    success "jq успешно установлен"
                fi
            fi
        fi
    fi
    
    # ИСПРАВЛЕНИЕ: Проверяем и исправляем некорректный JSON перед парсингом
    if command -v python3 >/dev/null 2>&1; then
        # Проверяем валидность JSON через Python
        if ! echo "$lshw_output" | python3 -m json.tool >/dev/null 2>&1; then
            warning "Обнаружен некорректный JSON от lshw. Попытка исправления..."
            lshw_output=$(fix_lshw_json "$lshw_output")
            # Проверяем еще раз
            if ! echo "$lshw_output" | python3 -m json.tool >/dev/null 2>&1; then
                warning "Не удалось исправить JSON от lshw. Используется упрощенный метод."
                get_system_info_fallback
                return
            else
                info "JSON успешно исправлен"
            fi
        fi
    elif command -v jq >/dev/null 2>&1; then
        # Проверяем валидность JSON через jq
        if ! echo "$lshw_output" | jq . >/dev/null 2>&1; then
            warning "Обнаружен некорректный JSON от lshw. Попытка исправления..."
            lshw_output=$(fix_lshw_json "$lshw_output")
            # Проверяем еще раз
            if ! echo "$lshw_output" | jq . >/dev/null 2>&1; then
                warning "Не удалось исправить JSON от lshw. Используется упрощенный метод."
                get_system_info_fallback
                return
            else
                info "JSON успешно исправлен"
            fi
        fi
    fi
    
    # Проверяем наличие python3 для парсинга JSON (fallback)
    if ! command -v python3 >/dev/null 2>&1; then
        # Пытаемся установить python3
        info "python3 не найден. Попытка установки..."
        local python_install_cmd=""
        if command -v apt-get >/dev/null 2>&1; then
            if [ "$EUID" -eq 0 ]; then
                python_install_cmd="apt-get install -y python3"
            else
                python_install_cmd="sudo apt-get install -y python3"
            fi
        elif command -v yum >/dev/null 2>&1; then
            if [ "$EUID" -eq 0 ]; then
                python_install_cmd="yum install -y python3"
            else
                python_install_cmd="sudo yum install -y python3"
            fi
        elif command -v dnf >/dev/null 2>&1; then
            if [ "$EUID" -eq 0 ]; then
                python_install_cmd="dnf install -y python3"
            else
                python_install_cmd="sudo dnf install -y python3"
            fi
        fi
        
        if [ -n "$python_install_cmd" ]; then
            if eval "$python_install_cmd" 2>/dev/null; then
                if command -v python3 >/dev/null 2>&1; then
                    success "python3 успешно установлен"
                fi
            fi
        fi
    fi
    
    # Парсим JSON через jq (приоритет) или python (fallback)
    # jq более легковесный и специализированный для JSON, но Python лучше для сложной рекурсивной логики
    if command -v jq >/dev/null 2>&1; then
        # Используем jq для парсинга JSON (упрощенная версия)
        # Для полной функциональности (NVMe storage info, сложные проверки) используется Python
        local lshw_debug_file=""
        if [ "${DEBUG:-0}" = "1" ]; then
            lshw_debug_file=$(mktemp /tmp/lshw_output.XXXXXX.json)
            echo "$lshw_output" > "$lshw_debug_file"
            info "Отладочный режим: вывод lshw сохранен в $lshw_debug_file"
        fi
        
        local jq_error_output=$(mktemp /tmp/jq_error.XXXXXX)
        
        # Парсим через jq с упрощенной логикой
        local parsed_info=$(echo "$lshw_output" | jq -r '
            (if type == "array" then .[0] else . end) as $data |
            
            # CPU
            ([$data | .. | select(.class? == "processor" or .class? == "cpu")] | length) as $cpu_count |
            ([$data | .. | select(.class? == "processor" or .class? == "cpu") | .product // .description] | first // "Unknown") as $cpu_model |
            ([$data | .. | select(.class? == "processor" or .class? == "cpu") | .vendor] | first // "") as $cpu_vendor |
            
            # RAM - только модули с детальной информацией
            ([$data | .. | select(.class? == "memory" and (.id? | test("bank") or .vendor? or .product?) and .size? and .size > 0) | .size] | add // 0) as $ram_total |
            (if $ram_total > 0 then $ram_total else ([$data | .. | select(.class? == "memory" and (.id? | test("bank") | not) and .size? and .size > 0) | .size] | add // 0) end) as $ram_final |
            ($ram_final / 1073741824 | floor) as $ram_gb |
            
            # RAM модули
            ([$data | .. | select(.class? == "memory" and (.id? | test("bank") or .vendor? or .product?) and .size? and .size > 0)] |
                map(
                    (.size / 1073741824 | if . >= 1024 then "\(. / 1024 | . * 10 | round / 10)T" elif . >= 1 then "\(. * 10 | round / 10)G" else "\(. * 1024 | round)M" end) +
                    (if .vendor? and (.vendor | test("generic|unknown|to be filled by o.e.m."; "i") | not) then ":vendor=\(.vendor)" else "" end) +
                    (if .product? and (.product | test("generic|unknown|to be filled by o.e.m."; "i") | not) then ":product=\(.product)" else "" end) +
                    (if .serial? and (.serial | test("to be filled by o.e.m.|unknown"; "i") | not) then ":serial=\(.serial)" else "" end)
                ) | join(",")) as $ram_modules |
            
            # Диски - обрабатываем как class="disk", так и class="volume" с logicalname без разделов (p1, p2 и т.д.)
            ([$data | .. | select(
                (.class? == "disk" or .class? == "volume") and 
                .size? and .size > 0 and 
                .logicalname? and 
                (.logicalname | type == "string") and 
                (.logicalname | test("hwmon|/dev/ng") | not) and
                # Исключаем разделы (partitions) - они имеют суффиксы типа p1, p2, sda1 и т.д.
                (.logicalname | test("/dev/(nvme[0-9]+n[0-9]+|sd[a-z]+)$")) 
            )] |
                map(
                    (.logicalname | if type == "array" then .[0] else . end | ltrimstr("/dev/")) as $name |
                    (.size / 1073741824 | if . >= 1024 then "\(. / 1024 | . * 10 | round / 10)T" elif . >= 1 then "\(. * 10 | round / 10)G" else "\(. * 1024 | round)M" end) as $size |
                    $name + ":" + $size +
                    (if .vendor? and (.vendor | test("generic|unknown|to be filled by o.e.m."; "i") | not) then ":vendor=\(.vendor)" else "" end) +
                    (if .product? and (.product | test("generic|unknown|to be filled by o.e.m."; "i") | not) then ":product=\(.product)" else "" end) +
                    (if .serial? and (.serial | test("to be filled by o.e.m.|unknown"; "i") | not) then ":serial=\(.serial)" else "" end)
                ) | join(",")) as $disks |
            
            # Device type
            ([$data | .. | select(.class? == "system") | .product] | first // "") as $product_name |
            (if ($product_name | test("vmware|virtualbox|kvm|qemu|xen|hyper-v|microsoft corporation|virtual"; "i")) then "virtual" else "physical" end) as $device_type |
            
            # Manufacturer (материнская плата приоритетнее)
            ([$data | .. | select(.class? == "bus" and (.description? | test("motherboard"; "i"))) | .vendor] | first // "") as $mb_vendor |
            ([$data | .. | select(.class? == "bus" and (.description? | test("motherboard"; "i"))) | .product] | first // "") as $mb_product |
            ([$data | .. | select(.class? == "bus" and (.description? | test("motherboard"; "i"))) | .serial] | first // "") as $mb_serial |
            ([$data | .. | select(.class? == "system") | .vendor] | first // "") as $sys_vendor |
            (if ($mb_vendor | length > 0 and ($mb_vendor | test("generic|unknown|to be filled by o.e.m."; "i") | not)) then $mb_vendor elif ($sys_vendor | length > 0 and ($sys_vendor | test("^System") | not)) then $sys_vendor else "" end) as $manufacturer |
            
            # Вывод в формате export VAR='value'
            "export CPU_COUNT='" + ($cpu_count | tostring) + "'\n" +
            "export CPU_MODEL='" + ($cpu_model | gsub("'" ; "'\\''")) + "'\n" +
            "export CPU_VENDOR='" + ($cpu_vendor | gsub("'" ; "'\\''")) + "'\n" +
            "export RAM_TOTAL_GB='" + ($ram_gb | tostring) + "'\n" +
            "export RAM_MODULES='" + ($ram_modules | gsub("'" ; "'\\''")) + "'\n" +
            "export DISKS='" + ($disks | gsub("'" ; "'\\''")) + "'\n" +
            "export DEVICE_TYPE='" + $device_type + "'\n" +
            (if ($manufacturer | length > 0) then "export MANUFACTURER='" + ($manufacturer | gsub("'" ; "'\\''")) + "'\n" else "" end) +
            (if ($mb_product | length > 0) then "export MOTHERBOARD_PRODUCT='" + ($mb_product | gsub("'" ; "'\\''")) + "'\n" else "" end) +
            (if ($mb_serial | length > 0) then "export MOTHERBOARD_SERIAL='" + ($mb_serial | gsub("'" ; "'\\''")) + "'\n" else "" end)
        ' 2>"$jq_error_output")
        
        local jq_exit_code=$?
        
        if [ $jq_exit_code -ne 0 ] || [ -z "$parsed_info" ]; then
            local error_msg=$(cat "$jq_error_output" 2>/dev/null || echo "Unknown error")
            warning "Не удалось распарсить вывод lshw через jq: $error_msg"
            if [ "${DEBUG:-0}" = "1" ] && [ -n "$lshw_debug_file" ]; then
                warning "Проверьте файл $lshw_debug_file для отладки"
            fi
            rm -f "$jq_error_output" "$lshw_debug_file"
            # Пробуем использовать Python как fallback
            if command -v python3 >/dev/null 2>&1; then
                info "Попытка использовать Python для парсинга..."
            else
                get_system_info_fallback
                return
            fi
        else
            rm -f "$jq_error_output"
            
            # Загружаем переменные
            local vars_file=$(mktemp /tmp/netbox_vars.XXXXXX)
            echo "$parsed_info" > "$vars_file"
            source "$vars_file"
            rm -f "$vars_file"
            
            # Проверяем, что получили хотя бы базовую информацию
            if [ -z "$CPU_COUNT" ] && [ -z "$CPU_MODEL" ] && [ -z "$RAM_TOTAL_GB" ]; then
                warning "jq вернул данные, но не удалось извлечь информацию. Пробуем Python..."
                if ! command -v python3 >/dev/null 2>&1; then
                    get_system_info_fallback
                    return
                fi
                # Продолжаем к Python fallback
            else
                rm -f "$lshw_debug_file"
                return
            fi
        fi
    fi
    
    # Fallback на Python для сложной логики (NVMe storage info, сложные проверки)
    if command -v python3 >/dev/null 2>&1; then
        local lshw_debug_file=""
        if [ "${DEBUG:-0}" = "1" ]; then
            lshw_debug_file=$(mktemp /tmp/lshw_output.XXXXXX.json)
            echo "$lshw_output" > "$lshw_debug_file"
            info "Отладочный режим: вывод lshw сохранен в $lshw_debug_file"
        fi
        
        # Используем Python для парсинга JSON (полная функциональность)
        local python_script='
import json
import sys
import re

def parse_lshw_data(input_data):
    """Парсит данные lshw и возвращает словарь с информацией"""
    try:
        data = json.loads(input_data)
    except json.JSONDecodeError as e:
        newline = chr(10)
        sys.stderr.write("Error: Invalid JSON from lshw: " + str(e) + newline)
        sys.stderr.write("First 500 chars: " + str(input_data[:500]) + newline)
        sys.exit(1)
    
    # lshw может вернуть массив или один объект
    if isinstance(data, list):
        if len(data) > 0:
            data = data[0]
        else:
            newline = chr(10)
            sys.stderr.write("Error: Empty lshw output array" + newline)
        sys.exit(1)
    
    if not isinstance(data, dict):
        newline = chr(10)
        sys.stderr.write("Error: Unexpected data type: " + str(type(data)) + newline)
        sys.exit(1)
    
    # CPU информация
    cpu_count = 0
    cpu_model = "Unknown"
    cpu_vendor = ""
    
    def find_cpu(node):
        nonlocal cpu_count, cpu_model, cpu_vendor
        if not isinstance(node, dict):
            return
        
        node_class = node.get("class", "").lower()
        # Ищем CPU по классу "processor" или "cpu"
        if node_class in ["processor", "cpu"]:
            cpu_count += 1
            if not cpu_model or cpu_model == "Unknown":
                cpu_model = node.get("product", node.get("description", "Unknown"))
                cpu_vendor = node.get("vendor", "")
        
        # Рекурсивно обрабатываем дочерние элементы
        if "children" in node and isinstance(node["children"], list):
            for child in node["children"]:
                if isinstance(child, dict):
                    find_cpu(child)
    
    find_cpu(data)
    
    # RAM информация
    ram_total = 0
    ram_modules = []  # Список модулей памяти с детальной информацией
    
    def find_memory(node):
        nonlocal ram_total, ram_modules
        if not isinstance(node, dict):
            return
        
        node_class = node.get("class", "").lower()
        
        # Ищем память по классу "memory" (общий объем) или отдельные модули
        if node_class == "memory":
            # Проверяем, является ли это отдельным модулем (bank) или общим объемом
            # Отдельные модули обычно имеют id начинающийся с "bank:" или содержат vendor/product
            node_id = str(node.get("id", "")).lower()
            vendor = str(node.get("vendor", "")).strip()
            product = str(node.get("product", "")).strip()
            serial = str(node.get("serial", "")).strip()
            size = node.get("size", 0)
            
            # Проверяем, есть ли дочерние элементы с детальной информацией (banks)
            has_detailed_children = False
            if "children" in node and isinstance(node["children"], list):
                for child in node["children"]:
                    if isinstance(child, dict):
                        child_class = child.get("class", "").lower()
                        child_id = str(child.get("id", "")).lower()
                        child_vendor = str(child.get("vendor", "")).strip()
                        child_product = str(child.get("product", "")).strip()
                        if child_class == "memory" and ("bank" in child_id or child_vendor or child_product):
                            has_detailed_children = True
                            break
            
            # Если это отдельный модуль памяти (bank) с детальной информацией
            # Проверяем по id (bank:0, bank:1 и т.д.) или наличию vendor/product
            # Пропускаем кэш (cache), BIOS и другие служебные элементы памяти
            description = str(node.get("description", "")).lower()
            skip_element = False
            if "cache" in description or "bios" in description or "rom" in description:
                skip_element = True
            
            if not skip_element and ("bank" in node_id or vendor or product) and size > 0:
                if isinstance(size, (int, str)):
                    try:
                        size = int(size)
                    except (ValueError, TypeError):
                        size = 0
                
                # Пропускаем очень маленькие размеры (меньше 1MB), это обычно кэш или служебная память
                if size > 0 and size >= (1024 * 1024):
                    ram_total += size
                    size_gb = size // (1024**3) if size > 0 else 0
                    
                    # Форматируем размер
                    if size_gb >= 1024:
                        size_str = str(round(size_gb/1024, 1)) + "T"
                    elif size_gb >= 1:
                        size_str = str(round(size_gb, 1)) + "G"
                    else:
                        size_mb = size // (1024**2) if size > 0 else 0
                        size_str = str(size_mb) + "M"
                    
                    # Пропускаем модули с нулевым размером (используем return вместо continue, так как это функция)
                    if size_str == "0M" or size_str == "0G" or size_str == "0T" or size_gb == 0:
                        # Рекурсивно обрабатываем дочерние элементы перед выходом
                        if "children" in node and isinstance(node["children"], list):
                            for child in node["children"]:
                                if isinstance(child, dict):
                                    find_memory(child)
                        return
                    
                    # Создаем строку с информацией о модуле
                    module_info = size_str
                    if vendor and vendor.lower() not in ["generic", "unknown", "to be filled by o.e.m."]:
                        module_info += ":vendor=" + str(vendor)
                    if product and product.lower() not in ["generic", "unknown", "to be filled by o.e.m."]:
                        module_info += ":product=" + str(product)
                    if serial and serial.lower() not in ["to be filled by o.e.m.", "unknown"]:
                        module_info += ":serial=" + str(serial)
                    
                    ram_modules.append(module_info)
            elif size > 0 and not has_detailed_children:
                # Общий объем памяти из системной памяти (без детальной информации)
                # Добавляем только если нет дочерних элементов с детальной информацией
                if isinstance(size, (int, str)):
                    try:
                        size = int(size)
                    except (ValueError, TypeError):
                        size = 0
                if size > 0:
                    ram_total += size
        
        # Рекурсивно обрабатываем дочерние элементы
        if "children" in node and isinstance(node["children"], list):
            for child in node["children"]:
                if isinstance(child, dict):
                    find_memory(child)
    
    find_memory(data)
    # Конвертируем байты в гигабайты
    ram_gb = ram_total // (1024**3) if ram_total > 0 else 0
    
    # Формируем строку с информацией о модулях RAM
    ram_modules_str = ",".join(ram_modules) if ram_modules else ""
    
    # Диски
    disks = []
    storage_info = {}  # Храним информацию о storage устройствах (NVMe) для дочерних disk элементов
    
    def find_storage(node, parent_vendor="", parent_product="", parent_serial=""):
        """Собирает информацию о storage устройствах (NVMe)"""
        nonlocal storage_info
        if not isinstance(node, dict):
            return
        
        node_class = node.get("class", "").lower()
        logicalname = node.get("logicalname", "")
        
        # Если это storage устройство (NVMe), сохраняем информацию
        if node_class == "storage":
            storage_vendor = str(node.get("vendor", "")).strip()
            storage_product = str(node.get("product", "")).strip()
            storage_serial = str(node.get("serial", "")).strip()
            
            # Если logicalname - это список, берем первый элемент
            if isinstance(logicalname, list):
                logicalname = logicalname[0] if logicalname else ""
            
            # Преобразуем в строку для использования как ключ словаря
            if logicalname:
                logicalname_str = str(logicalname).strip()
                if logicalname_str:
                    storage_info[logicalname_str] = {
                        "vendor": storage_vendor if storage_vendor and storage_vendor.lower() not in ["generic", "unknown", "to be filled by o.e.m."] else "",
                        "product": storage_product if storage_product and storage_product.lower() not in ["generic", "unknown", "to be filled by o.e.m."] else "",
                        "serial": storage_serial if storage_serial and storage_serial.lower() not in ["to be filled by o.e.m.", "unknown"] else ""
                    }
        
        # Передаем информацию о vendor/product/serial дочерним элементам
        current_vendor = str(node.get("vendor", "")).strip() or parent_vendor
        current_product = str(node.get("product", "")).strip() or parent_product
        current_serial = str(node.get("serial", "")).strip() or parent_serial
        
        # Рекурсивно обрабатываем дочерние элементы
        if "children" in node and isinstance(node["children"], list):
            for child in node["children"]:
                if isinstance(child, dict):
                    find_storage(child, current_vendor, current_product, current_serial)
    
    def find_disk(node, parent_vendor="", parent_product="", parent_serial=""):
        nonlocal disks, storage_info
        if not isinstance(node, dict):
            return
        
        node_class = node.get("class", "").lower()
        
        # Обрабатываем disk элементы и volume элементы, которые являются физическими дисками (не разделами)
        if node_class == "disk" or (node_class == "volume" and node.get("logicalname")):
            disk_name = node.get("logicalname", "")
            size = node.get("size", 0)
            
            # Пропускаем элементы без размера или с невалидными именами
            # (например, namespace без размера или hwmon устройства)
            if not size or size == 0:
                # Рекурсивно обрабатываем дочерние элементы, но не добавляем этот элемент
                if "children" in node and isinstance(node["children"], list):
                    for child in node["children"]:
                        if isinstance(child, dict):
                            find_disk(child, parent_vendor, parent_product, parent_serial)
                return
            
            # Извлекаем имя устройства из logicalname (например, /dev/sda -> sda)
            # Пропускаем элементы без logicalname или с невалидными именами
            if not disk_name:
                return
            
            # Если logicalname - это список, берем первый элемент
            if isinstance(disk_name, list):
                disk_name = disk_name[0] if disk_name else ""
            
            # Пропускаем hwmon устройства и другие служебные устройства
            if disk_name.startswith("hwmon") or disk_name.startswith("/dev/ng"):
                return
            
            # Извлекаем имя устройства из logicalname (например, /dev/sda -> sda)
            if disk_name.startswith("/dev/"):
                disk_name = disk_name.replace("/dev/", "")
            
            # Для volumes проверяем, что это не раздел
            if node_class == "volume":
                # Проверяем, что это физический диск, а не раздел
                # Разделы NVMe имеют суффиксы p1, p2, p3 (например nvme0n1p1)
                # Разделы SATA имеют цифру после буквы (например sda1)
                # Физические диски NVMe заканчиваются на n+цифра (например nvme0n1)
                # Физические диски SATA заканчиваются на букву (например sda)
                # Проверяем, что это раздел (p1, p2 для NVMe или цифра после буквы для SATA)
                pattern_nvme_partition = "p[0-9]+$"
                pattern_sata_partition = "[a-z]+[0-9]+$"
                pattern_nvme_disk = "n[0-9]+$"
                if re.search(pattern_nvme_partition, disk_name) or (re.search(pattern_sata_partition, disk_name) and not re.search(pattern_nvme_disk, disk_name)):
                    # Это раздел, пропускаем
                    return
            
            if disk_name:
                # size уже получен выше, проверяем его еще раз
                if isinstance(size, (int, str)):
                    try:
                        size = int(size)
                    except (ValueError, TypeError):
                        size = 0
                
                # Пропускаем диски без размера (дополнительная проверка)
                if size == 0:
                    return
                
                size_gb = size // (1024**3) if size > 0 else 0
                
                # Пытаемся получить vendor/product/serial из текущего узла
                vendor = str(node.get("vendor", "")).strip()
                product = str(node.get("product", "")).strip()
                serial = str(node.get("serial", "")).strip()
                
                # Если нет информации в текущем узле, пробуем получить из родителя
                if not vendor or vendor.lower() in ["generic", "unknown", "to be filled by o.e.m."]:
                    vendor = parent_vendor
                if not product or product.lower() in ["generic", "unknown", "to be filled by o.e.m."]:
                    product = parent_product
                if not serial or serial.lower() in ["to be filled by o.e.m.", "unknown"]:
                    serial = parent_serial
                
                # Для NVMe дисков проверяем storage_info по логическому имени родителя
                # Приоритетно используем информацию из storage устройства, так как serial в volume может быть LVM serial
                storage_match_found = False
                for storage_logicalname, storage_data in storage_info.items():
                    storage_name = storage_logicalname.replace("/dev/", "")
                    # Проверяем, что disk_name начинается с storage_name (например, nvme1n1 начинается с nvme1)
                    if disk_name.startswith(storage_name):
                        storage_match_found = True
                        # Для NVMe дисков всегда приоритетно используем vendor/product/serial из storage
                        if storage_data["vendor"]:
                            vendor = storage_data["vendor"]
                        if storage_data["product"]:
                            product = storage_data["product"]
                        if storage_data["serial"]:
                            # Используем serial из storage, так как serial в volume может быть LVM serial
                            serial = storage_data["serial"]
                        break
                
                # Если не нашли storage, но нет vendor/product, пробуем из родителя
                if not storage_match_found:
                    if not vendor or vendor.lower() in ["generic", "unknown", "to be filled by o.e.m."]:
                        vendor = parent_vendor
                    if not product or product.lower() in ["generic", "unknown", "to be filled by o.e.m."]:
                        product = parent_product
                    if not serial or serial.lower() in ["to be filled by o.e.m.", "unknown"]:
                        serial = parent_serial
                
                # Форматируем размер
                if size_gb >= 1024:
                    size_str = str(round(size_gb/1024, 1)) + "T"
                elif size_gb >= 1:
                    size_str = str(round(size_gb, 1)) + "G"
                else:
                    size_mb = size // (1024**2) if size > 0 else 0
                    size_str = str(size_mb) + "M"
                
                disk_info = str(disk_name) + ":" + size_str
                if vendor and vendor.lower() not in ["generic", "unknown", "to be filled by o.e.m."]:
                    disk_info += ":vendor=" + str(vendor)
                if product and product.lower() not in ["generic", "unknown", "to be filled by o.e.m."]:
                    disk_info += ":product=" + str(product)
                if serial and serial.lower() not in ["to be filled by o.e.m.", "unknown"]:
                    disk_info += ":serial=" + str(serial)
                disks.append(disk_info)
        
        # Передаем информацию о vendor/product/serial дочерним элементам
        current_vendor = str(node.get("vendor", "")).strip() or parent_vendor
        current_product = str(node.get("product", "")).strip() or parent_product
        current_serial = str(node.get("serial", "")).strip() or parent_serial
        
        # Рекурсивно обрабатываем дочерние элементы
        if "children" in node and isinstance(node["children"], list):
            for child in node["children"]:
                if isinstance(child, dict):
                    find_disk(child, current_vendor, current_product, current_serial)
    
    # Сначала собираем информацию о storage устройствах
    find_storage(data)
    # Затем обрабатываем диски
    find_disk(data)
    disks_str = ",".join(disks)
    
    # Определение типа устройства
    product_name = ""
    sys_vendor = ""
    motherboard_product = ""
    motherboard_vendor = ""
    motherboard_serial = ""
    
    def find_system(node):
        nonlocal product_name, sys_vendor, motherboard_product, motherboard_vendor, motherboard_serial
        if not isinstance(node, dict):
            return
        
        node_class = node.get("class", "").lower()
        description = str(node.get("description", "")).lower()
        
        # Ищем информацию о системе
        if node_class == "system":
            product_name = node.get("product", "")
            sys_vendor = node.get("vendor", "")
        
        # Ищем информацию о материнской плате
        if node_class == "bus" and "motherboard" in description:
            motherboard_product = node.get("product", "")
            motherboard_vendor = node.get("vendor", "")
            motherboard_serial = node.get("serial", "")
        
        # Рекурсивно обрабатываем дочерние элементы
        if "children" in node and isinstance(node["children"], list):
            for child in node["children"]:
                if isinstance(child, dict):
                    find_system(child)
    
    find_system(data)
    
    device_type = "physical"
    if product_name:
        product_lower = product_name.lower()
        if any(vm in product_lower for vm in ["vmware", "virtualbox", "kvm", "qemu", "xen", "hyper-v", "microsoft corporation", "virtual"]):
            device_type = "virtual"
    
    # Выводим результаты в формате, безопасном для bash
    # Используем одинарные кавычки для экранирования специальных символов
    
    def safe_export(var_name, var_value):
        """Безопасно выводит переменную для bash"""
        var_str = str(var_value)
        quote_char = chr(39)
        escape_pattern = quote_char + chr(92) + quote_char + quote_char
        safe_value = var_str.replace(quote_char, escape_pattern)
        print("export " + var_name + "=" + quote_char + safe_value + quote_char)
    
    safe_export("CPU_COUNT", cpu_count)
    safe_export("CPU_MODEL", cpu_model)
    safe_export("CPU_VENDOR", cpu_vendor)
    safe_export("RAM_TOTAL_GB", ram_gb)
    safe_export("RAM_MODULES", ram_modules_str)
    safe_export("DISKS", disks_str)
    safe_export("DEVICE_TYPE", device_type)
    
    # Используем vendor материнской платы или системный vendor
    if motherboard_vendor and motherboard_vendor.lower() not in ["generic", "unknown", "to be filled by o.e.m."]:
        safe_export("MANUFACTURER", motherboard_vendor)
        if motherboard_product:
            safe_export("MOTHERBOARD_PRODUCT", motherboard_product)
        if motherboard_serial:
            safe_export("MOTHERBOARD_SERIAL", motherboard_serial)
    elif sys_vendor and not sys_vendor.strip().startswith("System"):
        safe_export("MANUFACTURER", sys_vendor)

try:
    input_data = sys.stdin.read()
    if not input_data or input_data.strip() == "":
        error_msg = "Error: Empty input from lshw"
        newline = chr(10)
        sys.stderr.write(error_msg + newline)
        sys.exit(1)
    
    parse_lshw_data(input_data)
    
except Exception as e:
    newline = chr(10)
    sys.stderr.write("Error parsing lshw output: " + str(e) + newline)
    import traceback
    sys.stderr.write(traceback.format_exc())
    sys.exit(1)
'
        local python_error_output=$(mktemp /tmp/python_error.XXXXXX)
        local parsed_info=$(echo "$lshw_output" | python3 -c "$python_script" 2>"$python_error_output")
        local python_exit_code=$?
        
        if [ $python_exit_code -ne 0 ] || [ -z "$parsed_info" ]; then
            local error_msg=$(cat "$python_error_output" 2>/dev/null || echo "Unknown error")
            warning "Не удалось распарсить вывод lshw: $error_msg"
            if [ "${DEBUG:-0}" = "1" ] && [ -n "$lshw_debug_file" ]; then
                warning "Проверьте файл $lshw_debug_file для отладки"
            fi
            rm -f "$python_error_output" "$lshw_debug_file"
            get_system_info_fallback
            return
        fi
        
        rm -f "$python_error_output"
        
        # Загружаем переменные безопасным способом
        # Используем временный файл и source для безопасной загрузки
        local vars_file=$(mktemp /tmp/netbox_vars.XXXXXX)
        echo "$parsed_info" > "$vars_file"
        source "$vars_file"
        rm -f "$vars_file"
        
        # Проверяем, что получили хотя бы базовую информацию
        if [ -z "$CPU_COUNT" ] && [ -z "$CPU_MODEL" ] && [ -z "$RAM_TOTAL_GB" ]; then
            warning "lshw вернул данные, но не удалось извлечь информацию. Используется упрощенный метод."
            get_system_info_fallback
            return
        fi
    elif command -v jq >/dev/null 2>&1; then
        # jq доступен, но уже попробовали выше - используем fallback
        warning "jq доступен, но не удалось использовать. Используется упрощенный метод."
        get_system_info_fallback
        return
    else
        warning "Не найден python3 или jq для парсинга JSON. Используется упрощенный метод."
        get_system_info_fallback
        return
    fi
    
    # CPU информация (fallback если не получена)
    if [ -z "$CPU_COUNT" ] || [ "$CPU_COUNT" -eq 0 ]; then
        CPU_COUNT=$(nproc)
    fi
    if [ -z "$CPU_MODEL" ] || [ "$CPU_MODEL" = "Unknown" ]; then
        CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//' || echo "Unknown")
    fi
    
    # RAM информация (fallback если не получена)
    if [ -z "$RAM_TOTAL_GB" ] || [ "$RAM_TOTAL_GB" -eq 0 ]; then
        RAM_TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
        RAM_TOTAL_GB=$((RAM_TOTAL_MB / 1024))
    fi
    
    # Диски (fallback если не получены)
    if [ -z "$DISKS" ]; then
        DISKS=$(lsblk -d -n -o NAME,SIZE,TYPE | grep disk | awk '{print $1":"$2}' | tr '\n' ',' | sed 's/,$//')
    fi
    
    # IP адреса
    IP_ADDRESSES=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | tr '\n' ',' | sed 's/,$//')
    
    # Производитель (для виртуальных машин)
    if [ -z "$MANUFACTURER" ] && [ "$DEVICE_TYPE" = "virtual" ]; then
        if [ -f /sys/class/dmi/id/sys_vendor ]; then
            MANUFACTURER=$(cat /sys/class/dmi/id/sys_vendor)
        else
            MANUFACTURER="Generic"
        fi
    fi
    
    # Платформа
    if [ -z "$PLATFORM" ]; then
        if [ -f /etc/os-release ]; then
            PLATFORM=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | awk '{print toupper($0)}')
        else
            PLATFORM="Linux"
        fi
    fi
    
    info "Собранная информация:"
    info "  Имя устройства: $DEVICE_NAME"
    info "  Тип: $DEVICE_TYPE"
    info "  CPU: $CPU_COUNT ядер, $CPU_MODEL"
    if [ -n "$CPU_VENDOR" ]; then
        info "  CPU Vendor: $CPU_VENDOR"
    fi
    info "  RAM: ${RAM_TOTAL_GB}GB"
    info "  Диски: $DISKS"
    info "  IP адреса: $IP_ADDRESSES"
}

# Fallback функция для сбора информации без lshw
get_system_info_fallback() {
    # Имя хоста
    if [ -z "$DEVICE_NAME" ]; then
        DEVICE_NAME=$(hostname)
    fi
    
    # CPU информация
    CPU_COUNT=$(nproc)
    CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^ *//' || echo "Unknown")
    
    # RAM информация (в MB)
    RAM_TOTAL_MB=$(free -m | awk '/^Mem:/{print $2}')
    RAM_TOTAL_GB=$((RAM_TOTAL_MB / 1024))
    
    # Диски
    DISKS=$(lsblk -d -n -o NAME,SIZE,TYPE | grep disk | awk '{print $1":"$2}' | tr '\n' ',' | sed 's/,$//')
    
    # IP адреса
    IP_ADDRESSES=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | tr '\n' ',' | sed 's/,$//')
    
    # Определение типа устройства (виртуальное или физическое)
    if [ -z "$DEVICE_TYPE" ]; then
        if [ -f /sys/class/dmi/id/product_name ]; then
            PRODUCT_NAME=$(cat /sys/class/dmi/id/product_name)
            if echo "$PRODUCT_NAME" | grep -qiE 'vmware|virtualbox|kvm|qemu|xen|hyper-v|microsoft corporation'; then
                DEVICE_TYPE="virtual"
            else
                DEVICE_TYPE="physical"
            fi
        elif [ -d /sys/class/dmi/id ]; then
            DEVICE_TYPE="physical"
        else
            DEVICE_TYPE="virtual"
        fi
    fi
    
    # Производитель (для виртуальных машин)
    if [ -z "$MANUFACTURER" ] && [ "$DEVICE_TYPE" = "virtual" ]; then
        if [ -f /sys/class/dmi/id/sys_vendor ]; then
            MANUFACTURER=$(cat /sys/class/dmi/id/sys_vendor)
        else
            MANUFACTURER="Generic"
        fi
    fi
    
    # Платформа
    if [ -z "$PLATFORM" ]; then
        if [ -f /etc/os-release ]; then
            PLATFORM=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"' | awk '{print toupper($0)}')
        else
            PLATFORM="Linux"
        fi
    fi
    
    info "Собранная информация:"
    info "  Имя устройства: $DEVICE_NAME"
    info "  Тип: $DEVICE_TYPE"
    info "  CPU: $CPU_COUNT ядер, $CPU_MODEL"
    info "  RAM: ${RAM_TOTAL_GB}GB"
    info "  Диски: $DISKS"
    info "  IP адреса: $IP_ADDRESSES"
}

# Функция для добавления устройства в Netbox
add_device_to_netbox() {
    info "Добавление устройства в Netbox..."
    
    # Инициализация переменных
    local MANUFACTURER_ID=""
    local DEVICE_TYPE_ID=""
    local DEVICE_ROLE_ID=""
    local SITE_ID=""
    local PLATFORM_ID=""
    local RACK_ID=""
    local LOCATION_ID=""
    local TENANT_ID=""
    
    # Получение или создание производителя
    # В Netbox manufacturer обязателен для device-type, поэтому создаем дефолтного если не указан
    if [ -z "$MANUFACTURER" ]; then
        if [ "$DEVICE_TYPE" = "virtual" ]; then
            MANUFACTURER="Generic"
        else
            MANUFACTURER="Unknown"
        fi
    fi
    
    local manufacturer_slug=$(echo "$MANUFACTURER" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
    
    # Сначала пробуем найти по slug (более надежно, так как slug уникален)
    local slug_search_url="/dcim/manufacturers/?slug=${manufacturer_slug}"
    local slug_response=$(netbox_api "GET" "$slug_search_url")
    local slug_count=$(echo "$slug_response" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
    
    if [ "$slug_count" -gt 0 ]; then
        MANUFACTURER_ID=$(echo "$slug_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
        if [ -n "$MANUFACTURER_ID" ] && [ "$MANUFACTURER_ID" -gt 0 ] 2>/dev/null; then
            info "Производитель найден по slug ID: $MANUFACTURER_ID"
        else
            # Если не нашли по slug, используем стандартную функцию get_or_create
            MANUFACTURER_ID=$(get_or_create "/dcim/manufacturers/" "name" "$MANUFACTURER" "{\"name\":\"$MANUFACTURER\",\"slug\":\"$manufacturer_slug\"}" | tr -d '\n\r\t ')
        fi
    else
        # Если не нашли по slug, используем стандартную функцию get_or_create
        MANUFACTURER_ID=$(get_or_create "/dcim/manufacturers/" "name" "$MANUFACTURER" "{\"name\":\"$MANUFACTURER\",\"slug\":\"$manufacturer_slug\"}" | tr -d '\n\r\t ')
    fi
    info "Производитель ID: $MANUFACTURER_ID"
    
    # Получение или создание типа устройства
    # manufacturer обязателен в Netbox API
    # Используем модель материнской платы если доступна, иначе общий тип
    local device_type_name=""
    if [ -n "${MOTHERBOARD_PRODUCT:-}" ] && [ -n "$MOTHERBOARD_PRODUCT" ]; then
        device_type_name="$MOTHERBOARD_PRODUCT"
    else
        device_type_name="${DEVICE_TYPE}-server"
    fi
    local device_type_slug=$(echo "$device_type_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
    DEVICE_TYPE_ID=$(get_or_create "/dcim/device-types/" "model" "$device_type_name" "{\"manufacturer\":$MANUFACTURER_ID,\"model\":\"$device_type_name\",\"slug\":\"$device_type_slug\"}" | tr -d '\n\r\t ')
    info "Тип устройства ID: $DEVICE_TYPE_ID"
    
    # Создаем module-bay templates на уровне device-type для стандартных компонентов
    # Это позволит всем устройствам этого типа иметь одинаковую структуру bays
    if [ -n "$DEVICE_TYPE_ID" ]; then
        # Создаем bay template для CPU
        local cpu_bay_template_check=$(netbox_api "GET" "/dcim/module-bay-templates/?device_type_id=${DEVICE_TYPE_ID}&name=CPU")
        local cpu_bay_template_count=$(echo "$cpu_bay_template_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
        if [ "$cpu_bay_template_count" -eq 0 ]; then
            local cpu_bay_template_data="{\"device_type\":$DEVICE_TYPE_ID,\"name\":\"CPU\",\"position\":\"1\",\"label\":\"CPU Socket\"}"
            netbox_api "POST" "/dcim/module-bay-templates/" "$cpu_bay_template_data" > /dev/null || true
        fi
        
        # Templates для RAM будут создаваться динамически в create_modules_and_platform
        # только когда модули RAM успешно создаются (чтобы избежать пустых bays)
        
        # Создаем bay templates для дисков динамически, только для реального количества дисков
        # Это нужно сделать ПЕРЕД созданием device, чтобы Netbox не создал лишние пустые bays
        if [ -n "${DISKS:-}" ] && [ -n "$DISKS" ]; then
            IFS=',' read -ra DISK_ARRAY_TEMP <<< "$DISKS"
            local disk_count=${#DISK_ARRAY_TEMP[@]}
            if [ "$disk_count" -gt 0 ]; then
                for i in $(seq 1 $disk_count); do
                    local disk_bay_name="Disk-$i"
                    local disk_bay_template_check=$(netbox_api "GET" "/dcim/module-bay-templates/?device_type_id=${DEVICE_TYPE_ID}&name=${disk_bay_name}")
                    local disk_bay_template_count=$(echo "$disk_bay_template_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
                    if [ "$disk_bay_template_count" -eq 0 ]; then
                        local disk_position=$((10 + i))
                        local disk_bay_template_data="{\"device_type\":$DEVICE_TYPE_ID,\"name\":\"$disk_bay_name\",\"position\":\"$disk_position\",\"label\":\"Disk Slot $i\"}"
                        netbox_api "POST" "/dcim/module-bay-templates/" "$disk_bay_template_data" > /dev/null || true
                    fi
                done
            fi
        fi
    fi
    
    # Получение или создание роли устройства для самого сервера (если указана)
    if [ -z "$DEVICE_ROLE" ]; then
        DEVICE_ROLE="server"
    fi
    local device_role_slug=$(echo "$DEVICE_ROLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    DEVICE_ROLE_ID=$(get_or_create "/dcim/device-roles/" "name" "$DEVICE_ROLE" "{\"name\":\"$DEVICE_ROLE\",\"slug\":\"$device_role_slug\"}" | tr -d '\n\r\t ')
    info "Роль устройства ID: $DEVICE_ROLE_ID"
    
    # Получение или создание сайта
    if [ -z "$SITE_NAME" ]; then
        SITE_NAME="default"
    fi
    local site_slug=$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    SITE_ID=$(get_or_create "/dcim/sites/" "name" "$SITE_NAME" "{\"name\":\"$SITE_NAME\",\"slug\":\"$site_slug\"}" | tr -d '\n\r\t ')
    info "Сайт ID: $SITE_ID"
    
    # Платформа будет создана автоматически из компонентов в функции create_component_devices_and_platform
    # Если платформа указана явно, она будет использована как имя для платформы из компонентов
    PLATFORM_ID=""
    
    # Получение или создание стеллажа (rack)
    if [ -n "$RACK_NAME" ]; then
        # Rack должен принадлежать сайту
        local rack_slug=$(echo "$RACK_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        # Ищем rack по имени и сайту
        local rack_search=$(netbox_api "GET" "/dcim/racks/?name=${RACK_NAME}&site_id=${SITE_ID}")
        local rack_count=$(echo "$rack_search" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
        if [ "$rack_count" -gt 0 ]; then
            RACK_ID=$(echo "$rack_search" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
            info "Стеллаж ID: $RACK_ID"
        else
            # Создаем новый rack
            local rack_data="{\"name\":\"$RACK_NAME\",\"site\":$SITE_ID,\"slug\":\"$rack_slug\"}"
            local rack_response=$(netbox_api "POST" "/dcim/racks/" "$rack_data")
            if echo "$rack_response" | grep -q '"id"'; then
                RACK_ID=$(echo "$rack_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
                info "Создан стеллаж ID: $RACK_ID"
            else
                warning "Не удалось создать стеллаж: $rack_response"
            fi
        fi
    fi
    
    # Получение или создание местоположения (location)
    if [ -n "$LOCATION_NAME" ]; then
        # Location должен принадлежать сайту
        local location_slug=$(echo "$LOCATION_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        local location_search=$(netbox_api "GET" "/dcim/locations/?name=${LOCATION_NAME}&site_id=${SITE_ID}")
        local location_count=$(echo "$location_search" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
        if [ "$location_count" -gt 0 ]; then
            LOCATION_ID=$(echo "$location_search" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
            info "Местоположение ID: $LOCATION_ID"
        else
            # Создаем новое location
            local location_data="{\"name\":\"$LOCATION_NAME\",\"site\":$SITE_ID,\"slug\":\"$location_slug\"}"
            local location_response=$(netbox_api "POST" "/dcim/locations/" "$location_data")
            if echo "$location_response" | grep -q '"id"'; then
                LOCATION_ID=$(echo "$location_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
                info "Создано местоположение ID: $LOCATION_ID"
            else
                warning "Не удалось создать местоположение: $location_response"
            fi
        fi
    fi
    
    # Получение или создание арендатора (tenant)
    if [ -n "$TENANT_NAME" ]; then
        local tenant_slug=$(echo "$TENANT_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        TENANT_ID=$(get_or_create "/tenancy/tenants/" "name" "$TENANT_NAME" "{\"name\":\"$TENANT_NAME\",\"slug\":\"$tenant_slug\"}" | tr -d '\n\r\t ')
        info "Арендатор ID: $TENANT_ID"
    fi
    
    # Проверка существования устройства
    local device_name_encoded=$(echo "$DEVICE_NAME" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g')
    local device_check=$(netbox_api "GET" "/dcim/devices/?name=${device_name_encoded}")
    
    if [ -z "$device_check" ]; then
        error "Не удалось проверить существование устройства"
        return 1
    fi
    
    local device_count=$(echo "$device_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
    
    local DEVICE_ID=""
    if [ "$device_count" -gt 0 ]; then
        warning "Устройство '$DEVICE_NAME' уже существует в Netbox"
        DEVICE_ID=$(echo "$device_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
        if [ -n "$DEVICE_ID" ]; then
            info "Обновление существующего устройства ID: $DEVICE_ID"
        else
            info "Обновление существующего устройства"
        fi
        
        # Для существующих устройств обновляем platform, rack, location, tenant (если указаны)
        local update_fields=()
        if [ -n "$PLATFORM_ID" ]; then
            update_fields+=("\"platform\":$PLATFORM_ID")
        fi
        if [ -n "$RACK_ID" ]; then
            update_fields+=("\"rack\":$RACK_ID")
        fi
        if [ -n "$LOCATION_ID" ]; then
            update_fields+=("\"location\":$LOCATION_ID")
        fi
        if [ -n "$TENANT_ID" ]; then
            update_fields+=("\"tenant\":$TENANT_ID")
        fi
        
        if [ ${#update_fields[@]} -gt 0 ]; then
            info "Обновление полей устройства..."
            local update_data="{$(IFS=','; echo "${update_fields[*]}")}"
            
            # Выполняем обновление устройства напрямую через curl для лучшей обработки ошибок
            local base_url="${NETBOX_URL%/}"
            local update_url="${base_url}/api/dcim/devices/${DEVICE_ID}/"
            local update_curl_response=$(curl -s -k -L -w "\n%{http_code}" -X "PATCH" "$update_url" \
                -H "Authorization: Token ${NETBOX_TOKEN}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json" \
                -d "$update_data" 2>&1)
            
            local update_http_code=$(echo "$update_curl_response" | tail -n1)
            local update_body=$(echo "$update_curl_response" | sed '$d')
            
            if [ -z "$update_http_code" ] || [ "$update_http_code" -ge 400 ]; then
                warning "Не удалось обновить платформу устройства HTTP ${update_http_code:-unknown}"
                if [ -n "$update_body" ]; then
                    info "Ответ сервера: $update_body"
                fi
            else
                success "Платформа устройства обновлена"
            fi
        else
            info "Устройство уже существует, пропускаем обновление основных полей"
        fi
    else
        # Создание нового устройства
        # Экранируем имя устройства для JSON
        local device_name_json=$(echo "$DEVICE_NAME" | sed 's/"/\\"/g')
        # Формируем JSON в одну строку для избежания проблем с парсингом
        # В Netbox API для создания устройства используется поле "role" вместо "device_role"
        local device_data="{\"name\":\"$device_name_json\",\"device_type\":$DEVICE_TYPE_ID,\"role\":$DEVICE_ROLE_ID,\"site\":$SITE_ID"
        if [ -n "$PLATFORM_ID" ]; then
            device_data="${device_data},\"platform\":$PLATFORM_ID"
        fi
        if [ -n "$RACK_ID" ]; then
            device_data="${device_data},\"rack\":$RACK_ID"
        fi
        if [ -n "$LOCATION_ID" ]; then
            device_data="${device_data},\"location\":$LOCATION_ID"
        fi
        if [ -n "$TENANT_ID" ]; then
            device_data="${device_data},\"tenant\":$TENANT_ID"
        fi
        device_data="${device_data}}"
        
        local device_response=$(netbox_api "POST" "/dcim/devices/" "$device_data")
        DEVICE_ID=$(echo "$device_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
        
        if [ -z "$DEVICE_ID" ] || [ "$DEVICE_ID" -le 0 ] 2>/dev/null; then
            error "Не удалось создать устройство: $device_response"
            return 1
        fi
        success "Устройство создано с ID: $DEVICE_ID"
    fi
    
    # Проверка, что DEVICE_ID установлена
    if [ -z "$DEVICE_ID" ]; then
        error "DEVICE_ID не установлена после создания/обновления устройства"
        return 1
    fi
    
    # Создание модулей для компонентов и сборка платформы
    create_modules_and_platform "$DEVICE_ID"
    
    # Добавление интерфейсов и IP адресов
    add_interfaces_and_ips "$DEVICE_ID"
    
    success "Устройство '$DEVICE_NAME' успешно добавлено/обновлено в Netbox!"
}

# Функция для получения ID module-type-profile по имени
get_module_type_profile_id() {
    local profile_name=$1
    local profile_name_encoded=$(echo "$profile_name" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g')
    local profile_check=$(netbox_api "GET" "/dcim/module-type-profiles/?name=${profile_name_encoded}")
    local profile_count=$(echo "$profile_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
    
    if [ "$profile_count" -gt 0 ]; then
        local profile_id=$(echo "$profile_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
        echo "$profile_id"
    else
        warning "Module-type-profile '$profile_name' не найден"
        echo ""
    fi
}

# Функция для получения или создания module bay
get_or_create_module_bay() {
    local device_id=$1
    local bay_name=$2
    local bay_name_json=$(echo "$bay_name" | sed 's/"/\\"/g')
    local bay_name_encoded=$(echo "$bay_name_json" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g')
    
    # Проверяем существование module bay
    local bay_check=$(netbox_api "GET" "/dcim/module-bays/?device_id=${device_id}&name=${bay_name_encoded}")
    local bay_count=$(echo "$bay_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
    
    if [ "$bay_count" -gt 0 ]; then
        local bay_id=$(echo "$bay_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
        echo "$bay_id"
    else
        # Создаем новый module bay
        local bay_data="{\"device\":$device_id,\"name\":\"$bay_name_json\"}"
        local bay_response=$(netbox_api "POST" "/dcim/module-bays/" "$bay_data")
        if echo "$bay_response" | grep -q '"id"'; then
            local bay_id=$(echo "$bay_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
            echo "$bay_id"
        else
            warning "Не удалось создать module bay '$bay_name': $bay_response"
            echo ""
        fi
    fi
}

# Функция для создания модулей компонентов и сборки платформы
create_modules_and_platform() {
    local server_device_id=$1
    info "Создание модулей компонентов и сборка платформы..."
    
    # Создаем или получаем платформу
    local platform_name="${CPU_MODEL} ${CPU_COUNT}cores ${RAM_TOTAL_GB}GB"
    if [ -n "$PLATFORM" ]; then
        platform_name="$PLATFORM"
    fi
    
    local platform_slug=$(echo "$platform_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
    local platform_name_encoded=$(echo "$platform_name" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g')
    local platform_check=$(netbox_api "GET" "/dcim/platforms/?name=${platform_name_encoded}")
    local platform_count=$(echo "$platform_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
    
    if [ "$platform_count" -gt 0 ]; then
        PLATFORM_ID=$(echo "$platform_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
        info "Платформа уже существует ID: $PLATFORM_ID"
    else
        local platform_name_json=$(echo "$platform_name" | sed 's/"/\\"/g')
        local platform_data="{\"name\":\"$platform_name_json\",\"slug\":\"$platform_slug\"}"
        local platform_response=$(netbox_api "POST" "/dcim/platforms/" "$platform_data")
        if echo "$platform_response" | grep -q '"id"'; then
            PLATFORM_ID=$(echo "$platform_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
            info "Создана платформа: $platform_name ID: $PLATFORM_ID"
        else
            warning "Не удалось создать платформу: $platform_response"
        fi
    fi
    
    # Обновляем основное устройство с платформой
    if [ -n "$PLATFORM_ID" ]; then
        local device_update_data="{\"platform\":$PLATFORM_ID}"
        netbox_api "PATCH" "/dcim/devices/${server_device_id}/" "$device_update_data" > /dev/null || warning "Не удалось обновить платформу устройства"
    fi
    
    # Извлекаем manufacturer из CPU_MODEL
    # Используем CPU_VENDOR если доступен, иначе извлекаем из CPU_MODEL
    local cpu_manufacturer=""
    local cpu_model_part=""
    
    # Приоритетно используем CPU_VENDOR если он указан
    if [ -n "${CPU_VENDOR:-}" ] && [ -n "$CPU_VENDOR" ]; then
        cpu_manufacturer="$CPU_VENDOR"
        # Модель - это весь CPU_MODEL
        cpu_model_part="$CPU_MODEL"
    elif echo "$CPU_MODEL" | grep -qiE '^Intel|Intel\(R\)'; then
        # Для Intel используем просто "Intel" без торговых марок
        cpu_manufacturer="Intel"
        # Убираем "Intel(R) Core(TM)" или "Intel" из начала модели
        cpu_model_part=$(echo "$CPU_MODEL" | sed 's/Intel(R) Core(TM) //' | sed 's/Intel(R) //' | sed 's/^Intel //')
    elif echo "$CPU_MODEL" | grep -qiE '^AMD'; then
        cpu_manufacturer="AMD"
        cpu_model_part=$(echo "$CPU_MODEL" | sed 's/^AMD //')
    else
        cpu_manufacturer="Generic"
        cpu_model_part="$CPU_MODEL"
    fi
    
    # Создаем или получаем manufacturer для CPU
    local cpu_manufacturer_slug=$(echo "$cpu_manufacturer" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
    local cpu_manufacturer_id=$(get_or_create "/dcim/manufacturers/" "name" "$cpu_manufacturer" "{\"name\":\"$cpu_manufacturer\",\"slug\":\"$cpu_manufacturer_slug\"}" | tr -d '\n\r\t ')
    
    # Создаем module-type для CPU
    # В Netbox module-type имеет manufacturer и model отдельно, model - это только модель процессора
    local cpu_model_json=$(echo "$cpu_model_part" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g')
    local cpu_module_type_model="$cpu_model_part"
    local cpu_module_type_slug=$(echo "$cpu_module_type_model" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
    local cpu_module_type_model_encoded=$(echo "$cpu_module_type_model" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g' | sed 's/@/%40/g' | sed 's/(/%28/g' | sed 's/)/%29/g')
    local cpu_module_type_check=$(netbox_api "GET" "/dcim/module-types/?manufacturer_id=${cpu_manufacturer_id}&model=${cpu_module_type_model_encoded}")
    local cpu_module_type_count=$(echo "$cpu_module_type_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
    
    local cpu_module_type_id=""
    if [ "$cpu_module_type_count" -gt 0 ]; then
        cpu_module_type_id=$(echo "$cpu_module_type_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
        info "  CPU module-type уже существует ID: $cpu_module_type_id"
    else
        local cpu_profile_id=$(get_module_type_profile_id "CPU")
        local cpu_module_type_model_json=$(echo "$cpu_module_type_model" | sed 's/"/\\"/g')
        
        # Извлекаем частоту CPU из модели (если есть, например "3.90GHz")
        local cpu_speed=""
        if echo "$CPU_MODEL" | grep -qE '[0-9]+\.[0-9]+GHz'; then
            cpu_speed=$(echo "$CPU_MODEL" | grep -oE '[0-9]+\.[0-9]+GHz' | head -1)
        fi
        
        # Определяем архитектуру (обычно x86_64 для современных систем)
        local cpu_arch="x86_64"
        if [ -n "${CPU_VENDOR:-}" ] && echo "${CPU_VENDOR:-}" | grep -qi "arm"; then
            cpu_arch="arm64"
        fi
        
        # Формируем данные для создания module-type с профилем и атрибутами
        local cpu_module_type_data="{\"manufacturer\":$cpu_manufacturer_id,\"model\":\"$cpu_module_type_model_json\",\"slug\":\"$cpu_module_type_slug\""
        if [ -n "$cpu_profile_id" ]; then
            cpu_module_type_data="${cpu_module_type_data},\"module_type_profile\":$cpu_profile_id"
        fi
        # Добавляем атрибуты CPU согласно профилю: cores, speed, architecture
        cpu_module_type_data="${cpu_module_type_data},\"attributes\":{"
        cpu_module_type_data="${cpu_module_type_data}\"cores\":$CPU_COUNT"
        if [ -n "$cpu_speed" ]; then
            local cpu_speed_json=$(echo "$cpu_speed" | sed 's/"/\\"/g')
            cpu_module_type_data="${cpu_module_type_data},\"speed\":\"$cpu_speed_json\""
        fi
        cpu_module_type_data="${cpu_module_type_data},\"architecture\":\"$cpu_arch\""
        cpu_module_type_data="${cpu_module_type_data}}"
        cpu_module_type_data="${cpu_module_type_data}}"
        
        local cpu_module_type_response=$(netbox_api "POST" "/dcim/module-types/" "$cpu_module_type_data")
        if echo "$cpu_module_type_response" | grep -q '"id"'; then
            cpu_module_type_id=$(echo "$cpu_module_type_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
            info "  Создан CPU module-type: $cpu_manufacturer $cpu_module_type_model ID: $cpu_module_type_id"
        else
            warning "Не удалось создать CPU module-type: $cpu_module_type_response"
        fi
    fi
    
    # Создаем module (экземпляр) для CPU
    if [ -n "$cpu_module_type_id" ]; then
        # Получаем или создаем module bay для CPU
        local cpu_bay_id=$(get_or_create_module_bay "$server_device_id" "CPU")
        if [ -z "$cpu_bay_id" ]; then
            warning "Не удалось получить или создать module bay для CPU"
        else
            local platform_desc_json=$(echo "$platform_name" | sed 's/"/\\"/g')
            local cpu_module_data="{\"device\":$server_device_id,\"module_bay\":$cpu_bay_id,\"module_type\":$cpu_module_type_id,\"description\":\"Installed in platform: $platform_desc_json\"}"
            local cpu_module_check=$(netbox_api "GET" "/dcim/modules/?device_id=${server_device_id}&module_bay_id=${cpu_bay_id}")
            local cpu_module_count=$(echo "$cpu_module_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
            
            if [ "$cpu_module_count" -gt 0 ]; then
                local cpu_module_id=$(echo "$cpu_module_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                # Обновляем описание
                local cpu_module_update_data="{\"description\":\"Installed in platform: $platform_desc_json\"}"
                netbox_api "PATCH" "/dcim/modules/${cpu_module_id}/" "$cpu_module_update_data" > /dev/null || true
                info "  CPU module уже существует ID: $cpu_module_id"
            else
                local cpu_module_response=$(netbox_api "POST" "/dcim/modules/" "$cpu_module_data")
                if echo "$cpu_module_response" | grep -q '"id"'; then
                    local cpu_module_id=$(echo "$cpu_module_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                    info "  Создан CPU module ID: $cpu_module_id"
                else
                    warning "Не удалось создать CPU module: $cpu_module_response"
                fi
            fi
        fi
    fi
    
    # Создаем module-type для RAM
    local ram_manufacturer="Generic"
    local ram_manufacturer_slug=$(echo "$ram_manufacturer" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
    local ram_manufacturer_id=$(get_or_create "/dcim/manufacturers/" "name" "$ram_manufacturer" "{\"name\":\"$ram_manufacturer\",\"slug\":\"$ram_manufacturer_slug\"}" | tr -d '\n\r\t ')
    
    local ram_module_type_name="${RAM_TOTAL_GB}GB"
    local ram_module_type_slug=$(echo "$ram_module_type_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
    local ram_module_type_name_encoded=$(echo "$ram_module_type_name" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g')
    local ram_module_type_check=$(netbox_api "GET" "/dcim/module-types/?manufacturer_id=${ram_manufacturer_id}&model=${ram_module_type_name_encoded}")
    local ram_module_type_count=$(echo "$ram_module_type_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
    
    local ram_module_type_id=""
    if [ "$ram_module_type_count" -gt 0 ]; then
        ram_module_type_id=$(echo "$ram_module_type_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
        info "  RAM module-type уже существует ID: $ram_module_type_id"
    else
        local ram_profile_id=$(get_module_type_profile_id "Memory")
        local ram_module_type_name_json=$(echo "$ram_module_type_name" | sed 's/"/\\"/g')
        
        # Формируем данные для создания module-type с профилем Memory и атрибутами
        local ram_module_type_data="{\"manufacturer\":$ram_manufacturer_id,\"model\":\"$ram_module_type_name_json\",\"slug\":\"$ram_module_type_slug\""
        if [ -n "$ram_profile_id" ]; then
            ram_module_type_data="${ram_module_type_data},\"module_type_profile\":$ram_profile_id"
        fi
        # Добавляем атрибуты Memory согласно профилю: ecc, size, class, data_rate
        ram_module_type_data="${ram_module_type_data},\"attributes\":{"
        ram_module_type_data="${ram_module_type_data}\"size\":\"${RAM_TOTAL_GB}GB\""
        ram_module_type_data="${ram_module_type_data},\"ecc\":false"
        ram_module_type_data="${ram_module_type_data},\"class\":\"DDR4\""
        ram_module_type_data="${ram_module_type_data}}"
        ram_module_type_data="${ram_module_type_data}}"
        
        local ram_module_type_response=$(netbox_api "POST" "/dcim/module-types/" "$ram_module_type_data")
        if echo "$ram_module_type_response" | grep -q '"id"'; then
            ram_module_type_id=$(echo "$ram_module_type_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
            info "  Создан RAM module-type: $ram_module_type_name ID: $ram_module_type_id"
        else
            warning "Не удалось создать RAM module-type: $ram_module_type_response"
        fi
    fi
    
    # Создаем modules (экземпляры) для RAM
    # Если есть детальная информация о модулях RAM, создаем отдельный module для каждого
    if [ -n "${RAM_MODULES:-}" ] && [ -n "$RAM_MODULES" ]; then
        # Создаем bay templates для отдельных модулей RAM (RAM-1, RAM-2, и т.д.)
        # только если есть детальная информация о модулях
        if [ -n "$DEVICE_TYPE_ID" ]; then
            IFS=',' read -ra RAM_MODULE_ARRAY_TEMP <<< "$RAM_MODULES"
            local ram_module_count_temp=0
            for ram_module_info_temp in "${RAM_MODULE_ARRAY_TEMP[@]}"; do
                local ram_module_size_temp=$(echo "$ram_module_info_temp" | cut -d: -f1)
                if [ -n "$ram_module_size_temp" ] && [ "$ram_module_size_temp" != "" ] && [ "$ram_module_size_temp" != "0M" ] && [ "$ram_module_size_temp" != "0G" ] && [ "$ram_module_size_temp" != "0T" ] && [ "$ram_module_size_temp" != "0" ]; then
                    ram_module_count_temp=$((ram_module_count_temp + 1))
                fi
            done
            
            # Создаем templates только для нужного количества модулей
            for i in $(seq 1 $ram_module_count_temp); do
                local ram_bay_name="RAM-$i"
                local ram_bay_template_check=$(netbox_api "GET" "/dcim/module-bay-templates/?device_type_id=${DEVICE_TYPE_ID}&name=${ram_bay_name}")
                local ram_bay_template_count=$(echo "$ram_bay_template_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
                if [ "$ram_bay_template_count" -eq 0 ]; then
                    local ram_position=$((20 + i))
                    local ram_bay_template_data="{\"device_type\":$DEVICE_TYPE_ID,\"name\":\"$ram_bay_name\",\"position\":\"$ram_position\",\"label\":\"Memory Slot $i\"}"
                    netbox_api "POST" "/dcim/module-bay-templates/" "$ram_bay_template_data" > /dev/null || true
                fi
            done
        fi
        
        local ram_module_index=1
        IFS=',' read -ra RAM_MODULE_ARRAY <<< "$RAM_MODULES"
        for ram_module_info in "${RAM_MODULE_ARRAY[@]}"; do
            # Пропускаем пустые элементы
            if [ -z "$ram_module_info" ] || [ "$ram_module_info" = "" ]; then
                continue
            fi
            
            # Извлекаем информацию о модуле (формат: 16G:vendor=Kingston:product=KHX2133C13S4/16G:serial=19441024)
            local ram_module_size=$(echo "$ram_module_info" | cut -d: -f1)
            
            # Пропускаем модули с нулевым или пустым размером
            if [ -z "$ram_module_size" ] || [ "$ram_module_size" = "" ] || [ "$ram_module_size" = "0M" ] || [ "$ram_module_size" = "0G" ] || [ "$ram_module_size" = "0T" ] || [ "$ram_module_size" = "0" ]; then
                continue
            fi
            
            local ram_module_vendor=$(echo "$ram_module_info" | grep -o 'vendor=[^:]*' | cut -d= -f2 || echo "")
            local ram_module_product=$(echo "$ram_module_info" | grep -o 'product=[^:]*' | cut -d= -f2 || echo "")
            local ram_module_serial=$(echo "$ram_module_info" | grep -o 'serial=[^:]*' | cut -d= -f2 || echo "")
            
            # Создаем или находим module-type для конкретного модуля RAM
            local ram_module_type_name=""
            if [ -n "$ram_module_product" ] && [ -n "$ram_module_vendor" ]; then
                ram_module_type_name="${ram_module_vendor} ${ram_module_product}"
            else
                ram_module_type_name="${ram_module_size} RAM"
            fi
            
            local ram_module_type_slug=$(echo "$ram_module_type_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
            local ram_module_type_name_encoded=$(echo "$ram_module_type_name" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g')
            
            # Используем производителя модуля или дефолтный
            local ram_module_manufacturer_id=$ram_manufacturer_id
            if [ -n "$ram_module_vendor" ]; then
                local ram_module_manufacturer_slug=$(echo "$ram_module_vendor" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
                ram_module_manufacturer_id=$(get_or_create "/dcim/manufacturers/" "name" "$ram_module_vendor" "{\"name\":\"$ram_module_vendor\",\"slug\":\"$ram_module_manufacturer_slug\"}" | tr -d '\n\r\t ')
            fi
            
            local ram_module_type_check=$(netbox_api "GET" "/dcim/module-types/?manufacturer_id=${ram_module_manufacturer_id}&model=${ram_module_type_name_encoded}")
            local ram_module_type_count=$(echo "$ram_module_type_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
            
            local ram_module_type_id_for_module=""
            if [ "$ram_module_type_count" -gt 0 ]; then
                ram_module_type_id_for_module=$(echo "$ram_module_type_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
            else
                # Создаем module-type для конкретного модуля
                local ram_profile_id=$(get_module_type_profile_id "Memory")
                local ram_module_type_name_json=$(echo "$ram_module_type_name" | sed 's/"/\\"/g')
                local ram_module_type_data="{\"manufacturer\":$ram_module_manufacturer_id,\"model\":\"$ram_module_type_name_json\",\"slug\":\"$ram_module_type_slug\""
                if [ -n "$ram_profile_id" ]; then
                    ram_module_type_data="${ram_module_type_data},\"module_type_profile\":$ram_profile_id"
                fi
                ram_module_type_data="${ram_module_type_data},\"attributes\":{"
                ram_module_type_data="${ram_module_type_data}\"size\":\"${ram_module_size}\""
                ram_module_type_data="${ram_module_type_data},\"ecc\":false"
                ram_module_type_data="${ram_module_type_data},\"class\":\"DDR4\""
                ram_module_type_data="${ram_module_type_data}}"
                ram_module_type_data="${ram_module_type_data}}"
                
                local ram_module_type_response=$(netbox_api "POST" "/dcim/module-types/" "$ram_module_type_data")
                if echo "$ram_module_type_response" | grep -q '"id"'; then
                    ram_module_type_id_for_module=$(echo "$ram_module_type_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                fi
            fi
            
            # Создаем module bay для каждого модуля RAM (RAM-1, RAM-2, и т.д.)
            local ram_bay_name="RAM-$ram_module_index"
            local ram_bay_id=$(get_or_create_module_bay "$server_device_id" "$ram_bay_name")
            
            if [ -n "$ram_bay_id" ] && [ -n "$ram_module_type_id_for_module" ]; then
                local platform_desc_json=$(echo "$platform_name" | sed 's/"/\\"/g')
                local ram_module_desc="Installed in platform: $platform_desc_json"
                if [ -n "$ram_module_serial" ]; then
                    ram_module_desc="${ram_module_desc} Serial: $ram_module_serial"
                fi
                local ram_module_desc_json=$(echo "$ram_module_desc" | sed 's/"/\\"/g')
                
                local ram_module_data="{\"device\":$server_device_id,\"module_bay\":$ram_bay_id,\"module_type\":$ram_module_type_id_for_module,\"description\":\"$ram_module_desc_json\"}"
                local ram_module_check=$(netbox_api "GET" "/dcim/modules/?device_id=${server_device_id}&module_bay_id=${ram_bay_id}")
                local ram_module_count=$(echo "$ram_module_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
                
                if [ "$ram_module_count" -gt 0 ]; then
                    local ram_module_id=$(echo "$ram_module_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                    info "  RAM module $ram_module_index уже существует ID: $ram_module_id"
                else
                    local ram_module_response=$(netbox_api "POST" "/dcim/modules/" "$ram_module_data")
                    if echo "$ram_module_response" | grep -q '"id"'; then
                        local ram_module_id=$(echo "$ram_module_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                        info "  Создан RAM module $ram_module_index: $ram_module_type_name ID: $ram_module_id"
                    else
                        warning "Не удалось создать RAM module $ram_module_index: $ram_module_response"
                    fi
                fi
            fi
            
            ram_module_index=$((ram_module_index + 1))
        done
    elif [ -n "$ram_module_type_id" ]; then
        # Fallback: создаем один модуль RAM если нет детальной информации
        local ram_bay_id=$(get_or_create_module_bay "$server_device_id" "RAM")
        if [ -z "$ram_bay_id" ]; then
            warning "Не удалось получить или создать module bay для RAM"
        else
            local platform_desc_json=$(echo "$platform_name" | sed 's/"/\\"/g')
            local ram_module_data="{\"device\":$server_device_id,\"module_bay\":$ram_bay_id,\"module_type\":$ram_module_type_id,\"description\":\"Installed in platform: $platform_desc_json\"}"
            local ram_module_check=$(netbox_api "GET" "/dcim/modules/?device_id=${server_device_id}&module_bay_id=${ram_bay_id}")
            local ram_module_count=$(echo "$ram_module_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
            
            if [ "$ram_module_count" -gt 0 ]; then
                local ram_module_id=$(echo "$ram_module_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                local ram_module_update_data="{\"description\":\"Installed in platform: $platform_desc_json\"}"
                netbox_api "PATCH" "/dcim/modules/${ram_module_id}/" "$ram_module_update_data" > /dev/null || true
                info "  RAM module уже существует ID: $ram_module_id"
            else
                local ram_module_response=$(netbox_api "POST" "/dcim/modules/" "$ram_module_data")
                if echo "$ram_module_response" | grep -q '"id"'; then
                    local ram_module_id=$(echo "$ram_module_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                    info "  Создан RAM module ID: $ram_module_id"
                else
                    warning "Не удалось создать RAM module: $ram_module_response"
                    # Если модуль не создан, удаляем пустой bay чтобы избежать пустых slots
                    if [ -n "$ram_bay_id" ]; then
                        netbox_api "DELETE" "/dcim/module-bays/${ram_bay_id}/" > /dev/null 2>&1 || true
                    fi
                fi
            fi
        fi
    fi
    
    # Создаем module-types и modules для дисков
    # Templates для дисков уже созданы в add_device_to_netbox перед созданием device
    IFS=',' read -ra DISK_ARRAY <<< "$DISKS"
    local disk_index=1
    for disk in "${DISK_ARRAY[@]}"; do
        local disk_name=$(echo "$disk" | cut -d: -f1)
        local disk_size=$(echo "$disk" | cut -d: -f2)
        
        # Извлекаем дополнительную информацию из формата lshw (vendor, product, serial)
        local disk_vendor=""
        local disk_product=""
        local disk_serial=""
        
        if echo "$disk" | grep -q "vendor="; then
            disk_vendor=$(echo "$disk" | grep -o 'vendor=[^:]*' | cut -d= -f2)
        fi
        if echo "$disk" | grep -q "product="; then
            disk_product=$(echo "$disk" | grep -o 'product=[^:]*' | cut -d= -f2)
        fi
        if echo "$disk" | grep -q "serial="; then
            disk_serial=$(echo "$disk" | grep -o 'serial=[^:]*' | cut -d= -f2)
        fi
        
        # Определяем manufacturer для диска
        local disk_manufacturer="Generic"
        if [ -n "$disk_vendor" ] && [ "$disk_vendor" != "Generic" ]; then
            disk_manufacturer="$disk_vendor"
        fi
        
        # Используем product как model, если доступен
        local disk_module_type_name="${disk_size}"
        if [ -n "$disk_product" ]; then
            disk_module_type_name="${disk_product} ${disk_size}"
        fi
        
        # Получаем или создаем manufacturer для диска
        local disk_manufacturer_slug=$(echo "$disk_manufacturer" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
        local disk_manufacturer_id=$(get_or_create "/dcim/manufacturers/" "name" "$disk_manufacturer" "{\"name\":\"$disk_manufacturer\",\"slug\":\"$disk_manufacturer_slug\"}" | tr -d '\n\r\t ')
        local disk_module_type_slug=$(echo "$disk_module_type_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g')
        local disk_module_type_name_encoded=$(echo "$disk_module_type_name" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g')
        local disk_module_type_check=$(netbox_api "GET" "/dcim/module-types/?manufacturer_id=${disk_manufacturer_id}&model=${disk_module_type_name_encoded}")
        local disk_module_type_count=$(echo "$disk_module_type_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
        
        local disk_module_type_id=""
        if [ "$disk_module_type_count" -gt 0 ]; then
            disk_module_type_id=$(echo "$disk_module_type_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
            info "  Disk module-type уже существует: $disk_module_type_name ID: $disk_module_type_id"
        else
            local disk_profile_id=$(get_module_type_profile_id "Hard disk")
            local disk_module_type_name_json=$(echo "$disk_module_type_name" | sed 's/"/\\"/g')
            
            # Извлекаем информацию о диске из формата lshw
            local disk_vendor_from_info=""
            local disk_product_from_info=""
            if echo "$disk" | grep -q "vendor="; then
                disk_vendor_from_info=$(echo "$disk" | grep -o 'vendor=[^:]*' | cut -d= -f2)
            fi
            if echo "$disk" | grep -q "product="; then
                disk_product_from_info=$(echo "$disk" | grep -o 'product=[^:]*' | cut -d= -f2)
            fi
            
            # Определяем тип диска (SSD или HDD) на основе модели
            local disk_type="HDD"
            if echo "$disk_product_from_info" | grep -qiE 'ssd|solid|nvme'; then
                disk_type="SSD"
            fi
            
            # Формируем данные для создания module-type с профилем Hard disk и атрибутами
            local disk_module_type_data="{\"manufacturer\":$disk_manufacturer_id,\"model\":\"$disk_module_type_name_json\",\"slug\":\"$disk_module_type_slug\""
            if [ -n "$disk_profile_id" ]; then
                disk_module_type_data="${disk_module_type_data},\"module_type_profile\":$disk_profile_id"
            fi
            # Добавляем атрибуты Hard disk согласно профилю: size, type, speed
            local disk_size_json=$(echo "$disk_size" | sed 's/"/\\"/g')
            disk_module_type_data="${disk_module_type_data},\"attributes\":{"
            disk_module_type_data="${disk_module_type_data}\"size\":\"$disk_size_json\""
            disk_module_type_data="${disk_module_type_data},\"type\":\"$disk_type\""
            disk_module_type_data="${disk_module_type_data}}"
            disk_module_type_data="${disk_module_type_data}}"
            
            local disk_module_type_response=$(netbox_api "POST" "/dcim/module-types/" "$disk_module_type_data")
            if echo "$disk_module_type_response" | grep -q '"id"'; then
                disk_module_type_id=$(echo "$disk_module_type_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                info "  Создан Disk module-type: $disk_module_type_name ID: $disk_module_type_id"
            else
                warning "Не удалось создать Disk module-type: $disk_module_type_response"
                disk_module_type_id=""  # Устанавливаем пустую строку при ошибке
            fi
        fi
        
        # Создаем module (экземпляр) для диска
        if [ -n "$disk_module_type_id" ]; then
            # Используем стандартное имя bay из template (Disk-1, Disk-2, и т.д.)
            local disk_bay_name="Disk-$disk_index"
            local disk_bay_id=$(get_or_create_module_bay "$server_device_id" "$disk_bay_name")
            if [ -z "$disk_bay_id" ]; then
                warning "Не удалось получить или создать module bay для диска $disk_name"
            else
                local platform_desc_json=$(echo "$platform_name" | sed 's/"/\\"/g')
                local disk_module_data="{\"device\":$server_device_id,\"module_bay\":$disk_bay_id,\"module_type\":$disk_module_type_id,\"description\":\"Installed in platform: $platform_desc_json - $disk_name\"}"
                local disk_module_check=$(netbox_api "GET" "/dcim/modules/?device_id=${server_device_id}&module_bay_id=${disk_bay_id}")
                local disk_module_count=$(echo "$disk_module_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
                
                if [ "$disk_module_count" -gt 0 ]; then
                    local disk_module_id=$(echo "$disk_module_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                    # Обновляем описание
                    local disk_module_update_data="{\"description\":\"Installed in platform: $platform_desc_json - $disk_name\"}"
                    netbox_api "PATCH" "/dcim/modules/${disk_module_id}/" "$disk_module_update_data" > /dev/null || true
                    info "  Disk module уже существует: $disk_name ID: $disk_module_id"
                else
                    local disk_module_response=$(netbox_api "POST" "/dcim/modules/" "$disk_module_data")
                    if echo "$disk_module_response" | grep -q '"id"'; then
                        local disk_module_id=$(echo "$disk_module_response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' | tr -d '\n\r\t ')
                        info "  Создан Disk module: $disk_name ID: $disk_module_id"
                    else
                        warning "Не удалось создать Disk module для $disk_name: $disk_module_response"
                    fi
                fi
            fi
        fi
        
        disk_index=$((disk_index + 1))
    done
    
    # Очистка пустых module-bays после создания всех модулей
    cleanup_empty_module_bays "$server_device_id"
}

# Функция для очистки пустых module-bays
cleanup_empty_module_bays() {
    local device_id=$1
    
    # Получаем все module-bays для устройства
    local bays_response=$(netbox_api "GET" "/dcim/module-bays/?device_id=${device_id}")
    local bays_count=$(echo "$bays_response" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
    
    if [ "$bays_count" -eq 0 ]; then
        return
    fi
    
    # Определяем реальное количество дисков и RAM модулей
    local real_disk_count=0
    if [ -n "${DISKS:-}" ] && [ -n "$DISKS" ]; then
        IFS=',' read -ra DISK_ARRAY <<< "$DISKS"
        real_disk_count=${#DISK_ARRAY[@]}
    fi
    
    local real_ram_count=0
    if [ -n "${RAM_MODULES:-}" ] && [ -n "$RAM_MODULES" ]; then
        IFS=',' read -ra RAM_MODULE_ARRAY <<< "$RAM_MODULES"
        for ram_module_info in "${RAM_MODULE_ARRAY[@]}"; do
            local ram_module_size=$(echo "$ram_module_info" | cut -d: -f1)
            if [ -n "$ram_module_size" ] && [ "$ram_module_size" != "" ] && [ "$ram_module_size" != "0M" ] && [ "$ram_module_size" != "0G" ] && [ "$ram_module_size" != "0T" ] && [ "$ram_module_size" != "0" ]; then
                real_ram_count=$((real_ram_count + 1))
            fi
        done
    fi
    
    # Извлекаем все bays из ответа (используем jq для парсинга JSON)
    local bays_json=""
    if command -v jq >/dev/null 2>&1; then
        bays_json=$(echo "$bays_response" | jq -r '.results[]? | "\(.id)|\(.name)|\(if .installed_module then 1 else 0 end)"' 2>/dev/null)
    else
        # Fallback на python если jq недоступен
        bays_json=$(echo "$bays_response" | python3 -c "
import sys
import json
try:
    data = json.load(sys.stdin)
    if 'results' in data:
        for bay in data['results']:
            bay_id = bay.get('id', '')
            bay_name = bay.get('name', '')
            installed_module = bay.get('installed_module', None)
            if bay_id and bay_name:
                print(str(bay_id) + '|' + str(bay_name) + '|' + ('1' if installed_module else '0'))
except:
    pass
" 2>/dev/null)
    fi
    
    if [ -z "$bays_json" ]; then
        return
    fi
    
    # Обрабатываем каждый bay
    echo "$bays_json" | while IFS='|' read -r bay_id bay_name has_module; do
        if [ -z "$bay_id" ] || [ -z "$bay_name" ]; then
            continue
        fi
        
        # Пропускаем bays с установленными модулями
        if [ "$has_module" = "1" ]; then
            continue
        fi
        
        # Проверяем, нужно ли удалять этот bay
        local should_delete=false
        
        # Удаляем пустые Disk bays выше реального количества дисков
        if echo "$bay_name" | grep -qE "^Disk-[0-9]+$"; then
            local disk_num=$(echo "$bay_name" | grep -oE "[0-9]+")
            if [ -n "$disk_num" ] && [ "$disk_num" -gt "$real_disk_count" ]; then
                should_delete=true
            fi
        fi
        
        # Удаляем пустой RAM bay, если есть детальные RAM модули (RAM-1, RAM-2 и т.д.)
        if [ "$bay_name" = "RAM" ] && [ "$real_ram_count" -gt 0 ]; then
            should_delete=true
        fi
        
        # Удаляем пустые RAM-N bays выше реального количества RAM модулей
        if echo "$bay_name" | grep -qE "^RAM-[0-9]+$"; then
            local ram_num=$(echo "$bay_name" | grep -oE "[0-9]+")
            if [ -n "$ram_num" ] && [ "$ram_num" -gt "$real_ram_count" ]; then
                should_delete=true
            fi
        fi
        
        if [ "$should_delete" = "true" ]; then
            netbox_api "DELETE" "/dcim/module-bays/${bay_id}/" > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                info "  Удален пустой module-bay: $bay_name"
            fi
        fi
    done
}

# Функция для добавления интерфейсов и IP адресов
add_interfaces_and_ips() {
    local device_id=$1
    info "Добавление интерфейсов и IP адресов..."
    
    # Получение списка интерфейсов
    local interfaces=$(ip -4 addr show | grep -E "^[0-9]+:" | awk '{print $2}' | sed 's/:$//')
    
    while IFS= read -r interface; do
        if [ -z "$interface" ]; then
            continue
        fi
        
        # Попытка найти существующий интерфейс сначала
        local interface_encoded=$(echo "$interface" | sed 's/ /%20/g' | sed 's/&/%26/g' | sed 's/=/%3D/g')
        local existing_interface=$(netbox_api "GET" "/dcim/interfaces/?device_id=${device_id}&name=${interface_encoded}")
        local interface_id=""
        
        if [ -n "$existing_interface" ]; then
            local interface_count=$(echo "$existing_interface" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
            if [ "$interface_count" -gt 0 ]; then
                interface_id=$(echo "$existing_interface" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
            fi
        fi
        
        # Получаем MAC адрес интерфейса (если есть)
        local mac_address=""
        if [ -f "/sys/class/net/$interface/address" ]; then
            mac_address=$(cat "/sys/class/net/$interface/address" 2>/dev/null | tr -d '\n\r ')
            # Проверяем, что это валидный MAC адрес (не пустой и не 00:00:00:00:00:00)
            if [ -z "$mac_address" ] || [ "$mac_address" = "00:00:00:00:00:00" ]; then
                mac_address=""
            fi
        fi
        
        # Если интерфейс не найден, создаем новый
        if [ -z "$interface_id" ]; then
            # Определяем тип интерфейса
            local interface_type="other"
            if echo "$interface" | grep -qiE 'lo|loopback'; then
                interface_type="virtual"
            elif echo "$interface" | grep -qiE 'eth|enp|ens|eno|em'; then
                interface_type="1000base-t"
            elif echo "$interface" | grep -qiE 'wlan|wifi|wlp'; then
                interface_type="802.11n"
            elif echo "$interface" | grep -qiE 'docker|br-|veth|virbr'; then
                interface_type="virtual"
            fi
            
            # Очищаем device_id от лишних символов
            local clean_device_id=$(echo "$device_id" | tr -d '\n\r\t ' | grep -o '[0-9]*' | head -1)
            if [ -z "$clean_device_id" ] || [ "$clean_device_id" -le 0 ] 2>/dev/null; then
                warning "Некорректный device_id для интерфейса $interface: '$device_id'"
                continue
            fi
            
            # Экранируем имя интерфейса для JSON
            local interface_name_json=$(echo "$interface" | sed 's/"/\\"/g')
            # Формируем данные интерфейса с MAC адресом (если есть)
            if [ -n "$mac_address" ]; then
                local interface_data="{\"device\":$clean_device_id,\"name\":\"$interface_name_json\",\"type\":\"$interface_type\",\"mac_address\":\"$mac_address\"}"
            else
                local interface_data="{\"device\":$clean_device_id,\"name\":\"$interface_name_json\",\"type\":\"$interface_type\"}"
            fi
            local interface_response=$(netbox_api "POST" "/dcim/interfaces/" "$interface_data")
            
            # Проверяем результат создания
            if echo "$interface_response" | grep -q '"id"'; then
                # Извлекаем только первый ID, убирая все лишнее
                interface_id=$(echo "$interface_response" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://' | tr -d '\n' | head -c 20)
                if [ -n "$interface_id" ] && [ "$interface_id" -gt 0 ] 2>/dev/null; then
                    info "  Создан интерфейс: $interface ID: $interface_id"
                else
                    warning "Не удалось извлечь ID интерфейса из ответа: $interface_response"
                fi
            elif echo "$interface_response" | grep -q '"error"'; then
                warning "Не удалось создать интерфейс $interface: $interface_response"
                # Пытаемся найти интерфейс еще раз (возможно, он был создан параллельно)
                existing_interface=$(netbox_api "GET" "/dcim/interfaces/?device_id=${device_id}&name=${interface_encoded}")
                if [ -n "$existing_interface" ]; then
                    local retry_count=$(echo "$existing_interface" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
                    if [ "$retry_count" -gt 0 ]; then
                        interface_id=$(echo "$existing_interface" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
                        info "  Интерфейс $interface найден после повторной проверки ID: $interface_id"
                    fi
                fi
            fi
        else
            info "  Интерфейс $interface уже существует ID: $interface_id"
            # Обновляем MAC адрес, если он отсутствует в Netbox, но есть в системе
            if [ -n "$mac_address" ]; then
                # Проверяем, есть ли MAC адрес у существующего интерфейса
                local existing_mac=$(echo "$existing_interface" | grep -o '"mac_address":"[^"]*"' | sed 's/"mac_address":"\([^"]*\)"/\1/' || echo "")
                if [ -z "$existing_mac" ] || [ "$existing_mac" = "null" ]; then
                    # Обновляем MAC адрес
                    local clean_interface_id=$(echo "$interface_id" | tr -d '\n\r\t ' | grep -o '[0-9]*' | head -1)
                    local mac_update_data="{\"mac_address\":\"$mac_address\"}"
                    netbox_api "PATCH" "/dcim/interfaces/${clean_interface_id}/" "$mac_update_data" > /dev/null && info "  Обновлен MAC адрес для интерфейса $interface: $mac_address"
                fi
            fi
        fi
        
        # Получение IP адреса для интерфейса (если есть)
        local ip_addr=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1)
        
        # Добавляем IP адрес только если интерфейс существует и есть IP адрес
        if [ -n "$interface_id" ] && [ -n "$ip_addr" ]; then
            # Извлечение IP адреса с маской
            local ip_address_with_mask="$ip_addr"
            local ip_address=$(echo "$ip_addr" | cut -d/ -f1)
            local ip_prefix=$(echo "$ip_addr" | cut -d/ -f2)
            
            # Проверяем, не существует ли уже этот IP адрес
            # URL encoding для IP адреса (заменяем / на %2F)
            local ip_address_encoded=$(echo "$ip_address_with_mask" | sed 's/\//%2F/g')
            local ip_check=$(netbox_api "GET" "/ipam/ip-addresses/?address=${ip_address_encoded}")
            local ip_count=$(echo "$ip_check" | grep -o '"count":[0-9]*' | grep -o '[0-9]*' || echo "0")
            
            if [ "$ip_count" -gt 0 ]; then
                # IP адрес уже существует, проверяем привязку к интерфейсу
                local existing_ip_id=$(echo "$ip_check" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
                local existing_assigned=$(echo "$ip_check" | grep -o '"assigned_object_id":[0-9]*' | grep -o '[0-9]*' || echo "")
                
                # Очищаем interface_id перед использованием
                local clean_interface_id=$(echo "$interface_id" | tr -d '\n\r\t ' | grep -o '[0-9]*' | head -1)
                if [ -n "$existing_assigned" ] && [ "$existing_assigned" != "$clean_interface_id" ]; then
                    # IP адрес привязан к другому интерфейсу, обновляем привязку
                    local ip_update_data="{\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$clean_interface_id}"
                    netbox_api "PATCH" "/ipam/ip-addresses/${existing_ip_id}/" "$ip_update_data" > /dev/null || warning "Не удалось обновить привязку IP адреса $ip_addr"
                fi
            else
                # Создаем новый IP адрес без требования наличия префикса
                # Очищаем interface_id от всех лишних символов (переносы строк, пробелы и т.д.)
                local clean_interface_id=$(echo "$interface_id" | tr -d '\n\r\t ' | grep -o '[0-9]*' | head -1)
                if [ -z "$clean_interface_id" ] || [ "$clean_interface_id" -le 0 ] 2>/dev/null; then
                    warning "Некорректный ID интерфейса для IP адреса $ip_addr: '$interface_id'"
                    continue
                fi
                local ip_data="{\"address\":\"$ip_address_with_mask\",\"assigned_object_type\":\"dcim.interface\",\"assigned_object_id\":$clean_interface_id}"
                local ip_create_response=$(netbox_api "POST" "/ipam/ip-addresses/" "$ip_data")
                local ip_create_status=$?
                if [ $ip_create_status -ne 0 ]; then
                    warning "Не удалось добавить IP адрес $ip_addr для интерфейса $interface"
                    info "  JSON данные: $ip_data"
                    info "  Ответ сервера: $ip_create_response"
                else
                    info "  Добавлен IP адрес $ip_addr для интерфейса $interface"
                fi
            fi
        fi
    done <<< "$interfaces"
}

# Функция для вывода справки
show_help() {
    cat << EOF
Использование: $0 [OPTIONS]

Опции:
  -u, --url URL              URL Netbox сервера (по умолчанию: https://netbox.homeinfra.su:8900)
  -t, --token TOKEN          API токен Netbox (обязательно)
  -n, --name NAME            Имя устройства (по умолчанию: hostname)
  -d, --device-type TYPE     Тип устройства: virtual или physical (автоопределение если не указано)
  -m, --manufacturer NAME    Производитель устройства
  -r, --role ROLE            Роль устройства (по умолчанию: server)
  -s, --site SITE            Название сайта (по умолчанию: default)
  -p, --platform PLATFORM    Платформа (по умолчанию: определяется автоматически)
  --rack RACK                Название стеллажа (rack)
  --location LOCATION        Название местоположения (location)
  --tenant TENANT            Название арендатора (tenant)
  -h, --help                 Показать эту справку

Переменные окружения:
  NETBOX_URL                 URL Netbox сервера
  NETBOX_TOKEN               API токен Netbox
  DEVICE_NAME                Имя устройства
  DEVICE_TYPE                Тип устройства
  MANUFACTURER               Производитель
  DEVICE_ROLE                Роль устройства
  SITE_NAME                  Название сайта
  PLATFORM                   Платформа
  RACK_NAME                  Название стеллажа
  LOCATION_NAME              Название местоположения
  TENANT_NAME                Название арендатора
  
  NETBOX_NO_PROXY            Отключить proxy (1 или "yes" - для всех, или список хостов через запятую)
  NETBOX_VERIFY_SSL          Проверка SSL сертификата (1 - включить, 0 - отключить, по умолчанию: 0)
  NETBOX_TLS_VERSION         Версия TLS (1.0, 1.1, 1.2, 1.3)
  NETBOX_CONNECT_TIMEOUT     Таймаут подключения в секундах (по умолчанию: 30)
  NETBOX_MAX_TIME            Максимальное время выполнения запроса в секундах (по умолчанию: 60)

Примеры:
  # Использование с параметрами командной строки
  $0 --token YOUR_API_TOKEN --name myserver --role webserver --site datacenter1

  # Использование с переменными окружения
  export NETBOX_TOKEN="your_api_token"
  export DEVICE_NAME="myserver"
  $0

  # Комбинированный вариант
  export NETBOX_TOKEN="your_api_token"
  $0 --name myserver --role webserver
  
  # С дополнительными параметрами
  $0 --token YOUR_TOKEN --name myserver --role webserver --site datacenter1 --rack Rack-01 --location Server-Room-A --tenant Company-ABC
  
  # Отключение proxy для решения проблем с подключением
  export NETBOX_NO_PROXY=1
  $0 --token YOUR_TOKEN --name myserver
  
  # Использование конкретной версии TLS
  export NETBOX_TLS_VERSION=1.2
  $0 --token YOUR_TOKEN --name myserver
  
  # Увеличение таймаутов для медленных соединений
  export NETBOX_CONNECT_TIMEOUT=60
  export NETBOX_MAX_TIME=120
  $0 --token YOUR_TOKEN --name myserver
EOF
}

# Парсинг аргументов командной строки
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--url)
                NETBOX_URL="$2"
                shift 2
                ;;
            -t|--token)
                NETBOX_TOKEN="$2"
                shift 2
                ;;
            -n|--name)
                DEVICE_NAME="$2"
                shift 2
                ;;
            -d|--device-type)
                DEVICE_TYPE="$2"
                shift 2
                ;;
            -m|--manufacturer)
                MANUFACTURER="$2"
                shift 2
                ;;
            -r|--role)
                DEVICE_ROLE="$2"
                shift 2
                ;;
            -s|--site)
                SITE_NAME="$2"
                shift 2
                ;;
            -p|--platform)
                PLATFORM="$2"
                shift 2
                ;;
            --rack)
                RACK_NAME="$2"
                shift 2
                ;;
            --location)
                LOCATION_NAME="$2"
                shift 2
                ;;
            --tenant)
                TENANT_NAME="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "Неизвестный параметр: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Основная функция
main() {
    parse_args "$@"
    
    # Проверка наличия API токена
    if [ -z "$NETBOX_TOKEN" ]; then
        error "API токен не указан. Используйте -t/--token или переменную окружения NETBOX_TOKEN"
        exit 1
    fi
    
    # Проверка доступности Netbox через реальный API запрос
    info "Проверка доступности Netbox сервера..."
    local base_url="${NETBOX_URL%/}"
    
    # Пробуем выполнить простой API запрос для проверки доступности
    local check_response=$(curl -s -k -L -w "\n%{http_code}" -X "GET" \
        "${base_url}/api/" \
        -H "Authorization: Token ${NETBOX_TOKEN}" \
        -H "Accept: application/json" 2>&1)
    
    local check_http_code=$(echo "$check_response" | tail -n1)
    local check_body=$(echo "$check_response" | sed '$d')
    
    # Проверяем HTTP код (200-399 считаются успешными)
    if [ -z "$check_http_code" ] || [ "$check_http_code" -ge 400 ]; then
        error "Не удалось подключиться к Netbox серверу: ${base_url}/api/"
        if [ -n "$check_http_code" ]; then
            error "HTTP код: $check_http_code"
        fi
        if [ -n "$check_body" ]; then
            error "Ответ сервера: $check_body"
        fi
        info "Проверьте:"
        info "  1. Доступность сервера и правильность URL"
        info "  2. Правильность API токена"
        info "  3. Сетевое подключение к серверу"
        exit 1
    fi
    
    success "Подключение к Netbox успешно HTTP $check_http_code"
    
    # Сбор информации о системе
    get_system_info
    
    # Добавление устройства в Netbox
    add_device_to_netbox
    
    success "Готово!"
}

# Запуск основной функции
main "$@"

