{ config, lib, ... }:

{
  # 网关容器组（改造目标见 docs/gateway.md）
  #
  #   main-router.nix   唯一网关：YunShu 策略分流，隧道不可用时降级直连
  #   dnsmasq.nix       DHCP 服务器（全网唯一）
  #   tailscale.nix     两个 tailscale 实例合一个容器（官方 + 自建 headscale）
  #   cloudflared.nix   内网穿透隧道（token 模式，ingress 在 CF 面板管理）
  #
  # 五个容器的地址与接口约定（见 docs/gateway.md §3）：
  #   main-router  .1   lan0:eth0 + wan0:eth1   网关 + DNS（DHCP 下发）
  #   tailscale    .4   lan0:eth0
  #   cloudflared  .6   lan0:eth0
  #   dnsmasq      .7   lan0:eth0               DHCP + 降级态 DNS
  # 全程 macvlan；宿主机保留 macvlan shim 作为管理通道（.2）
  imports = [
    ./main-router.nix
    ./dnsmasq.nix
    ./tailscale.nix
    ./cloudflared.nix
  ];
}
