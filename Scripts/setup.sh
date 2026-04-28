#!/bin/bash
# VLESS + Reality VPN Setup Script
# Tested on Ubuntu 20.04/22.04/24.04

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[x]${NC} $1"; exit 1; }
header() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# ── root check ──────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run as root: sudo bash $0"

# ── config ───────────────────────────────────────────────────────────────────
PORT=${PORT:-443}
SNI=${SNI:-"www.microsoft.com"}
FINGERPRINT=${FINGERPRINT:-"chrome"}
PROFILE_TITLE="Simple VPN"         # название профиля/подписки в приложении
LOCATION_ICON=${LOCATION_ICON:-"🇩🇪"}  # иконка локации в приложении
LOCATION_NAME=${LOCATION_NAME:-"Германия"} # имя локации в приложении
SERVER_LABEL=""                    # полное имя сервера (иконка + локация)
SUB_PORT=${SUB_PORT:-8080}          # порт HTTP-сервера подписки
CONFIG_DIR="/usr/local/etc/xray"
LOG_DIR="/var/log/xray"
SUB_DIR="/var/www/sub"

header "VLESS + Reality Installer"

# ── location label ───────────────────────────────────────────────────────────
echo "Example: use de / Germany, us / USA, jp / Japan, or any custom values."
read -rp "Location icon [${LOCATION_ICON}]: " input_icon
[[ -n "$input_icon" ]] && LOCATION_ICON="$input_icon"

read -rp "Location name [${LOCATION_NAME}]: " input_location
[[ -n "$input_location" ]] && LOCATION_NAME="$input_location"

SERVER_LABEL="${LOCATION_ICON} ${LOCATION_NAME}"
log "Server label: $SERVER_LABEL"

# ── detect server IP ─────────────────────────────────────────────────────────
SERVER_IP=$(curl -s4 https://api.ipify.org 2>/dev/null \
         || curl -s4 https://ifconfig.me 2>/dev/null \
         || ip route get 1.1.1.1 | awk '{print $7; exit}')
[[ -z "$SERVER_IP" ]] && error "Cannot determine public IP"
log "Server IP: $SERVER_IP"

# ── system update & deps ─────────────────────────────────────────────────────
header "System Preparation"
apt-get update -qq
apt-get install -y -qq curl wget unzip uuid-runtime openssl python3 nginx

# ── install xray-core ────────────────────────────────────────────────────────
header "Installing Xray-core"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
XRAY_BIN=$(which xray 2>/dev/null || echo /usr/local/bin/xray)
[[ ! -x "$XRAY_BIN" ]] && error "Xray binary not found after install"
log "Xray version: $($XRAY_BIN version | head -1)"

# ── generate keys & IDs ──────────────────────────────────────────────────────
header "Generating Keys"
mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$SUB_DIR"

UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
log "UUID: $UUID"

KEYS=$($XRAY_BIN x25519)
# xray ≥26.x: "PrivateKey: ..." / "Password (PublicKey): ..."
# xray <26.x:  "Private key: ..." / "Public key: ..."
PRIVATE_KEY=$(echo "$KEYS" | grep -i 'privatekey'  | awk '{print $NF}')
PUBLIC_KEY=$(echo  "$KEYS" | grep -i 'publickey\|Password' | awk '{print $NF}')
log "Public key generated"

SHORT_ID=$(openssl rand -hex 8)
log "Short ID: $SHORT_ID"

# ── write xray config ────────────────────────────────────────────────────────
header "Writing Xray Config"
cat > "$CONFIG_DIR/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "$LOG_DIR/access.log",
    "error":  "$LOG_DIR/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http","tls","quic"]
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"],              "outboundTag": "block"},
      {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"}
    ]
  }
}
EOF
log "Config written to $CONFIG_DIR/config.json"

# ── build VLESS link ─────────────────────────────────────────────────────────
# Фрагмент после # — имя сервера (локации), которое видно в списке серверов
SERVER_LABEL_ENC=$(python3 - "$SERVER_LABEL" <<'PYEOF'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1]))
PYEOF
)
VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=${FINGERPRINT}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${SERVER_LABEL_ENC}"

# ── subscription file ─────────────────────────────────────────────────────────
# base64-кодируем ссылку — стандартный формат подписки
VLESS_B64=$(echo -n "$VLESS_LINK" | base64 -w 0)
echo "$VLESS_B64" > "$SUB_DIR/sub.txt"
chmod 644 "$SUB_DIR/sub.txt"
log "Subscription file written"

# ── nginx для раздачи подписки ────────────────────────────────────────────────
header "Setting up subscription server"

# Кодируем название профиля для заголовка
PROFILE_TITLE_ENC=$(python3 - "$PROFILE_TITLE" <<'PYEOF'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1]))
PYEOF
)

cat > /etc/nginx/sites-available/sub <<NGINX
server {
    listen ${SUB_PORT};
    server_name _;

    location /sub {
        alias ${SUB_DIR}/sub.txt;
        default_type text/plain;

        # Эти заголовки читают Hiddify, Clash Meta, NekoBox и др.
        # profile-title  → название профиля ("Simple VPN")
        # content-disposition → имя файла (тоже подхватывают некоторые клиенты)
        add_header profile-title          "${PROFILE_TITLE_ENC}";
        add_header profile-update-interval "1";
        add_header subscription-userinfo  "upload=0; download=0; total=107374182400; expire=0";
        add_header content-disposition    "attachment; filename=\"${PROFILE_TITLE}.txt\"";
        add_header Cache-Control          "no-cache";
    }
}
NGINX

ln -sf /etc/nginx/sites-available/sub /etc/nginx/sites-enabled/sub
nginx -t -q && systemctl restart nginx
log "Nginx subscription server started on port $SUB_PORT"

# ── firewall ─────────────────────────────────────────────────────────────────
header "Firewall"
open_port() {
    local p=$1 proto=${2:-tcp}
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$p/$proto" >/dev/null
        log "ufw: allowed $p/$proto"
    elif command -v iptables &>/dev/null; then
        iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT 2>/dev/null \
          || iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT
        log "iptables: allowed $p/$proto"
    fi
}
open_port "$PORT"
open_port "$SUB_PORT"

# ── enable & start xray ───────────────────────────────────────────────────────
header "Starting Xray"
systemctl enable xray >/dev/null 2>&1
systemctl restart xray
sleep 2
systemctl is-active --quiet xray \
  && log "Xray is running" \
  || error "Xray failed to start. Check: journalctl -u xray -n 30"

# ── save credentials ─────────────────────────────────────────────────────────
SUB_URL="http://${SERVER_IP}:${SUB_PORT}/sub"
CREDS_FILE="$CONFIG_DIR/client-credentials.txt"
cat > "$CREDS_FILE" <<EOF
========================================
  VLESS + Reality — Client Credentials
========================================
Profile name : ${PROFILE_TITLE}
Server label : ${SERVER_LABEL}
Server IP    : $SERVER_IP
Port         : $PORT
UUID         : $UUID
Public Key   : $PUBLIC_KEY
Short ID     : $SHORT_ID
SNI          : $SNI
Fingerprint  : $FINGERPRINT
Flow         : xtls-rprx-vision

Subscription URL (рекомендуется):
$SUB_URL

VLESS Link (ручной импорт):
$VLESS_LINK
========================================
EOF
chmod 600 "$CREDS_FILE"

# ── print result ─────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║              Setup Complete                              ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}Профиль:${NC}  ${PROFILE_TITLE}"
echo -e "${GREEN}Сервер:${NC}   ${SERVER_LABEL}  (${SERVER_IP}:${PORT})"
echo ""
echo -e "${YELLOW}── Способ 1: URL подписки (лучший вариант) ──${NC}"
echo -e "Добавь в приложение как подписку (subscription):"
echo ""
echo "  $SUB_URL"
echo ""
echo -e "  Название профиля «${PROFILE_TITLE}» подхватится автоматически."
echo -e "  Сервер будет называться «${SERVER_LABEL}»."
echo ""
echo -e "${YELLOW}── Способ 2: VLESS ссылка (ручной импорт) ──${NC}"
echo "$VLESS_LINK"
echo ""

# QR — подписка удобнее для сканирования
if command -v qrencode &>/dev/null || apt-get install -y -qq qrencode 2>/dev/null; then
    echo -e "${CYAN}QR-код URL подписки:${NC}"
    qrencode -t ANSIUTF8 "$SUB_URL"
fi

echo ""
echo -e "${GREEN}Файл с данными:${NC} $CREDS_FILE"
echo -e "${GREEN}Xray статус:${NC}    systemctl status xray"
echo -e "${GREEN}Xray логи:${NC}      journalctl -u xray -f"
echo ""
warn "Клиенты с поддержкой названия профиля через подписку:"
echo "  Android : Hiddify, v2rayNG"
echo "  iOS     : Hiddify, Streisand"
echo "  Windows : Hiddify, v2rayN"
echo "  macOS   : Hiddify, FoXray"
echo "  Linux   : Hiddify, v2rayA"
