# 持久化 nftables 建议

`moonctl.sh firewall-open` 只是临时规则。确认公网串流跑通后，应该把规则整理进主机自己的 nftables 配置。

最小端口：

```text
TCP 47989
TCP 47984
TCP 48010
UDP 47998-48010
```

示例：

```nft
table inet filter {
  chain input {
    type filter hook input priority filter; policy drop;

    iifname "enp3s0" tcp dport { 47989, 47984, 48010 } accept
    iifname "enp3s0" udp dport 47998-48010 accept
  }
}
```

如果客户端来源 IP 相对固定，可以进一步收窄：

```nft
iifname "enp3s0" ip saddr <client-ip-or-cidr> tcp dport { 47989, 47984, 48010 } accept
iifname "enp3s0" ip saddr <client-ip-or-cidr> udp dport 47998-48010 accept
```

注意：先确认端到端能通，再收紧来源限制。
