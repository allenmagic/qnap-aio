{ config, lib, ... }:

{
  # 网关容器组（改造目标见 docs/gateway.md）
  #
  #   main-router  .1   br-lan(veth) + wan(macvlan)   网关 + DNS + DHCP
  #   tailscale    .4   br-lan                  官方 + 自建 headscale 两实例
  #   cloudflare-mesh .5 br-lan                 Mesh 节点（L3 双向，原 WARP Connector）
  #   cloudflared  .6   br-lan                  内网穿透（token 模式）
  #   ts-ecs        .7  br-lan                  迁移实例：aliyun-ecs 新 headscale
  #   wg-spoke      .8  br-lan                  WireGuard spoke（非 Tailscale 设备）
  #
  # DHCP/DNS 合进 main-router：客户端拿到的 option 3/6 必须是同一个地址。
  imports = [
    ./main-router.nix
    ./tailscale.nix
    ./tailscale-ecs.nix
    ./wg-spoke.nix
    ./cloudflared.nix
    # 2026-11-11 临时禁用 Cloudflare Mesh；恢复时取消注释。
    # 容器配置由 bridge-iface.nix 的 containers.cloudflare-mesh 补齐，
    # 不引用本模块时 autoStart 为 false，不会启动。
    # ./cloudflare-mesh.nix
    # 桥接容器的接口整备（nspawn 的 veth 改名 + 固定 MAC）
    ./bridge-iface.nix
  ];
}
