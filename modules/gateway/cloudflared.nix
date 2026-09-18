# cloudflared —— 内网服务的内网穿透隧道（出站连接，无需入站放行）
#   br-lan ──> lan     192.168.10.6/24   LAN（单口，出站直连）
{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.6";
  gatewayIp = "192.168.10.1";

  credDir = "/run/credentials/@system";
in
{
  containers.cloudflared = {
    autoStart = true;
    privateNetwork = true;
    hostBridge = "br-lan";

    # token 从宿主 sops 解密后经 nspawn 注入，容器内不留任何持久副本
    extraFlags = [
      "--load-credential=cf-token:${config.sops.secrets.cloudflared-token.path}"
    ];

    config = { config, lib, pkgs, ... }: {
      system.stateVersion = "26.05";
      networking.hostName = "cloudflared";

      networking = {
        interfaces.lan.ipv4.addresses = [
          {
            address = lanIp;
            prefixLength = 24;
          }
        ];
        defaultGateway = {
          address = gatewayIp;
          interface = "lan";
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
          # token 经环境变量传给 cloudflared（它认 TUNNEL_TOKEN）
          ExecStart = pkgs.writeShellScript "cloudflared-run" ''
            TUNNEL_TOKEN="$(cat ${credDir}/cf-token)" \
              exec ${pkgs.cloudflared}/bin/cloudflared --no-autoupdate tunnel --protocol http2 run
          '';
        };
      };
    };
  };
}
