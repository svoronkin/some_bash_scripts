#!/bin/bash -x
# DB Copy

# Перед началом работы необходимо задать в скрипте IP адреса серверов баз данных в указанных переменных
#```bash
#SOURCE='SOURCE'
#DESTINATION='DESTINATION'
#```
## Необходимо подготовить файл в данными для подключения к БД
#Файл должен содержать актуальные пароли доступа, ip адреса для подключения, соответствовать формату.
#римерный список БД для переноса по формату файла настроек подключения для psql:
#```
#IP:port:db_name:db_user:pass
#127.0.0.1:5432:dapi:user:12345678
#127.0.0.1:5432:dp_test:user:12345678
#
#```
#В этом примере необходимо заменить креды и ip адрес для подключения
#
## Подготовленный файл с настройками и данными для подключения к БД нужно сохранить в ~/.pgpass
#назначить файлу маску доступа 600
#```bash
#chmod 600 ~/.pgpass
#```
#
## Если в vault лежит ссылка на подключение к БД и символы закодированы urlencode, то можно воспользоваться bash функцией для декодирования
#
#```bash
#function urldecode() { : "${*//+/ }"; echo -e "${_//%/\\x}"; }
#```
SOURCE='SOURCE'
DESTINATION='DESTINATION'

RSSTART=$(date '+%Y-%m-%d_%H.%M')
mkdir -p $RSSTART

#DB_LIST=$(awk -F : -- '{print $3}' ~/.pgpass)
DB_LIST=$(cat ~/.pgpass)

for DB in ${DB_LIST}
do
	SOURCE=$(echo $DB | awk -F : '{print $1}')
	DB_NAME=$(echo $DB | awk -F : '{print $3}')
	DB_USER=$(echo $DB | awk -F : '{print $4}')
	echo "Dumping $DB_NAME..."
	pg_dump -h $SOURCE -U $DB_USER -d $DB_NAME -cf ./$RSSTART/$DB_NAME.sql
done

echo "Prepare move databases... sleep 5 minute"
sleep 300

sed -i "s/${SOURCE}/${DESTINATION}/" ~/.pgpass

for DB in ${DB_LIST}
do
        DB_NAME=$(echo $DB | awk -F : '{print $3}')
        DB_USER=$(echo $DB | awk -F : '{print $4}')
        psql -h $DESTINATION -U $DB_USER -d $DB_NAME -f ./$RSSTART/$DB_NAME.sql
done
