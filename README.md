# vfly.click

这是一个为 VPS 设计的轻量级、交互式全能管理脚本。它可以同时部署 Reality、Hysteria2 和 Snell v5 三种协议，并实现端口共存，互不干扰。

**特别优化：**

- 安装时支持自定义端口、随机端口或默认 443，灵活配置。
- 适配 Xray v26+ 新版密钥格式输出 (兼容 Password 字段)。
- 完美实现 TCP 443 (Reality) 与 UDP 443 (Hysteria2) 共存。
- 内置 BBR 加速开启功能。

## 🚀 快速开始 / Quick Start

**系统要求：** Debian 10+, Ubuntu 20+, CentOS 7+ (推荐使用 Debian/Ubuntu)

**权限要求：** 需要 Root 权限

在终端执行以下命令即可启动交互菜单：

```bash
bash <(curl -Ls https://vfly.click)
```

## ✨ 功能特性 / Features

### 三协议共存 (Port Sharing)

| 协议 | 默认端口 | 说明 |
|------|---------|------|
| Reality | 可选（443 / 随机 / 自定义） | 伪装成正常 HTTPS 流量 |
| Hysteria2 | 可选（443 / 随机 / 自定义） | HTTP/3 QUIC 伪装 |
| Snell v5 | 独立端口 (默认 11807) | 专为 Surge 用户优化 |

### 交互式管理菜单

- 一键安装/重置任意协议
- 安装时三选一端口策略：443 / 随机端口 / 手动输入
- 自动生成二维码 (QR Code) 和分享链接
- 服务状态监控与日志查看
- 一键开启 BBR 加速

### 智能修复与兼容

- 自动识别 CPU 架构 (AMD64 / ARM64)
- 修复 Xray v26+ 版本 x25519 密钥输出格式变更导致的问题
- 自动处理自签名证书 (Hysteria2) 和 PSK 生成

## 🛠️ 协议详细配置 / Configuration Details

| 协议 | 传输层 (Network) | 端口 (Port) | 备注 (Note) |
|------|----------------|------------|------------|
| Xray Reality | TCP | 自定义（推荐 443） | 默认 SNI: griffithobservatory.org, 流控: xtls-rprx-vision |
| Hysteria2 | UDP | 自定义（推荐 443） | 自签名证书 (bing.com)，客户端需开启 Allow Insecure |
| Snell v5 | TCP/UDP | 11807 | 支持 ipv6=false, tfo=true |

## 🖥️ 菜单预览 / Menu Preview

```text
=== VPS All-in-One Manager ===
1. 安装/重置 Reality
2. 安装/重置 Hysteria2
3. 安装/重置 Snell v5
----------------------------
4. 管理 Reality (查看配置/二维码)
5. 管理 Hysteria2
6. 管理 Snell
----------------------------
7. 开启 BBR
0. 退出
```

## ⚠️ 注意事项

- **端口选择**：Reality 和 Hysteria2 使用 443 端口隐蔽性最佳（流量混入正常 HTTPS），其他端口功能完全正常但可能更容易被识别。
- **Hysteria2 连接问题**：由于 Hysteria2 使用 UDP 协议，请务必在 VPS 提供的防火墙（如 AWS Security Group, 阿里云安全组）中放行所选 UDP 端口。
- **客户端设置**：
  - 连接 Hysteria2 时，必须勾选"允许不安全连接" (Allow Insecure / Skip Cert Verify)。
  - Reality 客户端建议使用最新版 v2rayN / Nekoray / Surge 以支持 Vision 流控。

## 📝 免责声明

本脚本仅供学习交流和服务器性能测试使用。请遵守当地法律法规，切勿用于非法用途。
