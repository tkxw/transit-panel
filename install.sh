#!/bin/bash
#
# Transit Panel - 一键管理脚本
# 基于 sing-box 的节点中转管理面板
#
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/tkxw/transit-panel/main/install.sh)
#

# ==================== 配置 ====================
PANEL_VERSION="1.1.0"
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
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

# ==================== 工具函数 ====================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行"
        exit 1
    fi
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        log_error "不支持的系统"
        exit 1
    fi
}

detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) log_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
}

generate_password() { openssl rand -base64 16 | tr -d '=' | head -c 16; }

get_public_ip() {
    curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || \
    curl -s -4 --max-time 5 https://ifconfig.me 2>/dev/null || echo "127.0.0.1"
}

show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════╗"
    echo "║         Transit Panel 管理脚本                ║"
    echo "║              v${PANEL_VERSION}                          ║"
    echo "╚════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ==================== 安装相关 ====================
install_deps() {
    log_info "安装依赖..."
    case $OS in
        ubuntu|debian)
            apt-get update -y
            apt-get install -y curl wget jq openssl unzip python3 python3-pip python3-venv socat cron
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y curl wget jq openssl unzip python3 python3-pip socat cronie 2>/dev/null || \
            dnf install -y curl wget jq openssl unzip python3 python3-pip socat cronie
            ;;
        alpine)
            apk add curl wget jq openssl unzip python3 py3-pip bash socat
            ;;
    esac
}

download_singbox() {
    log_info "下载 sing-box v${SINGBOX_VERSION}..."
    local url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${ARCH}.tar.gz"
    curl -L -o /tmp/sing-box.tar.gz "$url" || { log_error "下载失败"; exit 1; }
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
    curl -fsSL "$GITHUB_RAW/web/app.py" -o "$INSTALL_DIR/web/app.py"
    curl -fsSL "$GITHUB_RAW/web/static/css/style.css" -o "$INSTALL_DIR/web/static/css/style.css"
    curl -fsSL "$GITHUB_RAW/web/static/js/app.js" -o "$INSTALL_DIR/web/static/js/app.js"
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
    "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
    "$INSTALL_DIR/venv/bin/pip" install flask gunicorn
}

init_config() {
    log_info "初始化配置..."
    local admin_pass=$(generate_password)
    local admin_hash=$(echo -n "$admin_pass" | sha256sum | awk '{print $1}')
    local server_ip=$(get_public_ip)
    local use_domain="${1:-}"
    local domain="${2:-}"
    
    cat > "$CONFIG_DIR/config.json" << EOFCONFIG
{
    "panel": {
        "version": "$PANEL_VERSION",
        "admin_user": "admin",
        "admin_pass_hash": "$admin_hash",
        "admin_pass_plain": "$admin_pass",
        "server_ip": "$server_ip",
        "domain": "$domain",
        "use_ssl": $([ -n "$domain" ] && echo "true" || echo "false"),
        "web_port": $WEB_PORT
    },
    "inbounds": [],
    "outbounds": [],
    "routes": []
}
EOFCONFIG

    cat > "$CONFIG_DIR/singbox.json" << EOFSINGBOX
{
    "log": {"level": "info", "timestamp": true, "output": "$LOG_DIR/singbox.log"},
    "inbounds": [],
    "outbounds": [{"type": "direct", "tag": "direct"}],
    "route": {"rules": [], "final": "direct"}
}
EOFSINGBOX
}

# ==================== SSL 证书 ====================
install_acme() {
    log_info "安装 acme.sh..."
    curl https://get.acme.sh | sh -s email=admin@example.com
    source ~/.bashrc
}

apply_ssl_cert() {
    local domain=$1
    log_info "申请 SSL 证书: $domain"
    
    # 安装 acme.sh
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        install_acme
    fi
    
    # 申请证书
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --force
    
    # 安装证书
    ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
        --key-file "$CONFIG_DIR/certs/panel.key" \
        --fullchain-file "$CONFIG_DIR/certs/panel.crt" \
        --reloadcmd "systemctl restart transit-panel-web"
    
    log_info "SSL 证书申请完成"
}

# ==================== 服务管理 ====================
create_services() {
    log_info "创建系统服务..."
    local domain=$(jq -r '.panel.domain // ""' "$CONFIG_DIR/config.json" 2>/dev/null)
    local use_ssl="false"
    [ -n "$domain" ] && [ -f "$CONFIG_DIR/certs/panel.crt" ] && use_ssl="true"
    
    cat > /etc/systemd/system/transit-panel.service << EOFSVC1
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
EOFSVC1

    if [ "$use_ssl" = "true" ]; then
        cat > /etc/systemd/system/transit-panel-web.service << EOFSVC2
[Unit]
Description=Transit Panel - Web (HTTPS)
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR/web
Environment="CONFIG_DIR=$CONFIG_DIR"
Environment="DATA_DIR=$DATA_DIR"
Environment="LOG_DIR=$LOG_DIR"
Environment="SINGBOX_BIN=$SINGBOX_BIN"
ExecStart=$INSTALL_DIR/venv/bin/gunicorn -b 0.0.0.0:$WEB_PORT -w 2 --certfile=$CONFIG_DIR/certs/panel.crt --keyfile=$CONFIG_DIR/certs/panel.key app:app
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOFSVC2
    else
        cat > /etc/systemd/system/transit-panel-web.service << EOFSVC2
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
EOFSVC2
    fi

    systemctl daemon-reload
    systemctl enable transit-panel transit-panel-web
    systemctl start transit-panel transit-panel-web
}

# ==================== 主菜单 ====================
show_menu() {
    show_banner
    
    local installed="否"
    [ -f "$CONFIG_DIR/config.json" ] && installed="是"
    
    local status="${RED}未运行${NC}"
    systemctl is-active --quiet transit-panel-web && status="${GREEN}运行中${NC}"
    
    echo -e "  安装状态: $([ "$installed" = "是" ] && echo -e "${GREEN}已安装${NC}" || echo -e "${YELLOW}未安装${NC}")"
    echo -e "  服务状态: $status"
    echo ""
    echo -e "${BOLD}请选择操作:${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} 安装面板"
    echo -e "  ${GREEN}2.${NC} 卸载面板"
    echo -e "  ${GREEN}3.${NC} 查看状态"
    echo -e "  ${GREEN}4.${NC} 查看登录信息"
    echo -e "  ${GREEN}5.${NC} 重置密码"
    echo -e "  ${GREEN}6.${NC} 重启服务"
    echo -e "  ${GREEN}7.${NC} 查看日志"
    echo -e "  ${GREEN}8.${NC} 配置域名/SSL"
    echo -e "  ${GREEN}0.${NC} 退出"
    echo ""
    echo -n -e "请输入选项 [0-8]: "
}

# ==================== 安装流程 ====================
do_install() {
    show_banner
    check_root
    
    if [ -f "$CONFIG_DIR/config.json" ]; then
        log_warn "检测到已安装，是否重新安装？"
        read -p "继续将覆盖现有配置 [y/N]: " confirm
        [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return
    fi
    
    echo ""
    echo -e "${BOLD}选择安装模式:${NC}"
    echo -e "  ${GREEN}1.${NC} 无域名模式 (使用 IP 访问，自签名证书)"
    echo -e "  ${GREEN}2.${NC} 有域名模式 (自动申请 SSL 证书)"
    echo ""
    read -p "请选择 [1/2]: " mode
    
    local domain=""
    if [ "$mode" = "2" ]; then
        read -p "请输入域名 (例如: panel.example.com): " domain
        if [ -z "$domain" ]; then
            log_error "域名不能为空"
            return
        fi
        echo ""
        log_warn "请确保域名已解析到本服务器 IP"
        read -p "确认继续? [y/N]: " confirm
        [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return
    fi
    
    echo ""
    detect_os
    detect_arch
    
    install_deps
    create_dirs
    download_singbox
    download_web_files
    setup_python
    init_config "" "$domain"
    
    if [ -n "$domain" ]; then
        apply_ssl_cert "$domain"
    fi
    
    create_services
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✓ 安装完成！${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    show_login_info
    
    read -p "按回车键继续..."
}

# ==================== 卸载 ====================
do_uninstall() {
    show_banner
    check_root
    
    if [ ! -f "$CONFIG_DIR/config.json" ]; then
        log_error "未检测到安装"
        read -p "按回车键继续..."
        return
    fi
    
    echo -e "${RED}警告: 这将删除所有数据和配置！${NC}"
    read -p "确认卸载? (输入 yes): " confirm
    
    if [ "$confirm" != "yes" ]; then
        log_info "已取消"
        read -p "按回车键继续..."
        return
    fi
    
    log_info "停止服务..."
    systemctl stop transit-panel-web transit-panel 2>/dev/null || true
    systemctl disable transit-panel-web transit-panel 2>/dev/null || true
    
    log_info "删除文件..."
    rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
    rm -f /etc/systemd/system/transit-panel*.service
    rm -f "$SINGBOX_BIN"
    systemctl daemon-reload
    
    log_info "卸载完成！"
    read -p "按回车键继续..."
}

# ==================== 查看状态 ====================
show_status() {
    show_banner
    echo -e "${BOLD}服务状态:${NC}"
    echo ""
    
    echo -n "  sing-box 服务: "
    if systemctl is-active --quiet transit-panel; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
    
    echo -n "  Web 面板服务: "
    if systemctl is-active --quiet transit-panel-web; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi
    
    echo ""
    echo -e "${BOLD}端口监听:${NC}"
    ss -tuln | grep -E ":$WEB_PORT|:443" | head -5
    
    echo ""
    read -p "按回车键继续..."
}

# ==================== 查看登录信息 ====================
show_login_info() {
    if [ ! -f "$CONFIG_DIR/config.json" ]; then
        log_error "未检测到安装"
        return
    fi
    
    local server_ip=$(jq -r '.panel.server_ip' "$CONFIG_DIR/config.json")
    local domain=$(jq -r '.panel.domain // ""' "$CONFIG_DIR/config.json")
    local admin_pass=$(jq -r '.panel.admin_pass_plain // ""' "$CONFIG_DIR/config.json")
    local use_ssl=$(jq -r '.panel.use_ssl // false' "$CONFIG_DIR/config.json")
    
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  登录信息${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    if [ -n "$domain" ] && [ "$domain" != "null" ]; then
        echo -e "  访问地址: ${GREEN}https://$domain:$WEB_PORT${NC}"
    else
        echo -e "  访问地址: ${GREEN}http://$server_ip:$WEB_PORT${NC}"
    fi
    
    echo ""
    echo -e "  用户名: ${CYAN}admin${NC}"
    echo -e "  密码:   ${CYAN}$admin_pass${NC}"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
}

view_login_info() {
    show_banner
    show_login_info
    echo ""
    read -p "按回车键继续..."
}

# ==================== 重置密码 ====================
reset_password() {
    show_banner
    check_root
    
    if [ ! -f "$CONFIG_DIR/config.json" ]; then
        log_error "未检测到安装"
        read -p "按回车键继续..."
        return
    fi
    
    local new_pass=$(generate_password)
    local new_hash=$(echo -n "$new_pass" | sha256sum | awk '{print $1}')
    
    # 更新配置
    local tmp=$(mktemp)
    jq ".panel.admin_pass_hash = \"$new_hash\" | .panel.admin_pass_plain = \"$new_pass\"" "$CONFIG_DIR/config.json" > "$tmp"
    mv "$tmp" "$CONFIG_DIR/config.json"
    
    log_info "密码已重置"
    echo ""
    echo -e "  新密码: ${CYAN}$new_pass${NC}"
    echo ""
    
    read -p "按回车键继续..."
}

# ==================== 重启服务 ====================
restart_services() {
    show_banner
    check_root
    
    log_info "重启 sing-box..."
    systemctl restart transit-panel
    
    log_info "重启 Web 面板..."
    systemctl restart transit-panel-web
    
    sleep 2
    show_status
}

# ==================== 查看日志 ====================
view_logs() {
    show_banner
    echo -e "${BOLD}最近日志:${NC}"
    echo ""
    
    if [ -f "$LOG_DIR/singbox.log" ]; then
        tail -20 "$LOG_DIR/singbox.log"
    else
        journalctl -u transit-panel-web -n 30 --no-pager
    fi
    
    echo ""
    read -p "按回车键继续..."
}

# ==================== 配置域名 ====================
config_domain() {
    show_banner
    check_root
    
    if [ ! -f "$CONFIG_DIR/config.json" ]; then
        log_error "请先安装面板"
        read -p "按回车键继续..."
        return
    fi
    
    local current_domain=$(jq -r '.panel.domain // ""' "$CONFIG_DIR/config.json")
    
    echo -e "${BOLD}当前域名配置:${NC}"
    if [ -n "$current_domain" ] && [ "$current_domain" != "null" ]; then
        echo -e "  域名: ${GREEN}$current_domain${NC}"
    else
        echo -e "  域名: ${YELLOW}未配置${NC}"
    fi
    echo ""
    
    read -p "请输入新域名 (留空取消): " new_domain
    
    if [ -z "$new_domain" ]; then
        log_info "已取消"
        read -p "按回车键继续..."
        return
    fi
    
    log_warn "请确保域名已解析到本服务器"
    read -p "确认继续? [y/N]: " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return
    
    # 申请证书
    apply_ssl_cert "$new_domain"
    
    # 更新配置
    local tmp=$(mktemp)
    jq ".panel.domain = \"$new_domain\" | .panel.use_ssl = true" "$CONFIG_DIR/config.json" > "$tmp"
    mv "$tmp" "$CONFIG_DIR/config.json"
    
    # 重新创建服务
    create_services
    
    log_info "域名配置完成！"
    echo -e "  访问地址: ${GREEN}https://$new_domain:$WEB_PORT${NC}"
    echo ""
    
    read -p "按回车键继续..."
}

# ==================== 主程序 ====================
main() {
    # 检查是否有命令行参数
    case "${1:-}" in
        install) do_install; exit 0 ;;
        uninstall) do_uninstall; exit 0 ;;
        status) show_status; exit 0 ;;
        info) view_login_info; exit 0 ;;
    esac
    
    # 交互式菜单
    while true; do
        show_menu
        read choice
        
        case $choice in
            1) do_install ;;
            2) do_uninstall ;;
            3) show_status ;;
            4) view_login_info ;;
            5) reset_password ;;
            6) restart_services ;;
            7) view_logs ;;
            8) config_domain ;;
            0) echo ""; exit 0 ;;
            *) log_error "无效选项" ;;
        esac
    done
}

main "$@"
