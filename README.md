# sing-box TUIC 快捷安装脚本

`install-singbox-tuic.sh` 是一个面向通用 systemd Linux VPS 的 sing-box TUIC 服务端快捷安装脚本。脚本只配置 TUIC，不混入其他协议，适合需要快速部署单用户 TUIC 节点的场景。

## 功能

- 默认安装官方稳定版 sing-box；ACME 域名/IP 证书模式使用 `acme.sh` 实际申请并安装证书，不依赖 sing-box beta 或 `certificate_providers`。
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
- ACME 模式会把证书安装到 `/etc/sing-box/certs/tuic-acme.crt` 和 `/etc/sing-box/certs/tuic-acme.key`，并配置续签后的 reload 命令。
- ACME IP 模式会额外安装每日续签检查 timer，并提供手动触发命令。
- 默认自动彩色输出；如需禁用颜色，可使用 `NO_COLOR=1`。
- 安装前校验端口、UUID、域名/IP、证书路径等输入；交互模式下输入错误会停留在当前项。
- 配置完成后优先输出 sing-box outbound JSON、终端二维码和 PNG 二维码文件；TUIC URI 仅作为兼容分享链接输出。二维码依赖 `qrencode`，缺失时脚本会尝试自动安装。

## 快捷下载执行

直接使用 GitHub Raw 地址下载并执行：

```bash
curl -fsSL https://raw.githubusercontent.com/haiyan1301/sing-box-tuic/main/install-singbox-tuic.sh | sudo bash
```

或使用 `wget`：

```bash
wget -qO- https://raw.githubusercontent.com/haiyan1301/sing-box-tuic/main/install-singbox-tuic.sh | sudo bash
```

通过管道运行且需要传参数时，必须使用 `bash -s --`，参数要放在 `--` 后面。

禁用彩色输出：

```bash
curl -fsSL https://raw.githubusercontent.com/haiyan1301/sing-box-tuic/main/install-singbox-tuic.sh | sudo env NO_COLOR=1 bash
```

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

## 输入校验

脚本会在安装前校验端口、UUID、密码、拥塞控制、证书模式、域名/IP、邮箱和证书路径。交互模式下输入非法值会提示具体原因并继续要求重新输入；参数模式下会直接退出，避免错误配置写入系统。

已有证书模式要求证书和私钥路径必须是绝对路径、可读普通文件，并且不能指向同一个文件。ACME 域名不接受通配符、下划线、连续点、空 label 或首尾连字符。

## ACME IP 证书续签检查

ACME 证书由 `acme.sh` 申请和续签。域名/IP 证书签发成功后，脚本会把证书安装到 sing-box 的证书目录，并设置续签后的 reload 命令：

```bash
/usr/local/sbin/sing-box-tuic-acme-reload
```

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

ACME standalone 验证需要公网可访问 `80/tcp`。TUIC 业务端口是脚本配置的 UDP 端口，默认 `443/udp`。

## 客户端配置输出

安装完成后会输出并保存：

```bash
/root/sing-box-tuic-client.json
/root/sing-box-tuic-client-json.png
/root/sing-box-tuic-uri.png
```

`sing-box-tuic-client.json` 是 sing-box 客户端的推荐配置；`sing-box-tuic-client-json.png` 是该 JSON 的二维码。TUIC URI 不是统一标准，部分客户端无法识别，遇到导入失败时请使用 JSON 配置。

## 注意事项

- 需要 root 权限运行。
- 仅支持 systemd Linux，不支持 OpenWrt、Docker 容器、Windows 或 macOS。
- ACME 域名证书要求域名已经解析到服务器。
- ACME IP 证书要求 IP 属于当前服务器，并且公网可以访问验证端口。
- 自签证书模式下，客户端需要启用 `tls.insecure=true`，或手动导入证书信任。
