# Persistent Hostname HTTPS Shim

[中文](hostname-https-shim.zh-CN.md) | [TLDR README](../README.md)

This document turns the verified hostname HTTPS workaround into a repeatable persistent setup.

## Relationship To The Top-Level Scripts

The top-level scripts are the base split-DNS / VPN add-and-pair toolkit:

```text
wgctl.sh      WireGuard setup and tunnel lifecycle
moonctl.sh    split DNS, VPN/public firewall helpers, and packet capture
depsctl.sh    runtime dependency checks and installation
```

The `https-shim/` scripts are an extra public-mode backend for the case where Moonlight/VoidLink iOS sends TLS ClientHello to `<MOON_HOST>:47989` instead of plaintext HTTP:

```text
https-shim/install-https-shim.sh
  installs the 47989 HTTPS shim, makes Sunshine 47984 present a hostname-valid cert,
  and persists HAProxy/nft/systemd state

https-shim/uninstall-https-shim.sh
  removes the shim and can optionally restore Sunshine's original cert/key
```

Use the repository in one of two modes:

```text
Mode A: split-DNS/plain mode
  Use wgctl.sh + moonctl.sh.
  Do not enable the HTTPS shim.
  This is for clients that send GET /serverinfo to hostname:47989.

Mode B: hostname-HTTPS-shim mode
  You may still use wgctl.sh for VPN testing and moonctl.sh for DNS/capture diagnostics.
  Public 47989/47984/streaming firewall and redirect state is owned by https-shim/.
  This is for clients that send TLS ClientHello to hostname:47989.
```

In shim mode, avoid using `moonctl.sh firewall-open` as the public-mode authority. It overlaps with the persistent nft rules installed by `moonlight-https-shim-nft.service`. The command is still useful for the plain mode, but shim mode should let the shim service own public firewall state.

## Working Shape

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

Do not reverse-proxy `47984`. Sunshine's `47984` is an mTLS endpoint that asks Moonlight/VoidLink for a client certificate. HAProxy does not have the iOS client private key, so it cannot connect to Sunshine `47984` on the client's behalf.

## Required `.env` Variables

At minimum:

```bash
MOON_HOST=moon.example.test
LAN_IP=10.0.42.1
PUBLIC_IFACE=enp3s0
```

HTTPS shim variables can override the defaults:

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

`LE_COMBINED_PEM` must contain the certificate/chain and private key:

```bash
sudo install -d -m 700 /etc/haproxy/certs
sudo sh -c 'cat /path/to/fullchain-or-cert.pem /path/to/private-key.pem > /etc/haproxy/certs/moon.example.test.pem'
sudo chmod 600 /etc/haproxy/certs/moon.example.test.pem
```

## Install

```bash
./https-shim/install-https-shim.sh
```

The installer:

1. Backs up Sunshine's original `credentials/cacert.pem` and `credentials/cakey.pem`.
2. Extracts the public certificate and private key from `LE_COMBINED_PEM`.
3. Replaces Sunshine credentials so native `47984` presents the hostname-valid public certificate.
4. Installs HAProxy config and `moonlight-47989-haproxy.service`.
5. Installs the nft helper and `moonlight-https-shim-nft.service`.
6. Opens the required public ports and redirects public `47989` to `48489`.

## Verify

HAProxy bootstrap:

```bash
curl -vk --noproxy '*' \
  --resolve "$MOON_HOST:$HAPROXY_TLS_PORT:$LAN_IP" \
  "https://$MOON_HOST:$HAPROXY_TLS_PORT/serverinfo"
```

Sunshine native `47984` certificate:

```bash
openssl s_client -connect 127.0.0.1:47984 -servername "$MOON_HOST" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -fingerprint -sha256
```

Services and rules:

```bash
sudo systemctl status moonlight-47989-haproxy.service
sudo systemctl status moonlight-https-shim-nft.service
sudo /usr/local/sbin/moonlight-https-shim-nft list
sudo ss -lntp | grep -E '47984|47989|48489'
```

Public streaming capture should show packets such as:

```text
server-public-ip:47998 -> phone-public-ip:...
server-public-ip:47999 -> phone-public-ip:...
server-public-ip:48000 -> phone-public-ip:...
```

`tcpdump` may show `bad udp cksum` because of checksum offload. Treat actual streaming behavior as the source of truth.

## Uninstall

Remove only HAProxy/nft shim state, leaving Sunshine credentials as-is:

```bash
./https-shim/uninstall-https-shim.sh
```

Remove the shim and restore original Sunshine credentials:

```bash
./https-shim/uninstall-https-shim.sh /home/user/.config/sunshine/credentials.bak.YYYYMMDD-HHMMSS
```

## Known Boundaries

- Do not reverse-proxy `47984` to Sunshine `47984`; backend mTLS requires the client certificate.
- Do not redirect `47984` to Sunshine HTTP `47989`; even if `pairchallenge` returns 200, later `/applist` will hit the wrong backend.
- Proxying only `47989` is not enough if Sunshine `47984` still presents its self-signed certificate in hostname mode.
- The successful shape is asymmetric: proxy `47989`, keep `47984` native.
