{ config, lib, ... }:

{
  # 网关容器组（改造目标见 docs/gateway.md）
  #
  #   main-router  .1   br-lan(veth) + wan0(macvlan)   网关 + DNS + DHCP
  #   tailscale    .4   br-lan                  官方 + 自建 headscale 两实例
  #   cloudflared  .6   br-lan                  内网穿透（token 模式）
  #
  # DHCP/DNS 合进 main-router：客户端拿到的 option 3/6 必须是同一个地址。
  # 两个出站隧道保持独立：不在数据路径上，重启不影响网关，也能确定地保持直连。
  imports = [
    ./main-router.nix
    ./tailscale.nix
    ./cloudflared.nix
  ];
}
