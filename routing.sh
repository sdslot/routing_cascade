#!/bin/bash

# --- ЦВЕТА ---
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

type_text() {
    local text="$1"
    local delay=0.03
    for (( i=0; i<${#text}; i++ )); do
        echo -n "${text:$i:1}"
        sleep $delay
    done
    echo ""
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERROR] Запустите скрипт с правами root!${NC}"
        exit 1
    fi
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# --- ПОДГОТОВКА СИСТЕМЫ ---
prepare_system() {
    # Включение IP Forwarding
    if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    else
        sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    fi

    # Активация Google BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null

    # Установка зависимостей
    export DEBIAN_FRONTEND=noninteractive
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        apt-get update -y > /dev/null
        apt-get install -y iptables-persistent netfilter-persistent > /dev/null
    fi
}

# --- ИНСТРУКЦИЯ (ТЕКСТ ВНУТРИ КОДА) ---
show_instructions() {
    clear
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║             📚 ИНСТРУКЦИЯ: КАК НАСТРОИТЬ КАСКАД              ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${CYAN}ШАГ 1: Подготовка${NC}"
    echo -e "У вас должны быть данные от зарубежного VPN (WireGuard/VLESS):"
    echo -e " - ${YELLOW}IP адрес${NC} (зарубежный)"
    echo -e " - ${YELLOW}Порт${NC} (на котором работает VPN)"
    echo ""
    echo -e "${CYAN}ШАГ 2: Настройка данного сервера${NC}"
    echo -e "1. В меню выберите пункт ${GREEN}1${NC} (для UDP-трафика/VPN) или ${GREEN}2${NC} (для TCP-трафика/Proxy)."
    echo -e "2. Введите ${YELLOW}IP${NC} зарубежного сервера, ${YELLOW}входной порт${NC} на этом сервере"
    echo -e "   и ${YELLOW}порт${NC} на зарубежном сервере (Enter = такой же, как входной)."
    echo -e "3. Скрипт создаст 'мост' через этот VPS."
    echo ""
    echo -e "${CYAN}ШАГ 3: Настройка клиентского приложения (Важно!)${NC}"
    echo -e "1. Откройте приложение (AmneziaWG / WireGuard / v2rayNG)."
    echo -e "2. В настройках соединения найдите поле ${YELLOW}Endpoint / Адрес сервера${NC}."
    echo -e "3. Замените зарубежный IP на ${GREEN}IP ЭТОГО СЕРВЕРА${NC}."
    echo -e "4. Порт укажите ${GREEN}входной${NC} (тот, что задали на этом сервере)."
    echo ""
    echo -e "${GREEN}Готово! Теперь трафик идет по следующей схеме: клиент -> этот сервер -> зарубежный сервер.${NC}"
    echo ""
    read -p "Нажмите Enter, чтобы вернуться в меню..."
}

# --- ЯДРО НАСТРОЙКИ ---
configure_rule() {
    local PROTO=$1
    local NAME=$2

    echo -e "\n${CYAN}--- Настройка $NAME ($PROTO) ---${NC}"

    while true; do
        echo -e "Введите IP адрес конечного сервера:"
        read -p "> " TARGET_IP
        if [[ -n "$TARGET_IP" ]]; then break; fi
    done

    while true; do
        echo -e "Введите входной порт (на этом сервере):"
        read -p "> " IN_PORT
        if valid_port "$IN_PORT"; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done

    while true; do
        echo -e "Введите порт на конечном сервере (Enter = $IN_PORT):"
        read -p "> " OUT_PORT
        OUT_PORT=${OUT_PORT:-$IN_PORT}
        if valid_port "$OUT_PORT"; then break; fi
        echo -e "${RED}Ошибка: порт должен быть числом от 1 до 65535!${NC}"
    done

    IFACE=$(ip route get 8.8.8.8 | awk -- '{printf $5}')
    if [[ -z "$IFACE" ]]; then
        echo -e "${RED}[ERROR] Скрипту не удалось определить интерфейс!${NC}"
        exit 1
    fi

    echo -e "${YELLOW}[*] Применение правил...${NC}"

    # Удаляем возможные дубли этого же правила
    iptables -t nat -D PREROUTING -p $PROTO --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT" 2>/dev/null
    iptables -D INPUT -p $PROTO --dport "$IN_PORT" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p $PROTO -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p $PROTO -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    iptables -A INPUT -p $PROTO --dport "$IN_PORT" -j ACCEPT
    iptables -t nat -A PREROUTING -p $PROTO --dport "$IN_PORT" -j DNAT --to-destination "$TARGET_IP:$OUT_PORT"

    if ! iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
    fi

    # После DNAT в FORWARD пакет идёт уже на порт конечного сервера
    iptables -A FORWARD -p $PROTO -d "$TARGET_IP" --dport "$OUT_PORT" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -p $PROTO -s "$TARGET_IP" --sport "$OUT_PORT" -m state --state ESTABLISHED,RELATED -j ACCEPT

    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$IN_PORT"/$PROTO >/dev/null
        sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
        ufw reload >/dev/null
    fi

    netfilter-persistent save > /dev/null

    echo -e "${GREEN}[SUCCESS] Туннель успешно настроен!${NC}"
    echo -e "$PROTO: Порт $IN_PORT -> $TARGET_IP:$OUT_PORT"
    read -p "Нажмите Enter для возврата в меню..."
}

# --- СПИСОК ПРАВИЛ ---
list_active_rules() {
    echo -e "\n${CYAN}--- Активные переадресации ---${NC}"
    echo -e "${MAGENTA}ПОРТ\tПРОТОКОЛ\tЦЕЛЬ${NC}"
    iptables -t nat -S PREROUTING | grep "DNAT" | while read -r line ; do
        l_port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
        l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
        l_dest=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        if [[ -n "$l_port" ]]; then echo -e "$l_port\t$l_proto\t\t$l_dest"; fi
    done
    echo ""
    read -p "Нажмите Enter..."
}

# --- УДАЛЕНИЕ ОДНОГО ПРАВИЛА ---
delete_single_rule() {
    echo -e "\n${CYAN}--- Удаление правила ---${NC}"
    declare -a RULES_LIST
    local i=1
    while read -r line; do
        l_port=$(echo "$line" | grep -oP '(?<=--dport )\d+')
        l_proto=$(echo "$line" | grep -oP '(?<=-p )\w+')
        l_dest=$(echo "$line" | grep -oP '(?<=--to-destination )[\d\.:]+')
        if [[ -n "$l_port" ]]; then
            RULES_LIST[$i]="$l_port|$l_proto|$l_dest"
            echo -e "${YELLOW}[$i]${NC} Порт: $l_port ($l_proto) -> $l_dest"
            ((i++))
        fi
    done < <(iptables -t nat -S PREROUTING | grep "DNAT")

    if [ ${#RULES_LIST[@]} -eq 0 ]; then
        echo -e "${RED}Нет активных правил.${NC}"
        read -p "Нажмите Enter..."
        return
    fi

    echo ""
    read -p "Номер правила для удаления (или введите число 0 для отмены): " rule_num
    if [[ "$rule_num" == "0" || -z "${RULES_LIST[$rule_num]}" ]]; then return; fi

    IFS='|' read -r d_port d_proto d_dest <<< "${RULES_LIST[$rule_num]}"
    local d_ip="${d_dest%:*}"
    local d_tport="${d_dest##*:}"

    iptables -t nat -D PREROUTING -p "$d_proto" --dport "$d_port" -j DNAT --to-destination "$d_dest" 2>/dev/null
    iptables -D INPUT -p "$d_proto" --dport "$d_port" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$d_proto" -d "$d_ip" --dport "$d_tport" -m state --state NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -p "$d_proto" -s "$d_ip" --sport "$d_tport" -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

    netfilter-persistent save > /dev/null
    echo -e "${GREEN}[OK] Удалено.${NC}"
    read -p "Нажмите Enter..."
}

# --- ПОЛНАЯ ОЧИСТКА ---
flush_rules() {
    echo -e "\n${RED}!!! ВНИМАНИЕ !!!${NC}"
    echo "Сброс ВСЕХ настроек iptables."
    read -p "Вы уверены? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -t nat -F
        iptables -t mangle -F
        iptables -F
        iptables -X
        netfilter-persistent save > /dev/null
        echo -e "${GREEN}[OK] Очищено.${NC}"
    fi
    read -p "Нажмите Enter..."
}

# --- МЕНЮ ---
show_menu() {
    while true; do
        clear

        echo -e "------------------------------------------------------"
        echo -e "${CYAN}           СКРИПТ НАСТРОЙКИ КАСКАДА VPN${NC}"
        echo -e "------------------------------------------------------"
        echo ""
        echo -e "1) Настроить ${CYAN}AmneziaWG / WireGuard${NC} (UDP)"
        echo -e "2) Настроить ${CYAN}VLESS / XRay${NC} (TCP)"
        echo -e "3) Посмотреть активные правила"
        echo -e "4) ${RED}Удалить одно правило${NC}"
        echo -e "5) ${RED}Сбросить ВСЕ настройки${NC}"
        echo -e "6) ${MAGENTA}📚 ИНСТРУКЦИЯ (Как настроить)${NC}"
        echo -e "0) Выход"
        echo -e "------------------------------------------------------"
        read -p "Ваш выбор: " choice

        case $choice in
            1) configure_rule "udp" "AmneziaWG" ;;
            2) configure_rule "tcp" "VLESS" ;;
            3) list_active_rules ;;
            4) delete_single_rule ;;
            5) flush_rules ;;
            6) show_instructions ;;
            0) exit 0 ;;
            *) ;;
        esac
    done
}

# --- ЗАПУСК ---
check_root
prepare_system
show_menu
