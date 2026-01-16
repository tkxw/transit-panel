#!/bin/bash
#
# 节点中转面板 - 卸载脚本
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

INSTALL_DIR="/opt/transit-panel"
CONFIG_DIR="/etc/transit-panel"
DATA_DIR="/var/lib/transit-panel"
LOG_DIR="/var/log/transit-panel"
SINGBOX_BIN="/usr/local/bin/sing-box"

echo -e "${RED}"
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                                                          ║"
echo "║            节点中转面板 - 卸载程序                       ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${YELLOW}警告: 这将卸载 Transit Panel 及所有配置！${NC}"
echo ""
echo "将删除以下内容:"
echo "  - 安装目录: $INSTALL_DIR"
echo "  - 配置目录: $CONFIG_DIR"
echo "  - 数据目录: $DATA_DIR"
echo "  - 日志目录: $LOG_DIR"
echo "  - sing-box: $SINGBOX_BIN"
echo "  - systemd 服务"
echo ""

read -p "确认卸载? (输入 'yes' 确认): " confirm

if [ "$confirm" != "yes" ]; then
    echo -e "${GREEN}已取消卸载${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}[INFO]${NC} 停止服务..."
systemctl stop transit-panel 2>/dev/null || true
systemctl disable transit-panel 2>/dev/null || true

echo -e "${GREEN}[INFO]${NC} 删除文件..."
rm -rf "$INSTALL_DIR"
rm -rf "$CONFIG_DIR"
rm -rf "$DATA_DIR"
rm -rf "$LOG_DIR"
rm -f /etc/systemd/system/transit-panel.service
rm -f /usr/local/bin/transit-panel
rm -f "$SINGBOX_BIN"

echo -e "${GREEN}[INFO]${NC} 重载 systemd..."
systemctl daemon-reload

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  卸载完成！${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
