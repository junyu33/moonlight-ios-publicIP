# Moonlight iOS + Sunshine Split DNS

[English README](README.md)

使用官方 Moonlight iOS 客户端时，让同一个域名在两个阶段解析到不同地址：

```text
VPN / 内网添加配对阶段 -> <MOON_HOST> 解析到 <LAN_IP>
公网使用阶段           -> <MOON_HOST> 解析到公网 IP
```

本仓库提供 WireGuard、临时 split DNS、临时防火墙规则和抓包辅助脚本。

## 依赖

- Linux 主机，Sunshine 已安装并运行
- Moonlight iOS 官方客户端
- 一个一次性 HTTP-clean 域名
- 可配置公网 DNS A 记录
- `dnsmasq`、`nftables`、`tcpdump`、`dig`、`ss`
- 可选：`wireguard-tools`，可由 `wgctl.sh install` 安装

不要使用有 HSTS、HTTPS-only 跳转、Cloudflare 代理、URL forwarding 或不确定 HTTPS 历史的域名。如果抓包看到 `TLS ClientHello` 而不是 `GET /serverinfo`，换一个域名。

## 配置

复制环境变量模板：

```bash
cp .env.example .env
vim .env
```

至少设置：

```bash
MOON_HOST=moon.example.test
LAN_IP=10.0.42.1
WG_IFACE=moonwg0
PUBLIC_IFACE=enp3s0
WG_ENDPOINT=moon.example.test:51820
```

推荐的 WireGuard 默认值：

```bash
WG_PORT=51820
WG_SERVER_ADDR=10.0.42.1/24
WG_CLIENT_NAME=iphone
WG_CLIENT_ADDR=10.0.42.2/32
WG_DNS=10.0.42.1
WG_ALLOWED_IPS=10.0.42.0/24
```

## 公网 DNS

公网 DNS 在仓库外配置。

只创建：

```text
Type: A
Host: <子域名>
Value: <公网 IP>
```

不要创建 `AAAA`、`CNAME`、URL forwarding、HTTPS redirect 或 CDN/proxy 记录。

从公网检查：

```sh
dig A <MOON_HOST> +short
dig AAAA <MOON_HOST> +short
```

期望：A 返回公网 IP，AAAA 为空。

## WireGuard

安装工具：

```bash
sudo ./wgctl.sh install
```

生成密钥：

```bash
sudo ./wgctl.sh gen-keys
```

写服务端配置：

```bash
sudo ./wgctl.sh write-server
```

临时放通 WireGuard UDP 端口：

```bash
sudo ./wgctl.sh firewall-open
```

生成 iOS 客户端配置：

```bash
sudo env WG_ENDPOINT=moon.example.test:51820 ./wgctl.sh write-client
```

启动 WireGuard：

```bash
sudo ./wgctl.sh up
./wgctl.sh status
```

导入 iOS 客户端配置：

```bash
sudo ./wgctl.sh qr-client
```

然后用 WireGuard iOS App 扫码导入。

## Split DNS

添加 / 配对阶段启动临时 DNS：

```bash
sudo ./moonctl.sh dns-start
```

iPhone 开启 WireGuard 后检查：

```sh
dig A <MOON_HOST> @<LAN_IP> +short
dig AAAA <MOON_HOST> @<LAN_IP> +short
```

期望：A 返回 `<LAN_IP>`，AAAA 为空。

## Sunshine 防火墙

临时放通 Sunshine / Moonlight 端口：

```bash
sudo ./moonctl.sh firewall-open
sudo ./moonctl.sh firewall-list
```

脚本会放通：

```text
TCP 47989, 47984, 48010
UDP 47998-48010
```

所有由 `moonctl.sh` 创建的防火墙规则都会带上 `NFT_COMMENT` 标记，并且可以这样删除：

```bash
sudo ./moonctl.sh firewall-close
```

重复执行 `firewall-open` 会先删除旧的同标记规则，再添加新规则。

检查本机状态：

```bash
./moonctl.sh check
```

## 添加和配对

开始抓包：

```bash
sudo ./moonctl.sh capture-add
```

在 iPhone 上：

1. 开启 WireGuard。
2. 打开 Moonlight。
3. 添加 `<MOON_HOST>`。
4. 配对并进入一次 Desktop。

另开一个 shell 检查：

```bash
./moonctl.sh grep-add
```

期望看到：

```http
GET /serverinfo HTTP/1.1
Host: <MOON_HOST>:47989
```

配对成功应包含：

```xml
<paired>1</paired>
```

配对后不要删除 Moonlight 中已保存的 host。

## 公网使用

在 iPhone 上：

1. 关闭 WireGuard。
2. 确认 `<MOON_HOST>` 解析到公网 IP。
3. 刷新 Moonlight 中已保存的 host。
4. 进入 Desktop。

可选公网抓包：

```bash
sudo ./moonctl.sh capture-public
./moonctl.sh grep-public
```

测试结束后清理临时状态：

```bash
sudo ./moonctl.sh firewall-close
sudo ./moonctl.sh dns-stop
```

## 常见问题

### VPN DNS 没结果

确认 iPhone 已连接 WireGuard，并且能访问 `<LAN_IP>`。

```bash
sudo tail -f /tmp/moon-dnsmasq.log
sudo tcpdump -ni <WG_IFACE> 'udp port 53 or tcp port 53'
```

如果 `dnsmasq` 报 `cannot open log /tmp/moon-dnsmasq.log: Permission denied`，先清掉旧临时文件再启动：

```bash
sudo ./moonctl.sh dns-stop
sudo ./moonctl.sh dns-start
```

### 抓包显示 TLS ClientHello

换一个 HTTP-clean 域名。

### 公网 SYN 到了但没有 SYN-ACK

重新放通临时公网防火墙规则：

```bash
sudo ./moonctl.sh firewall-open
sudo ./moonctl.sh firewall-list
```

### Discovery 正常但串流失败

确认公网接口已放通 UDP `47998-48010`。

### Moonlight 显示警告或感叹号

检查：

1. 公网 DNS A 记录指向公网 IP；
2. AAAA 为空，除非你明确配置了 IPv6；
3. 抓包里出现 `GET /serverinfo`；
4. 抓包里没有 `TLS ClientHello`；
5. Sunshine TCP 和 UDP 端口已放通。

## 命令

WireGuard：

```text
install        安装 wireguard-tools 和 qrencode
gen-keys       生成服务端和客户端密钥
write-server   写 /etc/wireguard/<iface>.conf
write-client   写 iOS 客户端配置
firewall-open  临时放通 WireGuard UDP 端口
up             启动 wg-quick
down           停止 wg-quick
restart        重启 wg-quick
status         显示 WireGuard 状态
qr-client      输出 iOS 客户端配置二维码
```

Moonlight / Sunshine：

```text
dns-start        启动临时 split DNS
dns-stop         停止临时 split DNS 并删除临时文件
firewall-open    临时放通 Sunshine / Moonlight 端口
firewall-close   删除临时 Sunshine / Moonlight 端口规则
firewall-list    列出临时 Sunshine / Moonlight 端口规则
check            显示配置、接口、监听、DNS 测试、nft 提示
capture-add      抓 VPN 添加 / 配对阶段
capture-public   抓公网阶段
grep-add         检索添加 / 配对抓包
grep-public      检索公网抓包
env              打印解析后的环境变量
```

## 文件

```text
README.md
README.zh-CN.md
.env.example
moonctl.sh
wgctl.sh
docs/
```
