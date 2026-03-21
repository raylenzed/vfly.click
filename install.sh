#!/bin/bash

# =========================================================
# Multi-Protocol Manager V3.2
# =========================================================

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- 流量监控配置 ---
TRAFFIC_CONF="/etc/vps-traffic.conf"
DEFAULT_QUOTA_GB=2048  # 2TB

# --- 路径定义 ---
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
HY2_CONF="/etc/hysteria/config.yaml"
SNELL_CONF="/etc/snell/snell-server.conf"

# --- 基础函数 ---

check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 sudo -i 切换到 root 用户后运行！${NC}"; exit 1; }
}

install_tools() {
    if ! command -v jq &>/dev/null || ! command -v qrencode &>/dev/null; then
        echo -e "${BLUE}正在安装必要工具...${NC}"
        if command -v apt &>/dev/null; then
            apt update -y && apt install -y wget curl unzip vim jq qrencode openssl socat
        elif command -v yum &>/dev/null; then
            yum update -y && yum install -y wget curl unzip vim jq qrencode openssl socat
        elif command -v dnf &>/dev/null; then
            dnf update -y && dnf install -y wget curl unzip vim jq qrencode openssl socat
        fi
    fi
}

get_ip() {
    curl -s4m8 https://ip.gs || curl -s4m8 https://api.ipify.org
}

check_status() {
    if systemctl is-active --quiet $1; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

# --- 1. Reality 管理 (核心修复部分) ---

install_reality() {
    echo -e "${BLUE}>>> 安装/重置 Xray Reality...${NC}"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    mkdir -p /usr/local/etc/xray
    
    read -p "请输入伪装域名 (SNI) [默认: griffithobservatory.org]: " SNI
    [[ -z "$SNI" ]] && SNI="griffithobservatory.org"

    echo -e "${YELLOW}正在生成密钥...${NC}"
    
    # 获取原始输出
    KEYS_RAW=$($XRAY_BIN x25519)
    
    # 尝试匹配 Private Key (兼容 PrivateKey: 和 Private Key:)
    PK=$(echo "$KEYS_RAW" | grep -i "Private" | awk -F: '{print $NF}' | awk '{print $1}')
    
    # 尝试匹配 Public Key (兼容 Public Key: 和 Password:)
    PUB=$(echo "$KEYS_RAW" | grep -i "Public" | awk -F: '{print $NF}' | awk '{print $1}')
    
    # 如果没找到 Public，尝试找 Password (针对 Xray v26+)
    if [[ -z "$PUB" ]]; then
        PUB=$(echo "$KEYS_RAW" | grep -i "Password" | awk -F: '{print $NF}' | awk '{print $1}')
    fi

    # 如果还是失败，进入手动模式
    if [[ -z "$PK" || -z "$PUB" ]]; then
        echo -e "${RED}自动抓取密钥失败 (可能是Xray版本输出格式变更)。${NC}"
        echo -e "当前输出内容:\n$KEYS_RAW"
        echo -e "${YELLOW}请根据上方内容手动复制粘贴:${NC}"
        read -p "请输入 PrivateKey: " PK
        read -p "请输入 Public Key (或 Password): " PUB
    fi

    # 最终检查
    if [[ -z "$PK" || -z "$PUB" ]]; then
        echo -e "${RED}错误：未能获取有效密钥，停止安装。${NC}"
        return
    fi
    
    UUID=$($XRAY_BIN uuid)
    SID=$(openssl rand -hex 4)

    cat > $XRAY_CONF <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$SNI:443",
          "serverNames": ["$SNI"],
          "privateKey": "$PK",
          "shortIds": ["$SID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF
    # 保存公钥到文件以便后续查看
    echo "$PUB" > /usr/local/etc/xray/public.key

    systemctl restart xray
    echo -e "${GREEN}Reality 安装完成！${NC}"
    view_reality
}

view_reality() {
    if [[ ! -f $XRAY_CONF ]]; then echo -e "${RED}未找到配置文件${NC}"; return; fi
    
    IP=$(get_ip)
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONF)
    SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' $XRAY_CONF)
    SID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $XRAY_CONF)
    
    # 尝试读取保存的公钥
    if [[ -f /usr/local/etc/xray/public.key ]]; then
        PUB=$(cat /usr/local/etc/xray/public.key)
    else
        PUB="未找到公钥文件，请重置"
    fi
    
    LINK="vless://${UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#Reality_Vision"
    
    echo -e "\n${YELLOW}=== Reality 配置信息 ===${NC}"
    echo -e "SNI: $SNI"
    echo -e "UUID: $UUID"
    echo -e "Public Key: $PUB"
    echo -e "ShortID: $SID"
    echo -e "链接: $LINK"
    echo -e "\n${YELLOW}二维码:${NC}"
    qrencode -t ANSIUTF8 "$LINK"
}

manage_reality_menu() {
    echo -e "\n${BLUE}--- Reality 管理 ---${NC}"
    echo "1. 查看配置/二维码"
    echo "2. 重启服务"
    echo "3. 停止服务"
    echo "4. 查看日志"
    read -p "请选择: " OPT
    case $OPT in
        1) view_reality ;;
        2) systemctl restart xray && echo "已重启" ;;
        3) systemctl stop xray && echo "已停止" ;;
        4) journalctl -u xray -n 20 --no-pager ;;
        *) echo "无效选择" ;;
    esac
}

# --- 2. Hysteria 2 管理 ---

install_hy2() {
    echo -e "${BLUE}>>> 安装 Hysteria 2...${NC}"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) HY_ARCH="amd64" ;;
        aarch64) HY_ARCH="arm64" ;;
        *) echo "不支持架构"; return ;;
    esac
    LATEST=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep "tag_name" | cut -d '"' -f 4)
    wget -O /usr/local/bin/hysteria_server "https://github.com/apernet/hysteria/releases/download/${LATEST}/hysteria-linux-${HY_ARCH}"
    chmod +x /usr/local/bin/hysteria_server
    
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=bing.com" 2>/dev/null
    PASS=$(openssl rand -base64 16)
    
    cat > $HY2_CONF <<EOF
listen: :443
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: $PASS
ignoreClientBandwidth: false
EOF
    
    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria_server server -c /etc/hysteria/config.yaml
Restart=always
User=root
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl restart hysteria-server
    echo -e "${GREEN}Hysteria 2 安装完成！${NC}"
    view_hy2
}

view_hy2() {
    if [[ ! -f $HY2_CONF ]]; then echo -e "${RED}未找到配置${NC}"; return; fi
    IP=$(get_ip)
    PASS=$(grep "password:" $HY2_CONF | awk '{print $2}')
    LINK="hysteria2://${PASS}@${IP}:443?insecure=1&sni=bing.com#Hysteria2"
    
    echo -e "\n${YELLOW}=== Hysteria 2 配置信息 ===${NC}"
    echo -e "密码: $PASS"
    echo -e "端口: 443 (UDP)"
    echo -e "SNI: bing.com"
    echo -e "链接: $LINK"
    echo -e "\n${YELLOW}二维码:${NC}"
    qrencode -t ANSIUTF8 "$LINK"
}

manage_hy2_menu() {
    echo -e "\n${BLUE}--- Hysteria 2 管理 ---${NC}"
    echo "1. 查看配置/二维码"
    echo "2. 重启服务"
    echo "3. 停止服务"
    echo "4. 查看日志"
    read -p "请选择: " OPT
    case $OPT in
        1) view_hy2 ;;
        2) systemctl restart hysteria-server && echo "已重启" ;;
        3) systemctl stop hysteria-server && echo "已停止" ;;
        4) journalctl -u hysteria-server -n 20 --no-pager ;;
        *) echo "无效选择" ;;
    esac
}

# --- 3. Snell 管理 ---

install_snell() {
    echo -e "${BLUE}>>> 安装 Snell v5...${NC}"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-amd64.zip"
    else
        URL="https://dl.nssurge.com/snell/snell-server-v5.0.1-linux-aarch64.zip"
    fi
    wget -O snell.zip "$URL"
    unzip -o snell.zip -d /usr/local/bin
    rm snell.zip
    chmod +x /usr/local/bin/snell-server
    
    mkdir -p /etc/snell
    PSK=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9')
    
    cat > $SNELL_CONF <<EOF
[snell-server]
listen = 0.0.0.0:11807
psk = $PSK
ipv6 = false
EOF

    GROUP="nobody"
    grep -q "nogroup" /etc/group && GROUP="nogroup"

    cat > /lib/systemd/system/snell.service <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target
[Service]
Type=simple
User=nobody
Group=$GROUP
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable snell
    systemctl restart snell
    echo -e "${GREEN}Snell 安装完成！${NC}"
    view_snell
}

view_snell() {
    if [[ ! -f $SNELL_CONF ]]; then echo -e "${RED}未找到配置${NC}"; return; fi
    IP=$(get_ip)
    PSK=$(grep "psk =" $SNELL_CONF | awk -F'= ' '{print $2}')
    CONF_LINE="Proxy = snell, ${IP}, 11807, psk=${PSK}, version=5, tfo=true"
    
    echo -e "\n${YELLOW}=== Snell 配置信息 ===${NC}"
    echo -e "PSK: $PSK"
    echo -e "Surge 配置行:\n$CONF_LINE"
    echo -e "(Snell 协议暂无通用二维码标准)"
}

manage_snell_menu() {
    echo -e "\n${BLUE}--- Snell 管理 ---${NC}"
    echo "1. 查看配置"
    echo "2. 重启服务"
    echo "3. 停止服务"
    echo "4. 查看日志"
    read -p "请选择: " OPT
    case $OPT in
        1) view_snell ;;
        2) systemctl restart snell && echo "已重启" ;;
        3) systemctl stop snell && echo "已停止" ;;
        4) journalctl -u snell -n 20 --no-pager ;;
        *) echo "无效选择" ;;
    esac
}

# --- 5. 流量监控 ---

_traffic_get_iface() {
    ip route show default 2>/dev/null | awk '/^default/{print $5}' | head -1
}

_traffic_load_conf() {
    QUOTA_GB=$DEFAULT_QUOTA_GB
    RESET_DAY=1
    ALERT_PCT=80
    if [[ -f "$TRAFFIC_CONF" ]]; then
        source "$TRAFFIC_CONF"
    fi
}

_traffic_save_conf() {
    cat > "$TRAFFIC_CONF" <<EOF
QUOTA_GB=${QUOTA_GB}
RESET_DAY=${RESET_DAY}
ALERT_PCT=${ALERT_PCT}
EOF
}

_traffic_install_vnstat() {
    if ! command -v vnstat &>/dev/null; then
        echo -e "${BLUE}正在安装 vnstat...${NC}"
        if command -v apt &>/dev/null; then
            apt install -y vnstat
        elif command -v yum &>/dev/null; then
            yum install -y vnstat
        elif command -v dnf &>/dev/null; then
            dnf install -y vnstat
        fi
        systemctl enable vnstat --now
        local iface
        iface=$(_traffic_get_iface)
        if [[ -n "$iface" ]]; then
            vnstat -i "$iface" --add 2>/dev/null || true
        fi
        echo -e "${YELLOW}vnstat 刚安装，需要收集约 1 分钟数据后才有统计。${NC}"
        sleep 2
    fi
    # 确保 vnstat 服务在跑
    systemctl is-active --quiet vnstat || systemctl start vnstat
}

_traffic_bytes_to_human() {
    local bytes=$1
    if (( bytes >= 1099511627776 )); then
        awk "BEGIN {printf \"%.2f TB\", $bytes/1099511627776}"
    elif (( bytes >= 1073741824 )); then
        awk "BEGIN {printf \"%.2f GB\", $bytes/1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}"
    else
        echo "${bytes} B"
    fi
}

_traffic_progress_bar() {
    local pct=$1
    local width=30
    local filled=$(( pct * width / 100 ))
    [[ $filled -gt $width ]] && filled=$width
    local empty=$(( width - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    if (( pct >= 90 )); then
        echo -e "${RED}[${bar}] ${pct}%${NC}"
    elif (( pct >= 70 )); then
        echo -e "${YELLOW}[${bar}] ${pct}%${NC}"
    else
        echo -e "${GREEN}[${bar}] ${pct}%${NC}"
    fi
}

traffic_show() {
    _traffic_install_vnstat
    _traffic_load_conf
    local iface
    iface=$(_traffic_get_iface)
    if [[ -z "$iface" ]]; then
        echo -e "${RED}无法检测网络接口${NC}"
        return
    fi

    # 获取本月流量（bytes）
    local rx_bytes tx_bytes total_bytes
    rx_bytes=$(vnstat -i "$iface" --json m 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin)['interfaces'][0]['traffic']['month']; print(d[-1]['rx'])" 2>/dev/null || echo 0)
    tx_bytes=$(vnstat -i "$iface" --json m 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin)['interfaces'][0]['traffic']['month']; print(d[-1]['tx'])" 2>/dev/null || echo 0)
    total_bytes=$(( rx_bytes + tx_bytes ))

    local quota_bytes=$(( QUOTA_GB * 1024 * 1024 * 1024 ))
    local used_pct=0
    if (( quota_bytes > 0 )); then
        used_pct=$(( total_bytes * 100 / quota_bytes ))
    fi
    local remain_bytes=$(( quota_bytes - total_bytes ))
    [[ $remain_bytes -lt 0 ]] && remain_bytes=0

    # 今日流量
    local today_rx today_tx
    today_rx=$(vnstat -i "$iface" --json d 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin)['interfaces'][0]['traffic']['day']; print(d[-1]['rx'])" 2>/dev/null || echo 0)
    today_tx=$(vnstat -i "$iface" --json d 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin)['interfaces'][0]['traffic']['day']; print(d[-1]['tx'])" 2>/dev/null || echo 0)
    local today_total=$(( today_rx + today_tx ))

    local reset_date
    reset_date=$(date -d "$(date +%Y-%m)-${RESET_DAY}" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)

    echo -e "\n${BOLD}${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║           VPS 流量监控                   ║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo -e "  接口: ${CYAN}${iface}${NC}   重置日: 每月 ${RESET_DAY} 日"
    echo ""
    echo -e "  ${BOLD}本月用量${NC}"
    echo -e "  ↑ 上传:   $(printf '%10s' "$(_traffic_bytes_to_human $tx_bytes)")"
    echo -e "  ↓ 下载:   $(printf '%10s' "$(_traffic_bytes_to_human $rx_bytes)")"
    echo -e "  ∑ 合计:   $(printf '%10s' "$(_traffic_bytes_to_human $total_bytes)")"
    echo ""
    echo -e "  ${BOLD}月配额: ${QUOTA_GB} GB${NC}  剩余: $(_traffic_bytes_to_human $remain_bytes)"
    echo -n "  "
    _traffic_progress_bar "$used_pct"
    echo ""
    echo -e "  ${BOLD}今日用量${NC}"
    echo -e "  ↑ ${_traffic_bytes_to_human $today_tx}  ↓ ${_traffic_bytes_to_human $today_rx}  合计: $(_traffic_bytes_to_human $today_total)"
    echo ""

    if (( used_pct >= ALERT_PCT )); then
        echo -e "  ${RED}⚠  已用 ${used_pct}%，超过告警阈值 ${ALERT_PCT}%！${NC}"
    fi

    echo -e "${BLUE}──────────────────────────────────────────${NC}"
    echo -e "  ${YELLOW}最近 5 天明细:${NC}"
    vnstat -i "$iface" -d 5 2>/dev/null | tail -8
}

traffic_show_month() {
    _traffic_install_vnstat
    local iface
    iface=$(_traffic_get_iface)
    echo -e "\n${YELLOW}=== 历史月度流量 ===${NC}"
    vnstat -i "$iface" -m 2>/dev/null
}

traffic_set_quota() {
    _traffic_load_conf
    echo -e "\n${YELLOW}=== 配置流量配额 ===${NC}"
    echo -e "当前配额: ${QUOTA_GB} GB，告警阈值: ${ALERT_PCT}%，重置日: 每月 ${RESET_DAY} 日"
    echo ""
    read -p "月配额 (GB) [当前: ${QUOTA_GB}, 回车跳过]: " input
    [[ -n "$input" ]] && QUOTA_GB="$input"
    read -p "重置日 (1-28) [当前: ${RESET_DAY}, 回车跳过]: " input
    [[ -n "$input" ]] && RESET_DAY="$input"
    read -p "告警阈值 % [当前: ${ALERT_PCT}, 回车跳过]: " input
    [[ -n "$input" ]] && ALERT_PCT="$input"
    _traffic_save_conf
    echo -e "${GREEN}已保存。${NC}"
}

traffic_setup_cron() {
    _traffic_load_conf
    local iface
    iface=$(_traffic_get_iface)
    local cron_script="/usr/local/bin/vps-traffic-alert.sh"
    cat > "$cron_script" <<SCRIPT
#!/bin/bash
IFACE="$iface"
QUOTA_BYTES=$(( QUOTA_GB * 1024 * 1024 * 1024 ))
ALERT_PCT=$ALERT_PCT

rx=\$(vnstat -i "\$IFACE" --json m 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin)['interfaces'][0]['traffic']['month']; print(d[-1]['rx'])" 2>/dev/null || echo 0)
tx=\$(vnstat -i "\$IFACE" --json m 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin)['interfaces'][0]['traffic']['month']; print(d[-1]['tx'])" 2>/dev/null || echo 0)
total=\$(( rx + tx ))
pct=\$(( total * 100 / QUOTA_BYTES ))

if (( pct >= ALERT_PCT )); then
    wall "⚠ VPS 流量告警：本月已用 \${pct}% (\$(numfmt --to=iec \$total) / ${QUOTA_GB}GB)"
    logger -t vps-traffic "ALERT: used \${pct}% of monthly quota"
fi
SCRIPT
    chmod +x "$cron_script"

    # 每小时检查一次
    local cron_line="0 * * * * $cron_script"
    if crontab -l 2>/dev/null | grep -qF "$cron_script"; then
        echo -e "${YELLOW}定时告警已存在，已更新脚本。${NC}"
    else
        ( crontab -l 2>/dev/null; echo "$cron_line" ) | crontab -
        echo -e "${GREEN}已设置每小时检查，超过 ${ALERT_PCT}% 时写入系统日志并广播告警。${NC}"
    fi
}

traffic_remove_cron() {
    local cron_script="/usr/local/bin/vps-traffic-alert.sh"
    crontab -l 2>/dev/null | grep -v "$cron_script" | crontab -
    rm -f "$cron_script"
    echo -e "${GREEN}已移除定时告警。${NC}"
}

manage_traffic_menu() {
    while true; do
        echo -e "\n${BLUE}--- 流量监控 ---${NC}"
        echo "1. 查看本月流量"
        echo "2. 查看历史月度流量"
        echo "3. 设置配额与告警阈值"
        echo "4. 开启每小时自动告警 (cron)"
        echo "5. 关闭自动告警"
        echo "0. 返回主菜单"
        read -p "请选择: " OPT
        case $OPT in
            1) traffic_show ;;
            2) traffic_show_month ;;
            3) traffic_set_quota ;;
            4) traffic_setup_cron ;;
            5) traffic_remove_cron ;;
            0) break ;;
            *) echo "无效选择" ;;
        esac
    done
}

# --- 4. BBR 管理 ---

enable_bbr() {
    echo -e "${BLUE}>>> 开启 BBR 加速...${NC}"
    if grep -q "bbr" /etc/sysctl.conf; then
        echo -e "${GREEN}BBR 似乎已经开启，正在刷新...${NC}"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    sysctl -p
    RESULT=$(sysctl net.ipv4.tcp_congestion_control)
    echo -e "当前状态: ${GREEN}$RESULT${NC}"
}

# --- 主菜单 ---

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=====================================${NC}"
        echo -e "   全能协议管理脚本 V3.2"
        echo -e "${BLUE}=====================================${NC}"
        echo -e "1. 安装/重置 Reality (TCP 443)  [$(check_status xray)]"
        echo -e "2. 安装/重置 Hysteria2 (UDP 443)[$(check_status hysteria-server)]"
        echo -e "3. 安装/重置 Snell v5 (11807)   [$(check_status snell)]"
        echo -e "-------------------------------------"
        echo -e "4. 管理 Reality (查看配置/二维码)"
        echo -e "5. 管理 Hysteria2"
        echo -e "6. 管理 Snell"
        echo -e "-------------------------------------"
        echo -e "7. 开启 BBR 加速"
        echo -e "8. 流量监控"
        echo -e "0. 退出脚本"
        echo -e "${BLUE}=====================================${NC}"
        read -p "请输入选项: " CHOICE

        case $CHOICE in
            1) install_reality; read -p "按回车继续..." ;;
            2) install_hy2; read -p "按回车继续..." ;;
            3) install_snell; read -p "按回车继续..." ;;
            4) manage_reality_menu; read -p "按回车继续..." ;;
            5) manage_hy2_menu; read -p "按回车继续..." ;;
            6) manage_snell_menu; read -p "按回车继续..." ;;
            7) enable_bbr; read -p "按回车继续..." ;;
            8) manage_traffic_menu ;;
            0) exit 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

# --- 入口 ---
check_root
install_tools
main_menu
