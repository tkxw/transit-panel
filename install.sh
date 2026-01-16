#!/bin/bash
#
# Transit Panel - 一键安装脚本
# 基于 sing-box 的节点中转管理面板
#
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/tkxw/transit-panel/main/install.sh)
#

set -e

# ==================== 配置 ====================
PANEL_VERSION="1.0.0"
PANEL_NAME="Transit Panel"
GITHUB_REPO="tkxw/transit-panel"
GITHUB_RAW="https://raw.githubusercontent.com/$GITHUB_REPO/main"

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

# ==================== 函数 ====================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    [[ $EUID -ne 0 ]] && { log_error "请使用 root 权限运行"; exit 1; }
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        log_error "不支持的系统"
        exit 1
    fi
    log_info "系统: $OS"
}

detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) log_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    log_info "架构: $ARCH"
}

install_deps() {
    log_info "安装依赖..."
    case $OS in
        ubuntu|debian)
            apt-get update -y
            apt-get install -y curl wget jq openssl unzip python3 python3-pip python3-venv
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y curl wget jq openssl unzip python3 python3-pip || \
            dnf install -y curl wget jq openssl unzip python3 python3-pip
            ;;
        alpine)
            apk add curl wget jq openssl unzip python3 py3-pip bash
            ;;
    esac
}

download_singbox() {
    log_info "下载 sing-box..."
    local url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz"
    curl -L -o /tmp/sing-box.tar.gz "$url"
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/
    mv "/tmp/sing-box-${SINGBOX_VERSION}-linux-${ARCH}/sing-box" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"
    rm -rf /tmp/sing-box*
    log_info "sing-box 安装完成"
}

create_dirs() {
    mkdir -p "$INSTALL_DIR/web/static/css"
    mkdir -p "$INSTALL_DIR/web/static/js"
    mkdir -p "$INSTALL_DIR/web/templates"
    mkdir -p "$CONFIG_DIR/certs"
    mkdir -p "$DATA_DIR"
    mkdir -p "$LOG_DIR"
}

download_web_files() {
    log_info "下载 Web 面板文件..."
    
    # 下载 Python 后端
    curl -fsSL "$GITHUB_RAW/web/app.py" -o "$INSTALL_DIR/web/app.py"
    
    # 下载静态文件
    curl -fsSL "$GITHUB_RAW/web/static/css/style.css" -o "$INSTALL_DIR/web/static/css/style.css"
    curl -fsSL "$GITHUB_RAW/web/static/js/app.js" -o "$INSTALL_DIR/web/static/js/app.js"
    
    # 下载模板
    curl -fsSL "$GITHUB_RAW/web/templates/base.html" -o "$INSTALL_DIR/web/templates/base.html"
    curl -fsSL "$GITHUB_RAW/web/templates/login.html" -o "$INSTALL_DIR/web/templates/login.html"
    curl -fsSL "$GITHUB_RAW/web/templates/dashboard.html" -o "$INSTALL_DIR/web/templates/dashboard.html"
    curl -fsSL "$GITHUB_RAW/web/templates/inbounds.html" -o "$INSTALL_DIR/web/templates/inbounds.html"
    curl -fsSL "$GITHUB_RAW/web/templates/outbounds.html" -o "$INSTALL_DIR/web/templates/outbounds.html"
    curl -fsSL "$GITHUB_RAW/web/templates/routes.html" -o "$INSTALL_DIR/web/templates/routes.html"
    curl -fsSL "$GITHUB_RAW/web/templates/settings.html" -o "$INSTALL_DIR/web/templates/settings.html"
    
    log_info "Web 文件下载完成"
}

setup_python() {
    log_info "配置 Python 环境..."
    python3 -m venv "$INSTALL_DIR/venv"
    source "$INSTALL_DIR/venv/bin/activate"
    pip install --upgrade pip
    pip install flask gunicorn
    deactivate
}

generate_password() { openssl rand -base64 16 | tr -d '=' | head -c 16; }

get_public_ip() {
    curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -s -4 --max-time 5 https://ifconfig.me 2>/dev/null || echo "127.0.0.1"
}

init_config() {
    log_info "初始化配置..."
    local admin_pass=$(generate_password)
    local admin_hash=$(echo -n "$admin_pass" | sha256sum | awk '{print $1}')
    local server_ip=$(get_public_ip)
    
    cat > "$CONFIG_DIR/config.json" << EOF
{
    "panel": {
        "version": "$PANEL_VERSION",
        "admin_user": "admin",
        "admin_pass_hash": "$admin_hash",
        "server_ip": "$server_ip",
        "web_port": $WEB_PORT
    },
    "inbounds": [],
    "outbounds": [],
    "routes": []
}
EOF

    cat > "$CONFIG_DIR/singbox.json" << EOF
{
    "log": {"level": "info", "timestamp": true, "output": "$LOG_DIR/singbox.log"},
    "inbounds": [],
    "outbounds": [{"type": "direct", "tag": "direct"}],
    "route": {"rules": [], "final": "direct"}
}
EOF

    # 保存登录信息
    ADMIN_PASS="$admin_pass"
    SERVER_IP="$server_ip"
}

create_services() {
    log_info "创建系统服务..."
    
    cat > /etc/systemd/system/transit-panel.service << EOF
[Unit]
Description=Transit Panel - sing-box
After=network.target
[Service]
Type=simple
ExecStart=$SINGBOX_BIN run -c $CONFIG_DIR/singbox.json
Restart=on-failure
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/transit-panel-web.service << EOF
[Unit]
Description=Transit Panel - Web
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR/web
Environment="CONFIG_DIR=$CONFIG_DIR"
Environment="DATA_DIR=$DATA_DIR"
Environment="LOG_DIR=$LOG_DIR"
Environment="SINGBOX_BIN=$SINGBOX_BIN"
ExecStart=$INSTALL_DIR/venv/bin/gunicorn -b 0.0.0.0:$WEB_PORT -w 2 app:app
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable transit-panel transit-panel-web
    systemctl start transit-panel transit-panel-web
}

show_result() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ 安装完成！${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  访问地址: ${CYAN}http://$SERVER_IP:$WEB_PORT${NC}"
    echo ""
    echo -e "  用户名: ${CYAN}admin${NC}"
    echo -e "  密码: ${CYAN}$ADMIN_PASS${NC}"
    echo ""
    echo -e "${YELLOW}  请妥善保管登录信息！${NC}"
    echo ""
}

do_install() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════╗"
    echo "║       Transit Panel 一键安装脚本          ║"
    echo "║              v$PANEL_VERSION                       ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_root
    detect_os
    detect_arch
    install_deps
    create_dirs
    download_singbox
    download_web_files
    setup_python
    init_config
    create_services
    show_result
}

do_uninstall() {
    log_info "卸载 Transit Panel..."
    systemctl stop transit-panel-web transit-panel 2>/dev/null || true
    systemctl disable transit-panel-web transit-panel 2>/dev/null || true
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    rm -f /etc/systemd/system/transit-panel*.service
    rm -f "$SINGBOX_BIN"
    systemctl daemon-reload
    log_info "卸载完成"
}

# ==================== 主程序 ====================
case "${1:-}" in
    uninstall) do_uninstall ;;
    *) do_install ;;
esac
