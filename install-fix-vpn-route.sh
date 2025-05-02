#!/usr/bin/env bash
set -e

# Проверка на запуск от root
if [[ $EUID -ne 0 ]]; then
  echo "Этот скрипт нужно запускать от root или через sudo"
  exit 1
fi

echo "=== Установка проекта fix-vpn-route ==="

# 1. Конфиг /etc/default/fix-vpn-route
cat > /etc/default/fix-vpn-route <<'EOF'
# Если YES — скрипт сам найдёт интернет-интерфейс (eth0, wlan0, usb…)
AUTO_DETECT_INTERFACE="yes"
# VPN_SERVER_IP="auto" — берётся из текущей таблицы маршрутов
VPN_SERVER_IP="auto"
EOF
echo "[1/5] Конфиг /etc/default/fix-vpn-route создан"

# 2. Скрипт /usr/local/bin/fix-vpn-route.sh
cat > /usr/local/bin/fix-vpn-route.sh <<'EOF'
#!/bin/bash
set -e

CONFIG_FILE="/etc/default/fix-vpn-route"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

logger "[fix-vpn-route] started"

if [[ "$AUTO_DETECT_INTERFACE" == "yes" ]]; then
  INTERNET_IF=$(ip route | awk '/^default/ {print $5; exit}')
else
  logger "[fix-vpn-route] ERROR: AUTO_DETECT_INTERFACE != yes"
  exit 1
fi

INTERNET_GW=$(ip route | awk -v IF="$INTERNET_IF" \
  '/^default/ && $0 ~ IF {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
if [[ -z "$INTERNET_GW" ]]; then
  logger "[fix-vpn-route] WARN: Нет шлюза для $INTERNET_IF — выхожу."
  exit 0
fi

VPN_IF=$(ip route | awk -v IF="$INTERNET_IF" \
  '/^default/ && $0 !~ IF {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [[ -z "$VPN_IF" ]]; then
  logger "[fix-vpn-route] INFO: VPN interface not found — exit."
  exit 0
fi

VPN_GW=$(ip route | awk -v IF="$VPN_IF" \
  '/^default/ && $0 ~ IF {for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
if [[ -z "$VPN_GW" ]]; then
  logger "[fix-vpn-route] WARN: VPN gateway not found — exit."
  exit 0
fi

logger "[fix-vpn-route] internet: $INTERNET_IF → $INTERNET_GW; vpn: $VPN_IF → $VPN_GW"

if [[ "$VPN_SERVER_IP" == "auto" ]]; then
  VPN_SERVER_IP=$(ip route show dev "$INTERNET_IF" | awk '/ via / {print $1; exit}')
  if [[ -z "$VPN_SERVER_IP" ]]; then
    logger "[fix-vpn-route] WARN: Не удалось определить VPN_SERVER_IP — exit."
    exit 0
  fi
  logger "[fix-vpn-route] auto-detected VPN_SERVER_IP: $VPN_SERVER_IP"
fi

if ! ip route | grep -q "^$VPN_SERVER_IP "; then
  logger "[fix-vpn-route] Добавляем маршрут до $VPN_SERVER_IP через $INTERNET_GW dev $INTERNET_IF"
  ip route add "$VPN_SERVER_IP" via "$INTERNET_GW" dev "$INTERNET_IF"
else
  logger "[fix-vpn-route] маршрут до $VPN_SERVER_IP уже существует"
fi

if ! ip route | grep -q "^default via $VPN_GW dev $VPN_IF"; then
  logger "[fix-vpn-route] Устанавливаем default route через $VPN_IF"
  ip route del default 2>/dev/null || true
  ip route add default via "$VPN_GW" dev "$VPN_IF" metric 10
else
  logger "[fix-vpn-route] default маршрут уже правильный"
fi

logger "[fix-vpn-route] done"
EOF

chmod +x /usr/local/bin/fix-vpn-route.sh
echo "[2/5] Скрипт создан и стал исполняемым"

# 3. Systemd-сервис
cat > /etc/systemd/system/fix-vpn-route.service <<'EOF'
[Unit]
Description=Fix VPN Routing Table
Wants=network-online.target NetworkManager-wait-online.service
After=network-online.target NetworkManager-wait-online.service
Requires=NetworkManager-wait-online.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fix-vpn-route.sh
SuccessExitStatus=1
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fix-vpn-route.service
systemctl restart fix-vpn-route.service
echo "[3/5] Systemd-сервис создан, включён и запущен"

# 4. NetworkManager-хук
mkdir -p /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/99-fix-vpn-route <<'EOF'
#!/bin/bash
IFACE="$1"
STATUS="$2"
if [[ "$STATUS" == "up" || "$STATUS" == "vpn-up" ]]; then
  /usr/local/bin/fix-vpn-route.sh
fi
EOF
chmod +x /etc/NetworkManager/dispatcher.d/99-fix-vpn-route
echo "[4/5] NM-хук создан и стал исполняемым"

# 5. Systemd-хук на выход из сна
cat > /usr/lib/systemd/system-sleep/fix-vpn-route <<'EOF'
#!/bin/bash
case "$1" in
  post)
    /usr/local/bin/fix-vpn-route.sh
    ;;
esac
EOF
chmod +x /usr/lib/systemd/system-sleep/fix-vpn-route
echo "[5/5] Systemd-хук на выход из сна установлен"

echo "=== Установка завершена! ==="
echo "Проверьте логи: journalctl -u fix-vpn-route.service"
