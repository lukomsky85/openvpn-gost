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
MANAGEMENT_PORT=5555
LOG_FILE="/var/log/openvpn-gost.log"
VPN_SERVICE_NAME="openvpn-server@server-gost"
PUBLIC_IP=""
PORT=""
PROTO=""
DNS=""

# Установка пакетов
install_packages() {
  echo "Установка необходимых пакетов..."
  apt update && apt install -y openvpn easy-rsa openssl git ufw netcat gcc make cmake libssl-dev
}

# Сборка gost-engine
build_gost_engine() {
  echo "Сборка gost-engine..."
  if [ ! -d "/usr/local/src/gost-engine" ]; then
    mkdir -p /usr/local/src/gost-engine
    git clone https://github.com/gost-engine/engine.git /usr/local/src/gost-engine
  fi
  
  cd /usr/local/src/gost-engine
  cmake . && make
  cp bin/gost.so /usr/lib/x86_64-linux-gnu/engines-1.1/
  
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
  echo "gost-engine успешно установлен"
}

# Настройка EasyRSA
setup_easyrsa() {
  echo "Настройка EasyRSA..."
  if [ ! -d "$EASY_RSA_DIR" ]; then
    make-cadir "$EASY_RSA_DIR"
  fi
  
  cd "$EASY_RSA_DIR" || exit 1
  
  # Создаем или обновляем vars файл
  cat > vars <<EOF
set_var EASYRSA_REQ_COUNTRY "RU"
set_var EASYRSA_REQ_PROVINCE "Moscow"
set_var EASYRSA_REQ_CITY "Moscow"
set_var EASYRSA_REQ_ORG "OpenVPN-GOST"
set_var EASYRSA_REQ_EMAIL "admin@example.com"
set_var EASYRSA_REQ_OU "OpenVPN"
set_var EASYRSA_ALGO "gost2001"
set_var EASYRSA_DIGEST "streebog256"
EOF

  ./easyrsa init-pki
}

# Генерация сертификатов
generate_certificates() {
  echo "Генерация сертификатов..."
  cd "$EASY_RSA_DIR" || exit 1
  
  ./easyrsa build-ca nopass
  ./easyrsa gen-req server nopass
  ./easyrsa sign-req server server
  ./easyrsa gen-dh
  openvpn --genkey --secret "$PKI_DIR/ta.key"
  
  # Копируем сертификаты в нужные места
  mkdir -p "$CONFIG_DIR/keys"
  cp "$PKI_DIR/ca.crt" "$PKI_DIR/issued/server.crt" "$PKI_DIR/private/server.key" "$PKI_DIR/dh.pem" "$PKI_DIR/ta.key" "$CONFIG_DIR/keys/"
}

# Создание сервиса systemd
create_systemd_service() {
  echo "Создание systemd сервиса..."
  cat > /etc/systemd/system/$VPN_SERVICE_NAME.service <<EOF
[Unit]
Description=OpenVPN GOST Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/openvpn --config $CONFIG_DIR/server-gost.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
}

# Настройка конфигурации сервера
configure_server() {
  echo "Настройка конфигурации сервера..."
  cat > "$CONFIG_DIR/server-gost.conf" <<EOF
port $PORT
proto $PROTO
dev tun
ca $CONFIG_DIR/keys/ca.crt
cert $CONFIG_DIR/keys/server.crt
key $CONFIG_DIR/keys/server.key
dh $CONFIG_DIR/keys/dh.pem
tls-auth $CONFIG_DIR/keys/ta.key 0
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
management $MANAGEMENT_PORT 127.0.0.1
explicit-exit-notify 1
EOF
}

# Настройка сети и фаервола
configure_network() {
  echo "Настройка сетевых параметров..."
  # Включение IP forwarding
  sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p

  # Настройка UFW
  ufw --force reset
  ufw allow "$PORT/$PROTO"
  ufw allow OpenSSH
  ufw --force enable
}

# Основная установка
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

  install_packages
  build_gost_engine
  setup_easyrsa
  generate_certificates
  configure_server
  configure_network
  create_systemd_service

  systemctl start $VPN_SERVICE_NAME
  systemctl enable $VPN_SERVICE_NAME

  echo "OpenVPN успешно установлен и запущен на порту $PORT/$PROTO"
}

# Создание клиента
create_client() {
  if [ -z "$PUBLIC_IP" ] || [ -z "$PORT" ] || [ -z "$PROTO" ]; then
    echo "Сначала нужно установить сервер (пункт 1)"
    return
  fi

  read -p "Введите имя клиента: " USERNAME
  
  cd "$EASY_RSA_DIR" || exit 1
  
  ./easyrsa gen-req "$USERNAME" nopass
  ./easyrsa sign-req client "$USERNAME"

  # Создаем клиентский конфиг
  cat > "$CONFIG_DIR/keys/${USERNAME}.ovpn" <<EOF
client
dev tun
proto $PROTO
remote $PUBLIC_IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher GOST28147-TC26
auth GOST28147-TC26
verb 3
<ca>
$(cat "$CONFIG_DIR/keys/ca.crt")
</ca>
<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' "$PKI_DIR/issued/${USERNAME}.crt")
</cert>
<key>
$(cat "$PKI_DIR/private/${USERNAME}.key")
</key>
<tls-auth>
$(cat "$CONFIG_DIR/keys/ta.key")
</tls-auth>
key-direction 1
EOF

  echo "Клиентский конфиг создан: $CONFIG_DIR/keys/${USERNAME}.ovpn"
}

# Показать подключения
show_connections() {
  if [ -S "$MANAGEMENT_SOCKET" ]; then
    echo "Подключенные клиенты:"
    { echo "status"; sleep 1; } | nc -U "$MANAGEMENT_SOCKET" | grep "^CLIENT_LIST" || echo "Нет активных подключений"
  else
    echo "Сокет управления не активен. Запустите сервер OpenVPN."
  fi
}

# Отключить клиента
disconnect_client() {
  show_connections
  read -p "Введите имя клиента для отключения: " CLIENT
  if [ -S "$MANAGEMENT_SOCKET" ]; then
    { echo "kill $CLIENT"; sleep 1; } | nc -U "$MANAGEMENT_SOCKET"
    echo "Клиент $CLIENT отключен"
  else
    echo "Сокет управления не активен"
  fi
}

# Блокировка клиента
ban_client() {
  show_connections
  read -p "Введите имя клиента для блокировки: " CLIENT
  
  cd "$EASY_RSA_DIR" || exit 1
  
  ./easyrsa revoke "$CLIENT"
  ./easyrsa gen-crl
  cp "$PKI_DIR/crl.pem" "$CONFIG_DIR/keys/"
  
  # Добавляем проверку CRL в конфиг сервера
  if ! grep -q "crl-verify" "$CONFIG_DIR/server-gost.conf"; then
    echo "crl-verify $CONFIG_DIR/keys/crl.pem" >> "$CONFIG_DIR/server-gost.conf"
    systemctl restart $VPN_SERVICE_NAME
  fi
  
  echo "Клиент $CLIENT заблокирован"
}

# Управление сервисом
service_management() {
  echo "1) Запустить сервис"
  echo "2) Остановить сервис"
  echo "3) Перезапустить сервис"
  echo "4) Показать статус"
  read -p "Выберите действие: " CHOICE
  
  case $CHOICE in
    1) systemctl start $VPN_SERVICE_NAME ;;
    2) systemctl stop $VPN_SERVICE_NAME ;;
    3) systemctl restart $VPN_SERVICE_NAME ;;
    4) systemctl status $VPN_SERVICE_NAME ;;
    *) echo "Неверный выбор" ;;
  esac
}

# Главное меню
main_menu() {
  while true; do
    clear
    echo "=== Управление OpenVPN с ГОСТ ==="
    echo "1) Установить и настроить OpenVPN"
    echo "2) Создать клиентский конфиг"
    echo "3) Показать активные подключения"
    echo "4) Отключить клиента"
    echo "5) Заблокировать клиента"
    echo "6) Управление сервисом"
    echo "7) Выход"
    read -p "Выберите действие: " CHOICE
    
    case $CHOICE in
      1) install_openvpn ;;
      2) create_client ;;
      3) show_connections ;;
      4) disconnect_client ;;
      5) ban_client ;;
      6) service_management ;;
      7) exit 0 ;;
      *) echo "Неверный выбор";;
    esac
    
    read -p "Нажмите Enter для продолжения..."
  done
}

# Запуск
main_menu
