{ config, lib, ... }:

{
  # 网关容器组（改造目标见 docs/gateway.md）
  #
  # 已落地：
  #   main-router.nix    主透明网关，VRRP MASTER，持浮动网关，跑 YunShu 策略分流
  #   side-router.nix    备份直连网关，VRRP BACKUP，兼降级态 DNS 转发
  #   dnsmasq.nix        DHCP 服务器（全网唯一）+ 降级态 DNS 解析器
  #   tailscale.nix      两个 tailscale 实例合一个容器（官方 + 自建 headscale）
  #   cloudflared.nix    内网穿透隧道（token 模式，ingress 在 CF 面板管理）
  #
  # 六个容器的地址与接口约定（见 docs/gateway.md §3）：
  #   main-router  .2   lan0:eth0 + wan0:eth1   VRRP MASTER
  #   side-router  .3   lan0:eth0 + wan0:eth1   VRRP BACKUP
  #   tailscale    .4   lan0:eth0
  #   cloudflared  .6   lan0:eth0
  #   dnsmasq      .7   lan0:eth0               DHCP + 降级态 DNS
  # 全程 macvlan；宿主机保留 macvlan shim 作为管理通道，br-lan/br-wan 待退役（步骤 3）。
  #
  # ⚠️ 改造期间本仓库不可部署：modules/network/bridges.nix 仍在建 br-lan/br-wan。
  imports = [
    ./main-router.nix
    ./side-router.nix
    ./dnsmasq.nix
    ./tailscale.nix
    ./cloudflared.nix
  ];
}
