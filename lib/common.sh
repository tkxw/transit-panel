#!/bin/bash
#
# 公共函数库
#

# ==================== 全局变量 ====================
PANEL_VERSION="1.0.0"
PANEL_NAME="Transit Panel"
INSTALL_DIR="/opt/transit-panel"
CONFIG_DIR="/etc/transit-panel"
DATA_DIR="/var/lib/transit-panel"
LOG_DIR="/var/log/transit-panel"
SINGBOX_BIN="/usr/local/bin/sing-box"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ==================== 日志函数 ====================
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${CYAN}[DEBUG]${NC} $1"
}

# ==================== 工具函数 ====================

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

# 生成随机密码
generate_password() {
    openssl rand -base64 16 | tr -d '=' | head -c 16
}

# 生成 UUID
generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# 获取公网 IP
get_public_ip() {
    local ip=""
    ip=$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null) || \
    ip=$(curl -s -4 --max-time 5 https://ifconfig.me 2>/dev/null) || \
    ip=$(curl -s -4 --max-time 5 https://icanhazip.com 2>/dev/null)
    echo "$ip"
}

# 获取 IPv6 地址
get_public_ipv6() {
    local ip=""
    ip=$(curl -s -6 --max-time 5 https://api6.ipify.org 2>/dev/null) || \
    ip=$(curl -s -6 --max-time 5 https://ifconfig.co 2>/dev/null)
    echo "$ip"
}

# 配置防火墙
configure_firewall() {
    local port=$1
    local protocol=${2:-tcp}
    
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        ufw allow "$port/$protocol" 2>/dev/null || true
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port="$port/$protocol" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    elif command -v iptables &> /dev/null; then
        iptables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

# 移除防火墙规则
remove_firewall_rule() {
    local port=$1
    local protocol=${2:-tcp}
    
    if command -v ufw &> /dev/null; then
        ufw delete allow "$port/$protocol" 2>/dev/null || true
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --remove-port="$port/$protocol" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    elif command -v iptables &> /dev/null; then
        iptables -D INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if ss -tuln | grep -q ":$port "; then
        return 0  # 端口被占用
    else
        return 1  # 端口可用
    fi
}

# 获取可用端口
get_available_port() {
    local start_port=${1:-10000}
    local end_port=${2:-60000}
    
    while true; do
        local port=$((RANDOM % (end_port - start_port) + start_port))
        if ! check_port "$port"; then
            echo "$port"
            return 0
        fi
    done
}

# 验证 JSON 格式
validate_json() {
    local file=$1
    if jq empty "$file" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# 重载 sing-box 配置
reload_singbox() {
    if systemctl is-active --quiet transit-panel; then
        # 先验证配置
        if $SINGBOX_BIN check -c "$CONFIG_DIR/singbox.json" 2>/dev/null; then
            systemctl reload transit-panel 2>/dev/null || systemctl restart transit-panel
            return 0
        else
            log_error "配置验证失败"
            return 1
        fi
    fi
    return 0
}

# 启动服务
start_service() {
    systemctl start transit-panel
    systemctl enable transit-panel 2>/dev/null || true
}

# 停止服务
stop_service() {
    systemctl stop transit-panel 2>/dev/null || true
}

# 重启服务
restart_service() {
    if $SINGBOX_BIN check -c "$CONFIG_DIR/singbox.json" 2>/dev/null; then
        systemctl restart transit-panel
        return 0
    else
        log_error "配置验证失败，无法重启"
        return 1
    fi
}

# 显示分隔线
show_separator() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# 确认操作
confirm_action() {
    local message=${1:-"确认继续?"}
    read -p "$message (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# 读取配置值
get_config_value() {
    local key=$1
    local config_file="${CONFIG_DIR}/config.json"
    jq -r "$key" "$config_file" 2>/dev/null
}

# 设置配置值
set_config_value() {
    local key=$1
    local value=$2
    local config_file="${CONFIG_DIR}/config.json"
    local temp_file=$(mktemp)
    
    jq "$key = $value" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
}

# URL 编码
urlencode() {
    local string="$1"
    python3 -c "import urllib.parse; print(urllib.parse.quote('$string', safe=''))" 2>/dev/null || \
    echo "$string"
}

# Base64 编码
base64_encode() {
    echo -n "$1" | base64 | tr -d '\n'
}

# Base64 解码
base64_decode() {
    echo -n "$1" | base64 -d
}
