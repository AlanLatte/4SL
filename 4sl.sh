#!/bin/bash


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

    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$ssl_certificate_key_path" -out "$ssl_certificate_path"

    if [ -f "$ssl_certificate_path" ] && [ -f "$ssl_certificate_key_path" ]
      then
        echo "ssl_certificate $ssl_certificate_path;" >> "$nginx_snippets"
        echo "ssl_certificate_key $ssl_certificate_key_path;" >> "$nginx_snippets"
      else
        echo "Error: ssl certs not Found, the certificate could not be added to nginx."
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
    echo "You haven't passed the \$domain. Read --help for see usage."
    exit 1;
  fi

  if [ -n "$dhparam" ]; then
    readonly ssl_dhparam_path="/etc/ssl/certs/$CERT_NAME.pem"
    files+=("$ssl_dhparam_path")
  fi

  readonly ssl_certificate_path="/etc/ssl/certs/$CERT_NAME.crt"
  files+=("$ssl_certificate_path")

  readonly ssl_certificate_key_path="/etc/ssl/private/$CERT_NAME.key"
  files+=("$ssl_certificate_key_path")

  if [ "$CERT_TYPE" == "--nginx" ]; then
    readonly nginx_snippets="/etc/nginx/snippets/ssl/$CERT_NAME"
    files+=("$nginx_snippets")
  fi
}

function __linebreak() {
  echo "──────────────────────────────────"
}

function ssl() {
  read -r -p "Do you want to create self-signed ssl certs by $CERT_NAME? (y/n) " yn

  case $yn in
    [yY] )

      if ! touch "$nginx_snippets"; then
        mkdir -p "/etc/nginx/snippets/ssl/"
        touch "$nginx_snippets"
      fi

      generate_ssl;

      if [ "$CERT_TYPE" == --nginx ]; then
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
    echo "Created Nginx snippets on: $nginx_snippets"
  fi
}

function delete_ssl(){
  for index in "${!files[@]}" ; do
      printf "%d. %s\n" "$index" "${files[$index]}"
  done

  read -r -p "You really want to delete this ssl certs? (y/n) " yn

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

  echo
  echo "Usage: ./ssl.sh [options] [arguments]"
  echo "Options:";
  echo "-h/--help                               - Show usage.";
  echo "-s/--ssl [arguments]                    - Create new ssl certificate.";
  echo "-d/--delete [arguments]                 - Delete ssl certificate.";
  echo
  echo "Arguments:"
  echo "--nginx [domain]                        - Create or Delete ssl certificate for Nginx.";
  echo "--docker                                - Create or Delete ssl certificate for Docker.";
  echo
  echo "Example:"
  echo "./4sl.sh --ssl --nginx example.com      - Create  Nginx ssl certificate. for example.com";
  echo "./4sl.sh --delete --nginx example.com   - Delete Nginx ssl certificate. for example.com";
  echo "./4sl.sh --ssl --docker                 - Create Docker ssl certificate.";
  echo "./4sl.sh --delete --docker              - Delete Docker ssl certificate.";
  show_created_by
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
        ssl;
        break;;
      -d|--delete)
        shift
        define_service_name "$1" "$2"
        delete_ssl;
        break;;
      *)
        echo "Command not found. Use -h/--help for see usage."
        exit 1;;
    esac
  done
}

process_arguments "$@";
echo "                              ┌─────────────────────┐"
echo "                              │  Thanks for usage.  │"
echo "                              └─────────────────────┘"
show_created_by

