#!/bin/bash
#
# 中转规则引擎模块
#

# 引入公共函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh" 2>/dev/null || true

# ==================== 一对一中转 ====================

# 添加一对一中转规则
add_one_to_one_route() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    echo -e "${GREEN}添加一对一中转规则${NC}"
    echo ""
    echo "规则说明: 将一个入站的流量转发到一个出站"
    echo ""
    
    # 显示可用的入站
    echo "可用入站:"
    jq -r '.inbounds[] | "  [\(.tag)] \(.type) 端口:\(.port)"' "$config_file" 2>/dev/null || echo "  暂无入站"
    echo ""
    
    read -p "选择入站标签: " inbound_tag
    
    # 验证入站存在
    if ! jq -e ".inbounds[] | select(.tag == \"$inbound_tag\")" "$config_file" &>/dev/null; then
        log_error "未找到入站: $inbound_tag"
        return 1
    fi
    
    # 显示可用的出站
    echo ""
    echo "可用出站:"
    jq -r '.outbounds[] | "  [\(.tag)] \(.server):\(.server_port)"' "$config_file" 2>/dev/null || echo "  暂无出站"
    echo ""
    
    read -p "选择出站标签: " outbound_tag
    
    # 验证出站存在
    if ! jq -e ".outbounds[] | select(.tag == \"$outbound_tag\")" "$config_file" &>/dev/null; then
        log_error "未找到出站: $outbound_tag"
        return 1
    fi
    
    # 生成规则名称
    local route_name="${inbound_tag}-to-${outbound_tag}"
    read -p "规则名称 [默认: $route_name]: " input_name
    route_name=${input_name:-$route_name}
    
    # 保存规则到面板配置
    local temp_file=$(mktemp)
    local route_config=$(cat << EOF
{
    "name": "$route_name",
    "type": "one-to-one",
    "inbound": "$inbound_tag",
    "outbound": "$outbound_tag",
    "created_at": "$(date -Iseconds)"
}
EOF
)
    
    jq ".routes += [$route_config]" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # 更新 sing-box 路由配置
    update_singbox_routes
    
    echo ""
    log_info "一对一中转规则添加成功！"
    echo ""
    echo -e "  规则: ${CYAN}$inbound_tag${NC} → ${CYAN}$outbound_tag${NC}"
    echo ""
    
    read -p "按回车键返回..."
}

# ==================== 一对多中转 ====================

# 添加一对多中转规则（负载均衡/故障转移）
add_one_to_many_route() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    echo -e "${GREEN}添加一对多中转规则${NC}"
    echo ""
    echo "规则说明: 将一个入站的流量分发到多个出站"
    echo ""
    
    # 显示可用的入站
    echo "可用入站:"
    jq -r '.inbounds[] | "  [\(.tag)] \(.type) 端口:\(.port)"' "$config_file" 2>/dev/null || echo "  暂无入站"
    echo ""
    
    read -p "选择入站标签: " inbound_tag
    
    if ! jq -e ".inbounds[] | select(.tag == \"$inbound_tag\")" "$config_file" &>/dev/null; then
        log_error "未找到入站: $inbound_tag"
        return 1
    fi
    
    # 显示可用的出站
    echo ""
    echo "可用出站:"
    jq -r '.outbounds[] | "  [\(.tag)] \(.server):\(.server_port)"' "$config_file" 2>/dev/null || echo "  暂无出站"
    echo ""
    
    echo "请输入出站标签（用逗号分隔，例如: proxy1,proxy2,proxy3）:"
    read -p "> " outbound_tags_input
    
    # 解析出站标签
    IFS=',' read -ra outbound_tags <<< "$outbound_tags_input"
    
    if [ ${#outbound_tags[@]} -lt 2 ]; then
        log_error "至少需要选择 2 个出站"
        return 1
    fi
    
    # 验证所有出站存在
    for tag in "${outbound_tags[@]}"; do
        tag=$(echo "$tag" | xargs)  # 去除空格
        if ! jq -e ".outbounds[] | select(.tag == \"$tag\")" "$config_file" &>/dev/null; then
            log_error "未找到出站: $tag"
            return 1
        fi
    done
    
    # 选择负载均衡策略
    echo ""
    echo "负载均衡策略:"
    echo "  1. random - 随机选择"
    echo "  2. consistent_hashing - 一致性哈希"
    echo "  3. round_robin - 轮询"
    echo "  4. fallback - 故障转移"
    read -p "请选择 [1-4, 默认: 1]: " strategy_choice
    
    local strategy="random"
    local route_type="urltest"
    case $strategy_choice in
        2) strategy="consistent_hashing"; route_type="urltest" ;;
        3) strategy="round_robin"; route_type="urltest" ;;
        4) strategy="fallback"; route_type="selector" ;;
        *) strategy="random"; route_type="urltest" ;;
    esac
    
    # 生成规则名称
    local route_name="${inbound_tag}-lb"
    read -p "规则名称 [默认: $route_name]: " input_name
    route_name=${input_name:-$route_name}
    
    # 构建出站标签数组
    local outbounds_json=$(printf '%s\n' "${outbound_tags[@]}" | jq -R . | jq -s .)
    
    # 保存规则
    local temp_file=$(mktemp)
    local route_config=$(cat << EOF
{
    "name": "$route_name",
    "type": "one-to-many",
    "inbound": "$inbound_tag",
    "outbounds": $outbounds_json,
    "strategy": "$strategy",
    "created_at": "$(date -Iseconds)"
}
EOF
)
    
    jq ".routes += [$route_config]" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # 创建负载均衡出站组
    local lb_outbound=""
    if [ "$route_type" = "urltest" ]; then
        lb_outbound=$(cat << EOF
{
    "type": "urltest",
    "tag": "$route_name",
    "outbounds": $outbounds_json,
    "url": "https://www.gstatic.com/generate_204",
    "interval": "3m",
    "tolerance": 50
}
EOF
)
    else
        lb_outbound=$(cat << EOF
{
    "type": "selector",
    "tag": "$route_name",
    "outbounds": $outbounds_json,
    "default": "$(echo ${outbound_tags[0]} | xargs)"
}
EOF
)
    fi
    
    # 添加负载均衡出站到 sing-box
    jq ".outbounds += [$lb_outbound]" "$singbox_config" > "$temp_file"
    mv "$temp_file" "$singbox_config"
    
    # 更新路由
    update_singbox_routes
    
    echo ""
    log_info "一对多中转规则添加成功！"
    echo ""
    echo -e "  入站: ${CYAN}$inbound_tag${NC}"
    echo -e "  出站: ${CYAN}${outbound_tags[*]}${NC}"
    echo -e "  策略: ${CYAN}$strategy${NC}"
    echo ""
    
    read -p "按回车键返回..."
}

# ==================== 多对多中转 ====================

# 添加多对多中转规则
add_many_to_many_route() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    echo -e "${GREEN}添加多对多中转规则${NC}"
    echo ""
    echo "规则说明: 将多个入站的流量路由到多个出站（基于规则）"
    echo ""
    
    # 显示可用的入站
    echo "可用入站:"
    jq -r '.inbounds[] | "  [\(.tag)] \(.type) 端口:\(.port)"' "$config_file" 2>/dev/null || echo "  暂无入站"
    echo ""
    
    echo "请输入入站标签（用逗号分隔）:"
    read -p "> " inbound_tags_input
    
    IFS=',' read -ra inbound_tags <<< "$inbound_tags_input"
    
    # 显示可用的出站
    echo ""
    echo "可用出站:"
    jq -r '.outbounds[] | "  [\(.tag)] \(.server):\(.server_port)"' "$config_file" 2>/dev/null || echo "  暂无出站"
    echo ""
    
    echo "请输入出站标签（用逗号分隔）:"
    read -p "> " outbound_tags_input
    
    IFS=',' read -ra outbound_tags <<< "$outbound_tags_input"
    
    # 选择默认出站
    echo ""
    echo "请选择默认出站（当没有匹配规则时使用）:"
    read -p "默认出站 [默认: ${outbound_tags[0]}]: " default_outbound
    default_outbound=${default_outbound:-$(echo ${outbound_tags[0]} | xargs)}
    
    # 生成规则名称
    local route_name="multi-route-$(date +%s)"
    read -p "规则名称 [默认: $route_name]: " input_name
    route_name=${input_name:-$route_name}
    
    # 构建数组
    local inbounds_json=$(printf '%s\n' "${inbound_tags[@]}" | xargs -I{} echo {} | jq -R . | jq -s .)
    local outbounds_json=$(printf '%s\n' "${outbound_tags[@]}" | xargs -I{} echo {} | jq -R . | jq -s .)
    
    # 保存规则
    local temp_file=$(mktemp)
    local route_config=$(cat << EOF
{
    "name": "$route_name",
    "type": "many-to-many",
    "inbounds": $inbounds_json,
    "outbounds": $outbounds_json,
    "default": "$default_outbound",
    "created_at": "$(date -Iseconds)"
}
EOF
)
    
    jq ".routes += [$route_config]" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # 更新路由
    update_singbox_routes
    
    echo ""
    log_info "多对多中转规则添加成功！"
    echo ""
    echo -e "  入站: ${CYAN}${inbound_tags[*]}${NC}"
    echo -e "  出站: ${CYAN}${outbound_tags[*]}${NC}"
    echo -e "  默认: ${CYAN}$default_outbound${NC}"
    echo ""
    
    read -p "按回车键返回..."
}

# ==================== 规则管理 ====================

# 列出所有规则
list_routes() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    
    echo -e "${GREEN}中转规则列表:${NC}"
    echo ""
    
    local count=$(jq '.routes | length' "$config_file" 2>/dev/null || echo "0")
    
    if [ "$count" -eq 0 ]; then
        echo "  暂无中转规则"
    else
        echo "  序号  名称                    类型            入站 → 出站"
        echo "  ────  ──────────────────────  ──────────────  ──────────────────────────"
        
        local i=1
        while read -r line; do
            local name=$(echo "$line" | jq -r '.name')
            local type=$(echo "$line" | jq -r '.type')
            local inbound=$(echo "$line" | jq -r '.inbound // (.inbounds | join(","))')
            local outbound=$(echo "$line" | jq -r '.outbound // (.outbounds | join(","))')
            
            printf "  %-4s  %-22s  %-14s  %s → %s\n" "$i" "$name" "$type" "$inbound" "$outbound"
            ((i++))
        done < <(jq -c '.routes[]' "$config_file" 2>/dev/null)
    fi
    
    echo ""
}

# 删除规则
delete_route() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    list_routes
    
    read -p "请输入要删除的规则名称: " route_name
    
    if [ -z "$route_name" ]; then
        log_error "规则名称不能为空"
        return 1
    fi
    
    # 获取规则信息
    local route=$(jq ".routes[] | select(.name == \"$route_name\")" "$config_file" 2>/dev/null)
    
    if [ -z "$route" ]; then
        log_error "未找到规则: $route_name"
        return 1
    fi
    
    local temp_file=$(mktemp)
    
    # 从面板配置删除
    jq "del(.routes[] | select(.name == \"$route_name\"))" "$config_file" > "$temp_file"
    mv "$temp_file" "$config_file"
    
    # 从 sing-box 配置删除对应的出站组
    jq "del(.outbounds[] | select(.tag == \"$route_name\"))" "$singbox_config" > "$temp_file"
    mv "$temp_file" "$singbox_config"
    
    # 更新路由
    update_singbox_routes
    
    log_info "规则 $route_name 已删除"
    read -p "按回车键返回..."
}

# ==================== 路由配置生成 ====================

# 更新 sing-box 路由配置
update_singbox_routes() {
    local config_file="${CONFIG_DIR:-/etc/transit-panel}/config.json"
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    local temp_file=$(mktemp)
    local rules="[]"
    
    # 遍历所有规则生成路由
    while read -r route; do
        local type=$(echo "$route" | jq -r '.type')
        local name=$(echo "$route" | jq -r '.name')
        
        case $type in
            "one-to-one")
                local inbound=$(echo "$route" | jq -r '.inbound')
                local outbound=$(echo "$route" | jq -r '.outbound')
                
                local rule=$(cat << EOF
{
    "inbound": ["$inbound"],
    "outbound": "$outbound"
}
EOF
)
                rules=$(echo "$rules" | jq ". += [$rule]")
                ;;
            
            "one-to-many")
                local inbound=$(echo "$route" | jq -r '.inbound')
                
                # 使用规则名称作为出站（指向负载均衡组）
                local rule=$(cat << EOF
{
    "inbound": ["$inbound"],
    "outbound": "$name"
}
EOF
)
                rules=$(echo "$rules" | jq ". += [$rule]")
                ;;
            
            "many-to-many")
                local inbounds=$(echo "$route" | jq -c '.inbounds')
                local default_out=$(echo "$route" | jq -r '.default')
                
                local rule=$(cat << EOF
{
    "inbound": $inbounds,
    "outbound": "$default_out"
}
EOF
)
                rules=$(echo "$rules" | jq ". += [$rule]")
                ;;
        esac
    done < <(jq -c '.routes[]' "$config_file" 2>/dev/null)
    
    # 更新 sing-box 路由配置
    jq ".route.rules = $rules" "$singbox_config" > "$temp_file"
    mv "$temp_file" "$singbox_config"
    
    # 重启服务使配置生效
    if systemctl is-active --quiet transit-panel; then
        if $SINGBOX_BIN check -c "$singbox_config" 2>/dev/null; then
            systemctl restart transit-panel
            log_info "路由配置已更新并生效"
        else
            log_error "配置验证失败，请检查配置"
        fi
    fi
}

# 验证路由配置
validate_routes() {
    local singbox_config="${CONFIG_DIR:-/etc/transit-panel}/singbox.json"
    
    if $SINGBOX_BIN check -c "$singbox_config" 2>&1; then
        log_info "配置验证通过"
        return 0
    else
        log_error "配置验证失败"
        return 1
    fi
}
