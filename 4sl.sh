#!/bin/bash

BASE_DIR="/etc/4sl"

SSL_DHPARAM_DIR_PATH="$BASE_DIR/dhparam"
SSL_CERTIFICATE_DIR_PATH="$BASE_DIR/certs"
SSL_CERTIFICATE_KEY_DIR_PATH="$BASE_DIR/private"
NGINX_SNIPPETS_DIR_PATH="$BASE_DIR/nginx/snippets"

SILENT_MODE=false
AUTO_CONFIRM=false

# Файл для логирования всех действий
LOG_FILE="/var/log/4sl.log"

# Удобная функция для логов: дублирует сообщение и в консоль, и в лог
function log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

function generate_dhparam_ssl() {
    if [ -f "$ssl_dhparam_path" ]
      then
        log "Error: dhparam уже существует для $CERT_NAME."
        exit 1;
    fi

    log "Генерация dhparam в $ssl_dhparam_path ..."
    sudo openssl dhparam -out "$ssl_dhparam_path" 2048

    if [ -f "$ssl_dhparam_path" ]; then
        echo "ssl_dhparam $ssl_dhparam_path;" >> "$nginx_snippets"
        log "dhparam успешно создан и добавлен в $nginx_snippets"
    else
        log "Error: dhparam не найден. Сертификат не был добавлен в nginx."
    fi
}

function generate_ssl() {
    if [ -f "$ssl_certificate_path" ] || [ -f "$ssl_certificate_key_path" ]; then
        log "Error: Сертификаты для $CERT_NAME уже существуют."
        exit 1;
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

    # Если всё успешно создалось и это nginx-сертификат, прописываем путь в snippets
    if [ -f "$ssl_certificate_path" ] && [ -f "$ssl_certificate_key_path" ] && [ "$CERT_TYPE" == "--nginx" ]; then
        echo "ssl_certificate $ssl_certificate_path;" >> "$nginx_snippets"
        echo "ssl_certificate_key $ssl_certificate_key_path;" >> "$nginx_snippets"
        log "Сертификат и ключ добавлены в $nginx_snippets"
    fi
}


function check_dependencies(){
  if ! openssl version &> /dev/null; then
    log "Openssl не установлен!"
    log "Для установки: sudo apt install openssl -y"
    exit 1
  fi

  arr=("$@")
  for i in "${arr[@]}"; do
    case $i in
      --nginx)
        if ! nginx -v &> /dev/null; then
          log "Nginx не установлен!"
          log "Для установки: sudo apt install nginx -y"
          exit 1
        fi
        ;;
      --docker)
        if ! docker -v &> /dev/null; then
          log "Docker не установлен!"
          log "Для установки: curl -fsSL https://get.docker.com | sh"
          # Здесь можно exit 1 или просто логировать
        fi
        ;;
      *)
        log "Данный сервис не поддерживается."
        exit 1
        ;;
    esac
  done
}

function cert_paths() {
  files=()
  dhparam=$1

  if [ -z "$CERT_NAME" ]; then
    log "Не указано имя домена (CERT_NAME). Используйте --help для справки."
    exit 1
  fi

  if [ -n "$dhparam" ]; then
    readonly ssl_dhparam_path="$SSL_DHPARAM_DIR_PATH/$CERT_NAME.pem"
    files+=("$ssl_dhparam_path")
  fi

  readonly ssl_certificate_path="$SSL_CERTIFICATE_DIR_PATH/$CERT_NAME.crt"
  files+=("$ssl_certificate_path")

  readonly ssl_certificate_key_path="$SSL_CERTIFICATE_KEY_DIR_PATH/$CERT_NAME.key"
  files+=("$ssl_certificate_key_path")

  if [ "$CERT_TYPE" == "--nginx" ]; then
    readonly nginx_snippets="$NGINX_SNIPPETS_DIR_PATH/$CERT_NAME"
    files+=("$nginx_snippets")
    files+=("/etc/nginx/snippets/ssl/$CERT_NAME")
  fi
}

function __linebreak() {
  echo "──────────────────────────────────"
}

function ssl() {
  if [ "$AUTO_CONFIRM" = true ]; then
    yn="y"
  else
    read -r -p "Создать самоподписанный ssl-сертификат для $CERT_NAME? (y/n) " yn
  fi

  case $yn in
    [yY] )
      generate_ssl

      if [ "$CERT_TYPE" == --nginx ]; then
        # Создаем ссылку в /etc/nginx/snippets/ssl/
        if ! ln -s "$nginx_snippets" "/etc/nginx/snippets/ssl/$CERT_NAME" 2>/dev/null; then
          mkdir -p "/etc/nginx/snippets/ssl/"
          ln -s "$nginx_snippets" "/etc/nginx/snippets/ssl/$CERT_NAME"
        fi
        generate_dhparam_ssl
      fi
      ;;
    [nN] )
      log "Операция отменена пользователем."
      exit
      ;;
    * )
      log "Неверный ответ, отмена..."
      exit 1
      ;;
  esac

  __linebreak
  log "Создан SSL-сертификат:       $ssl_certificate_path"
  log "Создан ключ SSL-сертификата: $ssl_certificate_key_path"

  if [ "$CERT_TYPE" == "--nginx" ]; then
    log "Создан dhparam: $ssl_dhparam_path"
    __linebreak
    log "Создана символьная ссылка: /etc/nginx/snippets/ssl/$CERT_NAME -> $nginx_snippets"
  fi
}

function delete_ssl(){
  __linebreak
  log "Файлы, которые будут удалены:"
  for index in "${!files[@]}" ; do
      printf "%d. %s\n" "$index" "${files[$index]}"
  done

  if [ "$AUTO_CONFIRM" = true ]; then
    yn="y"
  else
    read -r -p "Вы уверены, что хотите удалить эти файлы? (y/n) " yn
  fi

  __linebreak

  case $yn in
    [yY] )
      for file in "${files[@]}"; do
        if [ -f "$file" ] || [ -L "$file" ]; then
          log "Удаляю: $file"
          rm -f "$file"
        else
          log "Файл не найден, пропускаю: $file"
        fi
      done
      ;;
    [nN] )
      log "Удаление отменено пользователем."
      exit
      ;;
    * )
      log "Неверный ответ, отмена..."
      exit 1
      ;;
  esac
}

function ssl_expiration() {
  if ! [ -d "$SSL_CERTIFICATE_DIR_PATH" ]; then
    log "Каталог с сертификатами не найден: $SSL_CERTIFICATE_DIR_PATH"
    exit 1
  fi

  for pem in "$SSL_CERTIFICATE_DIR_PATH"/*.crt; do
    # 2678400 - ~31 день
    if openssl x509 -checkend 2678400 -noout -in "$pem" &> /dev/null; then
      printf "[ + ]: %s - %s\n" "$(date --date="$(openssl x509 -enddate -noout -in "$pem"|cut -d= -f 2)" --iso-8601)" "$pem"
    else
      printf "[ - ]: %s - %s\n" "$(date --date="$(openssl x509 -enddate -noout -in "$pem"|cut -d= -f 2)" --iso-8601)" "$pem"
    fi
  done | sort
}

function define_service_name() {
  readonly CERT_TYPE=$1
  if [ -z "$CERT_TYPE" ]; then
    log "Нужно указать --docker или --nginx. Используйте --help для справки."
    exit 1
  fi
  case $CERT_TYPE in
    --docker)
      # Для docker не используем домен
      if [ -n "$2" ]; then
        log "Ошибка: Имя домена не поддерживается при использовании --docker."
        exit 1
      fi
      readonly CERT_NAME="docker"
      cert_paths
      ;;
    --nginx)
      readonly CERT_NAME=$2
      cert_paths 1
      ;;
    *)
      log "Ошибка: Только --docker и --nginx поддерживаются"
      exit 1
      ;;
  esac

  check_dependencies "$CERT_TYPE"
}

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
  echo "                        /$$   /$$     /$$$$$$     /$$               "
  echo "                       | $$  | $$    /$$__  $$   | $$                "
  echo "                       | $$  | $$   | $$  \\__/   | $$                 "
  echo "                       | $$$$$$$$   |  $$$$$$    | $$             "
  echo "                       |_____  $$    \\____  $$   | $$                 "
  echo "                             | $$    /$$  \\ $$   | $$                 "
  echo "                             | $$   |  $$$$$$/   | $$$$$$$$           "
  echo "                             |__/    \\______/    |________/           "
  echo
  echo
  echo "Usage: 4sl [options] [arguments]"
  echo "Options:"
  echo "-h/--help                               - Показать справку."
  echo "-s/--ssl [service] [domain?]            - Создать новый SSL-сертификат."
  echo "-d/--delete [service] [domain?]         - Удалить SSL-сертификат."
  echo "-exp/--expirations                      - Показать срок действия SSL-сертификатов."
  echo "--renew-ssl (auto|manual) [service] [domain?] - Переподписать сертификат, если осталось < 7 дней."
  echo "                                          auto   -> создает cron-задачу на еженедельную проверку"
  echo "                                          manual -> без cron-задачи."
  echo "--remove <domain>                       - Удалить сертификат по домену (без указания --nginx)."
  echo "--silent                                - Включить тихий режим (non-interactive)."
  echo "-y                                      - Автоматически подтверждать удаление."
  echo "--update                                - Обновить скрипт 4sl до последней версии."
  echo
  echo "Service Arguments:"
  echo "--nginx [domain]                        - SSL-сертификат для Nginx."
  echo "--docker                                - SSL-сертификат для Docker."
  echo
  echo "Примеры:"
  echo "4sl --ssl --nginx example.com           - Создать Nginx SSL для example.com."
  echo "4sl --delete --nginx example.com        - Удалить Nginx SSL для example.com."
  echo "4sl --ssl --docker                      - Создать Docker SSL."
  echo "4sl --delete --docker                   - Удалить Docker SSL."
  echo "4sl --ssl --nginx example.com --silent  - Создать Nginx SSL для example.com (тихий режим)."
  echo "4sl --delete --nginx example.com -y     - Удалить Nginx SSL без подтверждения."
  echo "4sl --renew-ssl auto --nginx example.com - Переподписать cert для example.com (cron раз в неделю)."
  echo "4sl --remove example.com                - Удалить сертификат example.com отовсюду."
  echo "4sl --update                            - Обновиться до последней версии."
  show_created_by
}

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

function create_cron_job() {
  # Создаем (или перезаписываем) файл для еженедельного cron-job.
  local cron_file="/etc/cron.weekly/4sl-renew-$CERT_NAME"

  # Если хотим добавить условия, что если уже есть cron — не перезаписываем, добавляем проверку
  log "Создаю cron-задачу для еженедельной проверки сертификата $CERT_NAME в $cron_file..."
  sudo bash -c "cat <<EOF > \"$cron_file\"
#!/bin/bash
/usr/local/bin/4sl --renew-ssl manual $CERT_TYPE $CERT_NAME >> /var/log/4sl.log 2>&1
EOF
"
  sudo chmod +x "$cron_file"

  log "Cron-задача $cron_file успешно создана. Проверка будет запускаться раз в неделю."
}

# Переподписание (renew) сертификатов
function renew_ssl() {
  local RENEW_MODE="$1"

  # Если не передан auto|manual, используем auto по умолчанию
  if [ "$RENEW_MODE" != "auto" ] && [ "$RENEW_MODE" != "manual" ]; then
    RENEW_MODE="auto"
  fi

  # Проверяем, что сертификат есть, иначе не с чем работать
  if [ ! -f "$ssl_certificate_path" ]; then
    log "Сертификат $ssl_certificate_path не найден! Нечего переподписывать."
    exit 1
  fi

  log "Проверяем срок действия сертификата: $ssl_certificate_path"
  local now
  now=$(date +%s)
  local exp_date
  exp_date=$(openssl x509 -enddate -noout -in "$ssl_certificate_path" 2>/dev/null | cut -d= -f2)
  if [ -z "$exp_date" ]; then
    log "Не удалось определить дату окончания действия сертификата. Прерывание..."
    exit 1
  fi

  local expiration
  expiration=$(date -d "$exp_date" +%s 2>/dev/null)
  if [ $? -ne 0 ]; then
    log "Ошибка в обработке даты окончания действия сертификата. Прерывание..."
    exit 1
  fi

  local diff=$(( expiration - now ))
  local seven_days=$(( 7 * 24 * 3600 ))

  if [ $diff -lt $seven_days ]; then
    log "До истечения действия сертификата < 7 дней. Переподписываем..."
    # Удалим старые файлы и пересоздадим
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

  # Если auto - ставим cron для автоматической еженедельной проверки
  if [ "$RENEW_MODE" == "auto" ]; then
    create_cron_job
  fi
}

# Удаление сертификата по домену без указания --nginx/--docker
function remove_ssl() {
  local domain="$1"
  if [ -z "$domain" ]; then
    log "Использование: 4sl --remove <domain>"
    exit 1
  fi

  log "Удаление SSL-сертификатов для домена $domain..."
  local cert="$SSL_CERTIFICATE_DIR_PATH/$domain.crt"
  local key="$SSL_CERTIFICATE_KEY_DIR_PATH/$domain.key"
  local dhparam="$SSL_DHPARAM_DIR_PATH/$domain.pem"
  local snippet="$NGINX_SNIPPETS_DIR_PATH/$domain"
  local snippet_link="/etc/nginx/snippets/ssl/$domain"

  for file in "$cert" "$key" "$dhparam" "$snippet" "$snippet_link"; do
    if [ -f "$file" ] || [ -L "$file" ]; then
      log "Удаляю: $file"
      rm -f "$file"
    else
      log "Файл не найден, пропускаю: $file"
    fi
  done

  log "Удаление сертификата для $domain завершено."
}


function process_arguments() {
  if [[ $# -eq 0 ]]; then
    help
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        help
        exit 0
        ;;
      -s|--ssl)
        shift
        define_service_name "$1" "$2"
        if [[ "$*" == *"--silent"* ]]; then
          SILENT_MODE=true
        fi
        if [[ "$*" == *"-y"* ]]; then
          AUTO_CONFIRM=true
        fi
        ssl
        break
        ;;
      -d|--delete)
        shift
        define_service_name "$1" "$2"
        if [[ "$*" == *"-y"* ]]; then
          AUTO_CONFIRM=true
        fi
        delete_ssl
        break
        ;;
      -exp|--expirations)
        ssl_expiration
        break
        ;;
      --renew-ssl)
        shift
        local RENEW_MODE="$1"

        # Если первая позиция не auto|manual, считаем её частью define_service_name
        if [ "$RENEW_MODE" == "auto" ] || [ "$RENEW_MODE" == "manual" ]; then
          shift
          define_service_name "$1" "$2"
        else
          RENEW_MODE="auto"  # по умолчанию
          define_service_name "$RENEW_MODE" "$1"
        fi
        renew_ssl "$RENEW_MODE"
        break
        ;;
      --remove)
        shift
        remove_ssl "$1"
        exit 0
        ;;
      --silent)
        SILENT_MODE=true
        shift
        ;;
      -y)
        AUTO_CONFIRM=true
        shift
        ;;
      --update)
        update_script
        exit 0
        ;;
      *)
        log "Команда не найдена: $1. Используйте -h/--help для справки."
        exit 1
        ;;
    esac
  done
}

function create_dirs(){
  dirs=("$BASE_DIR" "$SSL_DHPARAM_DIR_PATH" "$SSL_CERTIFICATE_KEY_DIR_PATH" "$SSL_CERTIFICATE_DIR_PATH" "$NGINX_SNIPPETS_DIR_PATH")
  for dir in "${dirs[@]}"; do
    if ! [ -d "$dir" ]; then
      mkdir -p "$dir"
    fi
  done
}

# Основной блок запуска скрипта
create_dirs
process_arguments "$@"

echo
echo "                              ┌─────────────────────┐"
echo "                              │  Thanks for usage.  │"
echo "                              └─────────────────────┘"
show_created_by
