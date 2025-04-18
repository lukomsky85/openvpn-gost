#!/bin/bash

# Полный скрипт установки OpenVPN с российской криптографией ГОСТ
# Включает все функции: установку, управление пользователями, мониторинг

# Проверка root-прав
if [ "$(id -u)" -ne 0 ]; then
  echo "Этот скрипт должен запускаться с правами root" >&2
  exit 1
fi

# Конфигурационные переменные
CONFIG_DIR="/etc/openvpn"
SERVER_CONF="$CONFIG_DIR/server-gost.conf"
EASY_RSA_DIR="/etc/openvpn/easy-rsa"
CA_DIR="$EASY_RSA_DIR"
KEYS_DIR="$CA_DIR/pki"
MANAGEMENT_SOCKET="/tmp/openvpn-mgmt.sock"
MANAGEMENT_PORT=5555
LOG_FILE="/var/log/openvpn-gost.log"

# Функции управления сервисом
vpn_service() {
  case $1 in
    start) systemctl start openvpn-server@server-gost ;;
    stop) systemctl stop openvpn-server@server-gost ;;
    restart) systemctl restart openvpn-server@server-gost ;;
    status) systemctl status openvpn-server@server-gost ;;
    enable) systemctl enable openvpn-server@server-gost ;;
    disable) systemctl disable openvpn-server@server-gost ;;
    *) echo "Неизвестная команда: $1" ;;
  esac
}

# Функция создания пользователя
create_user() {
  cd $CA_DIR
  echo "Создание пользователя $1"
  
  # Генерация ключей и сертификатов через easyrsa
  ./easyrsa gen-req $1 nopass
  ./easyrsa sign-req client $1
  
  # Создание клиентского конфига
  cat > $KEYS_DIR/issued/"$1".ovpn <<EOF
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
$(cat $KEYS_DIR/ca.crt)
</ca>
<cert>
$(sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' $KEYS_DIR/issued/"$1".crt)
</cert>
<key>
$(cat $KEYS_DIR/private/"$1".key)
</key>
<tls-auth>
$(cat $KEYS_DIR/ta.key)
</tls-auth>
key-direction 1
EOF
  
  echo "Конфиг для $1 создан: $KEYS_DIR/issued/$1.ovpn"
}

# Функция отображения статистики
show_stats() {
  echo "Текущие подключения:"
  echo "status 3" | nc -U $MANAGEMENT_SOCKET | grep "^CLIENT_LIST"
  
  echo -e "\nОбщая статистика:"
  echo "load-stats" | nc -U $MANAGEMENT_SOCKET
  
  echo -e "\nТрафик:"
  echo "bytecount 5" | nc -U $MANAGEMENT_SOCKET
}

# Функция отключения клиента
disconnect_client() {
  echo "Отключаем клиента $1"
  echo "kill $1" | nc -U $MANAGEMENT_SOCKET
}

# Функция бана клиента
ban_client() {
  echo "Блокируем клиента $1"
  echo "kill $1" | nc -U $MANAGEMENT_SOCKET
  ./easyrsa revoke $1
  ./easyrsa gen-crl
  cp pki/crl.pem $CONFIG_DIR/
  echo "crl-verify $CONFIG_DIR/crl.pem" >> $SERVER_CONF
  systemctl restart openvpn-server@server-gost
}

# Установка OpenVPN с GOST
install_openvpn_gost() {
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

  # Установка пакетов
  apt-get update
  apt-get install -y openvpn easy-rsa openssl gost-engine netcat-traditional ufw

  # Настройка EasyRSA
  make-cadir $EASY_RSA_DIR
  cd $EASY_RSA_DIR
  ./easyrsa init-pki

  # Настройка GOST engine
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
CRYPT_PARAMS = id-Gost28147-89-CryptoPro-A-ParamSet
EOF

  export OPENSSL_CONF=/etc/ssl/openssl.cnf

  # Генерация сертификатов
  ./easyrsa build-ca nopass
  ./easyrsa gen-req server nopass
  ./easyrsa sign-req server server
  ./easyrsa gen-dh
  openvpn --genkey --secret $KEYS_DIR/ta.key

  # Конфигурация сервера
  cat > $SERVER_CONF <<EOF
port $PORT
proto $PROTO
dev tun
ca $KEYS_DIR/ca.crt
cert $KEYS_DIR/issued/server.crt
key $KEYS_DIR/private/server.key
dh $KEYS_DIR/dh.pem
tls-auth $KEYS_DIR/ta.key 0
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS $DNS"
ifconfig-pool-persist /var/log/openvpn/ipp.txt
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

  # Настройка сетевых параметров
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  sysctl -p

  # Настройка фаервола
  ufw allow $PORT/$PROTO
  ufw allow OpenSSH
  ufw --force enable

  # Запуск сервиса
  systemctl enable --now openvpn-server@server-gost

  # Создание пользователей
  while true; do
    read -p "Создать пользователя? (y/n): " CREATE_USER
    if [[ "$CREATE_USER" =~ ^[yYдД] ]]; then
      read -p "Введите имя пользователя: " USERNAME
      create_user "$USERNAME"
    else
      break
    fi
  done
}

# Главное меню
main_menu() {
  while true; do
    clear
    echo "OpenVPN GOST Management"
    echo "1. Установить OpenVPN с GOST"
    echo "2. Создать нового пользователя"
    echo "3. Показать статистику подключений"
    echo "4. Отключить клиента"
    echo "5. Заблокировать клиента"
    echo "6. Управление сервисом"
    echo "7. Выход"
    
    read -p "Выберите действие: " CHOICE
    
    case $CHOICE in
      1) install_openvpn_gost ;;
      2) 
        read -p "Введите имя пользователя: " USERNAME
        create_user "$USERNAME"
        ;;
      3) show_stats ;;
      4) 
        read -p "Введите имя клиента для отключения: " CLIENT
        disconnect_client "$CLIENT"
        ;;
      5) 
        read -p "Введите имя клиента для блокировки: " CLIENT
        ban_client "$CLIENT"
        ;;
      6)
        echo "1. Запустить OpenVPN"
        echo "2. Остановить OpenVPN"
        echo "3. Перезапустить OpenVPN"
        echo "4. Статус OpenVPN"
        read -p "Выберите действие: " SERVICE_CHOICE
        
        case $SERVICE_CHOICE in
          1) vpn_service start ;;
          2) vpn_service stop ;;
          3) vpn_service restart ;;
          4) vpn_service status ;;
          *) echo "Неверный выбор" ;;
        esac
        ;;
      7) exit 0 ;;
      *) echo "Неверный выбор" ;;
    esac
    
    read -p "Нажмите Enter для продолжения..."
  done
}

# Запуск главного меню
main_menu
