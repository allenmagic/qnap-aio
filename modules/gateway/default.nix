{ config, lib, ... }:

{
  # 网关容器组（改造目标见 docs/gateway.md）
  #
  #   main-router  .1   br-lan(veth) + wan(macvlan)   网关 + DNS + DHCP
  #   tailscale    .4   br-lan                  官方 + 自建 headscale 两实例
  #   cloudflared  .6   br-lan                  内网穿透（token 模式）
  #
  # DHCP/DNS 合进 main-router：客户端拿到的 option 3/6 必须是同一个地址。
  imports = [
    ./main-router.nix
    ./tailscale.nix
    ./cloudflared.nix
    # 桥接容器的接口整备（nspawn 的 veth 改名 + 固定 MAC）
    ./bridge-iface.nix
  ];
}
