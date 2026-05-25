# Hostname HTTPS shim for Moonlight iOS + Sunshine

本文记录一种在 Moonlight/VoidLink iOS 对 hostname 触发 TLS/HTTPS 访问时仍然完成添加、配对和进入主机列表的服务端侧方案。

这个方案来自一次实际排查。结论是：

```text
47989: 用 HAProxy + Let's Encrypt 证书给 hostname 做 TLS bootstrap，后端转 Sunshine 明文 47989
47984: 不反代，保留 Sunshine 原生 HTTPS/mTLS，但让 Sunshine 自己呈现 Let's Encrypt 证书
```

换句话说：**不要反代 47984**。Sunshine 的 47984 会要求 Moonlight/VoidLink 的客户端证书；如果让 HAProxy 代理到 Sunshine 47984，HAProxy 没有客户端私钥，会被 Sunshine 拒绝。

## 适用场景

适用于这些现象：

- iOS 客户端添加 `bar.example.com` 时，对 `47989` 发的是 TLS ClientHello，而不是明文 `GET /serverinfo`。
- 直接让 Sunshine 自签证书处理 hostname 时，iOS 报 SSL/cert error。
- 用 HAProxy 的公网证书接管 `47989` 后，early pairing 能过。
- `47984` 直接反代到 Sunshine HTTPS 会出现 `certificate required` 或 502。

不适用于：

- 你只是用 IP/VPN 添加主机，且 Moonlight iOS 没有对 hostname 强制 HTTPS。
- 你不想让 Sunshine 使用公网 TLS 证书。

## 最终拓扑

假设：

```text
MOON_HOST=bar.junyu33.me
LAN_IP=10.0.42.1
IOS_IP=10.0.42.2
WG_IFACE=moonwg0
```

最终链路：

```text
VoidLink/Moonlight iOS -> bar.junyu33.me:47989
  nft redirect to 10.0.42.1:48489
  HAProxy presents LE cert CN=*.junyu33.me
  HAProxy forwards plaintext HTTP to 127.0.0.1:47989

VoidLink/Moonlight iOS -> bar.junyu33.me:47984
  direct to Sunshine native HTTPS/mTLS 47984
  Sunshine presents LE cert CN=*.junyu33.me
  iOS client presents its Moonlight client certificate
```

The critical point is that `47984` remains a native Sunshine mTLS endpoint.

## 1. Prepare HAProxy PEM

Put a full-chain certificate plus private key into one PEM file for HAProxy:

```bash
sudo install -d -m 700 /etc/haproxy/certs

sudo sh -c 'cat \
/path/to/fullchain-or-cert.pem \
/path/to/private-key.pem \
> /etc/haproxy/certs/junyu33.pem'

sudo chmod 600 /etc/haproxy/certs/junyu33.pem
```

Verify:

```bash
sudo openssl x509 -in /etc/haproxy/certs/junyu33.pem \
  -noout -subject -issuer -dates -ext subjectAltName
```

Expected: the certificate should cover `MOON_HOST`, for example `CN=*.junyu33.me`.

## 2. Replace Sunshine 47984 server certificate with the public certificate

Sunshine stores its GameStream certificate/key here on this host:

```text
/home/junyu33/.config/sunshine/credentials/cacert.pem
/home/junyu33/.config/sunshine/credentials/cakey.pem
```

Back them up first:

```bash
sudo install -d -m 700 /home/junyu33/.config/sunshine/credentials.bak.$(date +%Y%m%d-%H%M%S)
BAK=$(ls -dt /home/junyu33/.config/sunshine/credentials.bak.* | head -1)

sudo cp -a /home/junyu33/.config/sunshine/credentials/cacert.pem "$BAK/cacert.pem"
sudo cp -a /home/junyu33/.config/sunshine/credentials/cakey.pem  "$BAK/cakey.pem"

echo "$BAK"
```

Extract the first cert and private key from the HAProxy PEM:

```bash
sudo awk '
  /BEGIN CERTIFICATE/ {p=1}
  p {print}
  /END CERTIFICATE/ {exit}
' /etc/haproxy/certs/junyu33.pem | sudo tee /tmp/junyu33-le-cert.pem >/dev/null

sudo awk '
  /BEGIN .*PRIVATE KEY/ {p=1}
  p {print}
' /etc/haproxy/certs/junyu33.pem | sudo tee /tmp/junyu33-le-key.pem >/dev/null

sudo openssl x509 -in /tmp/junyu33-le-cert.pem -noout -subject -issuer -dates
sudo openssl rsa -in /tmp/junyu33-le-key.pem -check -noout
```

Install them into Sunshine credentials:

```bash
sudo cp /tmp/junyu33-le-cert.pem /home/junyu33/.config/sunshine/credentials/cacert.pem
sudo cp /tmp/junyu33-le-key.pem  /home/junyu33/.config/sunshine/credentials/cakey.pem

sudo chmod 644 /home/junyu33/.config/sunshine/credentials/cacert.pem
sudo chmod 600 /home/junyu33/.config/sunshine/credentials/cakey.pem

systemctl --user restart sunshine
```

Verify that Sunshine 47984 now presents the public certificate:

```bash
openssl s_client -connect 127.0.0.1:47984 -servername "$MOON_HOST" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -fingerprint -sha256
```

Expected:

```text
subject=CN=*.junyu33.me
issuer=Let's Encrypt ...
```

If the client certificate is not provided, `curl https://127.0.0.1:47984/...` may still fail with `certificate required`. That is normal: `47984` is mTLS.

## 3. Run HAProxy only for 47989

Create `/tmp/moonlight-47989-only-le.cfg`:

```bash
cat > /tmp/moonlight-47989-only-le.cfg <<'EOF'
global
    maxconn 256
    log stdout format raw local0

defaults
    log global
    mode http
    option httplog
    timeout connect 5s
    timeout client 60s
    timeout server 60s

frontend moonlight_tls_48489_le
    bind 10.0.42.1:48489 ssl crt /etc/haproxy/certs/junyu33.pem alpn http/1.1
    default_backend sunshine_http_47989

backend sunshine_http_47989
    server sunshine_http 127.0.0.1:47989
EOF

sudo haproxy -c -f /tmp/moonlight-47989-only-le.cfg
sudo haproxy -f /tmp/moonlight-47989-only-le.cfg -db
```

For persistent use, install it as a system service:

```bash
sudo install -m 644 /tmp/moonlight-47989-only-le.cfg /etc/haproxy/moonlight-47989-only-le.cfg

sudo tee /etc/systemd/system/moonlight-47989-haproxy.service >/dev/null <<'EOF'
[Unit]
Description=Moonlight hostname HTTPS shim for Sunshine 47989
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/haproxy -f /etc/haproxy/moonlight-47989-only-le.cfg -db
ExecReload=/bin/kill -USR2 $MAINPID
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now moonlight-47989-haproxy.service
```

## 4. Add nftables redirect only for 47989

Do not redirect `47984`.

Temporary command:

```bash
sudo nft add table ip moonlight_nat 2>/dev/null || true
sudo nft 'add chain ip moonlight_nat prerouting { type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null || true

sudo nft add rule inet filter input \
  iifname "moonwg0" ip saddr 10.0.42.2 tcp dport 48489 \
  accept comment '"moonlight-ios-publicIP:allow-48489"'

sudo nft add rule ip moonlight_nat prerouting \
  iifname "moonwg0" ip saddr 10.0.42.2 tcp dport 47989 \
  redirect to :48489 comment '"moonlight-ios-publicIP:tls-47989"'
```

Expected rules:

```bash
sudo nft -a list table ip moonlight_nat
sudo ss -lntp | grep -E '47984|47989|48489'
```

Expected shape:

```text
tcp dport 47989 redirect to :48489
sunshine listens on 0.0.0.0:47989
sunshine listens on 0.0.0.0:47984
haproxy listens on 10.0.42.1:48489
```

Persistent nftables can be implemented by adding the same NAT table and the `48489` accept rule to your host's nftables configuration, or by using a small systemd unit that runs after WireGuard comes up.

## 5. Validate

Check HAProxy:

```bash
curl -vk --noproxy '*' \
  --resolve "$MOON_HOST:48489:$LAN_IP" \
  "https://$MOON_HOST:48489/serverinfo"
```

Check Sunshine 47984 certificate:

```bash
openssl s_client -connect 127.0.0.1:47984 -servername "$MOON_HOST" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -fingerprint -sha256
```

Add/pair from iOS. Watch HAProxy:

```bash
sudo journalctl -fu moonlight-47989-haproxy.service
```

Or foreground mode:

```bash
sudo haproxy -f /etc/haproxy/moonlight-47989-only-le.cfg -db
```

Expected 47989 bootstrap logs include:

```text
GET /serverinfo HTTP/1.1
GET /pair?...phrase=getservercert...
GET /pair?...clientchallenge...
GET /pair?...serverchallengeresp...
GET /pair?...clientpairingsecret...
```

After that, iOS should connect directly to Sunshine `47984` using native mTLS.

## 6. Rollback

Restore Sunshine's original credentials:

```bash
BAK=/home/junyu33/.config/sunshine/credentials.bak.YYYYMMDD-HHMMSS

sudo cp "$BAK/cacert.pem" /home/junyu33/.config/sunshine/credentials/cacert.pem
sudo cp "$BAK/cakey.pem"  /home/junyu33/.config/sunshine/credentials/cakey.pem

sudo chmod 644 /home/junyu33/.config/sunshine/credentials/cacert.pem
sudo chmod 600 /home/junyu33/.config/sunshine/credentials/cakey.pem

systemctl --user restart sunshine
```

Stop the shim and remove temporary nftables state:

```bash
sudo systemctl disable --now moonlight-47989-haproxy.service 2>/dev/null || true
sudo pkill haproxy 2>/dev/null || true
sudo nft delete table ip moonlight_nat 2>/dev/null || true

sudo nft -a list chain inet filter input | awk '/moonlight-ios-publicIP:allow-/ {print $NF}' | \
while read h; do sudo nft delete rule inet filter input handle "$h" 2>/dev/null || true; done
```

## Why the earlier attempts failed

- HAProxy with LE cert on `47989` alone can complete early pairing, but final HTTPS still reaches Sunshine `47984` with Sunshine's original self-signed certificate, causing iOS SSL errors in hostname mode.
- HAProxy with Sunshine cert on `47989` satisfies Moonlight's later pinning expectation but fails the initial hostname TLS bootstrap because iOS does not trust the self-signed Sunshine certificate.
- HAProxy on `47984` cannot simply proxy to Sunshine `47984`, because Sunshine requests a client certificate. HAProxy does not have the iOS client's private key, so Sunshine rejects the backend connection with `certificate required`.
- Redirecting `47984` to Sunshine HTTP `47989` can make `pairchallenge` return `200`, but later `/applist` returns `404`; it is the wrong backend.

The working solution is therefore asymmetric: proxy only `47989`, and make Sunshine's own `47984` hostname-valid.
