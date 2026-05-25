# 持久化 hostname HTTPS shim

[中文 README](../README.zh-CN.md) | [完整手册](full-guide.zh-CN.md)

本文把已经验证成功的实验态整理成可重复安装的持久化配置。

## TLDR

仅在 hostname-HTTPS-shim mode 下使用。请把示例域名、公网 IP 和证书路径替换为你自己的值。

在仓库外配置 DNS：

```text
<MOON_HOST> -> <PUBLIC_IPV4>
Proxy/CDN: off
AAAA: none
```

Sunshine 主机上执行：

`LE_COMBINED_PEM` 需要指向一份 hostname-valid 的 ACME/Let's Encrypt HAProxy PEM，通常由 `fullchain.pem` 和 `privkey.pem` 拼接生成。

```bash
sed -i 's/^MOON_HOST=.*/MOON_HOST=moon.example.test/' .env
grep -q '^LE_COMBINED_PEM=' .env \
  && sed -i 's|^LE_COMBINED_PEM=.*|LE_COMBINED_PEM=/etc/haproxy/certs/moon.example.test.pem|' .env \
  || printf '\nLE_COMBINED_PEM=/etc/haproxy/certs/moon.example.test.pem\n' >> .env
source .env

./https-shim/install-https-shim.sh
sudo /usr/local/sbin/moonlight-https-shim-nft status

sudo ./wgctl.sh up
sudo ./moonctl.sh dns-start
dig @"$LAN_IP" A "$MOON_HOST" +short

sudo ./https-shim/vpn.sh up
sudo ./https-shim/vpn.sh status
```

iPhone 上：

```text
开启 WireGuard
在官方 Moonlight 中添加 MOON_HOST
配对
进入一次 Desktop
关闭 WireGuard
刷新已保存的 host
通过公网再次进入 Desktop
```

确认公网串流成功后：

```bash
sudo ./https-shim/vpn.sh down
sudo /usr/local/sbin/moonlight-https-shim-nft status || sudo systemctl restart moonlight-https-shim-nft.service
```

## 和顶层脚本的关系

顶层脚本是 split-DNS / VPN 添加配对方案的基础设施：

```text
wgctl.sh      管 WireGuard 配置和 tunnel 生命周期
moonctl.sh    管 split DNS、VPN/public 防火墙辅助规则和抓包
depsctl.sh    管运行时依赖检查和安装
```

`https-shim/` 脚本是 Moonlight/VoidLink iOS 在 hostname 模式下对 `<MOON_HOST>:47989` 发送 TLS ClientHello 时使用的额外 public-mode backend：

```text
https-shim/install-https-shim.sh
  持久化公网使用阶段：
  安装 47989 HTTPS shim，让 Sunshine 47984 呈现 hostname-valid 证书，
  并持久化 HAProxy/nft/systemd 状态

https-shim/vpn.sh
  临时 VPN fresh-add/pair 阶段：
  把 WG_IFACE:47989 redirect 到 48489，同时保持 47984 为 Sunshine 原生 mTLS

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

在 shim mode 下，不建议再让 `moonctl.sh firewall-open` 主导公网阶段。它和 `moonlight-https-shim-nft.service` 持久化安装的 nft 规则有重叠；plain mode 仍然可以使用 `moonctl.sh firewall-open`。

## 工作结构

```text
47989:
  client -> public-ip:47989
  nft redirect -> public-ip:48489
  HAProxy presents Let's Encrypt cert
  HAProxy forwards plaintext HTTP -> 127.0.0.1:47989

47984:
  client -> public-ip:47984
  Sunshine native HTTPS/mTLS
  Sunshine itself presents the same hostname-valid Let's Encrypt cert

48010 and UDP 47998-48010:
  native Sunshine streaming/control ports
```

关键点：不要反代 `47984`。Sunshine 的 `47984` 是 mTLS 端点，会要求 Moonlight/VoidLink 的客户端证书。HAProxy 没有 iOS 客户端私钥，所以不能替客户端连接 Sunshine 的 `47984`。

## .env 需要的变量

至少：

```bash
MOON_HOST=moon.example.test
LAN_IP=10.0.42.1
PUBLIC_IFACE=enp3s0
```

HTTPS shim 相关变量可以覆盖默认值：

```bash
HAPROXY_TLS_PORT=48489
SUNSHINE_HTTP_PORT=47989
SUNSHINE_HTTPS_PORT=47984
SUNSHINE_RTSP_PORT=48010
SUNSHINE_UDP_RANGE=47998-48010
LE_COMBINED_PEM=/etc/haproxy/certs/moon.example.test.pem
SUNSHINE_CREDENTIALS_DIR=/home/user/.config/sunshine/credentials
SUNSHINE_RESTART_CMD="systemctl --user restart sunshine"
```

`LE_COMBINED_PEM` 必须包含证书/链和私钥，例如：

```bash
sudo install -d -m 700 /etc/haproxy/certs
sudo sh -c 'cat /path/to/fullchain-or-cert.pem /path/to/private-key.pem > /etc/haproxy/certs/moon.example.test.pem'
sudo chmod 600 /etc/haproxy/certs/moon.example.test.pem
```

## 安装

```bash
./https-shim/install-https-shim.sh
```

安装脚本会：

1. 备份 Sunshine 原始 `credentials/cacert.pem` 和 `credentials/cakey.pem`。
2. 从 `LE_COMBINED_PEM` 提取公网证书和私钥，替换到 Sunshine credentials。
3. 重启 Sunshine，使 `47984` 呈现 hostname-valid 公网证书。
4. 安装 HAProxy 配置和 `moonlight-47989-haproxy.service`。
5. 安装 nft helper 和 `moonlight-https-shim-nft.service`。
6. 放通公网所需端口，并把公网 `47989` redirect 到 `48489`。

## 验证

HAProxy bootstrap：

```bash
curl -vk --noproxy '*' \
  --resolve "$MOON_HOST:$HAPROXY_TLS_PORT:$LAN_IP" \
  "https://$MOON_HOST:$HAPROXY_TLS_PORT/serverinfo"
```

Sunshine 原生 `47984` 证书：

```bash
openssl s_client -connect 127.0.0.1:47984 -servername "$MOON_HOST" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -fingerprint -sha256
```

服务与规则：

```bash
sudo systemctl status moonlight-47989-haproxy.service
sudo systemctl status moonlight-https-shim-nft.service
sudo /usr/local/sbin/moonlight-https-shim-nft list
sudo /usr/local/sbin/moonlight-https-shim-nft status
sudo ss -lntp | grep -E '47984|47989|48489'
```

`moonlight-https-shim-nft.service` 是带 `RemainAfterExit=yes` 的 oneshot service，所以 `active (exited)` 只表示上次启动成功，不证明 nft 规则现在仍存在。排查 Moonlight 可用性前，用 helper 的机器可检查状态：

```bash
sudo /usr/local/sbin/moonlight-https-shim-nft status || sudo systemctl restart moonlight-https-shim-nft.service
```

公网串流抓包可见：

```text
server-public-ip:47998 -> phone-public-ip:...
server-public-ip:47999 -> phone-public-ip:...
server-public-ip:48000 -> phone-public-ip:...
```

`tcpdump` 显示 `bad udp cksum` 通常是 checksum offload，不等于坏包；以实际串流是否流畅为准。

## 通过 VPN fresh add / pair

持久化 public shim 负责公网日常使用。首次添加/配对仍可能需要 WireGuard 和 split DNS，因为官方 Moonlight iOS 不能直接 fresh-add 公网 IPv4 host。如果 `MOON_HOST` 已经解析到 `LAN_IP`，但 iOS 仍然对 `<MOON_HOST>:47989` 发送 TLS ClientHello，请添加临时 VPN shim 规则：

```bash
sudo ./wgctl.sh up
sudo ./moonctl.sh dns-start
sudo ./https-shim/vpn.sh up
```

iPhone 上：

```text
Enable WireGuard
Open official Moonlight iOS
Add MOON_HOST
Pair
Enter Desktop once
```

然后切到公网模式：

```text
Disable WireGuard
Refresh the saved Moonlight host
Enter Desktop again over public Internet
```

确认公网串流可用后，只移除临时 VPN add/pair 规则：

```bash
sudo ./https-shim/vpn.sh down
sudo /usr/local/sbin/moonlight-https-shim-nft status || sudo systemctl restart moonlight-https-shim-nft.service
```

不要停止持久化 public HTTPS shim services。

避免使用匹配裸 `moonlight-ios-publicIP` 的宽泛手动清理命令，因为它可能同时删除 public 和 VPN 规则。临时 VPN 规则用 `sudo ./https-shim/vpn.sh down` 清理，持久化 public shim 用 `./https-shim/uninstall-https-shim.sh` 清理。

## 卸载

只移除 HAProxy/nft shim，不恢复 Sunshine 证书：

```bash
./https-shim/uninstall-https-shim.sh
```

同时恢复 Sunshine 原始 credentials：

```bash
./https-shim/uninstall-https-shim.sh /home/user/.config/sunshine/credentials.bak.YYYYMMDD-HHMMSS
```

## 已知边界

* 不能把 `47984` 反代到 Sunshine `47984`，因为后端 mTLS 需要客户端证书。
* 不能把 `47984` 转到 Sunshine HTTP `47989`，即使 `pairchallenge` 可能返回 200，后续 `/applist` 也会走错后端。
* 只代理 `47989` 但 Sunshine `47984` 仍使用自签证书时，hostname 模式下 iOS 会继续 SSL error。
* 成功结构是不对称的：`47989` 代理，`47984` 原生直连。
