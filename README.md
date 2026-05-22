# Moonlight iOS + Sunshine Split DNS

[中文 README](README.zh-CN.md) | [Full guide](docs/full-guide.md)

Minimal helper scripts for using one disposable hostname with the official Moonlight iOS client and Sunshine.

Core idea:

```text
Add / pair over VPN or LAN -> <MOON_HOST> resolves to <LAN_IP>
Use over public Internet   -> <MOON_HOST> resolves to the public IP
```

For complete setup, troubleshooting, cleanup, and command reference details, read [docs/full-guide.md](docs/full-guide.md).

## Requirements

- Linux host with Sunshine installed and running
- Official Moonlight iOS client
- A disposable HTTP-clean hostname
- Public DNS access for one A record
- Runtime tools: `dnsmasq`, `nftables` / `nft`, `tcpdump`, `dig`, `ss`
- Optional: `wireguard-tools`, installed by `wgctl.sh install`

These tools may not be installed by default on minimal systems. Install them before running the scripts:

```bash
sudo ./depsctl.sh install
./depsctl.sh check
```

Manual examples:

```bash
sudo pacman -S --needed dnsmasq nftables tcpdump bind iproute2
sudo apt-get install dnsmasq nftables tcpdump dnsutils iproute2
```

**Do not use a hostname that has HSTS, HTTPS-only redirects, Cloudflare proxying, URL forwarding, or unknown HTTPS history.**

Also do not create `AAAA`, `CNAME`, redirect, forwarding, CDN, or proxy records for the Moonlight hostname.

If `WG_ENDPOINT` points to an FRP server instead of the Sunshine/WireGuard host itself, configure an external UDP FRP proxy for `WG_PORT`, for example UDP `51820`, before starting the WireGuard test.

## Quick Setup

1. Configure `.env`:

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

2. Configure public DNS outside this repository:

```text
Type: A
Host: <subdomain>
Value: <public-ip>
```

3. If `WG_ENDPOINT` points to FRP, configure external UDP forwarding for `WG_PORT`, for example UDP `51820`.

4. Set up WireGuard:

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

Use `sudo ./wgctl.sh status`; WireGuard status requires root.

On iPhone, open the WireGuard app, scan the QR code, import the tunnel, and enable it before the split DNS test.

5. Start split DNS and open VPN/LAN phase firewall rules:

```bash
sudo ./moonctl.sh dns-start
sudo ./moonctl.sh vpn-firewall-open
sudo ./moonctl.sh vpn-firewall-list
```

From iPhone/iSH while WireGuard is enabled:

```sh
dig @<LAN_IP> A <MOON_HOST> +short
dig @<LAN_IP> AAAA <MOON_HOST> +short
```

Expected: A returns `<LAN_IP>`, and AAAA is empty.

6. Add and pair in Moonlight over WireGuard:

```bash
sudo ./moonctl.sh capture-add
```

On iPhone: enable WireGuard, open Moonlight, add `<MOON_HOST>`, pair, and enter Desktop once.

If you need to enter the pairing PIN remotely, use an SSH local port forward for the Sunshine Web UI; see [Remote pairing note](docs/full-guide.md#remote-pairing-note).

In another shell:

```bash
./moonctl.sh grep-add
```

Expected markers:

```http
GET /serverinfo HTTP/1.1
Host: <MOON_HOST>:47989
```

```xml
<paired>1</paired>
```

7. Use the saved host over the public Internet:

If the host has already been added and paired, public use only needs `firewall-open`; WireGuard and split DNS are only needed for the initial add/pair phase.

```bash
sudo ./moonctl.sh firewall-open
sudo ./moonctl.sh firewall-list
```

Turn off WireGuard on iPhone, refresh the saved Moonlight host, and enter Desktop.

8. Cleanup:

```bash
sudo ./moonctl.sh firewall-close
sudo ./moonctl.sh vpn-firewall-close
sudo ./moonctl.sh dns-stop
sudo ./wgctl.sh down
```

## License

MIT. See [LICENSE](LICENSE).
