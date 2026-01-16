#!/bin/bash
#
# TUIC 协议配置模块
#

# 引入公共函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/common.sh" 2>/dev/null || true

# 添加 TUIC 入站
add_tuic_inbound() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    local cert_dir="${CONFIG_DIR:-/etc/transit-panel}/certs"
    
    echo -e "${GREEN}添加 TUIC 入站${NC}"
    echo ""
    
    # 获取用户输入
    read -p "监听端口 [默认: 8443]: " listen_port
    listen_port=${listen_port:-8443}
    
    read -p "入站标签 [默认: tuic-in]: " tag
    tag=${tag:-tuic-in}
    
    # 检查端口
    if ss -tuln | grep -q ":$listen_port "; then
        log_warn "端口 $listen_port 已被占用"
        read -p "请输入新端口: " listen_port
    fi
    
    # 生成 UUID 和密码
    local uuid=$(generate_uuid)
    local password=$(generate_password)
    
    read -p "用户 UUID [默认: $uuid]: " input_uuid
    uuid=${input_uuid:-$uuid}
    
    read -p "用户密码 [默认: $password]: " input_pass
    password=${input_pass:-$password}
    
    # 拥塞控制算法
    echo ""
    echo "拥塞控制算法："
    echo "  1. bbr (推荐)"
    echo "  2. cubic"
    echo "  3. new_reno"
    read -p "请选择 [1-3, 默认: 1]: " cc_choice
    
    local congestion_control="bbr"
    case $cc_choice in
        2) congestion_control="cubic" ;;
        3) congestion_control="new_reno" ;;
        *) congestion_control="bbr" ;;
    esac
    
    # 证书配置
    echo ""
    echo "证书配置："
    echo "  1. 自签名证书 (推荐)"
    echo "  2. 使用已有证书"
    read -p "请选择 [1-2, 默认: 1]: " cert_choice
    cert_choice=${cert_choice:-1}
    
    local cert_path="$cert_dir/tuic-$tag.crt"
    local key_path="$cert_dir/tuic-$tag.key"
    
    case $cert_choice in
        1)
            log_info "生成自签名证书..."
            
            openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
                -keyout "$key_path" \
                -out "$cert_path" \
                -subj "/CN=bing.com" \
                -days 36500 2>/dev/null
            
            chmod 600 "$key_path"
            log_info "证书生成完成"
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
    
    # 构建入站配置
    local inbound_config=$(cat << EOF
{
    "type": "tuic",
    "tag": "$tag",
    "listen": "::",
    "listen_port": $listen_port,
    "users": [
        {
            "uuid": "$uuid",
            "password": "$password"
        }
    ],
    "congestion_control": "$congestion_control",
    "zero_rtt_handshake": false,
    "tls": {
        "enabled": true,
        "certificate_path": "$cert_path",
        "key_path": "$key_path"
    }
}
EOF
)
    
    # 保存配置
    local temp_file=$(mktemp)
    local server_ip=$(jq -r '.panel.server_ip' "$config_file" 2>/dev/null || get_public_ip)
    
    # 面板配置
    local panel_inbound=$(cat << EOF
{
    "type": "tuic",
    "tag": "$tag",
    "port": $listen_port,
    "uuid": "$uuid",
    "password": "$password",
    "congestion_control": "$congestion_control",
    "cert_path": "$cert_path",
    "key_path": "$key_path",
    "created_at": "$(date -Iseconds)"
}
EOF
)
    
    jq ".inbounds += [$panel_inbound]" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # sing-box 配置
    jq ".inbounds += [$inbound_config]" "$singbox_config" > "$temp_file"
    mv "$temp_file" "$singbox_config"
    
    # 配置防火墙
    configure_firewall "$listen_port" "udp"
    
    # 重启服务
    if systemctl is-active --quiet transit-panel; then
        systemctl restart transit-panel
    fi
    
    # 生成分享链接
    local share_link="tuic://$uuid:$password@$server_ip:$listen_port?congestion_control=$congestion_control&udp_relay_mode=native&alpn=h3&allow_insecure=1#$tag"
    
    echo ""
    log_info "=========================================="
    log_info "  TUIC 入站添加成功！"
    log_info "=========================================="
    echo ""
    echo -e "  服务器: ${CYAN}$server_ip${NC}"
    echo -e "  端口: ${CYAN}$listen_port${NC}"
    echo -e "  UUID: ${CYAN}$uuid${NC}"
    echo -e "  密码: ${CYAN}$password${NC}"
    echo -e "  拥塞控制: ${CYAN}$congestion_control${NC}"
    echo ""
    echo -e "  ${YELLOW}分享链接:${NC}"
    echo -e "  ${GREEN}$share_link${NC}"
    echo ""
    
    read -p "按回车键返回..."
}

# 列出 TUIC 入站
list_tuic_inbounds() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    
    echo -e "${GREEN}TUIC 入站列表:${NC}"
    echo ""
    
    local count=$(jq '[.inbounds[] | select(.type == "tuic")] | length' "$config_file" 2>/dev/null || echo "0")
    
    if [ "$count" -eq 0 ]; then
        echo "  暂无 TUIC 入站"
    else
        jq -r '.inbounds[] | select(.type == "tuic") | "  [\(.tag)] 端口: \(.port) UUID: \(.uuid)"' "$config_file"
    fi
    
    echo ""
}

# 删除 TUIC 入站
delete_tuic_inbound() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    list_tuic_inbounds
    
    read -p "请输入要删除的入站标签: " tag
    
    if [ -z "$tag" ]; then
        log_error "标签不能为空"
        return 1
    fi
    
    local temp_file=$(mktemp)
    
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    jq "del(.inbounds[] | select(.tag == \"$tag\"))" "$singbox_config" > "$temp_file"
    mv "$temp_file" "$singbox_config"
    
    if systemctl is-active --quiet transit-panel; then
        systemctl restart transit-panel
    fi
    
    log_info "入站 $tag 已删除"
    read -p "按回车键返回..."
}

# 生成客户端配置
generate_tuic_client_config() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    
    list_tuic_inbounds
    
    read -p "请输入入站标签: " tag
    
    local inbound=$(jq ".inbounds[] | select(.tag == \"$tag\")" "$config_file" 2>/dev/null)
    
    if [ -z "$inbound" ]; then
        log_error "未找到入站: $tag"
        return 1
    fi
    
    local server=$(jq -r '.panel.server_ip' "$config_file")
    local port=$(echo "$inbound" | jq -r '.port')
    local uuid=$(echo "$inbound" | jq -r '.uuid')
    local password=$(echo "$inbound" | jq -r '.password')
    local cc=$(echo "$inbound" | jq -r '.congestion_control')
    
    echo ""
    echo -e "${GREEN}TUIC 客户端配置:${NC}"
    echo ""
    
    cat << EOF
{
    "type": "tuic",
    "tag": "$tag",
    "server": "$server",
    "server_port": $port,
    "uuid": "$uuid",
    "password": "$password",
    "congestion_control": "$cc",
    "udp_relay_mode": "native",
    "tls": {
        "enabled": true,
        "insecure": true
    }
}
EOF
    
    echo ""
    echo -e "${YELLOW}分享链接:${NC}"
    echo "tuic://$uuid:$password@$server:$port?congestion_control=$cc&udp_relay_mode=native&alpn=h3&allow_insecure=1#$tag"
    echo ""
    
    read -p "按回车键返回..."
}
