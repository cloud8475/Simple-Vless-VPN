#!/bin/bash
# manage.sh — интерактивное управление VLESS + Reality VPN

# ── цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ── пути ─────────────────────────────────────────────────────────────────────
CONFIG_FILE="/usr/local/etc/xray/config.json"
CREDS_FILE="/usr/local/etc/xray/client-credentials.txt"
ACCESS_LOG="/var/log/xray/access.log"
ERROR_LOG="/var/log/xray/error.log"
SUB_FILE="/var/www/sub/sub.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}[x]${NC} Нужен root: sudo bash $0"; exit 1; }

# ── helpers ───────────────────────────────────────────────────────────────────
press_enter() { echo; read -rp "$(echo -e "${DIM}Нажми Enter чтобы вернуться...${NC}")"; }

get_server_label() {
    if [[ -f "$CREDS_FILE" ]]; then
        awk -F': ' '/^Server label[[:space:]]*:/ {print $2; exit}' "$CREDS_FILE"
    fi
}

status_badge() {
    if systemctl is-active --quiet xray; then
        echo -e "${GREEN}● работает${NC}"
    else
        echo -e "${RED}● остановлен${NC}"
    fi
}

nginx_badge() {
    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}● работает${NC}"
    else
        echo -e "${RED}● остановлен${NC}"
    fi
}

draw_header() {
    clear
    local xray_status nginx_status uptime_str ip port
    xray_status=$(status_badge)
    nginx_status=$(nginx_badge)
    uptime_str=$(uptime -p 2>/dev/null | sed 's/up //' || echo "—")
    ip=$(curl -s4 https://api.ipify.org 2>/dev/null || echo "—")
    port=$(grep -o '"port": [0-9]*' "$CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $2}' || echo "—")

    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}          ${BOLD}Vless VPN — Панель управления${NC}               ${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    printf "${CYAN}║${NC}  Xray:    %-20s  Uptime: %-14s ${CYAN}║${NC}\n" "$xray_status" "$uptime_str"
    printf "${CYAN}║${NC}  Nginx:   %-20s  IP:     %-14s ${CYAN}║${NC}\n" "$nginx_status" "$ip"
    printf "${CYAN}║${NC}  Порт:    %-47s ${CYAN}║${NC}\n" "$port"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo
}

# ── действия ─────────────────────────────────────────────────────────────────

do_start() {
    draw_header
    echo -e "${BOLD}▶  Запуск сервисов${NC}\n"
    systemctl start xray  && echo -e "  Xray:  ${GREEN}запущен${NC}"  || echo -e "  Xray:  ${RED}ошибка${NC}"
    systemctl start nginx && echo -e "  Nginx: ${GREEN}запущен${NC}" || echo -e "  Nginx: ${RED}ошибка${NC}"
    press_enter
}

do_stop() {
    draw_header
    echo -e "${BOLD}⏹  Остановка сервисов${NC}\n"
    systemctl stop xray  && echo -e "  Xray:  ${YELLOW}остановлен${NC}"  || echo -e "  Xray:  ${RED}ошибка${NC}"
    systemctl stop nginx && echo -e "  Nginx: ${YELLOW}остановлен${NC}" || echo -e "  Nginx: ${RED}ошибка${NC}"
    press_enter
}

do_restart() {
    draw_header
    echo -e "${BOLD}↺  Перезапуск сервисов${NC}\n"
    systemctl restart xray  && echo -e "  Xray:  ${GREEN}перезапущен${NC}"  || echo -e "  Xray:  ${RED}ошибка${NC}"
    systemctl restart nginx && echo -e "  Nginx: ${GREEN}перезапущен${NC}" || echo -e "  Nginx: ${RED}ошибка${NC}"
    press_enter
}

do_status() {
    draw_header
    echo -e "${BOLD}ℹ  Статус сервисов${NC}\n"
    systemctl status xray  --no-pager -l | head -20
    echo
    systemctl status nginx --no-pager -l | head -10
    echo
    echo -e "${BOLD}Открытые порты:${NC}"
    ss -tlnp | grep -E 'xray|nginx' | awk '{print "  " $1 "  " $4}'
    echo
    echo -e "${BOLD}Активные подключения к Xray:${NC}"
    ss -tnp | grep xray | wc -l | xargs -I{} echo "  {} подключений"
    press_enter
}

do_logs_live() {
    draw_header
    echo -e "${BOLD}📋  Логи в реальном времени${NC}  ${DIM}(Ctrl+C чтобы выйти)${NC}\n"
    echo -e "  ${CYAN}1${NC}  Access log (подключения)"
    echo -e "  ${CYAN}2${NC}  Error log (ошибки)"
    echo -e "  ${CYAN}3${NC}  systemd journal (всё)"
    echo
    read -rp "Выбери [1-3]: " log_choice
    echo
    case $log_choice in
        1) [[ -f "$ACCESS_LOG" ]] && tail -f "$ACCESS_LOG" || echo -e "${RED}Файл не найден: $ACCESS_LOG${NC}" ;;
        2) [[ -f "$ERROR_LOG"  ]] && tail -f "$ERROR_LOG"  || echo -e "${RED}Файл не найден: $ERROR_LOG${NC}" ;;
        3) journalctl -u xray -f --no-pager ;;
        *) echo -e "${RED}Неверный выбор${NC}" ;;
    esac
    press_enter
}

do_logs_show() {
    draw_header
    echo -e "${BOLD}📋  Просмотр логов${NC}\n"
    echo -e "  ${CYAN}1${NC}  Последние 50 строк access.log"
    echo -e "  ${CYAN}2${NC}  Последние 50 строк error.log"
    echo -e "  ${CYAN}3${NC}  Последние 100 строк journal"
    echo -e "  ${CYAN}4${NC}  Поиск по access.log"
    echo
    read -rp "Выбери [1-4]: " log_choice
    echo
    case $log_choice in
        1) [[ -f "$ACCESS_LOG" ]] && tail -50 "$ACCESS_LOG" | less -R || echo "Файл не найден" ;;
        2) [[ -f "$ERROR_LOG"  ]] && tail -50 "$ERROR_LOG"  | less -R || echo "Файл не найден" ;;
        3) journalctl -u xray -n 100 --no-pager | less -R ;;
        4)
            read -rp "Поисковый запрос: " query
            echo
            [[ -f "$ACCESS_LOG" ]] && grep --color=always "$query" "$ACCESS_LOG" | tail -50 | less -R \
                || echo "Файл не найден"
            ;;
        *) echo -e "${RED}Неверный выбор${NC}" ;;
    esac
    press_enter
}

do_logs_download() {
    draw_header
    echo -e "${BOLD}💾  Скачать логи${NC}\n"

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local archive="vpn_logs_${timestamp}.tar.gz"
    local tmp_dir="/tmp/vpn_logs_${timestamp}"

    mkdir -p "$tmp_dir"

    # Копируем что есть
    [[ -f "$ACCESS_LOG" ]] && cp "$ACCESS_LOG" "$tmp_dir/access.log"
    [[ -f "$ERROR_LOG"  ]] && cp "$ERROR_LOG"  "$tmp_dir/error.log"
    journalctl -u xray --no-pager > "$tmp_dir/journal_xray.log" 2>/dev/null
    journalctl -u nginx --no-pager > "$tmp_dir/journal_nginx.log" 2>/dev/null

    # Системная информация
    {
        echo "=== Дата экспорта: $(date) ==="
        echo "=== Статус Xray ==="
        systemctl status xray --no-pager
        echo ""
        echo "=== Статус Nginx ==="
        systemctl status nginx --no-pager
        echo ""
        echo "=== Открытые порты ==="
        ss -tlnp
        echo ""
        echo "=== Активные соединения ==="
        ss -tnp | grep xray
    } > "$tmp_dir/system_info.txt" 2>&1

    tar -czf "$SCRIPT_DIR/$archive" -C "$tmp_dir" . 2>/dev/null
    rm -rf "$tmp_dir"

    if [[ -f "$SCRIPT_DIR/$archive" ]]; then
        local size
        size=$(du -h "$SCRIPT_DIR/$archive" | cut -f1)
        echo -e "  ${GREEN}✓${NC} Архив создан: ${BOLD}$SCRIPT_DIR/$archive${NC}"
        echo -e "  ${GREEN}✓${NC} Размер: $size"
        echo
        echo -e "  ${DIM}Содержимое архива:${NC}"
        echo -e "    access.log, error.log, journal_xray.log, journal_nginx.log, system_info.txt"
    else
        echo -e "  ${RED}✗${NC} Ошибка при создании архива"
    fi
    press_enter
}

do_show_link() {
    draw_header
    echo -e "${BOLD}🔗  Данные подключения${NC}\n"
    if [[ -f "$CREDS_FILE" ]]; then
        cat "$CREDS_FILE"
    else
        echo -e "  ${RED}Файл $CREDS_FILE не найден${NC}"
        echo -e "  Запусти setup заново"
    fi
    echo
    if command -v qrencode &>/dev/null && [[ -f "$SUB_FILE" ]]; then
        local sub_content
        sub_content=$(cat "$SUB_FILE" | base64 -d 2>/dev/null | head -1)
        [[ -n "$sub_content" ]] && {
            echo -e "${CYAN}QR-код VLESS ссылки:${NC}"
            qrencode -t ANSIUTF8 "$sub_content"
        }
    fi
    press_enter
}

do_add_user() {
    draw_header
    echo -e "${BOLD}👤  Добавить пользователя${NC}\n"
    read -rp "  Имя пользователя (для маркировки): " username
    [[ -z "$username" ]] && { echo -e "${RED}Имя не может быть пустым${NC}"; press_enter; return; }

    local new_uuid
    new_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')

    # Добавляем в конфиг
    if command -v python3 &>/dev/null; then
        python3 - "$CONFIG_FILE" "$new_uuid" "$username" <<'PYEOF'
import json, sys

config_path, new_uuid, username = sys.argv[1], sys.argv[2], sys.argv[3]

with open(config_path, 'r') as f:
    config = json.load(f)

new_client = {"id": new_uuid, "flow": "xtls-rprx-vision", "email": username}
config['inbounds'][0]['settings']['clients'].append(new_client)

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)

print("OK")
PYEOF
        if [[ $? -eq 0 ]]; then
            systemctl restart xray

            # Читаем параметры из существующего конфига
            local pubkey shortid sni port ip
            pubkey=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['streamSettings']['realitySettings'].get('publicKey',''))" 2>/dev/null)
            shortid=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['streamSettings']['realitySettings']['shortIds'][0])" 2>/dev/null)
            sni=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['streamSettings']['realitySettings']['serverNames'][0])" 2>/dev/null)
            port=$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['inbounds'][0]['port'])" 2>/dev/null)
            ip=$(curl -s4 https://api.ipify.org 2>/dev/null)

            local server_label label_enc
            server_label=$(get_server_label)
            [[ -z "$server_label" ]] && server_label="Simple VPN"
            label_enc=$(python3 - "$server_label" <<'PYEOF'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1]))
PYEOF
)
            local link="vless://${new_uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp&headerType=none#${label_enc}"

            echo -e "\n  ${GREEN}✓${NC} Пользователь добавлен: ${BOLD}$username${NC}"
            echo -e "  UUID: $new_uuid\n"
            echo -e "${YELLOW}VLESS ссылка:${NC}"
            echo "  $link"
            echo
            if command -v qrencode &>/dev/null; then
                qrencode -t ANSIUTF8 "$link"
            fi
        else
            echo -e "  ${RED}✗${NC} Ошибка при изменении конфига"
        fi
    else
        echo -e "  ${RED}✗${NC} python3 не найден, установи: apt install python3"
    fi
    press_enter
}

do_list_users() {
    draw_header
    echo -e "${BOLD}👥  Список пользователей${NC}\n"
    if command -v python3 &>/dev/null && [[ -f "$CONFIG_FILE" ]]; then
        python3 - "$CONFIG_FILE" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    config = json.load(f)

clients = config['inbounds'][0]['settings']['clients']
print(f"  Всего пользователей: {len(clients)}\n")
for i, c in enumerate(clients, 1):
    email = c.get('email', '—')
    uid   = c.get('id', '—')
    print(f"  {i}. {email}")
    print(f"     UUID: {uid}\n")
PYEOF
    else
        echo -e "  ${RED}Не удалось прочитать конфиг${NC}"
    fi
    press_enter
}

do_remove_user() {
    draw_header
    echo -e "${BOLD}🗑  Удалить пользователя${NC}\n"
    if ! command -v python3 &>/dev/null; then
        echo -e "  ${RED}✗${NC} python3 не найден"; press_enter; return
    fi

    # Показываем список
    python3 - "$CONFIG_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    config = json.load(f)
clients = config['inbounds'][0]['settings']['clients']
for i, c in enumerate(clients, 1):
    print(f"  {i}. {c.get('email','—')}  ({c['id']})")
PYEOF

    echo
    read -rp "  Введи номер пользователя для удаления (0 — отмена): " num
    [[ "$num" == "0" || -z "$num" ]] && return

    python3 - "$CONFIG_FILE" "$num" <<'PYEOF'
import json, sys
path, idx = sys.argv[1], int(sys.argv[2]) - 1
with open(path) as f:
    config = json.load(f)
clients = config['inbounds'][0]['settings']['clients']
if idx < 0 or idx >= len(clients):
    print("Неверный номер"); sys.exit(1)
removed = clients.pop(idx)
with open(path, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
print(f"Удалён: {removed.get('email','—')} ({removed['id']})")
PYEOF

    [[ $? -eq 0 ]] && systemctl restart xray && echo -e "  ${GREEN}✓${NC} Xray перезапущен"
    press_enter
}

do_update_xray() {
    draw_header
    echo -e "${BOLD}⬆  Обновление Xray-core${NC}\n"
    echo -e "  ${DIM}Текущая версия: $(xray version 2>/dev/null | head -1 || echo '—')${NC}\n"
    read -rp "  Продолжить обновление? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    echo
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl restart xray
    echo
    echo -e "  ${GREEN}✓${NC} Новая версия: $(xray version 2>/dev/null | head -1)"
    press_enter
}

do_traffic() {
    draw_header
    echo -e "${BOLD}📊  Статистика трафика${NC}  ${DIM}(Ctrl+C чтобы выйти)${NC}\n"
    echo -e "  ${DIM}Мониторинг интерфейса каждые 2 секунды:${NC}\n"
    # Определяем основной интерфейс
    local iface
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$iface" ]] && iface="eth0"
    echo -e "  Интерфейс: ${CYAN}$iface${NC}\n"

    local rx_prev tx_prev
    rx_prev=$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
    tx_prev=$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)

    while true; do
        sleep 2
        local rx_curr tx_curr rx_speed tx_speed conn
        rx_curr=$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
        tx_curr=$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)
        rx_speed=$(( (rx_curr - rx_prev) / 2 / 1024 ))
        tx_speed=$(( (tx_curr - tx_prev) / 2 / 1024 ))
        conn=$(ss -tnp | grep -c xray 2>/dev/null || echo 0)
        printf "\r  ↓ %-6s KB/s   ↑ %-6s KB/s   Соединений: %-4s   %s" \
            "$rx_speed" "$tx_speed" "$conn" "$(date +%H:%M:%S)"
        rx_prev=$rx_curr
        tx_prev=$tx_curr
    done
}

do_backup_config() {
    draw_header
    echo -e "${BOLD}💾  Резервная копия конфига${NC}\n"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup="$SCRIPT_DIR/xray_config_backup_${timestamp}.json"
    if [[ -f "$CONFIG_FILE" ]]; then
        cp "$CONFIG_FILE" "$backup"
        echo -e "  ${GREEN}✓${NC} Конфиг сохранён: ${BOLD}$backup${NC}"
        [[ -f "$CREDS_FILE" ]] && {
            cp "$CREDS_FILE" "$SCRIPT_DIR/credentials_backup_${timestamp}.txt"
            echo -e "  ${GREEN}✓${NC} Credentials: ${BOLD}$SCRIPT_DIR/credentials_backup_${timestamp}.txt${NC}"
        }
    else
        echo -e "  ${RED}✗${NC} Файл конфига не найден: $CONFIG_FILE"
    fi
    press_enter
}

# ── главное меню ──────────────────────────────────────────────────────────────

main_menu() {
    while true; do
        draw_header
        echo -e "  ${BOLD}Управление сервисом${NC}"
        echo -e "  ${CYAN}1${NC}  Запустить"
        echo -e "  ${CYAN}2${NC}  Остановить"
        echo -e "  ${CYAN}3${NC}  Перезапустить"
        echo -e "  ${CYAN}4${NC}  Статус"
        echo
        echo -e "  ${BOLD}Логи${NC}"
        echo -e "  ${CYAN}5${NC}  Логи в реальном времени"
        echo -e "  ${CYAN}6${NC}  Просмотр логов"
        echo -e "  ${CYAN}7${NC}  Скачать логи (архив)"
        echo
        echo -e "  ${BOLD}Пользователи${NC}"
        echo -e "  ${CYAN}8${NC}  Показать ссылку / QR-код"
        echo -e "  ${CYAN}9${NC}  Список пользователей"
        echo -e "  ${CYAN}10${NC} Добавить пользователя"
        echo -e "  ${CYAN}11${NC} Удалить пользователя"
        echo
        echo -e "  ${BOLD}Система${NC}"
        echo -e "  ${CYAN}12${NC} Статистика трафика (live)"
        echo -e "  ${CYAN}13${NC} Резервная копия конфига"
        echo -e "  ${CYAN}14${NC} Обновить Xray-core"
        echo
        echo -e "  ${CYAN}0${NC}  Выход"
        echo
        read -rp "$(echo -e "  ${BOLD}Выбери действие:${NC} ")" choice

        case $choice in
            1)  do_start ;;
            2)  do_stop ;;
            3)  do_restart ;;
            4)  do_status ;;
            5)  do_logs_live ;;
            6)  do_logs_show ;;
            7)  do_logs_download ;;
            8)  do_show_link ;;
            9)  do_list_users ;;
            10) do_add_user ;;
            11) do_remove_user ;;
            12) do_traffic ;;
            13) do_backup_config ;;
            14) do_update_xray ;;
            0)  echo -e "\n  ${DIM}Пока.${NC}\n"; exit 0 ;;
            *)  echo -e "\n  ${RED}Неверный выбор${NC}"; sleep 1 ;;
        esac
    done
}

main_menu
