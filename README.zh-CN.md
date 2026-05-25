# Moonlight iOS + Sunshine Split DNS

[English README](README.md) | [完整手册](docs/full-guide.zh-CN.md) | [hostname HTTPS shim](docs/hostname-https-shim.zh-CN.md)

这个仓库提供最小辅助脚本，用官方 Moonlight iOS 客户端和 Sunshine 通过一个一次性域名完成添加、配对和公网使用。

核心思路：

```text
VPN / 内网添加配对阶段 -> <MOON_HOST> 解析到 <LAN_IP>
公网使用阶段           -> <MOON_HOST> 解析到公网 IP
```

完整设置、排查、清理和命令参考见 [docs/full-guide.zh-CN.md](docs/full-guide.zh-CN.md)。

如果 Moonlight/VoidLink iOS 在 hostname 模式下对 `<MOON_HOST>:47989` 发送 TLS ClientHello，请使用 [hostname HTTPS shim](docs/hostname-https-shim.zh-CN.md)。

顶层脚本是 split-DNS / VPN 添加配对方案的基础设施：

```text
wgctl.sh      管 WireGuard 配置和 tunnel 生命周期
moonctl.sh    管 split DNS、VPN/public 防火墙辅助规则和抓包
depsctl.sh    管运行时依赖检查和安装
```

`https-shim/` 脚本是额外的 public-mode backend：

```text
https-shim/install-https-shim.sh
  安装 47989 HTTPS shim，让 Sunshine 47984 呈现 hostname-valid 证书，
  并持久化 HAProxy/nft/systemd 状态

https-shim/uninstall-https-shim.sh
  卸载 shim，必要时恢复 Sunshine 原始 cert/key
```

本仓库可以按两个 mode 使用：

```text
Mode A: split-DNS/plain mode
  使用 wgctl.sh + moonctl.sh。
  不启用 HTTPS shim。
  适合客户端对 hostname:47989 发送 GET /serverinfo 的情况。

Mode B: hostname-HTTPS-shim mode
  仍可用 wgctl.sh 做 VPN 测试，也可用 moonctl.sh 做 DNS/抓包诊断。
  公网 47989/47984/串流防火墙和 redirect 状态由 https-shim/ 管。
  适合客户端对 hostname:47989 发送 TLS ClientHello 的情况。
```

在 shim mode 下，不建议再让 `moonctl.sh firewall-open` 主导公网阶段，因为它会和 `moonlight-https-shim-nft.service` 持久化安装的 nft 规则重叠。

## 依赖

- Linux 主机，Sunshine 已安装并运行
- Moonlight iOS 官方客户端
- 一个一次性 HTTP-clean 域名
- 可配置公网 DNS A 记录
- 运行时工具：`dnsmasq`、`nftables` / `nft`、`tcpdump`、`dig`、`ss`
- 可选：`wireguard-tools`，可由 `wgctl.sh install` 安装

这些工具在最小系统中不一定默认安装。运行脚本前，请先安装并检查：

```bash
sudo ./depsctl.sh install
./depsctl.sh check
```

手动安装示例：

```bash
sudo pacman -S --needed dnsmasq nftables tcpdump bind iproute2
sudo apt-get install dnsmasq nftables tcpdump dnsutils iproute2
```

**不要使用有 HSTS、HTTPS-only 跳转、Cloudflare 代理、URL forwarding 或不确定 HTTPS 历史的域名。**

也不要为 Moonlight 域名创建 `AAAA`、`CNAME`、redirect、forwarding、CDN 或 proxy 记录。

如果 `WG_ENDPOINT` 指向的是 FRP 公网入口，而不是 Sunshine/WireGuard 主机本身，需要先在本仓库之外配置 `WG_PORT` 的 UDP FRP 转发，例如 UDP `51820`。

## 快速步骤

1. 配置 `.env`：

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

2. 在仓库外配置公网 DNS：

```text
Type: A
Host: <子域名>
Value: <公网 IP>
```

3. 如果 `WG_ENDPOINT` 指向 FRP，先为 `WG_PORT` 配置外部 UDP 转发，例如 UDP `51820`。

4. 设置 WireGuard：

```bash
sudo ./wgctl.sh install
sudo ./wgctl.sh gen-keys
sudo FORCE=1 ./wgctl.sh write-server
sudo ./wgctl.sh firewall-open
sudo env WG_ENDPOINT=<host>:51820 FORCE=1 ./wgctl.sh write-client
sudo ./wgctl.sh up
sudo ./wgctl.sh status
sudo ./wgctl.sh qr-client
```

使用 `sudo ./wgctl.sh status`；WireGuard 状态需要 root 权限。

iPhone 上打开 WireGuard App，扫码导入 tunnel，并在 split DNS 测试前开启它。

5. 启动 split DNS 并放通 VPN/LAN 阶段防火墙：

```bash
sudo ./moonctl.sh dns-start
sudo ./moonctl.sh vpn-firewall-open
sudo ./moonctl.sh vpn-firewall-list
```

iPhone 开启 WireGuard 后，在 iPhone/iSH 检查：

```sh
dig @<LAN_IP> A <MOON_HOST> +short
dig @<LAN_IP> AAAA <MOON_HOST> +short
```

期望：A 返回 `<LAN_IP>`，AAAA 为空。

6. 通过 WireGuard 在 Moonlight 中添加和配对：

```bash
sudo ./moonctl.sh capture-add
```

iPhone：开启 WireGuard，打开 Moonlight，添加 `<MOON_HOST>`，配对，并进入一次 Desktop。

如果需要远程输入配对 PIN，请用 SSH 本地端口转发访问 Sunshine Web UI；见[远程配对提示](docs/full-guide.zh-CN.md#远程配对提示)。

另一个 shell：

```bash
./moonctl.sh grep-add
```

期望标记：

```http
GET /serverinfo HTTP/1.1
Host: <MOON_HOST>:47989
```

```xml
<paired>1</paired>
```

7. 使用已保存的 host 走公网：

如果 host 已经添加并配对过，公网日常使用只需要 `firewall-open`；WireGuard 和 split DNS 只在首次添加/配对阶段需要。

```bash
sudo ./moonctl.sh firewall-open
sudo ./moonctl.sh firewall-list
```

iPhone 关闭 WireGuard，刷新 Moonlight 中已保存的 host，然后进入 Desktop。

8. 清理：

```bash
sudo ./moonctl.sh firewall-close
sudo ./moonctl.sh vpn-firewall-close
sudo ./moonctl.sh dns-stop
sudo ./wgctl.sh down
```

## License

MIT。见 [LICENSE](LICENSE)。
