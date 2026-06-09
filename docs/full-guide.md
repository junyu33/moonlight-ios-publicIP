# Moonlight iOS + Sunshine Split DNS

[中文完整手册](full-guide.zh-CN.md) | [TLDR README](../README.md) | [Hostname HTTPS shim](hostname-https-shim.md)

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
- Runtime tools: `dnsmasq`, `nftables` / `nft`, `tcpdump`, `dig`, `ss`
- HTTPS shim tools: `haproxy`, `openssl`, `systemctl`, `sudo`, `awk`, `pkill`, `curl`
- Optional: `wireguard-tools`, installed by `wgctl.sh install`

These tools may not be installed by default on minimal systems. Install the split-DNS/plain tools with your distribution's package manager before running the top-level scripts, or use:

```bash
sudo ./depsctl.sh install
./depsctl.sh check
```

For hostname-HTTPS-shim mode:

```bash
sudo ./depsctl.sh install-shim
./depsctl.sh check-shim
```

To install both sets:

```bash
sudo ./depsctl.sh install-all
./depsctl.sh check-all
```

Manual examples:

```bash
# Arch
sudo pacman -S --needed dnsmasq nftables tcpdump bind iproute2
sudo pacman -S --needed haproxy openssl procps-ng sudo gawk grep curl

# Debian / Ubuntu
sudo apt-get install dnsmasq nftables tcpdump dnsutils iproute2
sudo apt-get install haproxy openssl procps sudo gawk grep curl
```

**Do not use a hostname that has HSTS, HTTPS-only redirects, Cloudflare proxying, URL forwarding, or unknown HTTPS history.** If capture shows `TLS ClientHello` instead of `GET /serverinfo`, either use a different hostname for split-DNS/plain mode or switch the public phase to [Hostname HTTPS shim](hostname-https-shim.md).

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

Then open the WireGuard app on iPhone, scan the QR code, import the tunnel, and enable it before the split DNS test.

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

### Remote pairing note

If you are not physically in front of the Sunshine host, you may need access to the Sunshine Web UI to enter the pairing PIN shown by Moonlight.

Use an SSH local port forward instead of exposing the Web UI publicly:

```bash
ssh -L 47990:127.0.0.1:47990 user@sunshine-host
```

Then open on your local machine:

```text
https://127.0.0.1:47990
```

Enter the PIN there when Moonlight asks for pairing.

Do not expose the Sunshine Web UI port to the public Internet.

## Public Use

If the host has already been added and paired, public use only needs `firewall-open`; WireGuard and split DNS are only needed for the initial add/pair phase.

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

Use a different HTTP-clean hostname for split-DNS/plain mode, or switch the public phase to [Hostname HTTPS shim](hostname-https-shim.md). In shim mode, `wgctl.sh` remains reusable and `moonctl.sh` remains useful for DNS/capture diagnostics, but public firewall/redirect state is owned by `https-shim/install-https-shim.sh` and `moonlight-https-shim-nft.service`.

### Pairing Failed When Using WireGuard Direct IP

If `47989` works but `47984` connects, receives the server TLS response, and then the client immediately sends `FIN`, suspect a certificate/hostname mismatch rather than a routing problem. This can happen after testing HTTPS shim / Let's Encrypt certificate mode and then adding the WireGuard inner IP directly in Moonlight, such as `10.0.42.1`.

For direct IP mode, Sunshine should use its original self-signed credentials, or a certificate whose SAN matches the IP. For hostname mode, prefer `<MOON_HOST>` with split DNS instead of adding the direct IP. Sunshine logs may be empty; packet capture and certificate inspection are usually more useful.

Capture the WireGuard path:

```bash
sudo tcpdump -ni moonwg0 host 10.0.42.2 and \
  '(tcp port 47989 or tcp port 47984 or tcp port 48010 or udp portrange 47998-48010)'
```

Inspect what Sunshine presents on `47984`:

```bash
openssl s_client -connect 10.0.42.1:47984 -servername 10.0.42.1 -showcerts </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -ext subjectAltName -fingerprint -sha256
```

Inspect the active Sunshine credential file:

```bash
openssl x509 -in ~/.config/sunshine/credentials/cacert.pem -noout \
  -subject -issuer -ext subjectAltName -fingerprint -sha256
```

To find a safe restore candidate, inspect backups and pick the original Sunshine self-signed certificate. Its `subject` and `issuer` are the same, it is not Let's Encrypt, and it does not contain a hostname-only SAN such as `DNS:*.example.test`.

```bash
bash -c '
for d in "$HOME"/.config/sunshine/credentials.bak.*; do
  echo
  echo "== $d =="
  if [ -f "$d/cacert.pem" ]; then
    openssl x509 -in "$d/cacert.pem" -noout \
      -subject -issuer -ext subjectAltName -fingerprint -sha256 2>/dev/null \
      || echo "not a readable cert"
  fi
done
'
```

A typical original Sunshine certificate looks like:

```text
subject=CN=Sunshine Gamestream Host
issuer=CN=Sunshine Gamestream Host
```

If you intentionally want to restore direct IP mode, adapt `src=` to the backup directory you selected:

```bash
src="$HOME/.config/sunshine/credentials.bak.YYYYMMDD-HHMMSS"

ts=$(date +%Y%m%d-%H%M%S)
mkdir -p ~/Desktop/backup/sunshine-credentials-current-$ts
cp -a ~/.config/sunshine/credentials/* ~/Desktop/backup/sunshine-credentials-current-$ts/

sudo cp -a "$src/cacert.pem" ~/.config/sunshine/credentials/cacert.pem
sudo cp -a "$src/cakey.pem"  ~/.config/sunshine/credentials/cakey.pem
sudo chown "$USER:$USER" ~/.config/sunshine/credentials/cacert.pem ~/.config/sunshine/credentials/cakey.pem
chmod 644 ~/.config/sunshine/credentials/cacert.pem
chmod 600 ~/.config/sunshine/credentials/cakey.pem

systemctl --user restart sunshine 2>/dev/null || sudo systemctl restart sunshine
```

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

Runtime dependencies:

```text
install        Install split-DNS/plain runtime tools for moonctl.sh
install-shim   Install hostname HTTPS shim runtime tools
install-all    Install both runtime tool sets
check          Check split-DNS/plain runtime tools
check-shim     Check hostname HTTPS shim runtime tools
check-all      Check both runtime tool sets
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
depsctl.sh
moonctl.sh
wgctl.sh
docs/full-guide.md
docs/full-guide.zh-CN.md
docs/hostname-https-shim.md
docs/hostname-https-shim.zh-CN.md
https-shim/install-https-shim.sh
https-shim/uninstall-https-shim.sh
```

## License

MIT. See [../LICENSE](../LICENSE).
