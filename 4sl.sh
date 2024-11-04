#!/bin/bash

BASE_DIR="/etc/4sl"

SSL_DHPARAM_DIR_PATH="$BASE_DIR/dhparam"
SSL_CERTIFICATE_DIR_PATH="$BASE_DIR/certs"
SSL_CERTIFICATE_KEY_DIR_PATH="$BASE_DIR/private"
NGINX_SNIPPETS_DIR_PATH="$BASE_DIR/nginx/snippets"

SILENT_MODE=false
AUTO_CONFIRM=false

function generate_dhparam_ssl() {
    if [ -f "$ssl_dhparam_path" ]
      then
        echo "Error: dhparam certs on this domain already exists."
        exit 1;
    fi

    sudo openssl dhparam -out "$ssl_dhparam_path" 2048

    if [ -f "$ssl_dhparam_path" ]
      then
        echo "ssl_dhparam $ssl_dhparam_path;" >> "$nginx_snippets"
    else
        echo "Error: dhparam certs not Found, the certificate could not be added to nginx."
    fi

}

function generate_ssl() {
    if [ -f "$ssl_certificate_path" ] || [ -f "$ssl_certificate_key_path" ]
      then
        echo "Error: Certs on this domain already exists."
        exit 1;
    fi

    if [ "$SILENT_MODE" = true ]; then
      sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$ssl_certificate_key_path" -out "$ssl_certificate_path" -subj "/C=US/ST=State/L=City/O=Organization/OU=Unit/CN=$CERT_NAME"
    else
      sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$ssl_certificate_key_path" -out "$ssl_certificate_path"
    fi

    if [ -f "$ssl_certificate_path" ] && [ -f "$ssl_certificate_key_path" ] && [ "$CERT_TYPE" == "--nginx" ]
      then
        echo "ssl_certificate $ssl_certificate_path;" >> "$nginx_snippets"
        echo "ssl_certificate_key $ssl_certificate_key_path;" >> "$nginx_snippets"
    fi
}


function check_dependencies(){

  if ! openssl version &> /dev/null; then
    echo "Openssl could not be found!"
    echo "For install use: sudo apt install openssl -y"
  fi

  arr=("$@")
  for i in "${arr[@]}";
    do
      case $i in
        --nginx)
          if ! nginx -v &> /dev/null; then
            echo "Nginx  could not be found!"
            echo "For install use: sudo apt install nginx -y"
            exit 1
          fi;;
        --docker)
          if ! docker -v &> /dev/null; then
            echo "Docker could not be found!"
            echo "For install use: curl -fsSL https://get.docker.com | sh"
          fi;;
        *)
          echo "This dependencies is not supported now."
          exit 1;;
        esac
    done
}


function cert_paths() {
  files=()
  dhparam=$1

  if [ -z "$CERT_NAME" ]; then
    echo "You haven't passed the [domain]. Read --help for see usage."
    exit 1;
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
    read -r -p "Do you want to create self-signed ssl certs by $CERT_NAME? (y/n) " yn
  fi

  case $yn in
    [yY] )
      generate_ssl;

      if [ "$CERT_TYPE" == --nginx ]; then
        if ! ln -s "$nginx_snippets" "/etc/nginx/snippets/ssl/$CERT_NAME"; then
          mkdir -p "/etc/nginx/snippets/ssl/"
          ln -s "$nginx_snippets" "/etc/nginx/snippets/ssl/$CERT_NAME"
        fi
        generate_dhparam_ssl;
      fi

      ;;
    [nN] ) echo exiting...;
      exit;;
    * ) echo invalid response;
      exit 1;;
  esac

  __linebreak
  echo "Created ssl certificate on: $ssl_certificate_path"
  echo "Created ssl certificate key on: $ssl_certificate_key_path"

  if [ "$CERT_TYPE" == "--nginx" ]; then
    echo "Created ssl dhparam on: $ssl_dhparam_path"
    __linebreak
    echo "Created Nginx snippets link on: /etc/nginx/snippets/ssl/$CERT_NAME -> $nginx_snippets"
  fi
}


function delete_ssl(){
  for index in "${!files[@]}" ; do
      printf "%d. %s\n" "$index" "${files[$index]}"
  done

  if [ "$AUTO_CONFIRM" = true ]; then
    yn="y"
  else
    read -r -p "You really want to delete this ssl certs? (y/n) " yn
  fi

  __linebreak

  case $yn in
    [yY] )
      for file in "${files[@]}"; do
        echo "Deleting: $file"
        rm "$file"
      done
      ;;
    [nN] ) echo exiting...;
      exit;;
    * ) echo invalid response, exiting...;
      exit 1;;
  esac
}

function ssl_expiration() {
  if ! [ -d "$SSL_CERTIFICATE_DIR_PATH" ]; then
    echo "Not found any certs."
    exit 1
  fi

  for pem in "$SSL_CERTIFICATE_DIR_PATH"/*.crt; do
    # 2678400 - 31d
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
    echo "You must choice between --docker and --nginx. Pass --help for see usage."
    exit 1
  fi
  case $CERT_TYPE in
    --docker)
      if [ -n "$2" ]; then
        echo "Error: Domain name not supported when you pass --docker argument."
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
      echo "Error: Only --docker and --nginx service name supported"
      exit 1;
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
  echo "                        /$\$   /$\$     /$\$$\$$\$     /$\$               "
  echo "                       | $\$  | $\$    /$\$__  $\$   | $\$                "
  echo "                       | $\$  | $\$   | $\$  \__/   | $\$                 "
  echo "                       | $\$$\$$\$$\$   |  $\$$\$$\$    | $\$             "
  echo "                       |_____  $\$    \____  $\$   | $\$                  "
  echo "                             | $\$    /$\$  \ $\$   | $\$                 "
  echo "                             | $\$   |  $\$$\$$\$/   | $\$$\$$\$$\$       "
  echo "                             |__/    \______/    |________/               "
  echo
  echo
  echo "Usage: 4sl [options] [arguments]"
  echo "Options:"
  echo "-h/--help                               - Show usage."
  echo "-s/--ssl [arguments]                    - Create new SSL certificate."
  echo "-d/--delete [arguments]                 - Delete SSL certificate."
  echo "-exp/--expirations                      - Show SSL certificate expirations."
  echo "--silent                                - Enable silent mode for non-interactive certificate generation."
  echo "-y                                      - Automatically confirm deletion prompts."
  echo "--update                                - Update the 4sl script to the latest version."
  echo
  echo "Arguments:"
  echo "--nginx [domain]                        - Create or Delete SSL certificate for Nginx."
  echo "--docker                                - Create or Delete SSL certificate for Docker."
  echo
  echo "Example:"
  echo "4sl --ssl --nginx example.com           - Create Nginx SSL certificate for example.com."
  echo "4sl --delete --nginx example.com        - Delete Nginx SSL certificate for example.com."
  echo "4sl --ssl --docker                      - Create Docker SSL certificate."
  echo "4sl --delete --docker                   - Delete Docker SSL certificate."
  echo "4sl --ssl --nginx example.com --silent  - Create Nginx SSL certificate for example.com in silent mode."
  echo "4sl --delete --nginx example.com -y     - Delete Nginx SSL certificate for example.com without confirmation."
  echo "4sl --update                            - Update the 4sl script to the latest version."
  show_created_by
}

function update_script() {
  echo "Updating the 4sl script..."
  curl https://raw.githubusercontent.com/AlanLatte/4SL/main/4sl.sh > 4sl.sh && chmod +x ./4sl.sh && sudo mv ./4sl.sh /usr/local/bin/4sl
  if [ $? -eq 0 ]; then
    echo "Update completed successfully."
  else
    echo "Update failed. Please check your internet connection and try again."
    exit 1
  fi
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
        exit 1;;
      -s|--ssl)
        shift
        define_service_name "$1" "$2"
        if [[ "$*" == *--silent* ]]; then
          SILENT_MODE=true
        fi
        ssl;
        break ;;
      -d|--delete)
        shift
        define_service_name "$1" "$2"
        if [[ "$*" == *-y* ]]; then
          AUTO_CONFIRM=true
        fi
        delete_ssl;
        break ;;
      -exp|--expirations)
        ssl_expiration
        break ;;
      --silent)
        SILENT_MODE=true
        shift;;
      -y)
        AUTO_CONFIRM=true
        shift;;
      --update)
        update_script
        exit 0;;
      *)
        echo "Command not found. Use -h/--help to see usage."
        exit 1;;
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


create_dirs;
process_arguments "$@";
echo
echo
echo "                              ┌─────────────────────┐"
echo "                              │  Thanks for usage.  │"
echo "                              └─────────────────────┘"
show_created_by

