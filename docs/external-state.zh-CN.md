# 仓库外部状态

这个仓库故意不包含以下内容：

- DNS 服务商账号 / API token
- 公网 A 记录
- WireGuard 私钥
- WireGuard peer 配置
- Sunshine 私钥 / 证书
- Moonlight iOS pairing state
- Sunshine 完整配置
- 主机完整 nftables ruleset

原因：

1. 这些内容通常包含秘密或机器本地状态。
2. Moonlight/Sunshine pairing state 应由客户端和服务端自己保存。
3. 本方案不需要 HTTPS 证书，反而应该避免 discovery 域名走 HTTPS/HSTS。
4. nftables 完整 ruleset 通常与个人主机安全策略绑定，不适合作为通用脚本覆盖。

本仓库只提供最小化 helper：

```text
dns-start      启动临时 split-DNS
firewall-open  临时放通 Sunshine/Moonlight 端口
check          检查监听、DNS、接口、nft 线索
capture-*      抓包
grep-*         提取抓包关键信息
```
