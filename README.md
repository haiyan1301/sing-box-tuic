# sing-box TUIC 快捷安装脚本

`install-singbox-tuic.sh` 是一个面向通用 systemd Linux VPS 的 sing-box TUIC 服务端快捷安装脚本。脚本只配置 TUIC，不混入其他协议，适合需要快速部署单用户 TUIC 节点的场景。

## 功能

- 安装官方稳定版 sing-box。
- 生成 `/etc/sing-box/config.json`，仅包含 TUIC inbound 和 direct outbound。
- 支持交互式向导：默认值、自定义输入、返回上一步。
- 支持无人值守参数模式。
- 支持四种 TLS 证书模式：
  - 自签证书。
  - ACME 域名证书。
  - ACME IP 证书，使用 Let’s Encrypt `shortlived` profile。
  - 已有证书路径。
- 写入配置前自动备份旧配置。
- 执行 `sing-box check`，失败自动回滚。
- 自动识别并配置 `ufw` 或 `firewalld`。
- ACME IP 模式会安装每日续签检查 timer，并提供手动触发命令。
- 默认自动彩色输出；如需禁用颜色，可在命令前加 `NO_COLOR=1`。

## 快捷下载执行

将脚本上传到 GitHub、Gist 或自己的静态文件服务后，把下面命令里的 URL 替换为实际 Raw 地址：

```bash
curl -fsSL https://raw.githubusercontent.com/haiyan1301/sing-box-tuic/main/install-singbox-tuic.sh | sudo bash
```

或使用 `wget`：

```bash
wget -qO- https://raw.githubusercontent.com/haiyan1301/sing-box-tuic/main/install-singbox-tuic.sh | sudo bash
```

通过管道运行且需要传参数时，必须使用 `bash -s --`，参数要放在 `--` 后面。

无人值守默认安装：

```bash
curl -fsSL https://raw.githubusercontent.com/haiyan1301/sing-box-tuic/main/install-singbox-tuic.sh | sudo bash -s -- --yes
```

ACME 域名证书示例：

```bash
curl -fsSL https://raw.githubusercontent.com/haiyan1301/sing-box-tuic/main/install-singbox-tuic.sh | sudo bash -s -- \
  --cert-mode acme-domain \
  --domain example.com \
  --email admin@example.com
```

ACME IP 证书示例：

```bash
curl -fsSL https://raw.githubusercontent.com/haiyan1301/sing-box-tuic/main/install-singbox-tuic.sh | sudo bash -s -- \
  --cert-mode acme-ip \
  --ip 203.0.113.10 \
  --email admin@example.com
```

`sudo bash --yes` 是错误写法，`--yes` 会被 Bash 当成自己的参数解析。

## 本地执行

如果脚本已经在服务器上：

```bash
sudo bash install-singbox-tuic.sh
```

查看参数：

```bash
bash install-singbox-tuic.sh --help
```

常用参数：

```bash
sudo bash install-singbox-tuic.sh \
  --port 443 \
  --cert-mode self \
  --congestion cubic
```

## ACME IP 证书续签检查

ACME IP 模式会生成：

```bash
/usr/local/sbin/sing-box-tuic-renew
/etc/systemd/system/sing-box-tuic-renew.service
/etc/systemd/system/sing-box-tuic-renew.timer
```

手动触发验证和续签检查：

```bash
sudo /usr/local/sbin/sing-box-tuic-renew
```

查看 timer：

```bash
systemctl list-timers sing-box-tuic-renew.timer
```

查看日志：

```bash
journalctl -u sing-box-tuic-renew.service --output cat -e
```

ACME IP 证书验证需要公网可访问 `80/tcp` 和 `443/tcp`。TUIC 业务端口是脚本配置的 UDP 端口，默认 `443/udp`。

## 注意事项

- 需要 root 权限运行。
- 仅支持 systemd Linux，不支持 OpenWrt、Docker 容器、Windows 或 macOS。
- ACME 域名证书要求域名已经解析到服务器。
- ACME IP 证书要求 IP 属于当前服务器，并且公网可以访问验证端口。
- 自签证书模式下，客户端需要启用 `tls.insecure=true`，或手动导入证书信任。
