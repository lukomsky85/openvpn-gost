#!/bin/bash

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен запускаться с правами root" >&2
  exit 1
fi

# Конфигурационные переменные
CONFIG_DIR="/etc/openvpn"
EASY_RSA_DIR="/etc/openvpn/easy-rsa"
PKI_DIR="$EASY_RSA_DIR/pki"
KEYS_DIR="$PKI_DIR"
MANAGEMENT_SOCKET="/tmp/openvpn-mgmt.sock"
LOG_FILE="/var/log/openvpn-gost.log"
VPN_SERVICE_NAME="openvpn-server@server-gost"

# Установка пакетов
install_packages() {
  apt update
  apt install -y openvpn easy-rsa openssl git ufw
  # Собираем gost-engine
  build_gost_engine
}

# Сборка gost-engine
build_gost_engine() {
  echo "Скачивание и сборка gost-engine..."
  mkdir -p /usr/local/src/gost-engine
  cd /usr/local/src/gost-engine
  git clone https://github.com/gost-engine/engine.git
  cd engine
  make
  make install
  # Настройка openssl.cnf
  cat > /etc/ssl/openssl.cnf <<EOF
openssl_conf = openssl_def
[openssl_def]
engines = engine_section
[engine_section]
gost = gost_section
[gost_section]
engine_id = gost
dynamic_path = /usr/lib/x86_64-linux-gnu/engines-1.1/gost.so
default_algorithms = ALL
EOF
  export OPENSSL_CONF=/etc/ssl/openssl.cnf
  echo "gost-engine собран и настроен."
}

# Настройка easy-rsa
setup_easyrsa() {
  if [ ! -d "$EASY_RSA_DIR" ]; then
    echo "Настройка easy-rsa..."
    mkdir -p "$EASY_RSA_DIR"
    cp -r /usr/share/easy-rsa/* "$EASY_RSA_DIR"
  fi
  cd "$EASY_RSA_DIR"
  ./easyrsa init-pki
}

# Генерация сертификатов и ключей
generate_certificates() {
  cd "$EASY_RSA_DIR"
  ./easyrsa build-ca nopass
  ./easyrsa gen-req server nopass
  ./easyrsa sign-req server server
  ./easyrsa gen-dh
  openvpn --genkey --secret "$EASY_RSA_DIR/pki/ta.key"
  # Копирование сертификатов и ключей
  mkdir -p "$KEYS_DIR"
  cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem pki/ta.key "$KEYS_DIR"
}

# Создание системного юнита для openvpn
create_systemd_service() {
  cat > /etc/systemd/system/$VPN_SERVICE_NAME <<EOF
[Unit]
Description=OpenVPN service for %i
After=network.target

[Service]
Type=forking
ExecStart=/usr/sbin/openvpn --config /etc/openvpn/%i.conf --daemon
ExecReload=/bin/kill -HUP \$MAINPID
PIDFile=/run/openvpn/%i.pid
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable $VPN_SERVICE_NAME
}

# Основная установка OpenVPN с GOST
install_openvpn() {
  # Запрос параметров
  read -p "Введите порт для OpenVPN (по умолчанию 1194): " PORT
  PORT=${PORT:-1194}
  read -p "Введите протокол (udp/tcp, по умолчанию udp): " PROTO
  PROTO=${PROTO:-udp}
  read -p "Введите публичный IP/DNS сервера: " PUBLIC_IP
  echo "Выберите DNS сервер:"
  echo "1) Ростелеком (158.160.1.1)"
  echo "2) Сбербанк (77.88.8.8)"
  echo "3) Яндекс (77.88.8.1)"
  echo "4) Кастомный"
  read -p "Ваш выбор (1-4): " DNS_CHOICE
  case $DNS_CHOICE in
    1) DNS="158.160.1.1" ;;
    2) DNS="77.88.8.8" ;;
    3) DNS="77.88.8.1" ;;
    4) read -p "Введите IP DNS сервера: " DNS ;;
    *) DNS="158.160.1.1" ;;
  esac

  # Установка и сборка gost-engine
  install_packages

  # Настройка easy-rsa
  setup_easyrsa

  # Генерация сертификатов
  generate_certificates

  # Настройка конфигурации сервера
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_DIR/server-gost.conf" <<EOF
port $PORT
proto $PROTO
dev tun
ca $KEYS_DIR/ca.crt
cert $KEYS_DIR/server.crt
key $KEYS_DIR/server.key
dh $KEYS_DIR/dh.pem
tls-auth $KEYS_DIR/ta.key 0
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS $DNS"
keepalive 10 120
cipher GOST28147-TC26
auth GOST28147-TC26
tls-cipher GOST2012-GOST8912-GOST8912
persist-key
persist-tun
status /var/log/openvpn/openvpn-status.log 30
log-append $LOG_FILE
verb 4
management $MANAGEMENT_SOCKET unix
management $PORT 127.0.0.1
explicit-exit-notify 1
EOF

  # Включение IPv4 форвардинга
  sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p

  # Настройка firewall
  ufw allow "$PORT/$PROTO"
  ufw allow OpenSSH
  ufw --force enable

  # Создание systemd сервиса
  create_systemd_service

  # Запуск сервиса
  systemctl start $VPN_SERVICE_NAME
  systemctl enable $VPN_SERVICE_NAME

  echo "OpenVPN установлен и запущен на порту $PORT ($PROTO)."
  echo "Теперь можно создавать клиентов."
}

# Создание клиента
create_client() {
  local USERNAME="$1"
  cd "$EASY_RSA_DIR"
  ./easyrsa gen-req "$USERNAME" nopass
  ./easyrsa sign-req client "$USERNAME"

  # Создание файла конфигурации клиента
  mkdir -p "$KEYS_DIR/issued"
  cat > "$KEYS_DIR/issued/${USERNAME}.ovpn" <<EOF
client
dev tun
proto $(grep "^proto" "$CONFIG_DIR/server-gost.conf" | awk '{print $2}')
remote $PUBLIC_IP $(grep "^port" "$CONFIG_DIR/server-gost.conf" | awk '{print $2}')
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher GOST28147-TC26
auth GOST28147-TC26
verb 3
<ca>
$(cat "$KEYS_DIR/ca.crt")
</ca>
<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$KEYS_DIR/issued/$USER
NAME.crt")
</cert>
<key>
$(cat "$KEYS_DIR/private/$USERNAME.key")
</key>
<tls-auth>
$(cat "$KEYS_DIR/ta.key")
</tls-auth>
key-direction 1
EOF

  echo "Клиентский файл создан: $KEYS_DIR/issued/${USERNAME}.ovpn"
}

# Главное меню
main_menu() {
  while true; do
    clear
    echo "==== Управление OpenVPN с ГОСТ ===="
    echo "1) Установить и настроить OpenVPN с ГОСТ"
    echo "2) Создать нового клиента"
    echo "3) Статистика подключений"
    echo "4) Отключить клиента (заготовка)"
    echo "5) Заблокировать клиента (заготовка)"
    echo "6) Управление сервисом"
    echo "7) Выйти"
    read -p "Ваш выбор: " CHOICE
    case "$CHOICE" in
      1) install_openvpn ;;
      2) read -p "Введите имя клиента: " CLIENT_NAME; create_client "$CLIENT_NAME" ;;
      3) 
        echo "Статистика не реализована в этом скрипте." 
        read -p "Нажмите Enter" 
        ;;
      4) 
        echo "Отключение клиента — ручная настройка." 
        read -p "Нажмите Enter" 
        ;;
      5) 
        echo "Блокировка клиента — ручная." 
        read -p "Нажмите Enter" 
        ;;
      6) 
        echo "1) Старт сервиса" 
        echo "2) Стоп сервиса" 
        echo "3) Перезапуск сервиса" 
        echo "4) Статус" 
        read -p "Выбор: " SCHOICE
        case "$SCHOICE" in
          1) systemctl start $VPN_SERVICE_NAME ;;
          2) systemctl stop $VPN_SERVICE_NAME ;;
          3) systemctl restart $VPN_SERVICE_NAME ;;
          4) systemctl status $VPN_SERVICE_NAME ;;
          *) echo "Неверный выбор." ; read -p "Нажмите Enter" ;;
        esac
        ;;
      7) echo "Выход." ; exit 0 ;;
      *) echo "Неверный выбор." ; read -p "Нажмите Enter" ;;
    esac
  done
}

# Запуск
main_menu
