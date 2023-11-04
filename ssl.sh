#!/bin/bash


function generate_dhparam_ssl() {
    readonly ssl_dhparam_path="/etc/ssl/certs/$DOMAIN_NAME.pem"

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
    readonly ssl_certificate_path="/etc/ssl/certs/$DOMAIN_NAME.crt"
    readonly ssl_certificate_key_path="/etc/ssl/private/$DOMAIN_NAME.key"
    readonly nginx_snippets="/etc/nginx/snippets/ssl/$DOMAIN_NAME"

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

function ssl() {
    if [ -z "$DOMAIN_NAME" ]; then
        echo "You haven't passed the domain. Read --help for see usage."
        exit 1;
    fi

    read -r -p "Do you want to create self-signed ssl certs by $DOMAIN_NAME? (y/n) " yn

    case $yn in
      [yY] )
        generate_ssl;
        generate_dhparam_ssl;
        ;;
      [nN] ) echo exiting...;
        exit;;
      * ) echo invalid response;
        exit 1;;
    esac
    echo "Created ssl certificate on: $ssl_certificate_path"
    echo "Created ssl certificate key on: $ssl_certificate_key_path"
    echo "Created ssl dhparam on: $ssl_dhparam_path"
    echo "----------------------------------"
    echo "Created Nginx snippets on: $nginx_snippets"
}

function delete_ssl(){
    readonly ssl_certificate_path="/etc/ssl/certs/$DOMAIN_NAME.crt"
    readonly ssl_certificate_key_path="/etc/ssl/private/$DOMAIN_NAME.key"
    readonly ssl_dhparam_path="/etc/ssl/certs/$DOMAIN_NAME.pem"
    readonly nginx_snippets="/etc/nginx/snippets/ssl/$DOMAIN_NAME"

    read -r -p "You really want to delete ssl certs by $DOMAIN_NAME? (y/n) " yn

    case $yn in
      [yY] )
        readonly files=("$ssl_certificate_path" "$ssl_certificate_key_path" "$ssl_dhparam_path" "$nginx_snippets")
        for file in "${files[@]}"; do
          echo "Deleting: $file"
          rm "$file"
        done
        ;;
      [nN] ) echo exiting...;
        exit;;
      * ) echo invalid response;
        exit 1;;
    esac

}

function process_arguments() {
  if [[ $# -eq 0 ]]; then
    echo "Use -h/--help for see usage."
  fi
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        echo "-h/--help            - show usage.";
        echo "-s/--ssl \$domain     - Create new ssl certificate.";
        echo "-d/--delete \$domain  - Delete ssl certificate.";
        echo "";
        echo "Created by:       https://github.com/alan.latte";
        exit 1;;
      -s|--ssl)
        readonly DOMAIN_NAME="$2"
        shift
        ssl "$DOMAIN_NAME";
        break ;;
      -d|--delete)
        readonly DOMAIN_NAME="$2"
        delete_ssl "$DOMAIN_NAME";
        shift
        break;;
      -*|--*)
        echo "Command not found. Use -h/--help for see usage."
        exit 1;;
    esac
  done
}

process_arguments "$@";
