# Transit Panel - 节点中转面板

<p align="center">
  <b>基于 sing-box 内核的可视化节点中转管理面板</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-blue" alt="version">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/sing--box-1.10.0-orange" alt="sing-box">
</p>

---

## ✨ 功能特性

### 🌐 Web 可视化面板
- 现代深色主题界面
- 响应式设计，支持移动端
- 一键复制分享链接

### 📥 入站协议
| 协议 | 特点 |
|------|------|
| **Hysteria2** | 基于 QUIC，高速抗干扰 |
| **TUIC** | 低延迟，BBR 拥塞控制 |
| **VLESS + Reality** | 无需证书，高安全性 |

### 📤 出站支持
- SOCKS5 代理节点

### 🔄 中转模式
- **一对一**: 单入站 → 单出站
- **一对多**: 负载均衡 / 故障转移

---

## 🚀 快速安装

### 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/您的用户名/transit-panel/main/install.sh)
```

### 手动安装

```bash
# 克隆仓库
git clone https://github.com/您的用户名/transit-panel.git
cd transit-panel

# 安装
sudo bash install.sh install
```

---

## 📖 使用方法

安装完成后，访问 Web 面板:

```
http://服务器IP:8080
```

使用安装时显示的用户名和密码登录。

### 截图预览

#### 仪表盘
- 服务状态监控
- 节点统计
- 快速操作

#### 入站管理
- 添加 Hysteria2 / TUIC / VLESS-Reality
- 一键复制分享链接
- 查看详细配置

#### 出站管理
- 添加 SOCKS5 代理节点
- 节点列表管理

#### 中转规则
- 可视化配置中转关系
- 支持负载均衡

---

## 📁 安装目录

```
/opt/transit-panel/     # 安装目录
├── web/                # Web 面板
└── venv/               # Python 虚拟环境

/etc/transit-panel/     # 配置目录
├── config.json         # 面板配置
├── singbox.json        # sing-box 配置
└── certs/              # 证书目录
```

---

## 🔧 服务管理

```bash
# sing-box 服务
systemctl start transit-panel
systemctl stop transit-panel
systemctl restart transit-panel

# Web 面板服务
systemctl start transit-panel-web
systemctl stop transit-panel-web
systemctl restart transit-panel-web
```

---

## 🗑️ 卸载

```bash
sudo bash install.sh uninstall
```

---

## 📋 系统要求

- **系统**: Debian 10+, Ubuntu 20.04+, CentOS 7+
- **架构**: x86_64, arm64
- **内存**: 512MB+
- **权限**: root

---

## 🔒 安全建议

1. 修改默认密码
2. 使用 HTTPS 反向代理 (Nginx/Caddy)
3. 配置防火墙规则

---

## 📄 许可证

MIT License

---

## 🙏 致谢

- [sing-box](https://github.com/SagerNet/sing-box)
