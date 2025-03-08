#!/bin/bash

BASE_DIR="/etc/4sl"

SSL_DHPARAM_DIR_PATH="$BASE_DIR/dhparam"
SSL_CERTIFICATE_DIR_PATH="$BASE_DIR/certs"
SSL_CERTIFICATE_KEY_DIR_PATH="$BASE_DIR/private"
NGINX_SNIPPETS_DIR_PATH="$BASE_DIR/nginx/snippets"

# Файл для логирования
LOG_FILE="/var/log/4sl.log"

# Флаги/переменные для операций
CREATE_SSL=false
DELETE_SSL=false
SHOW_EXPIRATIONS=false
DO_UPDATE=false
DO_RENEW_SSL=false
RENEW_MODE="auto"  # по умолчанию
REMOVE_DOMAIN=""

# Остальные настройки
SILENT_MODE=false
AUTO_CONFIRM=false
CERT_TYPE=""  # --nginx или --docker
CERT_NAME=""  # example.com или docker

# Пути для будущего использования
ssl_dhparam_path=""
ssl_certificate_path=""
ssl_certificate_key_path=""
nginx_snippets=""

#################################################################
##                   Функции логирования                       ##
#################################################################
function log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

function __linebreak() {
  echo "──────────────────────────────────"
}

#################################################################
##               Основные функциональные блоки                 ##
#################################################################

# Создание необходимых директорий
function create_dirs(){
  dirs=("$BASE_DIR" "$SSL_DHPARAM_DIR_PATH" "$SSL_CERTIFICATE_KEY_DIR_PATH" "$SSL_CERTIFICATE_DIR_PATH" "$NGINX_SNIPPETS_DIR_PATH")
  for dir in "${dirs[@]}"; do
    if ! [ -d "$dir" ]; then
      mkdir -p "$dir"
    fi
  done
}

# Определить пути к файлам сертификата
function cert_paths() {
  files=()
  local dhparam=$1

  if [ -z "$CERT_NAME" ]; then
    log "Не указано имя домена (CERT_NAME). Используйте --help для справки."
    exit 1
  fi

  if [ -n "$dhparam" ]; then
    ssl_dhparam_path="$SSL_DHPARAM_DIR_PATH/$CERT_NAME.pem"
  fi

  ssl_certificate_path="$SSL_CERTIFICATE_DIR_PATH/$CERT_NAME.crt"
  ssl_certificate_key_path="$SSL_CERTIFICATE_KEY_DIR_PATH/$CERT_NAME.key"

  if [ "$CERT_TYPE" == "--nginx" ]; then
    nginx_snippets="$NGINX_SNIPPETS_DIR_PATH/$CERT_NAME"
  fi
}

# Проверка зависимостей
function check_dependencies(){
  if ! openssl version &> /dev/null; then
    log "Openssl не установлен! (sudo apt install openssl -y)"
    exit 1
  fi

  # если есть docker или nginx, проверяем
  case $CERT_TYPE in
    --nginx)
      if ! nginx -v &> /dev/null; then
        log "Nginx не установлен! (sudo apt install nginx -y)"
        exit 1
      fi
      ;;
    --docker)
      if ! docker -v &> /dev/null; then
        log "Docker не установлен! (curl -fsSL https://get.docker.com | sh)"
        # при желании здесь можно ставить exit 1
      fi
      ;;
  esac
}

#################################################################
##                    Создание/Удаление SSL                    ##
#################################################################

function generate_dhparam_ssl() {
    if [ -f "$ssl_dhparam_path" ]; then
        log "Error: dhparam уже существует для $CERT_NAME."
        return
    fi

    log "Генерация dhparam (2048 bit) может занять некоторое время..."

    # Запускаем openssl в фоновом режиме, убирая весь вывод
    (
      openssl dhparam -out "$ssl_dhparam_path" 2048
    )>/dev/null 2>&1 &

    # PID фонового процесса
    local pid=$!

    # Небольшой “спиннер”
    local i=0
    # Можно придумать другой набор символов, например '.oO°Oo.'
    local sp='|/-\'

    # Пока процесс жив, выводим спиннер
    while kill -0 "$pid" 2>/dev/null; do
      i=$(( (i+1) %4 ))
      # \r возвращает курсор в начало строки
      printf "\rГенерация DH: ${sp:$i:1}"
      sleep 0.1
    done

    # Дождаемся завершения фонового процесса и берём его код возврата
    wait "$pid"
    local status=$?

    # Стираем спиннер и выводим результат
    printf "\r"

    if [ $status -ne 0 ]; then
      log "Ошибка при генерации dhparam!"
      return
    fi

    log "dhparam успешно создан в $ssl_dhparam_path"

    # Если нужно сразу же дописать в сниппет
    if [ -f "$ssl_dhparam_path" ]; then
        echo "ssl_dhparam $ssl_dhparam_path;" >> "$nginx_snippets"
        log "Добавлен 'ssl_dhparam $ssl_dhparam_path;' в $nginx_snippets"
    else
        log "Error: dhparam-файл не найден, не удалось добавить в nginx."
    fi
}

function generate_ssl() {
    # Проверяем, может уже есть
    if [ -f "$ssl_certificate_path" ] || [ -f "$ssl_certificate_key_path" ]; then
        log "Error: Сертификаты для $CERT_NAME уже существуют. Пропускаем генерацию."
        return
    fi

    log "Генерация самоподписанного сертификата для $CERT_NAME ..."
    if [ "$SILENT_MODE" = true ]; then
      sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
       -keyout "$ssl_certificate_key_path" \
       -out "$ssl_certificate_path" \
       -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=$CERT_NAME"
    else
      sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
       -keyout "$ssl_certificate_key_path" \
       -out "$ssl_certificate_path"
    fi

    # Если всё успешно и это nginx-сертификат, прописываем путь в snippets
    if [ -f "$ssl_certificate_path" ] && [ -f "$ssl_certificate_key_path" ] && [ "$CERT_TYPE" == "--nginx" ]; then
        echo "ssl_certificate $ssl_certificate_path;" >> "$nginx_snippets"
        echo "ssl_certificate_key $ssl_certificate_key_path;" >> "$nginx_snippets"
        log "Сертификат и ключ добавлены в $nginx_snippets"

        # Создадим симлинк, если нужно
        if ! [ -L "/etc/nginx/snippets/ssl/$CERT_NAME" ]; then
          mkdir -p "/etc/nginx/snippets/ssl/"
          ln -s "$nginx_snippets" "/etc/nginx/snippets/ssl/$CERT_NAME"
          log "Создана символьная ссылка: /etc/nginx/snippets/ssl/$CERT_NAME -> $nginx_snippets"
        fi
    fi

    __linebreak
    log "Создан SSL-сертификат:       $ssl_certificate_path"
    log "Создан ключ SSL-сертификата: $ssl_certificate_key_path"
}

function ssl_create_main() {
  # Интеррактивное подтверждение (если не стоит -y)
  if ! $AUTO_CONFIRM; then
    read -r -p "Создать самоподписанный ssl-сертификат для $CERT_NAME? (y/n) " yn
    case $yn in
      [yY]) true ;;
      [nN]) log "Операция отменена пользователем."; return ;;
      *)    log "Неверный ответ, отмена..."; return ;;
    esac
  fi

  generate_ssl
  if [ "$CERT_TYPE" == "--nginx" ]; then
    generate_dhparam_ssl
  fi
}

function delete_ssl_files() {
  # Собираем список файлов
  local files_to_delete=()
  # crt/key
  if [ -n "$ssl_certificate_path" ]; then
    files_to_delete+=("$ssl_certificate_path")
  fi
  if [ -n "$ssl_certificate_key_path" ]; then
    files_to_delete+=("$ssl_certificate_key_path")
  fi
  # dhparam
  if [ -n "$ssl_dhparam_path" ]; then
    files_to_delete+=("$ssl_dhparam_path")
  fi
  # snippets
  if [ -n "$nginx_snippets" ]; then
    files_to_delete+=("$nginx_snippets")
    files_to_delete+=("/etc/nginx/snippets/ssl/$CERT_NAME")
  fi

  log "Файлы, которые будут удалены:"
  for f in "${files_to_delete[@]}"; do
    echo "$f"
  done

  if ! $AUTO_CONFIRM; then
    read -r -p "Вы уверены, что хотите удалить эти файлы? (y/n) " yn
    case $yn in
      [yY]) true ;;
      [nN]) log "Удаление отменено."; return ;;
      *)    log "Неверный ответ, отмена..."; return ;;
    esac
  fi

  for file in "${files_to_delete[@]}"; do
    if [ -f "$file" ] || [ -L "$file" ]; then
      log "Удаляю: $file"
      rm -f "$file"
    else
      log "Файл не найден, пропускаю: $file"
    fi
  done
}

function ssl_expiration() {
  if ! [ -d "$SSL_CERTIFICATE_DIR_PATH" ]; then
    log "Каталог с сертификатами не найден: $SSL_CERTIFICATE_DIR_PATH"
    exit 1
  fi

  for pem in "$SSL_CERTIFICATE_DIR_PATH"/*.crt; do
    [ -e "$pem" ] || continue  # если файлов нет
    # 2678400 ~ 31 день
    if openssl x509 -checkend 2678400 -noout -in "$pem" &> /dev/null; then
      printf "[ + ]: %s - %s\n" "$(date --date="$(openssl x509 -enddate -noout -in "$pem" | cut -d= -f 2)" --iso-8601)" "$pem"
    else
      printf "[ - ]: %s - %s\n" "$(date --date="$(openssl x509 -enddate -noout -in "$pem" | cut -d= -f 2)" --iso-8601)" "$pem"
    fi
  done | sort
}

#################################################################
##              Переподписание (renew) сертификата             ##
#################################################################

function create_cron_job() {
  # Создаем (или перезаписываем) файл для еженедельного cron-job.
  local cron_file="/etc/cron.weekly/4sl-renew-$CERT_NAME"

  log "Создаю cron-задачу для $CERT_NAME в $cron_file..."
  sudo bash -c "cat <<EOF > \"$cron_file\"
#!/bin/bash
/usr/local/bin/4sl --renew-ssl manual $CERT_TYPE $CERT_NAME >> /var/log/4sl.log 2>&1
EOF
"
  sudo chmod +x "$cron_file"
  log "Cron-задача $cron_file успешно создана."
}

function renew_ssl() {
  if [ ! -f "$ssl_certificate_path" ]; then
    # Если сертификат не существует, нет смысла «переподписывать».
    # Но если хотим всё равно проставить cron (auto), то делаем это.
    log "Сертификат $ssl_certificate_path не найден. Нечего переподписывать."
    if [ "$RENEW_MODE" == "auto" ]; then
      create_cron_job
    fi
    return
  fi

  log "Проверяем срок действия сертификата: $ssl_certificate_path"
  local now
  now=$(date +%s)
  local exp_date
  exp_date=$(openssl x509 -enddate -noout -in "$ssl_certificate_path" 2>/dev/null | cut -d= -f2)
  if [ -z "$exp_date" ]; then
    log "Не удалось определить дату окончания действия сертификата."
    return
  fi

  local expiration
  expiration=$(date -d "$exp_date" +%s 2>/dev/null)
  if [ $? -ne 0 ]; then
    log "Ошибка в обработке даты окончания сертификата."
    return
  fi

  local diff=$(( expiration - now ))
  local seven_days=$(( 7 * 24 * 3600 ))

  if [ $diff -lt $seven_days ]; then
    log "До истечения < 7 дней. Переподписываем..."
    rm -f "$ssl_certificate_path" "$ssl_certificate_key_path"
    if [ "$CERT_TYPE" == "--nginx" ]; then
      rm -f "$ssl_dhparam_path"
    fi
    generate_ssl
    if [ "$CERT_TYPE" == "--nginx" ]; then
      generate_dhparam_ssl
    fi
    log "Переподписание сертификата для $CERT_NAME завершено."
  else
    log "Сертификат $CERT_NAME действителен более 7 дней. Переподписание не требуется."
  fi

  # Создаем cron (если auto)
  if [ "$RENEW_MODE" == "auto" ]; then
    create_cron_job
  fi
}

#################################################################
##                   Удаление сертификата по домену            ##
#################################################################
function remove_ssl() {
  local domain="$1"
  if [ -z "$domain" ]; then
    log "Использование: 4sl --remove <domain>"
    exit 1
  fi

  log "Удаление SSL для домена $domain ..."
  local cert="$SSL_CERTIFICATE_DIR_PATH/$domain.crt"
  local key="$SSL_CERTIFICATE_KEY_DIR_PATH/$domain.key"
  local dhparam="$SSL_DHPARAM_DIR_PATH/$domain.pem"
  local snippet="$NGINX_SNIPPETS_DIR_PATH/$domain"
  local snippet_link="/etc/nginx/snippets/ssl/$domain"
  local cron="/etc/cron.weekly/4sl-renew-$domain"

  local all_files=("$cert" "$key" "$dhparam" "$snippet" "$snippet_link" "$cron")

  if ! $AUTO_CONFIRM; then
    echo "Файлы для удаления:"
    for f in "${all_files[@]}"; do
      echo "$f"
    done
    read -r -p "Удалить все эти файлы? (y/n) " yn
    case $yn in
      [yY]) true ;;
      [nN]) log "Операция отменена."; return ;;
      *)    log "Неверный ответ, отмена..."; return ;;
    esac
  fi

  for file in "${all_files[@]}"; do
    if [ -f "$file" ] || [ -L "$file" ]; then
      log "Удаляю: $file"
      rm -f "$file"
    else
      log "Файл не найден, пропускаю: $file"
    fi
  done
  log "Удаление сертификата для $domain завершено."
}

#################################################################
##                           UPDATE                            ##
#################################################################

function update_script() {
  log "Обновление скрипта 4sl..."
  curl https://raw.githubusercontent.com/AlanLatte/4SL/main/4sl.sh > 4sl.sh && chmod +x ./4sl.sh && sudo mv ./4sl.sh /usr/local/bin/4sl
  if [ $? -eq 0 ]; then
    log "Обновление успешно завершено."
  else
    log "Сбой при обновлении. Проверьте интернет-подключение и повторите попытку."
    exit 1
  fi
}

#################################################################
##                           HELP                              ##
#################################################################

function show_created_by() {
  echo
  echo "                                    Created by                "
  echo "                           ──────────────────────────────     "
  echo "                                   ┏┓┓     ┓                  "
  echo "                                   ┣┫┃┏┓┏┓ ┃ ┏┓╋╋┏┓           "
  echo "                               ━━━━┛┗┗┗┻┛┗•┗┛┗┻┗┗┗━━━━        "
  echo
}

function help() {
  echo
  echo
  echo "                        /$\$   /$\$     /$\$$\$$\$     /$\$               "
  echo "                       | $\$  | $\$    /$\$__  $\$   | $\$                "
  echo "                       | $\$  | $\$   | $\$  \__/   | $\$                 "
  echo "                       | $\$$\$$\$$\$   |  $\$$\$$\$    | $\$             "
  echo "                       |_____  $\$    \____  $\$   | $\$                  "
  echo "                             | $\$    /$\$  \ $\$   | $\$                 "
  echo "                             | $\$   |  $\$$\$$\$/   | $\$$\$$\$$\$       "
  echo "                             |__/    \______/    |________/               "
  echo
  echo "Usage: 4sl [OPTIONS] [ARGS]"
  echo
  echo "Основные опции (возможно комбинировать):"
  echo "  -h, --help               Показать эту справку."
  echo "  --update                 Обновить 4sl до последней версии."
  echo "  -exp, --expirations      Показать сроки действия всех сертификатов."
  echo "  --remove <domain>        Удалить сертификат (CRT, KEY, DH и Snippet) для домена."
  echo
  echo "Создание и удаление сертификатов:"
  echo "  -s, --ssl                Создать новый SSL-сертификат."
  echo "  -d, --delete             Удалить SSL-сертификат (CRT, KEY, DH, Snippet)."
  echo
  echo "Переподписание (renew) сертификата:"
  echo "  --renew-ssl [auto|manual]"
  echo "     auto   -> создать/обновить cron-задачу на еженедельную проверку,"
  echo "               при <= 7 дней до окончания — пересоздать."
  echo "     manual -> выполнить проверку один раз прямо сейчас без cron."
  echo
  echo "Сервисы и домены:"
  echo "  --nginx <domain>         Указать, что сертификат для Nginx, domain обязателен."
  echo "  --docker                 Указать, что сертификат для Docker (без домена)."
  echo
  echo "Дополнительные флаги:"
  echo "  --silent                 Не задавать вопросов при создании (subj = CN=domain)."
  echo "  -y                       Автоматически подтверждать удаления и т.д."
  echo
  echo "Примеры:"
  echo "  4sl --ssl --nginx example.com                # Создать Nginx SSL для example.com (спросит confirm)."
  echo "  4sl --ssl --nginx example.com --silent -y    # То же самое, без вопросов."
  echo "  4sl --delete --nginx example.com -y          # Удалить Nginx SSL без подтверждения."
  echo "  4sl --ssl --docker                           # Создать Docker SSL (имя = 'docker')."
  echo
  echo "  4sl --renew-ssl auto --nginx example.com     # Проверить и переподписать, если < 7 дней, + cron."
  echo "  4sl --renew-ssl manual --nginx example.com   # Проверить один раз, без cron."
  echo
  echo "  # Комбинировать (создать и сразу поставить renew-ssl auto):"
  echo "  4sl --ssl --nginx example.com --renew-ssl auto --silent -y"
  echo
  show_created_by
}


#################################################################
##              Разбор аргументов одной командой               ##
#################################################################
function process_arguments() {
  if [[ $# -eq 0 ]]; then
    help
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        help
        exit 0
        ;;
      --update)
        DO_UPDATE=true
        ;;
      -exp|--expirations)
        SHOW_EXPIRATIONS=true
        ;;
      --remove)
        shift
        REMOVE_DOMAIN="$1"
        ;;
      -s|--ssl)
        CREATE_SSL=true
        ;;
      -d|--delete)
        DELETE_SSL=true
        ;;
      --renew-ssl)
        DO_RENEW_SSL=true
        shift
        # Проверяем, указал ли пользователь auto/manual
        if [[ "$1" == "auto" || "$1" == "manual" ]]; then
          RENEW_MODE="$1"
        else
          # Если не указали — используем дефолт, но не откатываем shift
          RENEW_MODE="auto"
          # Можно сделать shift назад, но тогда мы можем потерять аргумент
          # Оставим по умолчанию auto.
          continue
        fi
        ;;
      --nginx)
        CERT_TYPE="--nginx"
        shift
        CERT_NAME="$1"
        ;;
      --docker)
        CERT_TYPE="--docker"
        # для Docker CERT_NAME не нужен
        ;;
      --silent)
        SILENT_MODE=true
        ;;
      -y)
        AUTO_CONFIRM=true
        ;;
      *)
        log "Неизвестная опция: $1"
        exit 1
        ;;
    esac
    shift
  done
}

#################################################################
##                      Точка входа (main)                     ##
#################################################################

create_dirs
process_arguments "$@"

# 1) Обновление скрипта
if $DO_UPDATE; then
  update_script
  exit 0
fi

# 2) Удаление по домену ( --remove domain ), если есть
if [ -n "$REMOVE_DOMAIN" ]; then
  remove_ssl "$REMOVE_DOMAIN"
  exit 0
fi

# 3) Показ expirations
if $SHOW_EXPIRATIONS; then
  ssl_expiration
  exit 0
fi

# Если есть тип (nginx/docker), нужно удостовериться, что всё настроено.
if [ -n "$CERT_TYPE" ]; then
  # Зададим CERT_NAME по умолчанию, если docker
  if [ "$CERT_TYPE" == "--docker" ] && [ -z "$CERT_NAME" ]; then
    CERT_NAME="docker"
  fi
  # Инициализируем пути
  if [ "$CERT_TYPE" == "--nginx" ]; then
    cert_paths 1   # Nginx -> dhparam
  else
    cert_paths     # Docker -> без dhparam
  fi

  # Проверяем зависимости (nginx/docker)
  check_dependencies
fi

# 4) Если нужно создать SSL
if $CREATE_SSL; then
  ssl_create_main
fi

# 5) Если нужно переподписать (renew)
if $DO_RENEW_SSL; then
  renew_ssl
fi

# 6) Если нужно удалить ( -d / --delete )
if $DELETE_SSL; then
  delete_ssl_files
fi

echo
echo "                              ┌─────────────────────┐"
echo "                              │  Thanks for usage.  │"
echo "                              └─────────────────────┘"
show_created_by
