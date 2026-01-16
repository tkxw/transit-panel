#!/bin/bash
#
# Hysteria2 协议配置模块
#

# 引入公共函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/common.sh" 2>/dev/null || true

# 添加 Hysteria2 入站
add_hy2_inbound() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    local cert_dir="${CONFIG_DIR:-/etc/transit-panel}/certs"
    
    echo -e "${GREEN}添加 Hysteria2 入站${NC}"
    echo ""
    
    # 获取用户输入
    read -p "监听端口 [默认: 443]: " listen_port
    listen_port=${listen_port:-443}
    
    read -p "入站标签 [默认: hy2-in]: " tag
    tag=${tag:-hy2-in}
    
    # 检查端口是否已被使用
    if ss -tuln | grep -q ":$listen_port "; then
        log_warn "端口 $listen_port 已被占用，请选择其他端口"
        read -p "请输入新端口: " listen_port
    fi
    
    # 生成密码
    local password=$(generate_password)
    read -p "认证密码 [默认: $password]: " input_pass
    password=${input_pass:-$password}
    
    # 证书配置
    echo ""
    echo "证书配置："
    echo "  1. 自签名证书 (推荐，无需域名)"
    echo "  2. 使用已有证书"
    read -p "请选择 [1-2, 默认: 1]: " cert_choice
    cert_choice=${cert_choice:-1}
    
    local cert_path="$cert_dir/hy2-$tag.crt"
    local key_path="$cert_dir/hy2-$tag.key"
    
    case $cert_choice in
        1)
            # 生成自签名证书
            log_info "生成自签名证书..."
            local server_ip=$(get_public_ip 2>/dev/null || echo "localhost")
            
            openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout "$key_path" \
                -out "$cert_path" \
                -subj "/CN=bing.com" \
                -days 36500 2>/dev/null
            
            chmod 600 "$key_path"
            log_info "自签名证书生成完成"
            ;;
        2)
            read -p "证书路径: " cert_path
            read -p "私钥路径: " key_path
            
            if [ ! -f "$cert_path" ] || [ ! -f "$key_path" ]; then
                log_error "证书或私钥文件不存在"
                return 1
            fi
            ;;
    esac
    
    # 高级选项
    echo ""
    read -p "是否配置端口跳跃? (y/N): " port_hopping
    local port_hopping_config=""
    if [[ "$port_hopping" =~ ^[Yy]$ ]]; then
        read -p "端口范围 (格式: 10000-20000): " port_range
        if [[ "$port_range" =~ ^[0-9]+-[0-9]+$ ]]; then
            port_hopping_config="$port_range"
        fi
    fi
    
    # 伪装配置
    read -p "伪装域名 [默认: www.bing.com]: " masquerade
    masquerade=${masquerade:-www.bing.com}
    
    # 构建入站配置
    local inbound_config=$(cat << EOF
{
    "type": "hysteria2",
    "tag": "$tag",
    "listen": "::",
    "listen_port": $listen_port,
    "users": [
        {
            "password": "$password"
        }
    ],
    "masquerade": "https://$masquerade",
    "tls": {
        "enabled": true,
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
    }
}
EOF
)
    
    # 保存到配置
    local temp_file=$(mktemp)
    local server_ip=$(jq -r '.panel.server_ip' "$config_file" 2>/dev/null || get_public_ip)
    
    # 添加到面板配置
    local panel_inbound=$(cat << EOF
{
    "type": "hysteria2",
    "tag": "$tag",
    "port": $listen_port,
    "password": "$password",
    "cert_path": "$cert_path",
    "key_path": "$key_path",
    "masquerade": "$masquerade",
    "created_at": "$(date -Iseconds)"
}
EOF
)
    
    jq ".inbounds += [$panel_inbound]" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # 更新 sing-box 配置
    jq ".inbounds += [$inbound_config]" "$singbox_config" > "$temp_file"
    mv "$temp_file" "$singbox_config"
    
    # 配置防火墙
    configure_firewall "$listen_port" "udp"
    
    # 重启服务
    if systemctl is-active --quiet transit-panel; then
        systemctl restart transit-panel
    fi
    
    # 生成分享链接
    local share_link="hy2://$password@$server_ip:$listen_port?insecure=1&sni=$masquerade#$tag"
    
    echo ""
    log_info "=========================================="
    log_info "  Hysteria2 入站添加成功！"
    log_info "=========================================="
    echo ""
    echo -e "  服务器: ${CYAN}$server_ip${NC}"
    echo -e "  端口: ${CYAN}$listen_port${NC}"
    echo -e "  密码: ${CYAN}$password${NC}"
    echo -e "  伪装: ${CYAN}$masquerade${NC}"
    echo ""
    echo -e "  ${YELLOW}分享链接:${NC}"
    echo -e "  ${GREEN}$share_link${NC}"
    echo ""
    
    read -p "按回车键返回..."
}

# 配置防火墙
configure_firewall() {
    local port=$1
    local protocol=${2:-tcp}
    
    # 检测防火墙类型
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        ufw allow "$port/$protocol" 2>/dev/null || true
    elif command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port="$port/$protocol" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    elif command -v iptables &> /dev/null; then
        iptables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || true
    fi
}

# 列出所有 Hysteria2 入站
list_hy2_inbounds() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    
    echo -e "${GREEN}Hysteria2 入站列表:${NC}"
    echo ""
    
    local count=$(jq '[.inbounds[] | select(.type == "hysteria2")] | length' "$config_file" 2>/dev/null || echo "0")
    
    if [ "$count" -eq 0 ]; then
        echo "  暂无 Hysteria2 入站"
    else
        jq -r '.inbounds[] | select(.type == "hysteria2") | "  [\(.tag)] 端口: \(.port) 密码: \(.password)"' "$config_file"
    fi
    
    echo ""
}

# 删除 Hysteria2 入站
delete_hy2_inbound() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    list_hy2_inbounds
    
    read -p "请输入要删除的入站标签: " tag
    
    if [ -z "$tag" ]; then
        log_error "标签不能为空"
        return 1
    fi
    
    local temp_file=$(mktemp)
    
    # 从面板配置删除
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # 从 sing-box 配置删除
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$singbox_config" > "$temp_file"
    mv "$temp_file" "$singbox_config"
    
    # 重启服务
    if systemctl is-active --quiet transit-panel; then
        systemctl restart transit-panel
    fi
    
    log_info "入站 $tag 已删除"
    read -p "按回车键返回..."
}

# 生成客户端配置
generate_hy2_client_config() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    
    list_hy2_inbounds
    
    read -p "请输入入站标签: " tag
    
    local inbound=$(jq ".inbounds[] | select(.tag == \"$tag\")" "$config_file" 2>/dev/null)
    
    if [ -z "$inbound" ]; then
        log_error "未找到入站: $tag"
        return 1
    fi
    
    local server=$(jq -r '.panel.server_ip' "$config_file")
    local port=$(echo "$inbound" | jq -r '.port')
    local password=$(echo "$inbound" | jq -r '.password')
    local sni=$(echo "$inbound" | jq -r '.masquerade')
    
    echo ""
    echo -e "${GREEN}Hysteria2 客户端配置:${NC}"
    echo ""
    
    # sing-box 客户端配置
    cat << EOF
{
    "type": "hysteria2",
    "tag": "$tag",
    "server": "$server",
    "server_port": $port,
    "password": "$password",
    "tls": {
        "enabled": true,
        "server_name": "$sni",
        "insecure": true
    }
}
EOF
    
    echo ""
    echo -e "${YELLOW}分享链接:${NC}"
    echo "hy2://$password@$server:$port?insecure=1&sni=$sni#$tag"
    echo ""
    
    read -p "按回车键返回..."
}
