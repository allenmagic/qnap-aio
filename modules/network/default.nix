{ config, lib, ... }:

{
  imports = [
    # 物理网口按 MAC 锚定命名（wan0 / lan0）——必须在 bridges.nix 之前生效
    ./links.nix
    ./bridges.nix
  ];

  # 基础网络配置
  networking = {
    hostName = "allenmagic-nas";
    useDHCP = false;
    useNetworkd = true;

    # 防火墙配置
    firewall = {
      enable = true;

      # Tailscale 接口（若在 NAS 上直接运行 tailscaled）：
      # 放行 SSH，供远程密钥登录（密码登录仍由 sshd 的 Match 保持禁用）
      interfaces.br-wan.allowedTCPPorts = [ 22 ];  # 管理 SSH（192.168.8.10）

      interfaces.tailscale0.allowedTCPPorts = [ 22 ];

      # 在 br-lan 上开放服务端口
      interfaces.br-lan = {
        allowedTCPPorts = [
          22      # SSH
          139 445 # Samba
          2049    # NFS (nfsd)
          111     # NFSv3 rpcbind
          20048   # NFSv3 mountd（services/nfs.nix 固定端口）
          4000    # NFSv3 statd
          4001    # NFSv3 lockd
          8384    # Syncthing Web UI
          22000   # Syncthing sync
          4533    # 音乐服务端（Navidrome，2026-09-14 从 gonic 回退，端口不变）
          9180    # Feishin Web（音乐前端）
          8090    # Beszel Hub Web UI
          9090    # Cockpit Web UI（cockpit 已剔除，端口保留待恢复）
          4918    # WebDAV（客户端直连内网；公网经路由 VM cloudflared 隧道回源）
          8080    # Glance 仪表盘（同上，公网经 cloudflared 隧道回源）
          8081    # qBittorrent Web UI（services/downloads.nix）
          6881    # qBittorrent BT 监听端口（TCP；UDP 见下）
          6800    # aria2 JSON-RPC（AriaNg 页面从浏览器直连它）
          6880    # AriaNg 静态页（nginx）
          5244    # OpenList Web UI / WebDAV（services/openlist.nix）
        ];
        allowedUDPPorts = [
          137 138 # Samba (NetBIOS)
          22000   # Syncthing discovery
          21027   # Syncthing discovery
          2049    # NFS (nfsd, UDP 用于 NFSv3)
          111     # NFSv3 rpcbind
          20048   # NFSv3 mountd
          4000    # NFSv3 statd
          4001    # NFSv3 lockd
          6881    # qBittorrent BT 监听端口（UDP）
        ];
      };
    };
  };
}
