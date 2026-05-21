# Moonlight iOS + Sunshine Split DNS

[中文完整手册](full-guide.zh-CN.md) | [TLDR README](../README.md)

Use one hostname with the official Moonlight iOS client:

```text
Add / pair over VPN or LAN -> <MOON_HOST> resolves to <LAN_IP>
Use over public Internet   -> <MOON_HOST> resolves to the public IP
```

This repository provides helper scripts for WireGuard setup, temporary split DNS, temporary firewall rules, and packet capture.

## Requirements

- Linux host with Sunshine installed and running
- Official Moonlight iOS client
- A disposable HTTP-clean hostname
- Public DNS access for an A record
- `dnsmasq`, `nftables`, `tcpdump`, `dig`, `ss`
- Optional: `wireguard-tools`, installed by `wgctl.sh install`

**Do not use a hostname that has HSTS, HTTPS-only redirects, Cloudflare proxying, URL forwarding, or unknown HTTPS history.** If capture shows `TLS ClientHello` instead of `GET /serverinfo`, use a different hostname.

## Configure

Copy the environment template:

```bash
cp .env.example .env
vim .env
```

Set at least:

```bash
MOON_HOST=moon.example.test
LAN_IP=10.0.42.1
WG_IFACE=moonwg0
PUBLIC_IFACE=enp3s0
WG_ENDPOINT=moon.example.test:51820
```

If `WG_ENDPOINT` points to an FRP server instead of the Sunshine/WireGuard host itself, configure an external UDP FRP proxy for `WG_PORT`, for example UDP `51820`, before starting the WireGuard test.

Recommended WireGuard defaults:

```bash
WG_PORT=51820
WG_SERVER_ADDR=10.0.42.1/24
WG_CLIENT_NAME=iphone
WG_CLIENT_ADDR=10.0.42.2/32
WG_DNS=10.0.42.1
WG_ALLOWED_IPS=10.0.42.0/24
```

## Public DNS

Configure public DNS outside this repository.

Create only:

```text
Type: A
Host: <subdomain>
Value: <public-ip>
```

Do not create `AAAA`, `CNAME`, URL forwarding, HTTPS redirect, or CDN/proxy records.

Check from a public network:

```sh
dig A <MOON_HOST> +short
dig AAAA <MOON_HOST> +short
```

Expected: A returns the public IP, and AAAA is empty.

## WireGuard

Install tools:

```bash
sudo ./wgctl.sh install
```

Generate keys:

```bash
sudo ./wgctl.sh gen-keys
```

Write the server config:

```bash
sudo ./wgctl.sh write-server
```

Open the temporary WireGuard UDP firewall rule:

```bash
sudo ./wgctl.sh firewall-open
```

Write the iOS client config:

```bash
sudo env WG_ENDPOINT=moon.example.test:51820 ./wgctl.sh write-client
```

Start WireGuard:

```bash
sudo ./wgctl.sh up
sudo ./wgctl.sh status
```

Import the iOS client config:

```bash
sudo ./wgctl.sh qr-client
```

Then scan the QR code in the WireGuard iOS app.

## Split DNS

Start temporary DNS for the add / pair phase:

```bash
sudo ./moonctl.sh dns-start
sudo ./moonctl.sh vpn-firewall-open
sudo ./moonctl.sh vpn-firewall-list
```

The VPN/LAN firewall helper opens DNS on `WG_IFACE` plus Sunshine / Moonlight add, pair, and streaming ports:

```text
UDP 53
TCP 47989, 47984, 48010
UDP 47998-48010
```

From the iPhone while WireGuard is enabled, check:

```sh
dig @<LAN_IP> A <MOON_HOST> +short
dig @<LAN_IP> AAAA <MOON_HOST> +short
```

Expected: A returns `<LAN_IP>`, and AAAA is empty.

## Sunshine Firewall

Open temporary Sunshine / Moonlight ports:

```bash
sudo ./moonctl.sh firewall-open
sudo ./moonctl.sh firewall-list
```

The helper opens:

```text
TCP 47989, 47984, 48010
UDP 47998-48010
```

Firewall rules created by `moonctl.sh` are tagged with comments derived from `NFT_COMMENT` and can be removed with:

```bash
sudo ./moonctl.sh firewall-close
sudo ./moonctl.sh vpn-firewall-close
```

Re-running `firewall-open` or `vpn-firewall-open` removes old tagged rules for that phase before adding fresh ones.

Check local state:

```bash
./moonctl.sh check
```

## Add And Pair

Start capture:

```bash
sudo ./moonctl.sh capture-add
```

On iPhone:

1. Enable WireGuard.
2. Open Moonlight.
3. Add `<MOON_HOST>`.
4. Pair and enter Desktop once.

In another shell, inspect:

```bash
./moonctl.sh grep-add
```

Expected:

```http
GET /serverinfo HTTP/1.1
Host: <MOON_HOST>:47989
```

Pairing success should include:

```xml
<paired>1</paired>
```

Do not delete the saved Moonlight host after pairing.

## Public Use

On iPhone:

1. Turn off WireGuard.
2. Confirm `<MOON_HOST>` resolves to the public IP.
3. Refresh the saved Moonlight host.
4. Enter Desktop.

Optional public capture:

```bash
sudo ./moonctl.sh capture-public
./moonctl.sh grep-public
```

When testing is done, remove temporary runtime state:

```bash
sudo ./moonctl.sh firewall-close
sudo ./moonctl.sh vpn-firewall-close
sudo ./moonctl.sh dns-stop
```

## Troubleshooting

### VPN DNS Returns Nothing

Check whether the iPhone is connected to WireGuard and can reach `<LAN_IP>`.

```bash
sudo tail -f /tmp/moon-dnsmasq.log
sudo tcpdump -ni <WG_IFACE> 'udp port 53 or tcp port 53'
```

If `dnsmasq` reports `cannot open log /tmp/moon-dnsmasq.log: Permission denied`, remove stale runtime files and start again:

```bash
sudo ./moonctl.sh dns-stop
sudo ./moonctl.sh dns-start
```

### Capture Shows TLS ClientHello

Use a different HTTP-clean hostname.

### Public SYN Arrives But No SYN-ACK

Open the temporary public firewall rules again:

```bash
sudo ./moonctl.sh firewall-open
sudo ./moonctl.sh firewall-list
```

### Discovery Works But Streaming Fails

Confirm UDP `47998-48010` is open on the public interface.

### Moonlight Shows Warning Or Exclamation Mark

Check:

1. public DNS A record points to the public IP;
2. AAAA is empty unless IPv6 is intentionally configured;
3. `GET /serverinfo` appears in capture;
4. no `TLS ClientHello` appears;
5. Sunshine TCP and UDP ports are open.

## Commands

WireGuard:

```text
install        Install wireguard-tools and qrencode
gen-keys       Generate server and client keys
write-server   Write /etc/wireguard/<iface>.conf
write-client   Write iOS client config
firewall-open  Open WireGuard UDP port temporarily
up             Start wg-quick
down           Stop wg-quick
restart        Restart wg-quick
status         Show WireGuard status; requires root
qr-client      Print iOS client config QR code
```

Moonlight / Sunshine:

```text
dns-start        Start temporary split DNS
dns-stop         Stop temporary split DNS and remove temporary files
firewall-open    Open temporary public Sunshine / Moonlight ports
firewall-close   Remove temporary public Sunshine / Moonlight ports
firewall-list    List temporary public Sunshine / Moonlight ports
vpn-firewall-open    Open VPN/LAN DNS and Sunshine / Moonlight ports
vpn-firewall-close   Remove VPN/LAN DNS and Sunshine / Moonlight ports
vpn-firewall-list    List VPN/LAN DNS and Sunshine / Moonlight ports
check            Show config, interfaces, listeners, DNS test, nft hints
capture-add      Capture VPN add / pair phase
capture-public   Capture public phase
grep-add         Grep add / pair capture
grep-public      Grep public capture
env              Print resolved environment
```

## Files

```text
README.md
README.zh-CN.md
.env.example
moonctl.sh
wgctl.sh
docs/full-guide.md
docs/full-guide.zh-CN.md
```
