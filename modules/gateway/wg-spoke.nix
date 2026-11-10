# wg-spoke —— NAS 侧的 WireGuard spoke，供非 Tailscale 设备访问 LAN
#
#   br-lan ──> lan  192.168.10.8/24   默认网关 .1
#   wg0  ──> 10.8.0.3/32              WireGuard 对端是 aliyun-ecs hub
#
# 家庭没有公网 IP，所以这里作为 spoke 主动连 aliyun hub（UDP 51820），
# 不需要任何端口转发。hub 侧的 peer AllowedIPs 包含 192.168.10.0/24，
# 因此其他 WG 客户端访问 LAN 时会由 hub 转到这里。
#
# 不跑 Tailscale：Tailscale 设备继续走 NAS 的 ts-ecs/headscale 子网路由。

{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.8";
  hubPub = "xp7Ix5+/FrDr25Yk/K6+L+cYXrpZKwlvWoTA8Va+fRg=";
  hubEndpoint = "47.117.59.163:443";
in
{
  containers.wg-spoke = {
    autoStart = true;
    privateNetwork = true;
    enableTun = true;
    hostBridge = "br-lan";

    # 私钥/PSK 由 sops 在宿主解密，经 nspawn credential 注入容器
    extraFlags = [
      "--load-credential=wg-private:${config.sops.secrets.wg-spoke-private-key.path}"
      "--load-credential=wg-psk:${config.sops.secrets.wg-spoke-preshared-key.path}"
    ];

    config = { config, lib, pkgs, ... }: {
      system.stateVersion = "26.05";
      networking.hostName = "wg-spoke";

      networking = {
        interfaces.lan.ipv4.addresses = [
          {
            address = lanIp;
            prefixLength = 24;
          }
        ];
        defaultGateway = {
          address = "192.168.10.1";
          interface = "lan";
        };
        resolvconf.enable = false;

        # 容器只在 LAN 内做 WG→LAN 转发，没有对外服务；关掉 input 过滤，
        # 转发由下面显式的 SNAT 规则处理。
        firewall.enable = false;

        wireguard.interfaces.wg0 = {
          ips = [ "10.8.0.3/32" ];
          privateKeyFile = "/run/credentials/@system/wg-private";
          peers = [
            {
              publicKey = hubPub;
              presharedKeyFile = "/run/credentials/@system/wg-psk";
              allowedIPs = [ "10.8.0.0/24" ];
              endpoint = hubEndpoint;
              persistentKeepalive = 25;
            }
          ];
        };
      };

      environment.etc."resolv.conf" = {
        mode = "0644";
        text = ''
          nameserver 223.5.5.5
          nameserver 119.29.29.29
        '';
      };

      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv4.conf.all.rp_filter" = 0;
        "net.ipv4.conf.default.rp_filter" = 0;
        "net.ipv6.conf.all.disable_ipv6" = 1;
        "net.ipv6.conf.default.disable_ipv6" = 1;
      };

      # WG 客户端 → LAN 的源地址伪装成 NAS/LAN 地址；LAN 主机回包直接到 .8
      networking.nftables.enable = true;
      networking.nftables.tables.wg-spoke = {
        family = "ip";
        content = ''
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "lan" ip saddr 10.8.0.0/24 masquerade
          }
        '';
      };
    };
  };
}
