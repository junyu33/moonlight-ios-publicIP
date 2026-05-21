# Moonlight iOS + Sunshine Split DNS

[中文 README](README.zh-CN.md)

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

Do not use a hostname that has HSTS, HTTPS-only redirects, Cloudflare proxying, URL forwarding, or unknown HTTPS history. If capture shows `TLS ClientHello` instead of `GET /serverinfo`, use a different hostname.

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
./wgctl.sh status
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
```

From the iPhone while WireGuard is enabled, check:

```sh
dig A <MOON_HOST> @<LAN_IP> +short
dig AAAA <MOON_HOST> @<LAN_IP> +short
```

Expected: A returns `<LAN_IP>`, and AAAA is empty.

## Sunshine Firewall

Open temporary Sunshine / Moonlight ports:

```bash
sudo ./moonctl.sh firewall-open
```

The helper opens:

```text
TCP 47989, 47984, 48010
UDP 47998-48010
```

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

## Troubleshooting

### VPN DNS Returns Nothing

Check whether the iPhone is connected to WireGuard and can reach `<LAN_IP>`.

```bash
sudo tail -f /tmp/moon-dnsmasq.log
sudo tcpdump -ni <WG_IFACE> 'udp port 53 or tcp port 53'
```

### Capture Shows TLS ClientHello

Use a different HTTP-clean hostname.

### Public SYN Arrives But No SYN-ACK

Open the temporary public firewall rules again:

```bash
sudo ./moonctl.sh firewall-open
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
status         Show WireGuard status
qr-client      Print iOS client config QR code
```

Moonlight / Sunshine:

```text
dns-start        Start temporary split DNS
dns-stop         Stop temporary split DNS
firewall-open    Open temporary Sunshine / Moonlight ports
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
docs/
```

