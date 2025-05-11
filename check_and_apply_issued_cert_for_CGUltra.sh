#!/bin/bash

# Пути к файлам
CERT_FILE="/root/certs/cert/fullchain.cer" # git репозиторий, периодически пуллится
KEY_FILE="/root/certs/cert/homeinfra.su.key" # git репозиторий, периодически пуллится
TARGET_CERT="/data/unifi-core/config/unifi-core.crt"
TARGET_KEY="/data/unifi-core/config/unifi-core.key"

# Файл для хранения хеша последней проверки
HASH_FILE="/tmp/last_cert_hash.txt"

# Получаем текущий хеш сертификата
CURRENT_HASH=$(sha256sum "$CERT_FILE" | awk '{print $1}')

# Проверяем, существует ли файл с предыдущим хешем
if [ -f "$HASH_FILE" ]; then
    # Читаем предыдущий хеш
    PREVIOUS_HASH=$(cat "$HASH_FILE")

    # Сравниваем хеши
    if [ "$CURRENT_HASH" != "$PREVIOUS_HASH" ]; then
        # Хеши разные - файл изменился
        echo "Сертификат изменился, обновляю файлы..."

        # Копируем файлы
        cp "$KEY_FILE" "$TARGET_KEY"
        cp "$CERT_FILE" "$TARGET_CERT"

        # Перезапускаем nginx
        sudo systemctl restart nginx

        # Обновляем хеш в файле
        echo "$CURRENT_HASH" > "$HASH_FILE"
    else
        echo "Сертификат не изменился, ничего не делаю."
    fi
else
    # Файла с хешем нет, значит это первый запуск
     echo "Первоначальное сохранение хеша сертификата..."
     echo "$CURRENT_HASH" > "$HASH_FILE"

    # Копируем файлы при первом запуске (если нужно)
    # cp "$KEY_FILE" "$TARGET_KEY"
    # cp "$CERT_FILE" "$TARGET_CERT"
    # sudo systemctl restart nginx
fi
