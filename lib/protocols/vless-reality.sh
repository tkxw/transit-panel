#!/bin/bash
#
# VLESS + Reality + Vision 协议配置模块
#

# 引入公共函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/common.sh" 2>/dev/null || true

# 生成 Reality 密钥对
generate_reality_keypair() {
    local singbox_bin="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
    
    if [ -x "$singbox_bin" ]; then
        $singbox_bin generate reality-keypair
    else
        log_error "sing-box 未安装"
        return 1
    fi
}

# 生成 short_id
generate_short_id() {
    openssl rand -hex 8
}

# 添加 VLESS Reality 入站
add_vless_reality_inbound() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    local singbox_bin="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
    
    echo -e "${GREEN}添加 VLESS + Reality + Vision 入站${NC}"
    echo ""
    
    # 获取用户输入
    read -p "监听端口 [默认: 443]: " listen_port
    listen_port=${listen_port:-443}
    
    read -p "入站标签 [默认: vless-reality-in]: " tag
    tag=${tag:-vless-reality-in}
    
    # 检查端口
    if ss -tuln | grep -q ":$listen_port "; then
        log_warn "端口 $listen_port 已被占用"
        read -p "请输入新端口: " listen_port
    fi
    
    # 生成 UUID
    local uuid=$(generate_uuid)
    read -p "用户 UUID [默认: $uuid]: " input_uuid
    uuid=${input_uuid:-$uuid}
    
    # Reality 配置
    echo ""
    log_info "生成 Reality 密钥对..."
    local keypair=$($singbox_bin generate reality-keypair 2>/dev/null)
    
    local private_key=$(echo "$keypair" | grep "PrivateKey" | awk '{print $2}')
    local public_key=$(echo "$keypair" | grep "PublicKey" | awk '{print $2}')
    
    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        log_error "生成 Reality 密钥对失败"
        return 1
    fi
    
    log_info "私钥: $private_key"
    log_info "公钥: $public_key"
    
    # 生成 short_id
    local short_id=$(generate_short_id)
    read -p "Short ID [默认: $short_id]: " input_short_id
    short_id=${input_short_id:-$short_id}
    
    # 伪装域名
    echo ""
    echo "伪装目标配置 (需要支持 TLS 1.3 和 HTTP/2):"
    echo "  推荐: www.microsoft.com, www.apple.com, www.cloudflare.com"
    read -p "伪装域名 [默认: www.microsoft.com]: " server_name
    server_name=${server_name:-www.microsoft.com}
    
    read -p "握手服务器 [默认: $server_name]: " handshake_server
    handshake_server=${handshake_server:-$server_name}
    
    # 构建入站配置
    local inbound_config=$(cat << EOF
{
    "type": "vless",
    "tag": "$tag",
    "listen": "::",
    "listen_port": $listen_port,
    "users": [
        {
            "uuid": "$uuid",
            "flow": "xtls-rprx-vision"
        }
    ],
    "tls": {
        "enabled": true,
        "server_name": "$server_name",
        "reality": {
            "enabled": true,
            "handshake": {
                "server": "$handshake_server",
                "server_port": 443
            },
            "private_key": "$private_key",
            "short_id": ["$short_id"]
        }
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
    "type": "vless-reality",
    "tag": "$tag",
    "port": $listen_port,
    "uuid": "$uuid",
    "flow": "xtls-rprx-vision",
    "server_name": "$server_name",
    "public_key": "$public_key",
    "private_key": "$private_key",
    "short_id": "$short_id",
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
    configure_firewall "$listen_port" "tcp"
    
    # 重启服务
    if systemctl is-active --quiet transit-panel; then
        systemctl restart transit-panel
    fi
    
    # 生成分享链接
    local share_link="vless://$uuid@$server_ip:$listen_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$server_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#$tag"
    
    echo ""
    log_info "=========================================="
    log_info "  VLESS Reality 入站添加成功！"
    log_info "=========================================="
    echo ""
    echo -e "  服务器: ${CYAN}$server_ip${NC}"
    echo -e "  端口: ${CYAN}$listen_port${NC}"
    echo -e "  UUID: ${CYAN}$uuid${NC}"
    echo -e "  流控: ${CYAN}xtls-rprx-vision${NC}"
    echo -e "  SNI: ${CYAN}$server_name${NC}"
    echo -e "  公钥: ${CYAN}$public_key${NC}"
    echo -e "  Short ID: ${CYAN}$short_id${NC}"
    echo ""
    echo -e "  ${YELLOW}分享链接:${NC}"
    echo -e "  ${GREEN}$share_link${NC}"
    echo ""
    
    read -p "按回车键返回..."
}

# 列出 VLESS Reality 入站
list_vless_reality_inbounds() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    
    echo -e "${GREEN}VLESS Reality 入站列表:${NC}"
    echo ""
    
    local count=$(jq '[.inbounds[] | select(.type == "vless-reality")] | length' "$config_file" 2>/dev/null || echo "0")
    
    if [ "$count" -eq 0 ]; then
        echo "  暂无 VLESS Reality 入站"
    else
        jq -r '.inbounds[] | select(.type == "vless-reality") | "  [\(.tag)] 端口: \(.port) UUID: \(.uuid)"' "$config_file"
    fi
    
    echo ""
}

# 删除 VLESS Reality 入站
delete_vless_reality_inbound() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    list_vless_reality_inbounds
    
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
generate_vless_reality_client_config() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    
    list_vless_reality_inbounds
    
    read -p "请输入入站标签: " tag
    
    local inbound=$(jq ".inbounds[] | select(.tag == \"$tag\")" "$config_file" 2>/dev/null)
    
    if [ -z "$inbound" ]; then
        log_error "未找到入站: $tag"
        return 1
    fi
    
    local server=$(jq -r '.panel.server_ip' "$config_file")
    local port=$(echo "$inbound" | jq -r '.port')
    local uuid=$(echo "$inbound" | jq -r '.uuid')
    local server_name=$(echo "$inbound" | jq -r '.server_name')
    local public_key=$(echo "$inbound" | jq -r '.public_key')
    local short_id=$(echo "$inbound" | jq -r '.short_id')
    
    echo ""
    echo -e "${GREEN}VLESS Reality 客户端配置:${NC}"
    echo ""
    
    cat << EOF
{
    "type": "vless",
    "tag": "$tag",
    "server": "$server",
    "server_port": $port,
    "uuid": "$uuid",
    "flow": "xtls-rprx-vision",
    "tls": {
        "enabled": true,
        "server_name": "$server_name",
        "utls": {
            "enabled": true,
            "fingerprint": "chrome"
        },
        "reality": {
            "enabled": true,
            "public_key": "$public_key",
            "short_id": "$short_id"
        }
    }
}
EOF
    
    echo ""
    echo -e "${YELLOW}分享链接:${NC}"
    echo "vless://$uuid@$server:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$server_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#$tag"
    echo ""
    
    read -p "按回车键返回..."
}
