#!/bin/bash

# =========================================================
# VFly - Multi-Protocol Manager V3.11
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
    if ! command -v jq &>/dev/null || ! command -v qrencode &>/dev/null || ! command -v python3 &>/dev/null; then
        echo -e "${BLUE}正在安装必要工具...${NC}"
        if command -v apt &>/dev/null; then
            apt update -y && apt install -y wget curl unzip vim jq qrencode openssl socat python3 python3-pip
        elif command -v yum &>/dev/null; then
            yum update -y && yum install -y wget curl unzip vim jq qrencode openssl socat python3 python3-pip
        elif command -v dnf &>/dev/null; then
            dnf update -y && dnf install -y wget curl unzip vim jq qrencode openssl socat python3 python3-pip
        fi
    fi
}

get_ip() {
    curl -s4m8 https://ip.gs || curl -s4m8 https://api.ipify.org
}

check_status() {
    if systemctl is-active --quiet "$1"; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
}

# --- 1. Reality 管理 (核心修复部分) ---

install_reality() {
    echo -e "${BLUE}>>> 安装/重置 Xray Reality...${NC}"
    if ! bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install; then
        echo -e "${RED}Xray 安装失败，请检查网络或稍后重试。${NC}"
        return 1
    fi

    mkdir -p /usr/local/etc/xray
    
    select_port "VLESS Reality"

    echo -e "${YELLOW}提示：443 端口让流量看起来像正常 HTTPS，隐蔽性最好；${NC}"
    echo -e "${YELLOW}      其他端口功能完全正常，但可能更容易被识别为代理流量。${NC}"

    while true; do
        read -p "请输入伪装域名 (SNI) [默认: griffithobservatory.org]: " SNI
        [[ -z "$SNI" ]] && SNI="griffithobservatory.org"
        if [[ "$SNI" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
            break
        else
            echo -e "${RED}无效域名格式，请重新输入（只允许字母、数字、点、连字符）${NC}"
        fi
    done

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
  "log": { "access": "/var/log/xray/access.log", "loglevel": "info" },
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
    # 收紧配置文件权限：640 + xray 运行组，防止低权限用户读取密钥
    local XRAY_GROUP="nobody"
    grep -q "^nogroup:" /etc/group && XRAY_GROUP="nogroup"
    chown root:"$XRAY_GROUP" "$XRAY_CONF"
    chmod 640 "$XRAY_CONF"
    # 保存公钥到文件以便后续查看
    echo "$PUB" > /usr/local/etc/xray/public.key
    chown root:"$XRAY_GROUP" /usr/local/etc/xray/public.key
    chmod 640 /usr/local/etc/xray/public.key

    if ! systemctl restart xray; then
        echo -e "${RED}Xray 服务启动失败，请查看日志: journalctl -u xray -n 20${NC}"
        return 1
    fi
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
    if ! wget -O /usr/local/bin/hysteria_server "https://github.com/apernet/hysteria/releases/download/${LATEST}/hysteria-linux-${HY_ARCH}"; then
        echo -e "${RED}Hysteria 2 下载失败，请检查网络或稍后重试。${NC}"
        return 1
    fi
    chmod +x /usr/local/bin/hysteria_server

    select_port "Hysteria 2 (UDP)"

    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -days 3650 -subj "/CN=bing.com" 2>/dev/null
    PASS=$(openssl rand -hex 16)

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
    
    local HY_GROUP="nobody"
    grep -q "nogroup" /etc/group && HY_GROUP="nogroup"
    chown -R nobody:"$HY_GROUP" /etc/hysteria

    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria_server server -c /etc/hysteria/config.yaml
Restart=always
User=nobody
Group=${HY_GROUP}
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-server
    if ! systemctl restart hysteria-server; then
        echo -e "${RED}Hysteria 2 服务启动失败，请查看日志: journalctl -u hysteria-server -n 20${NC}"
        return 1
    fi
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
    # 尝试动态获取最新版本号，失败时回退到已知稳定版本
    local SNELL_VER
    SNELL_VER=$(curl -fsSm5 https://dl.nssurge.com/snell/snell-server-latest-version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [[ -z "$SNELL_VER" ]] && SNELL_VER="v5.0.1"
    echo -e "${YELLOW}Snell 版本: ${SNELL_VER}${NC}"
    if [[ "$ARCH" == "x86_64" ]]; then
        URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VER}-linux-amd64.zip"
    else
        URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VER}-linux-aarch64.zip"
    fi
    if ! wget -O snell.zip "$URL"; then
        echo -e "${RED}Snell 下载失败，请检查网络或稍后重试。${NC}"
        return 1
    fi
    unzip -o snell.zip -d /usr/local/bin
    rm snell.zip
    chmod +x /usr/local/bin/snell-server
    
    mkdir -p /etc/snell
    PSK=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9')
    
    GROUP="nobody"
    grep -q "nogroup" /etc/group && GROUP="nogroup"

    cat > $SNELL_CONF <<EOF
[snell-server]
listen = 0.0.0.0:11807
psk = $PSK
ipv6 = false
EOF
    chown root:"$GROUP" "$SNELL_CONF"
    chmod 640 "$SNELL_CONF"

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
    if ! systemctl restart snell; then
        echo -e "${RED}Snell 服务启动失败，请查看日志: journalctl -u snell -n 20${NC}"
        return 1
    fi
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
    WEB_TOKEN=""
    WEB_PORT=""
    OFFSET_RX=0
    OFFSET_TX=0
    if [[ -f "$TRAFFIC_CONF" ]]; then
        local _val
        _val=$(grep -m1 '^QUOTA_GB=' "$TRAFFIC_CONF" | cut -d'=' -f2-)
        [[ "$_val" =~ ^[0-9]+$ ]] && QUOTA_GB="$_val"
        _val=$(grep -m1 '^RESET_DAY=' "$TRAFFIC_CONF" | cut -d'=' -f2-)
        [[ "$_val" =~ ^[0-9]+$ ]] && RESET_DAY="$_val"
        _val=$(grep -m1 '^ALERT_PCT=' "$TRAFFIC_CONF" | cut -d'=' -f2-)
        [[ "$_val" =~ ^[0-9]+$ ]] && ALERT_PCT="$_val"
        _val=$(grep -m1 '^WEB_TOKEN=' "$TRAFFIC_CONF" | cut -d'=' -f2-)
        [[ -n "$_val" ]] && WEB_TOKEN="$_val"
        _val=$(grep -m1 '^WEB_PORT=' "$TRAFFIC_CONF" | cut -d'=' -f2-)
        [[ "$_val" =~ ^[0-9]+$ ]] && WEB_PORT="$_val"
        _val=$(grep -m1 '^OFFSET_RX=' "$TRAFFIC_CONF" | cut -d'=' -f2-)
        [[ "$_val" =~ ^[0-9]+$ ]] && OFFSET_RX="$_val"
        _val=$(grep -m1 '^OFFSET_TX=' "$TRAFFIC_CONF" | cut -d'=' -f2-)
        [[ "$_val" =~ ^[0-9]+$ ]] && OFFSET_TX="$_val"
    fi
}

_traffic_save_conf() {
    cat > "$TRAFFIC_CONF" <<EOF
QUOTA_GB=${QUOTA_GB}
RESET_DAY=${RESET_DAY}
ALERT_PCT=${ALERT_PCT}
WEB_TOKEN=${WEB_TOKEN:-}
WEB_PORT=${WEB_PORT:-}
OFFSET_RX=${OFFSET_RX:-0}
OFFSET_TX=${OFFSET_TX:-0}
EOF
    chmod 600 "$TRAFFIC_CONF"
}

_traffic_setup_logrotate() {
    cat > /etc/logrotate.d/xray <<'EOF'
/var/log/xray/access.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
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

_traffic_install_conntrack() {
    if ! command -v conntrack &>/dev/null; then
        echo -e "${BLUE}正在安装 conntrack...${NC}"
        if command -v apt &>/dev/null; then
            apt install -y conntrack
        elif command -v yum &>/dev/null; then
            yum install -y conntrack-tools
        elif command -v dnf &>/dev/null; then
            dnf install -y conntrack-tools
        fi
    fi
    # 检查内核是否支持 conntrack
    if ! modinfo nf_conntrack &>/dev/null && ! lsmod | grep -q nf_conntrack; then
        echo -e "${RED}此系统内核不支持 nf_conntrack（可能是 OpenVZ/LXC），无法启用连接追踪。${NC}"
        return 1
    fi
    # 启用 conntrack 计数（默认关闭）
    sysctl -w net.netfilter.nf_conntrack_acct=1 &>/dev/null || true
    if ! grep -q "^net.netfilter.nf_conntrack_acct" /etc/sysctl.d/99-conntrack.conf 2>/dev/null; then
        echo "net.netfilter.nf_conntrack_acct=1" > /etc/sysctl.d/99-conntrack.conf
    fi
    echo -e "${GREEN}conntrack 就绪。${NC}"
}

_traffic_install_geoip() {
    local geoip_dir="/opt/vps-traffic-web/geoip"
    mkdir -p "$geoip_dir"
    echo -e "${BLUE}正在下载 GeoLite2-Country.mmdb...${NC}"
    local url="https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download/GeoLite2-Country.mmdb"
    if ! wget -qO "$geoip_dir/GeoLite2-Country.mmdb" "$url"; then
        echo -e "${RED}GeoIP 数据库下载失败，将跳过国家显示。${NC}"
        return 1
    fi
    # 安装 maxminddb python 库
    if ! python3 -c "import maxminddb" &>/dev/null; then
        # 优先用系统包管理（无需 --break-system-packages）
        if command -v apt-get &>/dev/null; then
            apt-get install -y python3-maxminddb &>/dev/null || true
        elif command -v yum &>/dev/null; then
            yum install -y python3-maxminddb &>/dev/null || true
        fi
        # 若系统包不存在，回退 pip（兼容 PEP 668 externally-managed 环境）
        if ! python3 -c "import maxminddb" &>/dev/null; then
            pip3 install maxminddb --quiet --break-system-packages 2>/dev/null || \
            pip3 install maxminddb --quiet 2>/dev/null || \
            pip install maxminddb --quiet 2>/dev/null || true
        fi
        if python3 -c "import maxminddb" &>/dev/null; then
            echo -e "${GREEN}maxminddb 安装成功。${NC}"
        else
            echo -e "${YELLOW}maxminddb 安装失败，国家显示将不可用。${NC}"
        fi
    fi
    echo -e "${GREEN}GeoIP 数据库就绪: $geoip_dir/GeoLite2-Country.mmdb${NC}"
}

_traffic_update_geoip() {
    echo -e "${YELLOW}正在更新 GeoIP 数据库...${NC}"
    _traffic_install_geoip
    # 重启采集器以加载新数据库
    systemctl is-active --quiet vps-traffic-collector && systemctl restart vps-traffic-collector
    echo -e "${GREEN}GeoIP 更新完成。${NC}"
}

_traffic_flows_cleanup_cron() {
    local cron_script="/usr/local/bin/vps-flows-cleanup.sh"
    cat > "$cron_script" <<'SCRIPT'
#!/bin/bash
DB="/var/lib/vps-traffic/flows.db"
[[ -f "$DB" ]] || exit 0
python3 - "$DB" <<'EOF'
import sys, sqlite3, time
db = sys.argv[1]
cutoff = int(time.time()) - 180 * 86400  # 6 个月
with sqlite3.connect(db) as conn:
    conn.execute("DELETE FROM flows WHERE ts < ?", (cutoff,))
    conn.execute("VACUUM")
EOF
logger -t vps-flows "cleanup: removed flows older than 6 months"
SCRIPT
    chmod +x "$cron_script"
    local cron_line="0 3 * * * $cron_script"
    if ! crontab -l 2>/dev/null | grep -qF "$cron_script"; then
        ( crontab -l 2>/dev/null; echo "$cron_line" ) | crontab -
    fi
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
    if [[ -n "$input" ]]; then
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 102400 )); then
            QUOTA_GB="$input"
        else
            echo -e "${YELLOW}无效值，保持当前配额 ${QUOTA_GB} GB${NC}"
        fi
    fi
    read -p "重置日 (1-28) [当前: ${RESET_DAY}, 回车跳过]: " input
    if [[ -n "$input" ]]; then
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 28 )); then
            RESET_DAY="$input"
        else
            echo -e "${YELLOW}无效值，保持当前重置日 ${RESET_DAY}${NC}"
        fi
    fi
    read -p "告警阈值 % [当前: ${ALERT_PCT}, 回车跳过]: " input
    if [[ -n "$input" ]]; then
        if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= 100 )); then
            ALERT_PCT="$input"
        else
            echo -e "${YELLOW}无效值，保持当前阈值 ${ALERT_PCT}%${NC}"
        fi
    fi
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
    local changed=0
    if ! grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        changed=1
    fi
    if ! grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        changed=1
    fi
    if (( changed == 0 )); then
        echo -e "${GREEN}BBR 配置已存在，正在刷新...${NC}"
    fi
    sysctl -p
    RESULT=$(sysctl net.ipv4.tcp_congestion_control)
    echo -e "当前状态: ${GREEN}$RESULT${NC}"
}

# --- 5. IPv6 管理 ---

disable_ipv6() {
    echo -e "${BLUE}>>> 禁用 IPv6...${NC}"
    local conf="/etc/sysctl.d/99-disable-ipv6.conf"
    cat > "$conf" <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 &>/dev/null
    sysctl -w net.ipv6.conf.lo.disable_ipv6=1 &>/dev/null
    echo -e "${GREEN}IPv6 已禁用（立即生效 + 重启持久化）${NC}"
    # 重启各协议服务，使其重新绑定到纯 IPv4
    for svc in xray hysteria-server snell; do
        if systemctl is-active "$svc" &>/dev/null; then
            systemctl restart "$svc" &>/dev/null && \
                echo -e "  已重启 ${CYAN}${svc}${NC}"
        fi
    done
    echo -e "${YELLOW}当前 IPv6 地址列表（应为空）:${NC}"
    ip -6 addr show scope global 2>/dev/null || echo "  (无)"
}

enable_ipv6() {
    echo -e "${BLUE}>>> 启用 IPv6...${NC}"
    rm -f /etc/sysctl.d/99-disable-ipv6.conf
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 &>/dev/null
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 &>/dev/null
    echo -e "${GREEN}IPv6 已启用（重启后生效）${NC}"
}

ipv6_status() {
    local state
    state=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    if [[ "$state" == "1" ]]; then
        echo -e "${YELLOW}IPv6 状态: 已禁用${NC}"
    else
        echo -e "${GREEN}IPv6 状态: 已启用${NC}"
        ip -6 addr show scope global 2>/dev/null | grep "inet6" | awk '{print "  "$2}'
    fi
}

# --- 6. Web 流量面板 ---

_traffic_install_collector() {
    local iface="$1"
    mkdir -p /var/lib/vps-traffic
    mkdir -p /opt/vps-traffic-web

    cat > /opt/vps-traffic-web/collector.py <<'PYEOF'
#!/usr/bin/env python3
"""
VPS 流量采集器 - 双数据源：Xray access.log + conntrack -E
"""
import re, socket, subprocess, sqlite3, time, threading, json, os, logging
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor

DB_PATH    = "/var/lib/vps-traffic/flows.db"
XRAY_LOG   = "/var/log/xray/access.log"
GEOIP_PATH = "/opt/vps-traffic-web/geoip/GeoLite2-Country.mmdb"
FILTER_PORTS = {22, 53}          # 过滤 SSH 和 DNS 噪音
RDNS_WORKERS = 8                  # rDNS 有界线程池大小
MATCH_WINDOW = 15                # Xray log 与 conntrack 匹配时间窗（秒，无 conntrack 时快速落库）
BATCH_INTERVAL = 5               # 批量写库间隔（秒）
RDNS_TTL   = 86400               # rDNS 缓存 TTL（秒）
RDNS_RATE  = 10                  # rDNS 每秒最多查询次数

# ---- 协议端口自动检测 ----
def detect_proto_ports():
    """从现有配置文件中读取各协议监听端口，返回 {port: 'protocol_name'} 映射"""
    ports = {}
    # Reality / VLESS (Xray)
    try:
        with open("/usr/local/etc/xray/config.json") as f:
            cfg = json.load(f)
            for inb in cfg.get("inbounds", []):
                if inb.get("protocol") in ("vless", "vmess"):
                    ports[inb["port"]] = "reality"
    except Exception:
        pass
    # Hysteria2
    try:
        with open("/etc/hysteria/config.yaml") as f:
            for line in f:
                if line.strip().startswith("listen:"):
                    # listen: :443  or  listen: 0.0.0.0:443
                    part = line.split(":")[-1].strip()
                    if part.isdigit():
                        ports[int(part)] = "hysteria2"
                    break
    except Exception:
        pass
    # Snell (config format: listen = 0.0.0.0:PORT)
    try:
        with open("/etc/snell/snell-server.conf") as f:
            for line in f:
                line = line.strip()
                if line.startswith("listen") and "=" in line:
                    val = line.split("=", 1)[1].strip()
                    if ":" in val:
                        port_s = val.rsplit(":", 1)[1]
                        if port_s.isdigit():
                            ports[int(port_s)] = "snell"
    except Exception:
        pass
    return ports

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("collector")

PROTO_PORTS = detect_proto_ports()
log.info("协议端口映射: %s", PROTO_PORTS)

# ---- GeoIP ----
try:
    import maxminddb
    _geo_db = maxminddb.open_database(GEOIP_PATH)
    def geoip(ip):
        try:
            r = _geo_db.get(ip)
            return r["country"]["iso_code"] if r else None
        except Exception:
            return None
except Exception:
    def geoip(ip): return None
    log.warning("maxminddb 未安装或 GeoIP 数据库不存在，国家字段将为空")

# ---- 获取本机 IP 列表 ----
def get_local_ips():
    try:
        out = subprocess.check_output(["ip", "-j", "addr"], text=True)
        data = json.loads(out)
        ips = set()
        for iface in data:
            for addr in iface.get("addr_info", []):
                ips.add(addr["local"])
        return ips
    except Exception:
        return {"127.0.0.1"}

LOCAL_IPS = get_local_ips()

# ---- rDNS 缓存 ----
_rdns_mem = OrderedDict()
_rdns_lock = threading.Lock()
_rdns_pool = ThreadPoolExecutor(max_workers=RDNS_WORKERS, thread_name_prefix="rdns")

def rdns_lookup(ip):
    now = int(time.time())
    with _rdns_lock:
        if ip in _rdns_mem:
            host, ts = _rdns_mem[ip]
            if now - ts < RDNS_TTL:
                return host
    # 检查 SQLite 缓存
    try:
        with sqlite3.connect(DB_PATH, timeout=10) as conn:
            row = conn.execute("SELECT host, updated FROM rdns_cache WHERE ip=?", (ip,)).fetchone()
            if row and now - row[1] < RDNS_TTL:
                with _rdns_lock:
                    _rdns_mem[ip] = (row[0], row[1])
                return row[0]
    except Exception:
        pass
    # 实际查询（在调用方的线程池中执行，此处直接同步调用）
    try:
        host = socket.gethostbyaddr(ip)[0]
    except Exception:
        host = None
    # 写缓存
    try:
        with sqlite3.connect(DB_PATH, timeout=10) as conn:
            conn.execute("INSERT OR REPLACE INTO rdns_cache VALUES (?,?,?)", (ip, host, now))
    except Exception:
        pass
    with _rdns_lock:
        _rdns_mem[ip] = (host, now)
        if len(_rdns_mem) > 5000:
            _rdns_mem.popitem(last=False)
    return host

# ---- SQLite 初始化 ----
def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with sqlite3.connect(DB_PATH) as conn:
        conn.executescript("""
PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS flows (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  ts         INTEGER NOT NULL,
  proto      TEXT,
  direction  TEXT,
  src_ip     TEXT, src_port INTEGER,
  dst_ip     TEXT, dst_port INTEGER,
  bytes_up   INTEGER,
  bytes_down INTEGER,
  country    TEXT,
  host       TEXT,
  protocol   TEXT
);
CREATE INDEX IF NOT EXISTS idx_flows_ts       ON flows(ts);
CREATE INDEX IF NOT EXISTS idx_flows_country  ON flows(country);
CREATE INDEX IF NOT EXISTS idx_flows_dst_ip   ON flows(dst_ip);
CREATE INDEX IF NOT EXISTS idx_flows_src_ip   ON flows(src_ip);
CREATE INDEX IF NOT EXISTS idx_flows_protocol ON flows(protocol);
CREATE TABLE IF NOT EXISTS rdns_cache (
  ip      TEXT PRIMARY KEY,
  host    TEXT,
  updated INTEGER
);
""")
        # 迁移旧数据库：若缺少 protocol 列则添加
        cols = [r[1] for r in conn.execute("PRAGMA table_info(flows)").fetchall()]
        if "protocol" not in cols:
            conn.execute("ALTER TABLE flows ADD COLUMN protocol TEXT")
            log.info("数据库已迁移：flows 表新增 protocol 列")

# ---- 批量写队列 ----
_write_queue = []
_write_lock  = threading.Lock()

def enqueue(row):
    with _write_lock:
        _write_queue.append(row)

def flush_writer():
    while True:
        time.sleep(BATCH_INTERVAL)
        with _write_lock:
            if not _write_queue:
                continue
            batch = _write_queue[:]
            _write_queue.clear()
        try:
            with sqlite3.connect(DB_PATH, timeout=30) as conn:
                conn.executemany(
                    "INSERT INTO flows (ts,proto,direction,src_ip,src_port,dst_ip,dst_port,bytes_up,bytes_down,country,host,protocol) "
                    "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", batch)
        except Exception as e:
            log.error("DB write error: %s", e)

# ---- Xray 日志解析 ----
# 格式: 2026/04/09 13:37:24.984632 from 1.2.3.4:54321 accepted tcp:host:443 [tag]
# 时间戳含微秒 .xxxxxx，用 (?:\.\d+)? 兼容
_xray_re = re.compile(
    r"(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})(?:\.\d+)? from ([\d.a-fA-F:]+):(\d+) accepted \w+:([\w\.\-\[\]:]+):(\d+)"
)
# 挂起的 Xray 事件，等待 conntrack 提供字节数
# key: (src_ip, src_port, dst_port)  value: [ts, direction, src_ip, src_port, dst_ip, dst_port, country, host, expire_time]
_xray_pending = {}
_xray_lock = threading.Lock()

def xray_log_reader():
    """tail -F Xray access.log，逐行解析"""
    while True:
        try:
            proc = subprocess.Popen(["tail", "-F", "-n", "0", XRAY_LOG],
                                    stdout=subprocess.PIPE, text=True)
            for line in proc.stdout:
                m = _xray_re.search(line)
                if not m:
                    continue
                ts_str, src_ip, src_port_s, dst_host, dst_port_s = m.groups()
                src_port = int(src_port_s)
                dst_port = int(dst_port_s)
                if dst_port in FILTER_PORTS:
                    continue
                ts = int(time.mktime(time.strptime(ts_str, "%Y/%m/%d %H:%M:%S")))
                # 方向：入站（客户端 -> 本机）
                direction = "in"
                peer_ip = src_ip
                country = geoip(peer_ip)
                # dst_host 可能是域名或 IP
                host = dst_host if not dst_host.replace(".", "").isdigit() else None
                dst_ip = dst_host if dst_host.replace(".", "").isdigit() else None
                key = (src_ip, src_port, dst_port)
                expire = time.time() + MATCH_WINDOW
                with _xray_lock:
                    _xray_pending[key] = [ts, "in", src_ip, src_port,
                                          dst_ip or "", dst_port,
                                          country, host or dst_host, expire, "reality"]
        except Exception as e:
            log.warning("xray_log_reader error: %s", e)
            time.sleep(5)

def xray_pending_reaper():
    """定期将超时未匹配的 Xray 事件直接写库（bytes=NULL）"""
    while True:
        time.sleep(10)
        now = time.time()
        expired = []
        with _xray_lock:
            for key, val in list(_xray_pending.items()):
                if now > val[8]:
                    expired.append((key, val))
                    del _xray_pending[key]
        for key, val in expired:
            ts, direction, src_ip, src_port, dst_ip, dst_port, country, host, _, protocol = val
            enqueue((ts, "tcp", direction, src_ip, src_port, dst_ip, dst_port, None, None, country, host, protocol))

# ---- conntrack 轮询（替代 conntrack -E，兼容不支持事件推送的环境）----
# 每 POLL_INTERVAL 秒读取 /proc/net/nf_conntrack，对消失的连接触发记录
# nf_conntrack_acct=1 时每行有两组 bytes= 字段（orig/reply 方向）
CT_FILE = "/proc/net/nf_conntrack"
POLL_INTERVAL = 3   # 秒，越小越实时但 CPU 略高
_ct_src_re  = re.compile(r"src=([\d.]+)\s+dst=([\d.]+)\s+sport=(\d+)\s+dport=(\d+)")
_ct_bytes_re = re.compile(r"bytes=(\d+)")
_ct_proto_re = re.compile(r"^\S+\s+\d+\s+(\w+)")

def _parse_ct_line(line):
    """返回 (proto, src_ip, dst_ip, sport, dport, bytes_orig, bytes_reply) 或 None"""
    pm = _ct_proto_re.match(line)
    if not pm:
        return None
    proto = pm.group(1)
    pairs = _ct_src_re.findall(line)
    if not pairs:
        return None
    src_ip, dst_ip, sport_s, dport_s = pairs[0]   # 原始方向
    sport, dport = int(sport_s), int(dport_s)
    bvals = _ct_bytes_re.findall(line)
    bytes_orig  = int(bvals[0]) if len(bvals) > 0 else 0
    bytes_reply = int(bvals[1]) if len(bvals) > 1 else 0
    return proto, src_ip, dst_ip, sport, dport, bytes_orig, bytes_reply

def _handle_gone_conn(proto, src_ip, dst_ip, sport, dport, bytes_orig, bytes_reply, first_ts):
    """连接消失时处理：匹配 Xray pending 或走 rDNS"""
    if dst_ip in LOCAL_IPS:
        direction, peer_ip = "in",  src_ip
        bytes_up, bytes_down = bytes_orig, bytes_reply
    else:
        direction, peer_ip = "out", dst_ip
        bytes_up, bytes_down = bytes_orig, bytes_reply

    xray_key = (src_ip, sport, dport)
    matched = None
    with _xray_lock:
        if xray_key in _xray_pending:
            matched = _xray_pending.pop(xray_key)

    if matched:
        _, _, _, _, xdst_ip, _, country, host, _, protocol = matched
        enqueue((first_ts, proto, direction, src_ip, sport,
                 xdst_ip or dst_ip, dport, bytes_up, bytes_down, country, host, protocol))
    else:
        country  = geoip(peer_ip)
        # 出站连接 sport 是本机随机端口，无法靠端口猜协议，留 None
        protocol = PROTO_PORTS.get(dport) if direction == "in" else None
        def do_rdns(ts=first_ts, proto=proto, direction=direction,
                    src_ip=src_ip, sport=sport, dst_ip=dst_ip, dport=dport,
                    bytes_up=bytes_up, bytes_down=bytes_down,
                    country=country, peer_ip=peer_ip, protocol=protocol):
            host = rdns_lookup(peer_ip)
            enqueue((ts, proto, direction, src_ip, sport, dst_ip, dport,
                     bytes_up, bytes_down, country, host, protocol))
        _rdns_pool.submit(do_rdns)

# ---- Hysteria2 日志解析（获取目标域名 + 标注协议）----
# Hysteria2 v2 使用结构化 JSON 日志，格式：
#   TIMESTAMP  INFO  TCP request  {"addr":"1.2.3.4:PORT","reqAddr":"domain:PORT",...}
#   TIMESTAMP  WARN  TCP error    {"addr":"1.2.3.4:PORT","reqAddr":"domain:PORT",...}
# 用 reqAddr 字段匹配目标域名（包含 request 和 error 两种情况都有目标地址）
_hy2_re = re.compile(
    r'"addr":\s*"([\d.a-fA-F\[\]:]+):(\d+)".*?"reqAddr":\s*"([^"]+):(\d+)"'
)

def hy2_log_reader():
    """从 journald 流式读取 Hysteria2 server 日志，提取目标域名写入 pending。
    Hysteria2 v2 的 MESSAGE 是 bytes 数组（journald JSON 格式），需用 --output=json 解码。"""
    import json as _json
    while True:
        try:
            proc = subprocess.Popen(
                ["journalctl", "-u", "hysteria-server", "-f", "-n", "0", "--output", "json"],
                stdout=subprocess.PIPE, text=True)
            for line in proc.stdout:
                try:
                    entry = _json.loads(line)
                except Exception:
                    continue
                msg = entry.get("MESSAGE", "")
                if isinstance(msg, list):
                    # journald 将二进制日志存为 int 数组
                    try:
                        msg = bytes(msg).decode("utf-8", errors="replace")
                    except Exception:
                        continue
                if not isinstance(msg, str):
                    continue
                m = _hy2_re.search(msg)
                if not m:
                    continue
                src_ip, src_port_s, dst_host, dst_port_s = m.groups()
                src_port = int(src_port_s)
                dst_port = int(dst_port_s)
                if dst_port in FILTER_PORTS:
                    continue
                ts = int(time.time())
                country = geoip(src_ip)
                # dst_host 为纯 IP 时不当 host
                is_ip = dst_host.replace(".", "").replace(":", "").isdigit()
                host   = None if is_ip else dst_host
                dst_ip = dst_host if is_ip else None
                key = (src_ip, src_port, dst_port)
                expire = time.time() + MATCH_WINDOW
                with _xray_lock:
                    _xray_pending[key] = [ts, "in", src_ip, src_port,
                                          dst_ip or "", dst_port,
                                          country, host or dst_host, expire, "hysteria2"]
        except FileNotFoundError:
            # journalctl 不存在或 hysteria-server unit 不存在，静默退出
            log.info("hy2_log_reader: journalctl 不可用或 hysteria-server 未安装，跳过")
            return
        except Exception as e:
            log.warning("hy2_log_reader error: %s", e)
            time.sleep(5)

def ss_poller():
    """ss-based 连接追踪（conntrack 不可用时的降级方案，不统计字节数）"""
    log.info("ss 轮询模式启动 (conntrack 不可用，间隔 %ds)", POLL_INTERVAL)
    active = {}  # key(local_ip, local_port, peer_ip, peer_port) -> first_ts
    while True:
        try:
            out = subprocess.check_output(
                ["ss", "-tnH", "state", "established"],
                text=True, timeout=5
            )
            current = set()
            for line in out.splitlines():
                parts = line.split()
                if len(parts) < 4:
                    continue
                # ss -tnH state established: RecvQ SendQ Local:Port Peer:Port
                local = parts[2]
                peer  = parts[3]
                try:
                    lcolon = local.rfind(":")
                    pcolon = peer.rfind(":")
                    local_ip   = local[:lcolon]
                    local_port = int(local[lcolon+1:])
                    peer_ip    = peer[:pcolon]
                    peer_port  = int(peer[pcolon+1:])
                except (ValueError, IndexError):
                    continue
                if local_port in FILTER_PORTS or peer_port in FILTER_PORTS:
                    continue
                key = (local_ip, local_port, peer_ip, peer_port)
                current.add(key)
                if key not in active:
                    active[key] = int(time.time())

            # 消失的连接 → 记录（字节数为 0，依赖 xray/hy2 pending 补充域名）
            for key in list(active):
                if key not in current:
                    fts = active.pop(key)
                    local_ip, local_port, peer_ip, peer_port = key
                    if local_port in PROTO_PORTS:
                        # 入站：peer 是客户端
                        _handle_gone_conn("tcp", peer_ip, local_ip,
                                          peer_port, local_port, 0, 0, fts)
                    else:
                        # 出站：local_port 是本机随机端口
                        _handle_gone_conn("tcp", local_ip, peer_ip,
                                          local_port, peer_port, 0, 0, fts)
        except Exception as e:
            log.warning("ss_poller error: %s", e)
        time.sleep(POLL_INTERVAL)

def conntrack_poller():
    """主采集循环：轮询 /proc/net/nf_conntrack，连接消失即记录。
    若 conntrack 表持续为空（内核不走 netfilter），自动切换到 ss_poller()。"""
    active = {}   # key(proto,src,dst,sport,dport) -> (bytes_orig, bytes_reply, first_ts)
    if not os.path.exists(CT_FILE):
        log.warning("conntrack 表 %s 不存在，切换到 ss 模式", CT_FILE)
        ss_poller()
        return
    log.info("conntrack 轮询模式启动 (间隔 %ds)", POLL_INTERVAL)
    empty_streak = 0
    while True:
        try:
            with open(CT_FILE) as f:
                lines = f.readlines()

            # 检测 conntrack 是否实际工作
            if not lines:
                empty_streak += 1
                if empty_streak >= 5:
                    log.warning("conntrack 表持续为空 (%d次)，切换到 ss 模式", empty_streak)
                    ss_poller()
                    return
                time.sleep(POLL_INTERVAL)
                continue
            else:
                empty_streak = 0

            current = set()
            for line in lines:
                parsed = _parse_ct_line(line)
                if not parsed:
                    continue
                proto, src_ip, dst_ip, sport, dport, bo, br = parsed
                if sport in FILTER_PORTS or dport in FILTER_PORTS:
                    continue
                key = (proto, src_ip, dst_ip, sport, dport)
                current.add(key)
                if key not in active:
                    active[key] = (bo, br, int(time.time()))
                else:
                    _, _, fts = active[key]
                    active[key] = (bo, br, fts)   # 更新字节数

            # 消失的连接
            for key in list(active):
                if key not in current:
                    proto, src_ip, dst_ip, sport, dport = key
                    bo, br, fts = active.pop(key)
                    _handle_gone_conn(proto, src_ip, dst_ip, sport, dport, bo, br, fts)

        except Exception as e:
            log.warning("conntrack_poller error: %s", e)
        time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    init_db()
    log.info("VPS 流量采集器启动 (DB: %s)", DB_PATH)
    threading.Thread(target=flush_writer,         daemon=True).start()
    threading.Thread(target=xray_log_reader,      daemon=True).start()
    threading.Thread(target=hy2_log_reader,       daemon=True).start()
    threading.Thread(target=xray_pending_reaper,  daemon=True).start()
    threading.Thread(target=conntrack_poller,     daemon=True).start()
    # 主线程保活
    while True:
        time.sleep(60)
PYEOF

    cat > /etc/systemd/system/vps-traffic-collector.service <<EOF
[Unit]
Description=VPS Traffic Collector (conntrack + Xray log)
After=network.target xray.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/vps-traffic-web/collector.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable vps-traffic-collector
    if ! systemctl restart vps-traffic-collector; then
        echo -e "${RED}采集器启动失败，请查看日志: journalctl -u vps-traffic-collector -n 30${NC}"
        return 1
    fi
    echo -e "${GREEN}流量采集器已启动。${NC}"
}

_web_write_server() {
    local iface="$1" quota_gb="$2" reset_day="$3" alert_pct="$4" token="$5"
    local offset_rx="${OFFSET_RX:-0}" offset_tx="${OFFSET_TX:-0}"
    mkdir -p "$TRAFFIC_WEB_DIR"

    # Phase A: bash 变量插值（仅写入配置常量，不含 JS 模板字符串）
    cat > "$TRAFFIC_WEB_DIR/server.py" <<EOF
#!/usr/bin/env python3
IFACE     = "${iface}"
QUOTA_GB  = ${quota_gb}
RESET_DAY = ${reset_day}
ALERT_PCT = ${alert_pct}
TOKEN     = "${token}"
PORT      = ${TRAFFIC_WEB_PORT}
# 本月已消耗基准（字节），叠加到 vnstat 读数之上
OFFSET_RX = ${offset_rx}
OFFSET_TX = ${offset_tx}
EOF

    # Phase B: 不插值（单引号 heredoc，JS 模板字符串安全）
    cat >> "$TRAFFIC_WEB_DIR/server.py" <<'PYEOF'
import http.server, json, subprocess, os, urllib.parse, hmac, sqlite3, re

import secrets

# ---- vnstat helpers ----
def vnstat_json(mode):
    try:
        r = subprocess.run(["vnstat", "-i", IFACE, "--json", mode],
                           capture_output=True, text=True, timeout=10)
        return json.loads(r.stdout)
    except Exception:
        return {}

def get_month_data():
    d = vnstat_json("m")
    try:
        cur = d["interfaces"][0]["traffic"]["month"][-1]
        return cur.get("rx", 0), cur.get("tx", 0)
    except Exception:
        return 0, 0

def get_day_data(n=30):
    d = vnstat_json("d")
    try:
        days = d["interfaces"][0]["traffic"]["day"][-n:]
        return [{"date": f"{x['date']['year']}-{x['date']['month']:02d}-{x['date']['day']:02d}",
                 "rx": x.get("rx", 0), "tx": x.get("tx", 0)} for x in days]
    except Exception:
        return []

def get_all_months():
    d = vnstat_json("m")
    try:
        months = d["interfaces"][0]["traffic"]["month"]
        return [{"month": f"{m['date']['year']}-{m['date']['month']:02d}",
                 "rx": m.get("rx", 0), "tx": m.get("tx", 0)} for m in months]
    except Exception:
        return []

# (old single-panel HTML removed — replaced by HTML below)

DB_PATH = "/var/lib/vps-traffic/flows.db"

RANGE_MAP = {
    "today": "strftime('%s','now','start of day')",
    "7d":    "strftime('%s','now','-7 days')",
    "30d":   "strftime('%s','now','-30 days')",
    "6m":    "strftime('%s','now','-6 months')",
}

def db_conn():
    import sqlite3
    if not os.path.exists(DB_PATH):
        return None
    try:
        conn = sqlite3.connect(DB_PATH, timeout=5)
        conn.row_factory = sqlite3.Row
        return conn
    except Exception:
        return None

def _safe_clause(val, col):
    """生成 AND col='val' 子句，仅允许字母数字"""
    if val and re.match(r'^[a-zA-Z0-9_-]+$', val):
        return f"AND {col}='{val}'"
    return ""

def flows_summary(range_key="7d", direction=None, protocol=None):
    since_expr = RANGE_MAP.get(range_key, RANGE_MAP["7d"])
    conn = db_conn()
    if not conn:
        return {"connections": 0, "bytes_up": 0, "bytes_down": 0}
    extra = _safe_clause(direction, "direction") + _safe_clause(protocol, "protocol")
    try:
        row = conn.execute(
            f"SELECT COUNT(*) as c, COALESCE(SUM(bytes_up),0) as bu, COALESCE(SUM(bytes_down),0) as bd "
            f"FROM flows WHERE ts >= {since_expr} {extra}"
        ).fetchone()
        return {"connections": row["c"], "bytes_up": row["bu"], "bytes_down": row["bd"]}
    except Exception:
        return {"connections": 0, "bytes_up": 0, "bytes_down": 0}
    finally:
        conn.close()

def flows_top(field="host", range_key="7d", direction=None, limit=30, protocol=None):
    since_expr = RANGE_MAP.get(range_key, RANGE_MAP["7d"])
    conn = db_conn()
    if not conn:
        return []
    # 安全白名单
    allowed = {"host": "COALESCE(host, dst_ip)", "dst_ip": "dst_ip",
               "src_ip": "src_ip", "country": "country", "protocol": "protocol"}
    expr = allowed.get(field, "COALESCE(host, dst_ip)")
    extra = _safe_clause(direction, "direction") + _safe_clause(protocol, "protocol")
    try:
        rows = conn.execute(
            f"SELECT {expr} as label, COUNT(*) as cnt, "
            f"COALESCE(SUM(bytes_up),0)+COALESCE(SUM(bytes_down),0) as total_bytes "
            f"FROM flows WHERE ts >= {since_expr} AND {expr} IS NOT NULL {extra} "
            f"GROUP BY label ORDER BY total_bytes DESC LIMIT ?", (limit,)
        ).fetchall()
        return [{"label": r["label"], "cnt": r["cnt"], "bytes": r["total_bytes"]} for r in rows]
    except Exception:
        return []
    finally:
        conn.close()

def flows_timeline(range_key="7d", bucket="day", direction=None, protocol=None):
    since_expr = RANGE_MAP.get(range_key, RANGE_MAP["7d"])
    conn = db_conn()
    if not conn:
        return []
    tfmt = "%Y-%m-%d" if bucket == "day" else "%Y-%m-%d %H:00"
    extra = _safe_clause(direction, "direction") + _safe_clause(protocol, "protocol")
    try:
        rows = conn.execute(
            f"SELECT strftime('{tfmt}', ts, 'unixepoch', 'localtime') as t, "
            f"COALESCE(SUM(bytes_up),0)+COALESCE(SUM(bytes_down),0) as bytes, COUNT(*) as cnt "
            f"FROM flows WHERE ts >= {since_expr} {extra} "
            f"GROUP BY t ORDER BY t"
        ).fetchall()
        return [{"t": r["t"], "bytes": r["bytes"], "cnt": r["cnt"]} for r in rows]
    except Exception:
        return []
    finally:
        conn.close()

def flows_recent(limit=100):
    conn = db_conn()
    if not conn:
        return []
    try:
        rows = conn.execute(
            "SELECT ts, proto, direction, src_ip, src_port, dst_ip, dst_port, "
            "bytes_up, bytes_down, country, host, protocol FROM flows ORDER BY ts DESC LIMIT ?", (limit,)
        ).fetchall()
        return [dict(r) for r in rows]
    except Exception:
        return []
    finally:
        conn.close()

def flows_by_protocol(range_key="7d"):
    """返回各协议的流量统计 {protocol: {connections, bytes_up, bytes_down}}"""
    since_expr = RANGE_MAP.get(range_key, RANGE_MAP["7d"])
    conn = db_conn()
    if not conn:
        return []
    try:
        rows = conn.execute(
            f"SELECT COALESCE(protocol,'其他') as p, COUNT(*) as c, "
            f"COALESCE(SUM(bytes_up),0) as bu, COALESCE(SUM(bytes_down),0) as bd "
            f"FROM flows WHERE ts >= {since_expr} "
            f"GROUP BY p ORDER BY bu+bd DESC"
        ).fetchall()
        return [{"protocol": r["p"], "connections": r["c"],
                 "bytes_up": r["bu"], "bytes_down": r["bd"]} for r in rows]
    except Exception:
        return []
    finally:
        conn.close()

HTML = r"""<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>VPS 流量监控</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
:root{
  --bg:#0f172a;--surface:#1e293b;--surface2:#263348;--border:#334155;
  --text:#e2e8f0;--text-sub:#94a3b8;--text-muted:#64748b;
  --accent:#6366f1;--sidebar-w:220px;
}
html.light{
  --bg:#f1f5f9;--surface:#ffffff;--surface2:#f8fafc;--border:#e2e8f0;
  --text:#0f172a;--text-sub:#475569;--text-muted:#94a3b8;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:'Segoe UI',system-ui,sans-serif;display:flex;min-height:100vh;transition:background .3s,color .3s}
#sidebar{width:var(--sidebar-w);background:var(--surface);border-right:1px solid var(--border);display:flex;flex-direction:column;flex-shrink:0;transition:transform .3s,background .3s}
.sidebar-logo{padding:18px 16px 14px;border-bottom:1px solid var(--border);font-weight:700;font-size:.95rem;color:var(--text);display:flex;align-items:center;gap:8px}
.nav-section{padding:12px 12px 4px;font-size:.65rem;text-transform:uppercase;letter-spacing:.1em;color:var(--text-muted);font-weight:600}
.nav-item{display:flex;align-items:center;gap:10px;padding:8px 14px;border-radius:8px;margin:1px 8px;cursor:pointer;font-size:.86rem;color:var(--text-sub);transition:all .15s;border:none;background:none;width:calc(100% - 16px);text-align:left}
.nav-item:hover{background:var(--surface2);color:var(--text)}
.nav-item.active{background:var(--accent);color:#fff;font-weight:600}
.nav-item .icon{font-size:.95rem;width:18px;text-align:center;flex-shrink:0}
.sidebar-footer{margin-top:auto;padding:10px 14px;border-top:1px solid var(--border);display:flex;align-items:center;justify-content:space-between}
.theme-btn{background:none;border:1px solid var(--border);color:var(--text-sub);padding:4px 10px;border-radius:6px;cursor:pointer;font-size:.78rem;transition:all .15s}
.theme-btn:hover{background:var(--surface2);color:var(--text)}
#main{flex:1;display:flex;flex-direction:column;min-width:0}
#topbar{height:52px;border-bottom:1px solid var(--border);display:flex;align-items:center;padding:0 20px;gap:10px;background:var(--surface);flex-shrink:0;transition:background .3s}
.hamburger{display:none;background:none;border:none;color:var(--text);cursor:pointer;font-size:1.3rem;padding:4px}
.topbar-title{font-weight:600;font-size:.95rem;color:var(--text)}
.topbar-sub{font-size:.75rem;color:var(--text-muted);margin-left:auto}
#content{flex:1;padding:20px;overflow-y:auto}
.panel{display:none}.panel.active{display:block}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px;margin-bottom:18px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:18px;transition:background .3s}
.card h3{font-size:.72rem;color:var(--text-muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:10px;font-weight:600}
.big{font-size:1.9rem;font-weight:700;color:var(--text)}
.sub{font-size:.76rem;color:var(--text-muted);margin-top:4px}
.bar-wrap{background:var(--bg);border-radius:999px;height:7px;margin:10px 0}
.bar{height:7px;border-radius:999px;transition:width .5s}
.bar.green{background:linear-gradient(90deg,#22c55e,#4ade80)}
.bar.yellow{background:linear-gradient(90deg,#eab308,#facc15)}
.bar.red{background:linear-gradient(90deg,#ef4444,#f87171)}
.stat-row{display:flex;justify-content:space-between;font-size:.8rem;margin-top:5px;color:var(--text-sub)}
.stat-val{color:var(--text);font-weight:600}
.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:.7rem;font-weight:600}
.badge.ok{background:#166534;color:#86efac}.badge.warn{background:#713f12;color:#fde68a}.badge.crit{background:#7f1d1d;color:#fca5a5}
.chart-card{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:18px;margin-bottom:14px;transition:background .3s}
.chart-card h3{font-size:.72rem;color:var(--text-muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:14px;font-weight:600}
table{width:100%;border-collapse:collapse;font-size:.81rem}
th{text-align:left;padding:8px 10px;color:var(--text-muted);border-bottom:1px solid var(--border);font-weight:500;font-size:.72rem}
td{padding:7px 10px;border-bottom:1px solid var(--border);color:var(--text-sub)}
tr:last-child td{border-bottom:none}
tr:hover td{background:var(--surface2)}
.bytes-bar{display:inline-block;height:4px;background:var(--accent);border-radius:2px;vertical-align:middle;margin-left:8px;opacity:.7}
.dir-in{color:#34d399;font-weight:600}.dir-out{color:#60a5fa;font-weight:600}
.range-bar{display:flex;gap:6px;margin-bottom:14px;flex-wrap:wrap;align-items:center}
.range-label{font-size:.76rem;color:var(--text-muted)}
.range-btn{padding:4px 11px;border-radius:6px;font-size:.76rem;cursor:pointer;border:1px solid var(--border);background:transparent;color:var(--text-muted);transition:all .15s}
.range-btn.active,.range-btn:hover{background:var(--surface2);color:var(--text);border-color:var(--accent)}
.two-col{display:grid;grid-template-columns:1fr 1fr;gap:14px;margin-bottom:14px}
#login-overlay{position:fixed;inset:0;background:rgba(0,0,0,.75);backdrop-filter:blur(6px);display:flex;align-items:center;justify-content:center;z-index:9999}
#login-box{background:var(--surface);border:1px solid var(--border);border-radius:16px;padding:36px;width:340px;max-width:90vw}
#login-box h2{font-size:1.15rem;font-weight:700;color:var(--text);margin-bottom:6px}
#login-box p{font-size:.82rem;color:var(--text-muted);margin-bottom:22px}
#login-box input{width:100%;padding:10px 14px;background:var(--bg);border:1px solid var(--border);border-radius:8px;color:var(--text);font-size:.88rem;outline:none;margin-bottom:10px}
#login-box input:focus{border-color:var(--accent)}
#login-btn{width:100%;padding:10px;background:var(--accent);color:#fff;border:none;border-radius:8px;font-size:.88rem;font-weight:600;cursor:pointer;transition:opacity .15s}
#login-btn:hover{opacity:.9}
#login-err{font-size:.78rem;color:#f87171;margin-top:8px;text-align:center;display:none}
.loading{text-align:center;color:var(--text-muted);padding:40px}
@media(max-width:768px){
  #sidebar{position:fixed;top:0;left:0;height:100vh;z-index:100;transform:translateX(-100%)}
  #sidebar.open{transform:translateX(0)}
  .hamburger{display:block}
  .two-col{grid-template-columns:1fr}
  #content{padding:14px}
}
</style>
</head>
<body>
<div id="login-overlay">
  <div id="login-box">
    <h2>VPS 流量监控</h2>
    <p>请输入访问密码</p>
    <input type="password" id="pwd-input" placeholder="密码" autofocus>
    <button id="login-btn" onclick="doLogin()">登 录</button>
    <div id="login-err">密码错误，请重试</div>
  </div>
</div>
<nav id="sidebar">
  <div class="sidebar-logo"><span>🖥️</span>VPS 监控</div>
  <div class="nav-section">监控面板</div>
  <button class="nav-item active" onclick="switchTab('overview',this)"><span class="icon">📊</span>总览</button>
  <button class="nav-item" onclick="switchTab('outbound',this)"><span class="icon">↑</span>出站详情</button>
  <button class="nav-item" onclick="switchTab('inbound',this)"><span class="icon">↓</span>入站详情</button>
  <button class="nav-item" onclick="switchTab('live',this)"><span class="icon">⚡</span>实时流水</button>
  <div class="sidebar-footer">
    <span style="font-size:.72rem;color:var(--text-muted)" id="footer-ts"></span>
    <button class="theme-btn" id="theme-btn" onclick="toggleTheme()">🌙</button>
  </div>
</nav>
<div id="main">
  <header id="topbar">
    <button class="hamburger" onclick="toggleSidebar()">☰</button>
    <span class="topbar-title" id="topbar-title">总览</span>
    <span class="topbar-sub" id="topbar-sub"></span>
  </header>
  <div id="content">
    <div class="panel active" id="panel-overview"><div class="loading">加载中...</div></div>
    <div class="panel" id="panel-outbound">
      <div class="range-bar">
        <span class="range-label">时间范围:</span>
        <button class="range-btn active" onclick="setRange('out','today',this)">今日</button>
        <button class="range-btn" onclick="setRange('out','7d',this)">7天</button>
        <button class="range-btn" onclick="setRange('out','30d',this)">30天</button>
        <button class="range-btn" onclick="setRange('out','6m',this)">6个月</button>
        <span class="range-label" style="margin-left:10px">协议:</span>
        <button class="range-btn active" onclick="setProto('out',null,this)">全部</button>
        <button class="range-btn" onclick="setProto('out','reality',this)">Reality</button>
        <button class="range-btn" onclick="setProto('out','hysteria2',this)">Hysteria2</button>
        <button class="range-btn" onclick="setProto('out','snell',this)">Snell</button>
      </div>
      <div id="outbound-content"><div class="loading">加载中...</div></div>
    </div>
    <div class="panel" id="panel-inbound">
      <div class="range-bar">
        <span class="range-label">时间范围:</span>
        <button class="range-btn active" onclick="setRange('in','today',this)">今日</button>
        <button class="range-btn" onclick="setRange('in','7d',this)">7天</button>
        <button class="range-btn" onclick="setRange('in','30d',this)">30天</button>
        <button class="range-btn" onclick="setRange('in','6m',this)">6个月</button>
        <span class="range-label" style="margin-left:10px">协议:</span>
        <button class="range-btn active" onclick="setProto('in',null,this)">全部</button>
        <button class="range-btn" onclick="setProto('in','reality',this)">Reality</button>
        <button class="range-btn" onclick="setProto('in','hysteria2',this)">Hysteria2</button>
        <button class="range-btn" onclick="setProto('in','snell',this)">Snell</button>
      </div>
      <div id="inbound-content"><div class="loading">加载中...</div></div>
    </div>
    <div class="panel" id="panel-live"><div id="live-content"><div class="loading">加载中...</div></div></div>
  </div>
</div>
<script>
let _tok = sessionStorage.getItem("vps_tok") || "";
async function doLogin() {
  const pwd = document.getElementById("pwd-input").value;
  const r = await fetch("/auth",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({password:pwd})}).catch(()=>null);
  if(r&&r.ok){
    const d=await r.json();
    _tok=d.token; sessionStorage.setItem("vps_tok",_tok);
    document.getElementById("login-overlay").style.display="none";
    initApp();
  } else {
    document.getElementById("login-err").style.display="block";
    document.getElementById("pwd-input").value="";
    document.getElementById("pwd-input").focus();
  }
}
document.getElementById("pwd-input").addEventListener("keydown",e=>{if(e.key==="Enter")doLogin();});
async function checkAuth(){
  if(!_tok) return false;
  const r=await fetch("/api",{headers:{"Authorization":"Bearer "+_tok}}).catch(()=>null);
  return r&&r.ok;
}
const api=async path=>{
  const r=await fetch(path,{headers:{"Authorization":"Bearer "+_tok}}).catch(()=>null);
  if(r&&r.status===401){_tok="";sessionStorage.removeItem("vps_tok");location.reload();return null;}
  return r&&r.ok?r.json():null;
};
function toggleTheme(){
  const isLight=document.documentElement.classList.contains("light");
  document.documentElement.classList.toggle("light",!isLight);
  document.documentElement.classList.toggle("dark",isLight);
  localStorage.setItem("theme",isLight?"dark":"light");
  document.getElementById("theme-btn").textContent=isLight?"🌙":"☀️";
}
(function(){
  const t=localStorage.getItem("theme")||"dark";
  document.documentElement.classList.add(t);
  if(t==="light")document.getElementById("theme-btn").textContent="☀️";
})();
function toggleSidebar(){document.getElementById("sidebar").classList.toggle("open");}
const fmt=b=>{
  if(b==null||b===undefined)return "—";
  if(b>=1099511627776)return (b/1099511627776).toFixed(2)+" TB";
  if(b>=1073741824)return (b/1073741824).toFixed(2)+" GB";
  if(b>=1048576)return (b/1048576).toFixed(2)+" MB";
  if(b>=1024)return (b/1024).toFixed(2)+" KB";
  return b+" B";
};
const TAB_TITLES={overview:"总览",outbound:"出站详情",inbound:"入站详情",live:"实时流水"};
let activeTab="overview",ranges={out:"today",in:"today"},protos={out:null,in:null},charts={};
function setProto(dir,p,el){
  el.closest(".range-bar").querySelectorAll(".range-btn").forEach(b=>{
    if(["全部","Reality","Hysteria2","Snell"].includes(b.textContent))b.classList.remove("active");
  });
  el.classList.add("active"); protos[dir]=p;
  loadTab(dir==="out"?"outbound":"inbound");
}
function switchTab(name,el){
  document.querySelectorAll(".nav-item").forEach(t=>t.classList.remove("active"));
  document.querySelectorAll(".panel").forEach(p=>p.classList.remove("active"));
  el.classList.add("active");
  document.getElementById("panel-"+name).classList.add("active");
  document.getElementById("topbar-title").textContent=TAB_TITLES[name]||name;
  activeTab=name; loadTab(name);
  if(window.innerWidth<=768)document.getElementById("sidebar").classList.remove("open");
}
function setRange(dir,r,el){
  el.closest(".range-bar").querySelectorAll(".range-btn").forEach(b=>b.classList.remove("active"));
  el.classList.add("active"); ranges[dir]=r;
  loadTab(dir==="out"?"outbound":"inbound");
}
async function loadTab(name){
  if(name==="overview")await loadOverview();
  else if(name==="outbound")await loadDirectional("out");
  else if(name==="inbound")await loadDirectional("in");
  else if(name==="live")await loadLive();
  const now=new Date().toLocaleString("zh-CN");
  document.getElementById("footer-ts").textContent=now;
  document.getElementById("topbar-sub").textContent="更新: "+now;
}
const isDark=()=>!document.documentElement.classList.contains("light");
const tickColor=()=>isDark()?"#64748b":"#94a3b8";
const legColor=()=>isDark()?"#94a3b8":"#475569";
const PROTO_COLORS={"reality":"rgba(99,102,241,.8)","hysteria2":"rgba(34,197,94,.8)","snell":"rgba(251,191,36,.8)","其他":"rgba(100,116,139,.6)"};
const PROTO_ICON={"reality":"⚡","hysteria2":"🌊","snell":"🐌","其他":"?"};
async function loadOverview(){
  const [d, proto7d] = await Promise.all([api("/api"), api("/api/flows/by_protocol?range=7d")]);
  const el=document.getElementById("panel-overview");
  if(!d){el.innerHTML="<div class='loading' style='color:#ef4444'>数据加载失败</div>";return;}
  const {rx,tx,quota_gb,alert_pct,used_pct,remain,days,months,iface,offset_rx,offset_tx}=d;
  const total=rx+tx,barCls=used_pct>=90?"red":used_pct>=alert_pct?"yellow":"green";
  const badgeCls=used_pct>=90?"crit":used_pct>=alert_pct?"warn":"ok";
  const badgeTxt=used_pct>=90?"⚠ 严重":used_pct>=alert_pct?"⚠ 告警":"✓ 正常";
  const protoRows=(proto7d||[]).map(r=>`<tr>
    <td><span style="font-size:.85rem">${PROTO_ICON[r.protocol]||"?"}</span> ${r.protocol}</td>
    <td>${r.connections.toLocaleString()}</td>
    <td>${fmt(r.bytes_up+r.bytes_down)}</td>
  </tr>`).join("")||`<tr><td colspan="3" style="text-align:center;color:var(--text-muted);padding:12px">暂无采集数据</td></tr>`;
  el.innerHTML=`
  <div class="grid">
    <div class="card"><h3>本月合计 <span class="badge ${badgeCls}">${badgeTxt}</span></h3>
      <div class="big">${fmt(total)}</div><div class="sub">接口: ${iface}</div>
      <div class="bar-wrap"><div class="bar ${barCls}" style="width:${Math.min(used_pct,100)}%"></div></div>
      <div class="stat-row"><span>已用 ${used_pct}%</span><span class="stat-val">剩余 ${fmt(remain)}</span></div>
      <div class="stat-row"><span>配额</span><span class="stat-val">${quota_gb} GB</span></div>
      ${(offset_rx||offset_tx)?`<div class="stat-row" style="margin-top:6px;font-size:.72rem;color:var(--text-muted)"><span>含手动偏移</span><span>↓${fmt(offset_rx||0)} ↑${fmt(offset_tx||0)}</span></div>`:""}
    </div>
    <div class="card"><h3>上传 / 下载</h3>
      <div class="big">${fmt(tx)}</div><div class="sub">↑ 上传</div>
      <div style="margin-top:12px"><div class="big">${fmt(rx)}</div><div class="sub">↓ 下载</div></div>
    </div>
    <div class="card"><h3>今日用量</h3>
      <div class="big">${days.length?fmt(days[days.length-1].rx+days[days.length-1].tx):"--"}</div>
      <div class="sub">↑ ${days.length?fmt(days[days.length-1].tx):"--"} &nbsp; ↓ ${days.length?fmt(days[days.length-1].rx):"--"}</div>
    </div>
  </div>
  <div class="two-col">
    <div class="chart-card"><h3>协议分布 (近7天)</h3>
      <canvas id="protoChart" height="120"></canvas>
    </div>
    <div class="chart-card"><h3>协议流量明细 (近7天)</h3>
      <table><thead><tr><th>协议</th><th>连接数</th><th>总流量</th></tr></thead>
      <tbody>${protoRows}</tbody></table>
    </div>
  </div>
  <div class="chart-card"><h3>近 30 天日流量</h3><canvas id="dayChart" height="70"></canvas></div>
  <div class="chart-card"><h3>月度流量历史</h3><canvas id="monChart" height="70"></canvas></div>`;
  if(charts.day)charts.day.destroy(); if(charts.mon)charts.mon.destroy(); if(charts.proto)charts.proto.destroy();
  // 协议饼图
  const pd=proto7d||[];
  if(pd.length){
    charts.proto=new Chart(document.getElementById("protoChart"),{type:"doughnut",data:{
      labels:pd.map(r=>r.protocol),
      datasets:[{data:pd.map(r=>r.bytes_up+r.bytes_down),
        backgroundColor:pd.map(r=>PROTO_COLORS[r.protocol]||"rgba(100,116,139,.6)"),
        borderWidth:1,borderColor:"var(--border)"}]
    },options:{plugins:{legend:{position:"right",labels:{color:legColor(),boxWidth:12,padding:10}}},cutout:"60%"}});
  }
  charts.day=new Chart(document.getElementById("dayChart"),{type:"bar",data:{labels:days.map(d=>d.date.slice(5)),datasets:[
    {label:"上传",data:days.map(d=>+(d.tx/1073741824).toFixed(3)),backgroundColor:"rgba(99,102,241,.7)",borderRadius:3},
    {label:"下载",data:days.map(d=>+(d.rx/1073741824).toFixed(3)),backgroundColor:"rgba(34,197,94,.7)",borderRadius:3}
  ]},options:{plugins:{legend:{labels:{color:legColor()}}},scales:{x:{ticks:{color:tickColor(),maxRotation:45}},y:{ticks:{color:tickColor(),callback:v=>v+"GB"}}}}});
  charts.mon=new Chart(document.getElementById("monChart"),{type:"bar",data:{labels:months.map(m=>m.month),datasets:[
    {label:"上传",data:months.map(m=>+(m.tx/1073741824).toFixed(3)),backgroundColor:"rgba(99,102,241,.7)",borderRadius:3},
    {label:"下载",data:months.map(m=>+(m.rx/1073741824).toFixed(3)),backgroundColor:"rgba(34,197,94,.7)",borderRadius:3}
  ]},options:{plugins:{legend:{labels:{color:legColor()}}},scales:{x:{ticks:{color:tickColor()}},y:{ticks:{color:tickColor(),callback:v=>v+"GB"}}}}});
}
async function loadDirectional(dir){
  const range=ranges[dir],proto=protos[dir],id=dir==="out"?"outbound-content":"inbound-content";
  const pq=proto?`&protocol=${proto}`:"";
  const [summary,topHost,topCountry,topIp,timeline]=await Promise.all([
    api(`/api/flows/summary?range=${range}&direction=${dir}${pq}`),
    api(`/api/flows/top?field=host&range=${range}&direction=${dir}&limit=30${pq}`),
    api(`/api/flows/top?field=country&range=${range}&direction=${dir}&limit=15${pq}`),
    api(`/api/flows/top?field=${dir==="out"?"dst_ip":"src_ip"}&range=${range}&direction=${dir}&limit=20${pq}`),
    api(`/api/flows/timeline?range=${range}&direction=${dir}${pq}`),
  ]);
  const s=summary||{connections:0,bytes_up:0,bytes_down:0};
  const totalBytes=s.bytes_up+s.bytes_down,maxBytes=(topHost&&topHost.length)?topHost[0].bytes:1;
  const label=dir==="out"?"目标域名 / IP":"来源 IP",ipField=dir==="out"?"目标 IP":"来源 IP";
  const empty=col=>`<tr><td colspan="${col}" style="text-align:center;color:var(--text-muted);padding:14px">暂无数据</td></tr>`;
  const hostRows=(topHost||[]).map(r=>`<tr><td>${r.label||"—"}</td><td>${r.cnt}</td><td>${fmt(r.bytes)}<span class="bytes-bar" style="width:${Math.round(r.bytes/maxBytes*60)}px"></span></td></tr>`).join("");
  const ipRows=(topIp||[]).map(r=>`<tr><td>${r.label||"—"}</td><td>${r.cnt}</td><td>${fmt(r.bytes)}</td></tr>`).join("");
  const countryRows=(topCountry||[]).map(r=>`<tr><td>${r.label||"未知"}</td><td>${r.cnt}</td><td>${fmt(r.bytes)}</td></tr>`).join("");
  document.getElementById(id).innerHTML=`
  <div class="grid">
    <div class="card"><h3>${dir==="out"?"出站总计":"入站总计"}</h3>
      <div class="big">${fmt(totalBytes)}</div>
      <div class="stat-row"><span>连接数</span><span class="stat-val">${s.connections.toLocaleString()}</span></div>
      <div class="stat-row"><span>上行</span><span class="stat-val">${fmt(s.bytes_up)}</span></div>
      <div class="stat-row"><span>下行</span><span class="stat-val">${fmt(s.bytes_down)}</span></div>
    </div>
  </div>
  <div class="chart-card"><h3>流量趋势</h3><canvas id="chart-${dir}" height="60"></canvas></div>
  <div class="two-col">
    <div class="chart-card"><h3>Top 国家</h3>
      <table><thead><tr><th>国家</th><th>次数</th><th>流量</th></tr></thead><tbody>${countryRows||empty(3)}</tbody></table>
    </div>
    <div class="chart-card"><h3>Top ${ipField}</h3>
      <table><thead><tr><th>IP</th><th>次数</th><th>流量</th></tr></thead><tbody>${ipRows||empty(3)}</tbody></table>
    </div>
  </div>
  <div class="chart-card"><h3>Top ${label}</h3>
    <table><thead><tr><th>域名 / IP</th><th>次数</th><th>流量</th></tr></thead><tbody>${hostRows||empty(3)}</tbody></table>
  </div>`;
  const cid=`chart-${dir}`;
  if(charts[cid])charts[cid].destroy();
  const tl=timeline||[];
  charts[cid]=new Chart(document.getElementById(cid),{type:"bar",data:{
    labels:tl.map(r=>r.t.slice(5)),
    datasets:[{label:"流量",data:tl.map(r=>+(r.bytes/1073741824).toFixed(3)),backgroundColor:"rgba(99,102,241,.7)",borderRadius:3}]
  },options:{plugins:{legend:{display:false}},scales:{x:{ticks:{color:tickColor(),maxRotation:45}},y:{ticks:{color:tickColor(),callback:v=>v+"GB"}}}}});
}
async function loadLive(){
  const rows=await api("/api/flows/recent?limit=100")||[];
  const tbody=rows.map(r=>{
    const ts=new Date(r.ts*1000).toLocaleTimeString("zh-CN");
    const dirLabel=r.direction==="in"?`<span class="dir-in">↓ 入站</span>`:`<span class="dir-out">↑ 出站</span>`;
    const host=r.host||r.dst_ip||"—";
    const pLabel=r.protocol?`<span style="font-size:.7rem;padding:1px 6px;border-radius:4px;background:var(--surface2);color:var(--text-sub)">${r.protocol}</span>`:"—";
    return `<tr><td>${ts}</td><td>${dirLabel}</td><td>${pLabel}</td><td>${r.src_ip||"—"}</td><td>${host}${r.dst_port?":"+r.dst_port:""}</td><td>${r.country||"—"}</td><td>${fmt((r.bytes_up||0)+(r.bytes_down||0))}</td></tr>`;
  }).join("");
  document.getElementById("live-content").innerHTML=`
  <div class="chart-card"><h3>最近 100 条连接 <span style="font-weight:400;font-size:.72rem;color:var(--text-muted)">(每30秒刷新)</span></h3>
    <div style="overflow-x:auto">
    <table><thead><tr><th>时间</th><th>方向</th><th>协议</th><th>来源 IP</th><th>目标 域名/IP</th><th>国家</th><th>流量</th></tr></thead>
    <tbody>${tbody||`<tr><td colspan="7" style="text-align:center;color:var(--text-muted);padding:20px">暂无数据，采集器正在收集中...</td></tr>`}</tbody>
    </table></div>
  </div>`;
}
async function initApp(){loadTab("overview");setInterval(()=>loadTab(activeTab),30000);}
(async function(){if(_tok&&await checkAuth()){document.getElementById("login-overlay").style.display="none";initApp();}})();
</script>
</body></html>"""

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args): pass

    def _check_auth(self):
        if not TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        return hmac.compare_digest(auth[7:].encode(), TOKEN.encode())

    def do_POST(self):
        if self.path == "/auth":
            length = int(self.headers.get("Content-Length", 0))
            try:
                body = json.loads(self.rfile.read(length))
                pwd = body.get("password", "")
            except Exception:
                pwd = ""
            if TOKEN and hmac.compare_digest(pwd.encode(), TOKEN.encode()):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"token": TOKEN}).encode())
            else:
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"error":"invalid password"}')
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        path = parsed.path
        if path == "/" or path == "/index.html":
            self._index(); return
        if not self._check_auth():
            self.send_response(401)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"unauthorized"}')
            return
        if path == "/api":
            self._api_vnstat()
        elif path == "/api/flows/summary":
            self._api_json(flows_summary(qs.get("range",["7d"])[0], qs.get("direction",[None])[0], qs.get("protocol",[None])[0]))
        elif path == "/api/flows/top":
            self._api_json(flows_top(qs.get("field",["host"])[0], qs.get("range",["7d"])[0], qs.get("direction",[None])[0], int(qs.get("limit",["30"])[0]), qs.get("protocol",[None])[0]))
        elif path == "/api/flows/timeline":
            self._api_json(flows_timeline(qs.get("range",["7d"])[0], qs.get("bucket",["day"])[0], qs.get("direction",[None])[0], qs.get("protocol",[None])[0]))
        elif path == "/api/flows/recent":
            self._api_json(flows_recent(int(qs.get("limit",["100"])[0])))
        elif path == "/api/flows/by_protocol":
            self._api_json(flows_by_protocol(qs.get("range",["7d"])[0]))
        else:
            self._index()

    def _index(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(HTML.encode())

    def _api_json(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _api_vnstat(self):
        rx, tx = get_month_data()
        rx += OFFSET_RX
        tx += OFFSET_TX
        total = rx + tx
        quota_bytes = QUOTA_GB * 1024**3
        used_pct = int(total * 100 / quota_bytes) if quota_bytes else 0
        remain = max(quota_bytes - total, 0)
        self._api_json({
            "iface": IFACE, "rx": rx, "tx": tx,
            "quota_gb": QUOTA_GB, "alert_pct": ALERT_PCT,
            "used_pct": used_pct, "remain": remain,
            "offset_rx": OFFSET_RX, "offset_tx": OFFSET_TX,
            "days": get_day_data(30),
            "months": get_all_months(),
        })

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

    echo -e "\n${YELLOW}=== 安装 Web 流量面板 (V3.11) ===${NC}"
    echo -e "接口: ${CYAN}${iface}${NC}  配额: ${QUOTA_GB}GB  重置日: ${RESET_DAY}日"
    echo ""

    local token
    while true; do
        read -p "访问密码 (仅限字母数字，回车自动生成): " token
        if [[ -z "$token" ]]; then
            token=$(openssl rand -hex 8)
            echo -e "${YELLOW}自动生成密码: ${CYAN}${token}${NC}"
            break
        elif [[ "$token" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            break
        else
            echo -e "${RED}密码只允许字母、数字、下划线、连字符，请重新输入${NC}"
        fi
    done

    read -p "Web 端口 [默认: ${TRAFFIC_WEB_PORT}]: " input_port
    if [[ -n "$input_port" ]]; then
        if [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
            TRAFFIC_WEB_PORT="$input_port"
        else
            echo -e "${YELLOW}无效端口，使用默认 ${TRAFFIC_WEB_PORT}${NC}"
        fi
    fi

    # 安装依赖
    echo -e "${BLUE}>>> 安装 conntrack...${NC}"
    _traffic_install_conntrack || echo -e "${YELLOW}conntrack 不可用，字节统计将受限。${NC}"

    echo -e "${BLUE}>>> 下载 GeoIP 数据库...${NC}"
    _traffic_install_geoip || true

    echo -e "${BLUE}>>> 配置 logrotate...${NC}"
    _traffic_setup_logrotate

    # 若 Xray 已安装，确保 loglevel=info
    if [[ -f "$XRAY_CONF" ]] && command -v jq &>/dev/null; then
        local cur_level
        cur_level=$(jq -r '.log.loglevel // "warning"' "$XRAY_CONF" 2>/dev/null)
        if [[ "$cur_level" != "info" ]]; then
            jq '.log.loglevel = "info"' "$XRAY_CONF" > /tmp/xray_conf_tmp.json && \
                mv /tmp/xray_conf_tmp.json "$XRAY_CONF"
            systemctl is-active --quiet xray && systemctl reload xray 2>/dev/null || \
                systemctl is-active --quiet xray && systemctl restart xray 2>/dev/null || true
            echo -e "${GREEN}Xray loglevel 已更新为 info。${NC}"
        fi
    fi

    # 写 web server 和 collector
    _web_write_server "$iface" "$QUOTA_GB" "$RESET_DAY" "$ALERT_PCT" "$token"
    _web_write_service
    _traffic_install_collector "$iface"
    _traffic_flows_cleanup_cron

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
    echo -e "\n${GREEN}✓ Web 面板 + 流量采集器已启动！${NC}"
    echo -e "${BOLD}访问地址:${NC}  ${CYAN}http://${ip}:${TRAFFIC_WEB_PORT}/${NC}"
    echo -e "${BOLD}登录密码:${NC}  ${CYAN}${token}${NC}"
    echo ""
    echo -e "${YELLOW}注意：采集器需要几分钟才能积累连接数据，实时流水标签页才会显示内容。${NC}"
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
    echo -e "地址: ${CYAN}http://${ip}:${port}/${NC}"
    echo -e "密码: ${CYAN}${token}${NC}"
    echo -e "面板状态:   $(check_status vps-traffic-web)"
    echo -e "采集器状态: $(check_status vps-traffic-collector)"
}

traffic_web_remove() {
    systemctl disable vps-traffic-web --now 2>/dev/null
    systemctl disable vps-traffic-collector --now 2>/dev/null
    rm -f /etc/systemd/system/vps-traffic-web.service
    rm -f /etc/systemd/system/vps-traffic-collector.service
    rm -rf "$TRAFFIC_WEB_DIR"
    systemctl daemon-reload
    read -p "是否同时删除历史流量数据库？[y/N]: " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        rm -rf /var/lib/vps-traffic
        echo -e "${GREEN}历史数据已删除。${NC}"
    fi
    # 移除清理 cron
    local cron_script="/usr/local/bin/vps-flows-cleanup.sh"
    crontab -l 2>/dev/null | grep -v "$cron_script" | crontab - 2>/dev/null
    rm -f "$cron_script"
    echo -e "${GREEN}Web 面板及采集器已卸载。${NC}"
}

traffic_web_set_offset() {
    _traffic_load_conf
    local iface
    iface=$(_traffic_get_iface)
    echo -e "\n${YELLOW}=== 设置本月已消耗流量偏移 ===${NC}"
    echo -e "当前偏移: 下行 ${CYAN}$(awk "BEGIN{printf \"%.2f GB\", ${OFFSET_RX:-0}/1073741824}")${NC}  上行 ${CYAN}$(awk "BEGIN{printf \"%.2f GB\", ${OFFSET_TX:-0}/1073741824}")${NC}"
    echo -e "${YELLOW}提示: 填入面板统计周期开始前已消耗的流量（如账单显示已用 280 GB，则填 280）${NC}"
    echo -e "      留空 = 保持原值，填 0 = 清零"
    read -p "本月已消耗下行 (GB，留空不变): " inp_rx
    read -p "本月已消耗上行 (GB，留空不变): " inp_tx
    if [[ -n "$inp_rx" ]]; then
        if [[ "$inp_rx" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            OFFSET_RX=$(awk "BEGIN{printf \"%d\", ${inp_rx}*1073741824}")
        else
            echo -e "${RED}无效数字，下行偏移未修改${NC}"
        fi
    fi
    if [[ -n "$inp_tx" ]]; then
        if [[ "$inp_tx" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            OFFSET_TX=$(awk "BEGIN{printf \"%d\", ${inp_tx}*1073741824}")
        else
            echo -e "${RED}无效数字，上行偏移未修改${NC}"
        fi
    fi
    _traffic_save_conf
    # 重写 server.py 并重启（保持原有其他参数不变）
    local token="${WEB_TOKEN:-}" port="${WEB_PORT:-${TRAFFIC_WEB_PORT}}"
    TRAFFIC_WEB_PORT="${port}"
    _web_write_server "$iface" "$QUOTA_GB" "$RESET_DAY" "$ALERT_PCT" "$token"
    systemctl restart vps-traffic-web 2>/dev/null
    echo -e "${GREEN}✓ 偏移已保存，面板已刷新。${NC}"
    echo -e "  新偏移: 下行 ${CYAN}$(awk "BEGIN{printf \"%.2f GB\", ${OFFSET_RX}/1073741824}")${NC}  上行 ${CYAN}$(awk "BEGIN{printf \"%.2f GB\", ${OFFSET_TX}/1073741824}")${NC}"
}

manage_traffic_web_menu() {
    while true; do
        echo -e "\n${BLUE}--- Web 流量面板 ---${NC}"
        echo -e "1. 安装/重装 Web 面板 (含采集器 + GeoIP)"
        echo -e "2. 查看访问地址"
        echo -e "3. 重启服务"
        echo -e "4. 查看面板日志"
        echo -e "5. 更新 GeoIP 数据库"
        echo -e "6. 查看采集器状态/日志"
        echo -e "7. 设置流量偏移（手动补录本月已消耗）"
        echo -e "8. 卸载 Web 面板"
        echo -e "0. 返回"
        read -p "请选择: " OPT
        case $OPT in
            1) traffic_web_install ;;
            2) traffic_web_show_url ;;
            3) systemctl restart vps-traffic-web vps-traffic-collector && echo "已重启" ;;
            4) journalctl -u vps-traffic-web -n 30 --no-pager ;;
            5) _traffic_update_geoip ;;
            6) echo -e "采集器状态: $(check_status vps-traffic-collector)"; journalctl -u vps-traffic-collector -n 30 --no-pager ;;
            7) traffic_web_set_offset ;;
            8) traffic_web_remove ;;
            0) break ;;
            *) echo "无效选择" ;;
        esac
    done
}

# --- 主菜单 ---

main_menu() {
    while true; do
        echo -e "\n${BLUE}=====================================${NC}"
        echo -e "   全能协议管理脚本 V3.11"
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
        echo -e "-------------------------------------"
        echo -e "10. IPv6 管理 [$(ipv6_status 2>/dev/null | grep -o '已.*')]"
        echo -e "0. 退出脚本"
        echo -e "${BLUE}=====================================${NC}"
        read -p "请输入选项: " CHOICE

        case $CHOICE in
            1) install_reality ;;
            2) install_hy2 ;;
            3) install_snell ;;
            4) manage_reality_menu ;;
            5) manage_hy2_menu ;;
            6) manage_snell_menu ;;
            7) enable_bbr ;;
            8) manage_traffic_menu ;;
            9) manage_traffic_web_menu ;;
            10)
                echo -e "\n${BLUE}--- IPv6 管理 ---${NC}"
                ipv6_status
                echo "1. 禁用 IPv6"
                echo "2. 启用 IPv6"
                echo "0. 返回"
                read -p "选项: " V6CHOICE
                case $V6CHOICE in
                    1) disable_ipv6 ;;
                    2) enable_ipv6 ;;
                esac
                ;;
            0) exit 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

# --- 入口 ---
check_root
install_tools
main_menu
