{ config, pkgs, lib, ... }:

{
  # Cockpit Web 管理界面（系统级 Web 管理工具）
  services.cockpit = {
    enable = true;

    # 插件列表，可按需添加：
    #   pkgs.cockpit-podman        - 容器管理
    #   pkgs.cockpit-files         - 文件管理
    #   pkgs.cockpit-zfs           - ZFS 管理
    #   pkgs.cockpit-dockermanager - Docker 管理
    # 注：cockpit-machines（虚拟机管理）已移除——路由 VM 由 router-image 模块声明式
    #     管理（cloud-hypervisor，Cockpit 不可见），libvirtd 已退役
    plugins = [
    ];

    # 监听端口（默认 9090）
    # 防火墙按接口放行：modules/network/default.nix 中 br-lan 已开放 9090
    port = 9090;

    # 允许的 WebSocket Origin。NixOS 模块默认只放行 https://localhost:9090，
    # 用其它地址访问时 cockpit-ws 会以 "received request from bad Origin" 拒绝
    # 握手——表现为页面能打开、能登录，但连不上后端。Origins 支持 fnmatch
    # 通配（见 cockpit.conf.5）。
    allowed-origins = [
      "https://192.168.10.2:9090"      # 内网 br-lan
      "https://allenmagic-nas:9090"    # 主机名
      "https://100.*:9090"             # Tailscale CGNAT 100.64.0.0/10
    ];
  };
}
