#!/bin/bash
#
# 节点中转面板 - Transit Panel
# 完整安装脚本 (包含 Web 面板)
#

set -e

# ==================== 全局变量 ====================
PANEL_VERSION="1.0.0"
PANEL_NAME="Transit Panel"
INSTALL_DIR="/opt/transit-panel"
CONFIG_DIR="/etc/transit-panel"
DATA_DIR="/var/lib/transit-panel"
LOG_DIR="/var/log/transit-panel"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_VERSION="1.10.0"
WEB_PORT=8080

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ==================== 日志函数 ====================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ==================== 工具函数 ====================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要 root 权限运行"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "无法检测操作系统"
        exit 1
    fi
    log_info "检测到系统: $OS $OS_VERSION"
}

detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) log_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    log_info "检测到架构: $ARCH"
}

install_dependencies() {
    log_info "安装依赖..."
    case $OS in
        ubuntu|debian)
            apt-get update -y
            apt-get install -y curl wget jq openssl unzip python3 python3-pip python3-venv
            ;;
        centos|rhel|fedora|rocky|almalinux)
            if command -v dnf &> /dev/null; then
                dnf install -y curl wget jq openssl unzip python3 python3-pip
            else
                yum install -y curl wget jq openssl unzip python3 python3-pip
            fi
            ;;
        alpine)
            apk update
            apk add curl wget jq openssl unzip python3 py3-pip bash
            ;;
    esac
    log_info "依赖安装完成"
}

download_singbox() {
    log_info "下载 sing-box v${SINGBOX_VERSION}..."
    local url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz"
    local tmp="/tmp/sing-box.tar.gz"
    
    curl -L -o "$tmp" "$url" || { log_error "下载失败"; exit 1; }
    tar -xzf "$tmp" -C /tmp/
    mv "/tmp/sing-box-${SINGBOX_VERSION}-linux-${ARCH}/sing-box" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    rm -rf "$tmp" "/tmp/sing-box-${SINGBOX_VERSION}-linux-${ARCH}"
    
    log_info "sing-box 安装成功"
}

create_directories() {
    log_info "创建目录..."
    mkdir -p "$INSTALL_DIR/web"
    mkdir -p "$CONFIG_DIR/certs"
    mkdir -p "$DATA_DIR"
    mkdir -p "$LOG_DIR"
}

generate_password() { openssl rand -base64 16 | tr -d '=' | head -c 16; }

get_public_ip() {
    curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -s -4 --max-time 5 https://ifconfig.me 2>/dev/null || \
    echo "127.0.0.1"
}

init_config() {
    log_info "初始化配置..."
    local admin_user="admin"
    local admin_pass=$(generate_password)
    local admin_pass_hash=$(echo -n "$admin_pass" | sha256sum | awk '{print $1}')
    local server_ip=$(get_public_ip)
    
    cat > "$CONFIG_DIR/config.json" << EOF
{
    "panel": {
        "version": "$PANEL_VERSION",
        "admin_user": "$admin_user",
        "admin_pass_hash": "$admin_pass_hash",
        "server_ip": "$server_ip",
        "web_port": $WEB_PORT,
        "install_time": "$(date -Iseconds)"
    },
    "inbounds": [],
    "outbounds": [],
    "routes": []
}
EOF

    cat > "$CONFIG_DIR/singbox.json" << EOF
{
    "log": {
        "level": "info",
        "timestamp": true,
        "output": "$LOG_DIR/singbox.log"
    },
    "inbounds": [],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        }
    ],
    "route": {
        "rules": [],
        "final": "direct"
    }
}
EOF

    cat > "$DATA_DIR/admin_info.txt" << EOF
========================================
  $PANEL_NAME 管理信息
========================================
用户名: $admin_user
密码: $admin_pass
服务器IP: $server_ip

Web 面板: http://$server_ip:$WEB_PORT
========================================
请妥善保管此信息！
EOF
    chmod 600 "$DATA_DIR/admin_info.txt"
    
    # 保存密码到临时变量供显示
    ADMIN_PASS="$admin_pass"
    SERVER_IP="$server_ip"
}

install_web_panel() {
    log_info "安装 Web 面板..."
    
    # 复制 web 目录
    if [ -d "$(dirname "$0")/web" ]; then
        cp -r "$(dirname "$0")/web"/* "$INSTALL_DIR/web/"
    fi
    
    # 创建 Python 虚拟环境
    python3 -m venv "$INSTALL_DIR/venv"
    source "$INSTALL_DIR/venv/bin/activate"
    
    # 安装 Flask
    pip install --upgrade pip
    pip install flask gunicorn
    
    deactivate
    
    log_info "Web 面板安装完成"
}

create_services() {
    log_info "创建系统服务..."
    
    # sing-box 服务
    cat > /etc/systemd/system/transit-panel.service << EOF
[Unit]
Description=Transit Panel - sing-box
After=network.target

[Service]
Type=simple
User=root
ExecStart=$SINGBOX_BIN run -c $CONFIG_DIR/singbox.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    # Web 面板服务
    cat > /etc/systemd/system/transit-panel-web.service << EOF
[Unit]
Description=Transit Panel - Web Interface
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/web
Environment="CONFIG_DIR=$CONFIG_DIR"
Environment="DATA_DIR=$DATA_DIR"
Environment="LOG_DIR=$LOG_DIR"
Environment="SINGBOX_BIN=$SINGBOX_BIN"
ExecStart=$INSTALL_DIR/venv/bin/gunicorn -b 0.0.0.0:$WEB_PORT -w 2 app:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_info "系统服务创建完成"
}

start_services() {
    log_info "启动服务..."
    
    systemctl enable transit-panel
    systemctl enable transit-panel-web
    systemctl start transit-panel
    systemctl start transit-panel-web
    
    log_info "服务已启动"
}

configure_firewall() {
    log_info "配置防火墙..."
    
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        ufw allow $WEB_PORT/tcp
        log_info "UFW 规则已添加"
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=$WEB_PORT/tcp
        firewall-cmd --reload
        log_info "Firewalld 规则已添加"
    fi
}

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║                                                          ║"
    echo "║            ${NC}${BOLD}节点中转面板 Transit Panel${NC}${CYAN}                  ║"
    echo "║                                                          ║"
    echo "║                    v${PANEL_VERSION}                              ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ==================== 安装 ====================
do_install() {
    show_banner
    log_info "开始安装 $PANEL_NAME..."
    echo ""
    
    check_root
    detect_os
    detect_arch
    install_dependencies
    create_directories
    download_singbox
    init_config
    install_web_panel
    create_services
    configure_firewall
    start_services
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  安装完成！${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Web 面板地址:${NC} http://$SERVER_IP:$WEB_PORT"
    echo ""
    echo -e "  ${CYAN}用户名:${NC} admin"
    echo -e "  ${CYAN}密码:${NC} $ADMIN_PASS"
    echo ""
    echo -e "  ${YELLOW}请妥善保管登录信息！${NC}"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
}

# ==================== 卸载 ====================
do_uninstall() {
    show_banner
    echo -e "${RED}警告: 这将卸载 $PANEL_NAME 及所有配置！${NC}"
    read -p "确认卸载? (输入 yes): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo "已取消"
        exit 0
    fi
    
    log_info "停止服务..."
    systemctl stop transit-panel-web 2>/dev/null || true
    systemctl stop transit-panel 2>/dev/null || true
    systemctl disable transit-panel-web 2>/dev/null || true
    systemctl disable transit-panel 2>/dev/null || true
    
    log_info "删除文件..."
    rm -rf "$INSTALL_DIR"
    rm -rf "$CONFIG_DIR"
    rm -rf "$DATA_DIR"
    rm -rf "$LOG_DIR"
    rm -f /etc/systemd/system/transit-panel.service
    rm -f /etc/systemd/system/transit-panel-web.service
    rm -f "$SINGBOX_BIN"
    
    systemctl daemon-reload
    
    log_info "卸载完成！"
}

# ==================== 主程序 ====================
case "${1:-install}" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    *)
        echo "用法: $0 {install|uninstall}"
        exit 1
        ;;
esac
