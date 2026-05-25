# 持久化 hostname HTTPS shim

本文把已经验证成功的实验态整理成可重复安装的持久化配置。

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
````

关键点：不要反代 `47984`。Sunshine 的 `47984` 是 mTLS 端点，会要求 Moonlight/VoidLink 的客户端证书。HAProxy 没有 iOS 客户端私钥，所以不能替客户端连接 Sunshine 的 `47984`。

## .env 需要的变量

至少：

```bash
MOON_HOST=bar.junyu33.me
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
LE_COMBINED_PEM=/etc/haproxy/certs/junyu33.pem
SUNSHINE_CREDENTIALS_DIR=/home/junyu33/.config/sunshine/credentials
SUNSHINE_RESTART_CMD="systemctl --user restart sunshine"
```

`LE_COMBINED_PEM` 必须包含证书/链和私钥，例如：

```bash
sudo install -d -m 700 /etc/haproxy/certs
sudo sh -c 'cat /path/to/fullchain-or-cert.pem /path/to/private-key.pem > /etc/haproxy/certs/junyu33.pem'
sudo chmod 600 /etc/haproxy/certs/junyu33.pem
```

## 安装

```bash
./scripts/install-https-shim.sh
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
sudo ss -lntp | grep -E '47984|47989|48489'
```

公网串流抓包可见：

```text
server-public-ip:47998 -> phone-public-ip:...
server-public-ip:47999 -> phone-public-ip:...
server-public-ip:48000 -> phone-public-ip:...
```

`tcpdump` 显示 `bad udp cksum` 通常是 checksum offload，不等于坏包；以实际串流是否流畅为准。

## 卸载

只移除 HAProxy/nft shim，不恢复 Sunshine 证书：

```bash
./scripts/uninstall-https-shim.sh
```

同时恢复 Sunshine 原始 credentials：

```bash
./scripts/uninstall-https-shim.sh /home/junyu33/.config/sunshine/credentials.bak.YYYYMMDD-HHMMSS
```

## 已知边界

* 不能把 `47984` 反代到 Sunshine `47984`，因为后端 mTLS 需要客户端证书。
* 不能把 `47984` 转到 Sunshine HTTP `47989`，即使 `pairchallenge` 可能返回 200，后续 `/applist` 也会走错后端。
* 只代理 `47989` 但 Sunshine `47984` 仍使用自签证书时，hostname 模式下 iOS 会继续 SSL error。
* 成功结构是不对称的：`47989` 代理，`47984` 原生直连。
  EOF

