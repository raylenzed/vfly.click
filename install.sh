#!/bin/bash

# =========================================================
# VFly - Multi-Protocol Manager V3.3
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
TRAFFIC_WEB_DIR="/opt/vps-traffic-web"
TRAFFIC_WEB_PORT=19999
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
HY2_CONF="/etc/hysteria/config.yaml"
SNELL_CONF="/etc/snell/snell-server.conf"

# --- 基础函数 ---

# 通用端口选择函数，结果存入全局变量 SELECTED_PORT
select_port() {
    local service_name="${1:-服务}"
    local default_random_min="${2:-10000}"
    local default_random_max="${3:-65535}"

    echo -e "\n${YELLOW}--- 端口选择 (${service_name}) ---${NC}"
    echo -e "  ${CYAN}1.${NC} 使用 443 端口 ${YELLOW}(最佳隐蔽性，流量混入 HTTPS)${NC}"
    echo -e "  ${CYAN}2.${NC} 随机端口 ${YELLOW}(${default_random_min}-${default_random_max}，避开常用端口)${NC}"
    echo -e "  ${CYAN}3.${NC} 手动输入端口"
    read -p "请选择 [1/2/3，默认 1]: " PORT_OPT
    [[ -z "$PORT_OPT" ]] && PORT_OPT=1

    case $PORT_OPT in
        1)
            SELECTED_PORT=443
            echo -e "${GREEN}使用 443 端口${NC}"
            ;;
        2)
            SELECTED_PORT=$(( RANDOM % (default_random_max - default_random_min + 1) + default_random_min ))
            echo -e "${GREEN}随机端口: ${SELECTED_PORT}${NC}"
            ;;
        3)
            while true; do
                read -p "请输入端口 (1-65535): " SELECTED_PORT
                if [[ "$SELECTED_PORT" =~ ^[0-9]+$ ]] && (( SELECTED_PORT >= 1 && SELECTED_PORT <= 65535 )); then
                    echo -e "${GREEN}使用端口: ${SELECTED_PORT}${NC}"
                    break
                else
                    echo -e "${RED}无效端口，请重新输入${NC}"
                fi
            done
            ;;
        *)
            SELECTED_PORT=443
            echo -e "${YELLOW}无效选择，默认使用 443${NC}"
            ;;
    esac
}

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
    
    select_port "VLESS Reality"

    echo -e "${YELLOW}提示：443 端口让流量看起来像正常 HTTPS，隐蔽性最好；${NC}"
    echo -e "${YELLOW}      其他端口功能完全正常，但可能更容易被识别为代理流量。${NC}"

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

    mkdir -p /var/log/xray
    touch /var/log/xray/access.log
    chown nobody:nogroup /var/log/xray/access.log 2>/dev/null || true

    cat > $XRAY_CONF <<EOF
{
  "log": { "access": "/var/log/xray/access.log", "loglevel": "warning" },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "port": $SELECTED_PORT,
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
          "dest": "$SNI:$SELECTED_PORT",
          "serverNames": ["$SNI"],
          "privateKey": "$PK",
          "shortIds": ["$SID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    },
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ],
  "routing": {
    "rules": [
      { "inboundTag": ["api"], "outboundTag": "api" }
    ]
  }
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
    PORT=$(jq -r '.inbounds[0].port' $XRAY_CONF)
    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' $XRAY_CONF)
    SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' $XRAY_CONF)
    SID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $XRAY_CONF)

    # 尝试读取保存的公钥
    if [[ -f /usr/local/etc/xray/public.key ]]; then
        PUB=$(cat /usr/local/etc/xray/public.key)
    else
        PUB="未找到公钥文件，请重置"
    fi

    LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#Reality_Vision"
    
    echo -e "\n${YELLOW}=== Reality 配置信息 ===${NC}"
    echo -e "端口: $PORT"
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

    select_port "Hysteria 2 (UDP)"

    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=bing.com" 2>/dev/null
    PASS=$(openssl rand -base64 16)

    cat > $HY2_CONF <<EOF
listen: :$SELECTED_PORT
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
    PORT=$(grep "^listen:" $HY2_CONF | awk -F: '{print $NF}' | tr -d ' ')

    LINK="hysteria2://${PASS}@${IP}:${PORT}?insecure=1&sni=bing.com#Hysteria2"

    echo -e "\n${YELLOW}=== Hysteria 2 配置信息 ===${NC}"
    echo -e "密码: $PASS"
    echo -e "端口: ${PORT} (UDP)"
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
    PORT=$(grep "^listen" $SNELL_CONF | awk -F: '{print $NF}' | tr -d ' ')
    CONF_LINE="Proxy = snell, ${IP}, ${PORT}, psk=${PSK}, version=5, tfo=true"
    
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

# --- 6. Web 流量面板 ---

_web_write_server() {
    local iface="$1" quota_gb="$2" reset_day="$3" alert_pct="$4" token="$5"
    mkdir -p "$TRAFFIC_WEB_DIR"
    cat > "$TRAFFIC_WEB_DIR/server.py" <<PYEOF
#!/usr/bin/env python3
import http.server, json, subprocess, os, datetime, urllib.parse, html

IFACE      = "${iface}"
QUOTA_GB   = ${quota_gb}
RESET_DAY  = ${reset_day}
ALERT_PCT  = ${alert_pct}
TOKEN      = "${token}"
PORT       = ${TRAFFIC_WEB_PORT}

def vnstat_json(mode):
    try:
        r = subprocess.run(["vnstat", "-i", IFACE, "--json", mode],
                           capture_output=True, text=True, timeout=10)
        return json.loads(r.stdout)
    except Exception:
        return {}

def fmt(b):
    if b >= 1099511627776: return f"{b/1099511627776:.2f} TB"
    if b >= 1073741824:    return f"{b/1073741824:.2f} GB"
    if b >= 1048576:       return f"{b/1048576:.2f} MB"
    if b >= 1024:          return f"{b/1024:.2f} KB"
    return f"{b} B"

def get_month_data():
    d = vnstat_json("m")
    try:
        months = d["interfaces"][0]["traffic"]["month"]
        cur = months[-1]
        return cur.get("rx", 0), cur.get("tx", 0)
    except Exception:
        return 0, 0

def get_day_data(n=30):
    d = vnstat_json("d")
    try:
        days = d["interfaces"][0]["traffic"]["day"][-n:]
        result = []
        for day in days:
            label = f"{day['date']['year']}-{day['date']['month']:02d}-{day['date']['day']:02d}"
            result.append({"date": label, "rx": day.get("rx", 0), "tx": day.get("tx", 0)})
        return result
    except Exception:
        return []

def get_all_months():
    d = vnstat_json("m")
    try:
        months = d["interfaces"][0]["traffic"]["month"]
        result = []
        for m in months:
            label = f"{m['date']['year']}-{m['date']['month']:02d}"
            result.append({"month": label, "rx": m.get("rx", 0), "tx": m.get("tx", 0)})
        return result
    except Exception:
        return []

HTML = r"""<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VPS 流量监控</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:#0f172a;color:#e2e8f0;font-family:'Segoe UI',system-ui,sans-serif;padding:20px}
  h1{text-align:center;font-size:1.5rem;margin-bottom:24px;color:#f8fafc}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px;margin-bottom:24px}
  .card{background:#1e293b;border-radius:12px;padding:20px}
  .card h2{font-size:.85rem;color:#94a3b8;text-transform:uppercase;letter-spacing:.08em;margin-bottom:12px}
  .big{font-size:2rem;font-weight:700;color:#f1f5f9}
  .sub{font-size:.8rem;color:#64748b;margin-top:4px}
  .bar-wrap{background:#0f172a;border-radius:999px;height:10px;margin:10px 0}
  .bar{height:10px;border-radius:999px;transition:width .5s}
  .bar.green{background:linear-gradient(90deg,#22c55e,#4ade80)}
  .bar.yellow{background:linear-gradient(90deg,#eab308,#facc15)}
  .bar.red{background:linear-gradient(90deg,#ef4444,#f87171)}
  .stat-row{display:flex;justify-content:space-between;font-size:.85rem;margin-top:6px;color:#94a3b8}
  .stat-val{color:#e2e8f0;font-weight:600}
  .chart-card{background:#1e293b;border-radius:12px;padding:20px;margin-bottom:16px}
  .chart-card h2{font-size:.85rem;color:#94a3b8;text-transform:uppercase;letter-spacing:.08em;margin-bottom:16px}
  .footer{text-align:center;font-size:.75rem;color:#334155;margin-top:24px}
  .badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:.75rem;font-weight:600}
  .badge.ok{background:#166534;color:#86efac}
  .badge.warn{background:#713f12;color:#fde68a}
  .badge.crit{background:#7f1d1d;color:#fca5a5}
  @media(max-width:600px){.big{font-size:1.5rem}}
</style>
</head>
<body>
<h1>🖥️ VPS 流量监控</h1>
<div id="app"><div style="text-align:center;color:#475569;padding:60px">加载中...</div></div>
<div class="footer">自动刷新 · <span id="ts"></span></div>
<script>
const fmt = b => {
  if(b>=1099511627776) return (b/1099511627776).toFixed(2)+' TB';
  if(b>=1073741824)    return (b/1073741824).toFixed(2)+' GB';
  if(b>=1048576)       return (b/1048576).toFixed(2)+' MB';
  if(b>=1024)          return (b/1024).toFixed(2)+' KB';
  return b+' B';
};
let dayChart=null, monChart=null;
async function load(){
  const r = await fetch('REPLACE_API_URL').catch(()=>null);
  if(!r||!r.ok){document.getElementById('app').innerHTML='<div style="text-align:center;color:#ef4444;padding:60px">数据加载失败</div>';return;}
  const d = await r.json();
  const {rx,tx,quota_gb,alert_pct,used_pct,remain,days,months,iface} = d;
  const total = rx+tx;
  const barCls = used_pct>=90?'red':used_pct>=alert_pct?'yellow':'green';
  const badgeCls = used_pct>=90?'crit':used_pct>=alert_pct?'warn':'ok';
  const badgeTxt = used_pct>=90?'⚠ 严重':used_pct>=alert_pct?'⚠ 告警':'✓ 正常';
  document.getElementById('app').innerHTML = \`
  <div class="grid">
    <div class="card">
      <h2>本月合计 <span class="badge \${badgeCls}">\${badgeTxt}</span></h2>
      <div class="big">\${fmt(total)}</div>
      <div class="sub">接口: \${iface}</div>
      <div class="bar-wrap"><div class="bar \${barCls}" style="width:\${Math.min(used_pct,100)}%"></div></div>
      <div class="stat-row"><span>已用 \${used_pct}%</span><span class="stat-val">剩余 \${fmt(remain)}</span></div>
      <div class="stat-row"><span>配额</span><span class="stat-val">\${quota_gb} GB</span></div>
    </div>
    <div class="card">
      <h2>上传 / 下载</h2>
      <div class="big">\${fmt(tx)}</div><div class="sub">↑ 上传</div>
      <div style="margin-top:14px"><div class="big">\${fmt(rx)}</div><div class="sub">↓ 下载</div></div>
    </div>
    <div class="card">
      <h2>今日用量</h2>
      <div class="big">\${days.length?fmt(days[days.length-1].rx+days[days.length-1].tx):'--'}</div>
      <div class="sub">↑ \${days.length?fmt(days[days.length-1].tx):'--'} &nbsp; ↓ \${days.length?fmt(days[days.length-1].rx):'--'}</div>
    </div>
  </div>
  <div class="chart-card"><h2>近 30 天日流量</h2><canvas id="dayChart" height="80"></canvas></div>
  <div class="chart-card"><h2>月度流量历史</h2><canvas id="monChart" height="80"></canvas></div>
  \`;

  if(dayChart){dayChart.destroy();dayChart=null;}
  if(monChart){monChart.destroy();monChart=null;}

  const dLabels=days.map(d=>d.date.slice(5));
  dayChart=new Chart(document.getElementById('dayChart'),{type:'bar',data:{labels:dLabels,datasets:[
    {label:'上传',data:days.map(d=>+(d.tx/1073741824).toFixed(3)),backgroundColor:'rgba(99,102,241,.7)',borderRadius:3},
    {label:'下载',data:days.map(d=>+(d.rx/1073741824).toFixed(3)),backgroundColor:'rgba(34,197,94,.7)',borderRadius:3}
  ]},options:{plugins:{legend:{labels:{color:'#94a3b8'}}},scales:{x:{ticks:{color:'#64748b',maxRotation:45}},y:{ticks:{color:'#64748b',callback:v=>v+'GB'}}}}});

  const mLabels=months.map(m=>m.month);
  monChart=new Chart(document.getElementById('monChart'),{type:'bar',data:{labels:mLabels,datasets:[
    {label:'上传',data:months.map(m=>+(m.tx/1073741824).toFixed(3)),backgroundColor:'rgba(99,102,241,.7)',borderRadius:3},
    {label:'下载',data:months.map(m=>+(m.rx/1073741824).toFixed(3)),backgroundColor:'rgba(34,197,94,.7)',borderRadius:3}
  ]},options:{plugins:{legend:{labels:{color:'#94a3b8'}}},scales:{x:{ticks:{color:'#64748b'}},y:{ticks:{color:'#64748b',callback:v=>v+'GB'}}}}});

  document.getElementById('ts').textContent=new Date().toLocaleString('zh-CN');
}
load();
setInterval(load,60000);
</script>
</body></html>
"""

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)

        # token 验证
        if TOKEN and qs.get("token", [""])[0] != TOKEN:
            self.send_response(401)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"<html><body style='background:#0f172a;color:#e2e8f0;font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;'><h2>401 - Access Denied</h2></body></html>")
            return

        if parsed.path == "/api":
            self._api()
        else:
            self._index()

    def _index(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        token_param = ("?token=" + TOKEN) if TOKEN else ""
        page = HTML.replace("REPLACE_API_URL", f"/api{token_param}")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(page.encode())

    def _api(self):
        rx, tx = get_month_data()
        total = rx + tx
        quota_bytes = QUOTA_GB * 1024**3
        used_pct = int(total * 100 / quota_bytes) if quota_bytes else 0
        remain = max(quota_bytes - total, 0)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        data = {
            "iface": IFACE, "rx": rx, "tx": tx,
            "quota_gb": QUOTA_GB, "alert_pct": ALERT_PCT,
            "used_pct": used_pct, "remain": remain,
            "days": get_day_data(30),
            "months": get_all_months(),
        }
        self.wfile.write(json.dumps(data).encode())

if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"VPS Traffic Web running on :{PORT}")
    server.serve_forever()
PYEOF
}

_web_write_service() {
    cat > /etc/systemd/system/vps-traffic-web.service <<EOF
[Unit]
Description=VPS Traffic Web Dashboard
After=network.target vnstat.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${TRAFFIC_WEB_DIR}/server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

traffic_web_install() {
    _traffic_install_vnstat
    _traffic_load_conf

    local iface
    iface=$(_traffic_get_iface)
    if [[ -z "$iface" ]]; then
        echo -e "${RED}无法检测网络接口${NC}"; return
    fi

    echo -e "\n${YELLOW}=== 安装 Web 流量面板 ===${NC}"
    echo -e "接口: ${CYAN}${iface}${NC}  配额: ${QUOTA_GB}GB  重置日: ${RESET_DAY}日"
    echo ""

    local token
    read -p "访问密码 (回车自动生成): " token
    if [[ -z "$token" ]]; then
        token=$(openssl rand -hex 8)
        echo -e "${YELLOW}自动生成密码: ${CYAN}${token}${NC}"
    fi

    read -p "Web 端口 [默认: ${TRAFFIC_WEB_PORT}]: " input_port
    [[ -n "$input_port" ]] && TRAFFIC_WEB_PORT="$input_port"

    _web_write_server "$iface" "$QUOTA_GB" "$RESET_DAY" "$ALERT_PCT" "$token"
    _web_write_service

    # 保存 token 到配置
    grep -q "^WEB_TOKEN=" "$TRAFFIC_CONF" 2>/dev/null && \
        sed -i "s/^WEB_TOKEN=.*/WEB_TOKEN=${token}/" "$TRAFFIC_CONF" || \
        echo "WEB_TOKEN=${token}" >> "$TRAFFIC_CONF"
    grep -q "^WEB_PORT=" "$TRAFFIC_CONF" 2>/dev/null && \
        sed -i "s/^WEB_PORT=.*/WEB_PORT=${TRAFFIC_WEB_PORT}/" "$TRAFFIC_CONF" || \
        echo "WEB_PORT=${TRAFFIC_WEB_PORT}" >> "$TRAFFIC_CONF"

    systemctl enable vps-traffic-web --now

    local ip
    ip=$(get_ip)
    echo -e "\n${GREEN}✓ Web 面板已启动！${NC}"
    echo -e "${BOLD}访问地址:${NC}"
    echo -e "  ${CYAN}http://${ip}:${TRAFFIC_WEB_PORT}/?token=${token}${NC}"
    echo ""
    echo -e "${YELLOW}提示：建议用 nginx 反代并套 TLS 以避免明文传输密码。${NC}"
}

traffic_web_show_url() {
    _traffic_load_conf
    local ip token port
    ip=$(get_ip)
    token="${WEB_TOKEN:-}"
    port="${WEB_PORT:-${TRAFFIC_WEB_PORT}}"
    if [[ -z "$token" ]]; then
        echo -e "${RED}Web 面板未安装，请先选择「安装 Web 面板」${NC}"
        return
    fi
    echo -e "\n${YELLOW}=== Web 面板访问信息 ===${NC}"
    echo -e "地址: ${CYAN}http://${ip}:${port}/?token=${token}${NC}"
    echo -e "状态: $(check_status vps-traffic-web)"
}

traffic_web_remove() {
    systemctl disable vps-traffic-web --now 2>/dev/null
    rm -f /etc/systemd/system/vps-traffic-web.service
    rm -rf "$TRAFFIC_WEB_DIR"
    systemctl daemon-reload
    echo -e "${GREEN}Web 面板已卸载。${NC}"
}

manage_traffic_web_menu() {
    while true; do
        echo -e "\n${BLUE}--- Web 流量面板 ---${NC}"
        echo -e "1. 安装/重装 Web 面板"
        echo -e "2. 查看访问地址"
        echo -e "3. 重启服务"
        echo -e "4. 查看日志"
        echo -e "5. 卸载 Web 面板"
        echo -e "0. 返回"
        read -p "请选择: " OPT
        case $OPT in
            1) traffic_web_install ;;
            2) traffic_web_show_url ;;
            3) systemctl restart vps-traffic-web && echo "已重启" ;;
            4) journalctl -u vps-traffic-web -n 30 --no-pager ;;
            5) traffic_web_remove ;;
            0) break ;;
            *) echo "无效选择" ;;
        esac
    done
}

# --- 主菜单 ---

main_menu() {
    while true; do
        clear
        echo -e "${BLUE}=====================================${NC}"
        echo -e "   全能协议管理脚本 V3.3"
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
        echo -e "8. 流量监控 (命令行)"
        echo -e "9. Web 流量面板"
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
            9) manage_traffic_web_menu ;;
            0) exit 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

# --- 入口 ---
check_root
install_tools
main_menu
