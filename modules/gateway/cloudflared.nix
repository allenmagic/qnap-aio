# cloudflared —— 内网服务的内网穿透隧道（出站连接，无需入站放行）
#
#   lan0 ──> eth0   192.168.10.6/24   LAN（单口，出站直连）
#
# token 模式（ingress 在 Cloudflare 面板管理），因此不用 NixOS 的
# services.cloudflared——那个模块只支持 credentials-file + 本地 ingress 配置。
#
# 出站直连：默认网关指向 side-router，不经商业 main（见 docs/gateway.md §6.4）。
{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.6";
  sideRouterIp = "192.168.10.3";
  mac = "02:00:00:02:00:51";

  credDir = "/run/credentials/@system";
in
{
  containers.cloudflared = {
    autoStart = true;
    privateNetwork = true;
    macvlans = [ "lan0:eth0" ];

    # token 从宿主 sops 解密后经 nspawn 注入，容器内不留任何持久副本
    extraFlags = [
      "--load-credential=cf-token:${config.sops.secrets.cloudflared-token.path}"
    ];

    config = { config, lib, pkgs, ... }: {
      system.stateVersion = "26.05";
      networking.hostName = "cloudflared";

      systemd.network.links."10-eth0" = {
        matchConfig.Name = "eth0";
        linkConfig.MACAddress = mac;
      };

      networking = {
        interfaces.eth0.ipv4.addresses = [
          {
            address = lanIp;
            prefixLength = 24;
          }
        ];
        defaultGateway = {
          address = sideRouterIp;
          interface = "eth0";
        };
        resolvconf.enable = false;
        # 隧道是纯出站的，不需要放行任何入站端口
      };

      environment.etc."resolv.conf" = {
        mode = "0644";
        text = ''
          nameserver 223.5.5.5
          nameserver 119.29.29.29
        '';
      };

      boot.kernel.sysctl = {
        "net.ipv6.conf.all.disable_ipv6" = 1;
        "net.ipv6.conf.default.disable_ipv6" = 1;
      };

      systemd.services.cloudflared = {
        description = "Cloudflare Tunnel";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = 5;
          # token 经环境变量传给 cloudflared（它认 TUNNEL_TOKEN），
          # 而不是走命令行参数——命令行会出现在 /proc/<pid>/cmdline 里。
          # 用 shell 展开读取凭据，进程退出后 token 不残留在任何地方。
          #
          # --protocol http2 是刻意的：QUIC（UDP 7844）在国内网络常被运营商
          # 干扰，隧道会频繁重连；http2 走 TCP 最稳。参数位置在 tunnel 与
          # run 之间（cloudflared 的 help 文本不列它，以官方 run-parameters
          # 文档为准）。这两行是 router-image 里踩出来的，别照着直觉"优化"。
          ExecStart = pkgs.writeShellScript "cloudflared-run" ''
            TUNNEL_TOKEN="$(cat ${credDir}/cf-token)" \
              exec ${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel --protocol http2 run
          '';
        };
      };
    };
  };
}
