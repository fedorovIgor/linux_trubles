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
# Если YES — скрипт сам найдёт активный интернет-интерфейс (eth0, wlan0, usb…)
AUTO_DETECT_INTERFACE="yes"
# VPN_SERVER_IP="auto" — автоматически забирается из текущей таблицы маршрутов
VPN_SERVER_IP="auto"
EOF
echo "[1/4] Конфиг /etc/default/fix-vpn-route создан"

# 2. Скрипт /usr/local/bin/fix-vpn-route.sh
cat > /usr/local/bin/fix-vpn-route.sh <<'EOF'
#!/bin/bash
set -e

source /etc/default/fix-vpn-route
logger "[fix-vpn-route] started"

# 1) определяем активный интернет-интерфейс
if [[ "\$AUTO_DETECT_INTERFACE" == "yes" ]]; then
  INTERNET_IF=\$(ip route | awk '/^default/ {print \$5; exit}')
else
  logger "[fix-vpn-route] ERROR: AUTO_DETECT_INTERFACE!=yes, нужен заданный IF"
  exit 0
fi

# 2) получаем его шлюз
INTERNET_GW=\$(ip route | awk -v IF="\$INTERNET_IF" \
  '/^default/ && \$0 ~ IF {for(i=1;i<=NF;i++) if(\$i=="via"){print \$(i+1); exit}}')
if [[ -z "\$INTERNET_GW" ]]; then
  logger "[fix-vpn-route] WARN: Нет шлюза для \$INTERNET_IF — выхожу."
  exit 0
fi

# 3) ищем VPN-интерфейс (любой default не через INTERNET_IF)
VPN_IF=\$(ip route | awk -v IF="\$INTERNET_IF" \
  '/^default/ && \$0 !~ IF {for(i=1;i<=NF;i++) if(\$i=="dev"){print \$(i+1); exit}}')
if [[ -z "\$VPN_IF" ]]; then
  logger "[fix-vpn-route] INFO: VPN interface not found (yet) — exiting."
  exit 0
fi

# 4) получаем gateway для VPN_IF
VPN_GW=\$(ip route | awk -v IF="\$VPN_IF" \
  '/^default/ && \$0 ~ IF {for(i=1;i<=NF;i++) if(\$i=="via"){print \$(i+1); exit}}')
if [[ -z "\$VPN_GW" ]]; then
  logger "[fix-vpn-route] WARN: VPN gateway not found for \$VPN_IF — exiting."
  exit 0
fi

logger "[fix-vpn-route] internet: \$INTERNET_IF → \$INTERNET_GW; vpn: \$VPN_IF → \$VPN_GW"

# 5) определяем VPN_SERVER_IP, если auto
if [[ "\$VPN_SERVER_IP" == "auto" ]]; then
  VPN_SERVER_IP=\$(ip route show dev "\$INTERNET_IF" | awk '/ via / {print \$1; exit}')
  if [[ -z "\$VPN_SERVER_IP" ]]; then
    logger "[fix-vpn-route] WARN: Cannot auto-detect VPN_SERVER_IP — exiting."
    exit 0
  fi
  logger "[fix-vpn-route] auto-detected VPN_SERVER_IP: \$VPN_SERVER_IP"
fi

# 6) создаём маршрут к VPN-серверу через INTERNET_IF
if ! ip route | grep -q "^\$VPN_SERVER_IP "; then
  logger "[fix-vpn-route] adding route to \$VPN_SERVER_IP via \$INTERNET_GW dev \$INTERNET_IF"
  ip route add "\$VPN_SERVER_IP" via "\$INTERNET_GW" dev "\$INTERNET_IF"
else
  logger "[fix-vpn-route] route to \$VPN_SERVER_IP exists"
fi

# 7) правим default маршрут через VPN_IF
if ! ip route | grep -q "^default via \$VPN_GW dev \$VPN_IF"; then
  logger "[fix-vpn-route] fixing default route via \$VPN_IF"
  ip route del default   2>/dev/null || true
  ip route add default via "\$VPN_GW" dev "\$VPN_IF" metric 10
else
  logger "[fix-vpn-route] default route OK"
fi

logger "[fix-vpn-route] done"
EOF
chmod +x /usr/local/bin/fix-vpn-route.sh
echo "[2/4] Скрипт /usr/local/bin/fix-vpn-route.sh создан и стал исполняемым"

# 3. Systemd-сервис
cat > /etc/systemd/system/fix-vpn-route.service <<'EOF'
[Unit]
Description=Fix VPN Routing Table
After=network-online.target
Wants=network-online.target

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
echo "[3/4] Systemd-сервис создан, включён и запущен"

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
echo "[4/4] NM-hook создан и стал исполняемым"

echo "=== Установка завершена! ==="
echo "Проверьте логи: journalctl -u fix-vpn-route.service"
