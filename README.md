# Transit Panel - 节点中转面板

<p align="center">
  <b>基于 sing-box 内核的可视化节点中转管理面板</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-1.1.0-blue" alt="version">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="license">
  <img src="https://img.shields.io/badge/sing--box-1.10.0-orange" alt="sing-box">
</p>

---

## ✨ 功能特性

### 🌐 Web 可视化面板
- 现代深色主题界面
- 响应式设计，支持移动端
- 一键复制分享链接
- 7天登录状态保持

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

### 🔐 SSL 证书
- 无域名模式：自签名证书
- 有域名模式：自动申请 Let's Encrypt 证书

---

## 🚀 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tkxw/transit-panel/main/install.sh)
```

运行后会显示交互式菜单，选择：
- `1` - 安装面板
- `2` - 卸载面板
- `3` - 查看状态
- `4` - 查看登录信息
- `5` - 重置密码
- `6` - 重启服务
- `7` - 查看日志
- `8` - 配置域名/SSL

---

## 📖 安装模式

### 无域名模式
使用 IP 访问，自动生成自签名证书

### 有域名模式
输入域名后自动：
1. 申请 Let's Encrypt SSL 证书
2. 配置 HTTPS 访问
3. 设置证书自动续期

---

## 🔧 服务管理

```bash
# 重新打开管理菜单
bash <(curl -fsSL https://raw.githubusercontent.com/tkxw/transit-panel/main/install.sh)

# 或直接使用 systemctl
systemctl start transit-panel-web
systemctl restart transit-panel
```

---

## 📋 系统要求

- **系统**: Debian 10+, Ubuntu 20.04+, CentOS 7+
- **架构**: x86_64, arm64
- **内存**: 512MB+
- **权限**: root

---

## 📄 许可证

MIT License

---

## 🙏 致谢

- [sing-box](https://github.com/SagerNet/sing-box)
