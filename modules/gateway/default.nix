{ config, lib, ... }:

{
  # 网关容器组（改造目标见 docs/gateway.md）
  #
  # 已落地：
  #   main-router.nix    主透明网关，VRRP MASTER，持浮动网关，跑 YunShu 策略分流
  #   side-router.nix    备份直连网关，VRRP BACKUP，兼降级态 DNS 转发
  #   dnsmasq.nix        DHCP 服务器（全网唯一）+ 降级态 DNS 解析器
  #   tailscale.nix      两个 tailscale 实例合一个容器（官方 + 自建 headscale）
  #
  # 待落地：
  #   cloudflared.nix    内网隧道
  #
  # 网络接入：LAN/WAN 全部走 macvlan（macvlans = [ "lan0:eth0" ]），
  # 宿主机保留 macvlan shim 作为管理通道；br-lan/br-wan 待退役（步骤 3）。
  #
  # ⚠️ 改造期间本仓库不可部署：modules/network/bridges.nix 仍在建 br-lan/br-wan。
  imports = [
    ./main-router.nix
    ./side-router.nix
    ./dnsmasq.nix
    ./tailscale.nix
  ];
}
