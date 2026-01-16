#!/bin/bash
#
# 出站管理模块
#

# 引入公共函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh" 2>/dev/null || true

# 添加 SOCKS5 出站
add_socks_outbound() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    echo -e "${GREEN}添加 SOCKS5 出站${NC}"
    echo ""
    
    # 获取用户输入
    read -p "出站标签 [必填]: " tag
    if [ -z "$tag" ]; then
        log_error "标签不能为空"
        return 1
    fi
    
    # 检查标签是否已存在
    if jq -e ".outbounds[] | select(.tag == \"$tag\")" "$config_file" &>/dev/null; then
        log_error "标签 $tag 已存在"
        return 1
    fi
    
    read -p "服务器地址 [必填]: " server
    if [ -z "$server" ]; then
        log_error "服务器地址不能为空"
        return 1
    fi
    
    read -p "服务器端口 [必填]: " server_port
    if [ -z "$server_port" ]; then
        log_error "端口不能为空"
        return 1
    fi
    
    # 认证信息（可选）
    read -p "用户名 [可选，留空跳过]: " username
    read -p "密码 [可选，留空跳过]: " password
    
    # 备注
    read -p "备注 [可选]: " remark
    
    # 构建 sing-box 出站配置
    local outbound_config=""
    if [ -n "$username" ] && [ -n "$password" ]; then
        outbound_config=$(cat << EOF
{
    "type": "socks",
    "tag": "$tag",
    "server": "$server",
    "server_port": $server_port,
    "username": "$username",
    "password": "$password"
}
EOF
)
    else
        outbound_config=$(cat << EOF
{
    "type": "socks",
    "tag": "$tag",
    "server": "$server",
    "server_port": $server_port
}
EOF
)
    fi
    
    # 保存到面板配置
    local temp_file=$(mktemp)
    local panel_outbound=$(cat << EOF
{
    "type": "socks",
    "tag": "$tag",
    "server": "$server",
    "server_port": $server_port,
    "username": "${username:-}",
    "password": "${password:-}",
    "remark": "${remark:-}",
    "created_at": "$(date -Iseconds)"
}
EOF
)
    
    jq ".outbounds += [$panel_outbound]" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # 添加到 sing-box 配置
    jq ".outbounds += [$outbound_config]" "$singbox_config" > "$temp_file"
    mv "$temp_file" "$singbox_config"
    
    echo ""
    log_info "SOCKS5 出站添加成功！"
    echo ""
    echo -e "  标签: ${CYAN}$tag${NC}"
    echo -e "  服务器: ${CYAN}$server:$server_port${NC}"
    if [ -n "$username" ]; then
        echo -e "  认证: ${CYAN}$username${NC}"
    fi
    echo ""
    
    # 询问是否测试连接
    read -p "是否测试连接? (y/N): " test_conn
    if [[ "$test_conn" =~ ^[Yy]$ ]]; then
        test_socks_connection "$server" "$server_port" "$username" "$password"
    fi
    
    read -p "按回车键返回..."
}

# 测试 SOCKS 连接
test_socks_connection() {
    local server=$1
    local port=$2
    local username=$3
    local password=$4
    
    log_info "测试连接到 $server:$port..."
    
    local proxy_url=""
    if [ -n "$username" ] && [ -n "$password" ]; then
        proxy_url="socks5://$username:$password@$server:$port"
    else
        proxy_url="socks5://$server:$port"
    fi
    
    # 测试连接
    local start_time=$(date +%s%N)
    if curl -x "$proxy_url" -s --max-time 10 https://www.google.com/generate_204 &>/dev/null; then
        local end_time=$(date +%s%N)
        local latency=$(( (end_time - start_time) / 1000000 ))
        log_info "连接成功！延迟: ${latency}ms"
        return 0
    else
        log_error "连接失败"
        return 1
    fi
}

# 列出所有出站
list_outbounds() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    
    echo -e "${GREEN}出站节点列表:${NC}"
    echo ""
    
    local count=$(jq '.outbounds | length' "$config_file" 2>/dev/null || echo "0")
    
    if [ "$count" -eq 0 ]; then
        echo "  暂无出站节点"
    else
        echo "  序号  标签                服务器                      备注"
        echo "  ────  ────────────────    ─────────────────────────   ────────"
        
        local i=1
        while read -r line; do
            local tag=$(echo "$line" | jq -r '.tag')
            local server=$(echo "$line" | jq -r '.server')
            local port=$(echo "$line" | jq -r '.server_port')
            local remark=$(echo "$line" | jq -r '.remark // ""')
            
            printf "  %-4s  %-18s  %-25s   %s\n" "$i" "$tag" "$server:$port" "$remark"
            ((i++))
        done < <(jq -c '.outbounds[]' "$config_file" 2>/dev/null)
    fi
    
    echo ""
}

# 删除出站
delete_outbound() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    list_outbounds
    
    read -p "请输入要删除的出站标签: " tag
    
    if [ -z "$tag" ]; then
        log_error "标签不能为空"
        return 1
    fi
    
    # 检查是否存在
    if ! jq -e ".outbounds[] | select(.tag == \"$tag\")" "$config_file" &>/dev/null; then
        log_error "未找到出站: $tag"
        return 1
    fi
    
    # 检查是否被中转规则引用
    local route_count=$(jq "[.routes[] | select(.outbound == \"$tag\" or (.outbounds[]? == \"$tag\"))] | length" "$config_file" 2>/dev/null || echo "0")
    if [ "$route_count" -gt 0 ]; then
        log_warn "该出站被 $route_count 条中转规则引用"
        read -p "是否强制删除? (y/N): " force
        if [[ ! "$force" =~ ^[Yy]$ ]]; then
            log_info "已取消删除"
            return 0
        fi
    fi
    
    local temp_file=$(mktemp)
    
    # 从面板配置删除
    jq "del(.outbounds[] | select(.tag == \"$tag\"))" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # 从 sing-box 配置删除
    jq "del(.outbounds[] | select(.tag == \"$tag\"))" "$singbox_config" > "$temp_file"
    mv "$temp_file" "$singbox_config"
    
    log_info "出站 $tag 已删除"
    read -p "按回车键返回..."
}

# 编辑出站
edit_outbound() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    list_outbounds
    
    read -p "请输入要编辑的出站标签: " tag
    
    if [ -z "$tag" ]; then
        log_error "标签不能为空"
        return 1
    fi
    
    local outbound=$(jq ".outbounds[] | select(.tag == \"$tag\")" "$config_file" 2>/dev/null)
    
    if [ -z "$outbound" ]; then
        log_error "未找到出站: $tag"
        return 1
    fi
    
    # 显示当前配置
    local current_server=$(echo "$outbound" | jq -r '.server')
    local current_port=$(echo "$outbound" | jq -r '.server_port')
    local current_user=$(echo "$outbound" | jq -r '.username // ""')
    local current_pass=$(echo "$outbound" | jq -r '.password // ""')
    local current_remark=$(echo "$outbound" | jq -r '.remark // ""')
    
    echo ""
    echo -e "当前配置:"
    echo -e "  服务器: ${CYAN}$current_server:$current_port${NC}"
    if [ -n "$current_user" ]; then
        echo -e "  用户名: ${CYAN}$current_user${NC}"
    fi
    if [ -n "$current_remark" ]; then
        echo -e "  备注: ${CYAN}$current_remark${NC}"
    fi
    echo ""
    
    # 获取新值
    read -p "新服务器地址 [留空保持不变]: " new_server
    read -p "新端口 [留空保持不变]: " new_port
    read -p "新用户名 [留空保持不变，输入 'none' 清除]: " new_user
    read -p "新密码 [留空保持不变，输入 'none' 清除]: " new_pass
    read -p "新备注 [留空保持不变]: " new_remark
    
    # 应用更新
    new_server=${new_server:-$current_server}
    new_port=${new_port:-$current_port}
    [ "$new_user" = "none" ] && new_user="" || new_user=${new_user:-$current_user}
    [ "$new_pass" = "none" ] && new_pass="" || new_pass=${new_pass:-$current_pass}
    new_remark=${new_remark:-$current_remark}
    
    local temp_file=$(mktemp)
    
    # 更新面板配置
    jq "(.outbounds[] | select(.tag == \"$tag\")) |= . + {server: \"$new_server\", server_port: $new_port, username: \"$new_user\", password: \"$new_pass\", remark: \"$new_remark\"}" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # 更新 sing-box 配置
    if [ -n "$new_user" ] && [ -n "$new_pass" ]; then
        jq "(.outbounds[] | select(.tag == \"$tag\")) |= . + {server: \"$new_server\", server_port: $new_port, username: \"$new_user\", password: \"$new_pass\"}" "$singbox_config" > "$temp_file"
    else
        jq "(.outbounds[] | select(.tag == \"$tag\")) |= {type: \"socks\", tag: \"$tag\", server: \"$new_server\", server_port: $new_port}" "$singbox_config" > "$temp_file"
    fi
    mv "$temp_file" "$singbox_config"
    
    log_info "出站 $tag 已更新"
    read -p "按回车键返回..."
}

# 批量测试出站
test_all_outbounds() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    
    echo -e "${GREEN}批量测试出站连接:${NC}"
    echo ""
    
    local count=$(jq '.outbounds | length' "$config_file" 2>/dev/null || echo "0")
    
    if [ "$count" -eq 0 ]; then
        echo "  暂无出站节点"
        read -p "按回车键返回..."
        return 0
    fi
    
    echo "  标签                状态        延迟"
    echo "  ────────────────    ────────    ────────"
    
    while read -r line; do
        local tag=$(echo "$line" | jq -r '.tag')
        local server=$(echo "$line" | jq -r '.server')
        local port=$(echo "$line" | jq -r '.server_port')
        local username=$(echo "$line" | jq -r '.username // ""')
        local password=$(echo "$line" | jq -r '.password // ""')
        
        local proxy_url=""
        if [ -n "$username" ] && [ -n "$password" ]; then
            proxy_url="socks5://$username:$password@$server:$port"
        else
            proxy_url="socks5://$server:$port"
        fi
        
        local start_time=$(date +%s%N)
        if curl -x "$proxy_url" -s --max-time 5 https://www.google.com/generate_204 &>/dev/null; then
            local end_time=$(date +%s%N)
            local latency=$(( (end_time - start_time) / 1000000 ))
            printf "  %-18s  ${GREEN}%-8s${NC}    %sms\n" "$tag" "在线" "$latency"
        else
            printf "  %-18s  ${RED}%-8s${NC}    -\n" "$tag" "离线"
        fi
    done < <(jq -c '.outbounds[]' "$config_file" 2>/dev/null)
    
    echo ""
    read -p "按回车键返回..."
}
