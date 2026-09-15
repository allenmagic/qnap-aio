# main-router —— 主透明网关（VRRP MASTER，持有浮动网关 192.168.10.1）
# 接入：macvlan 直连两个物理口，容器自己就是网关——自己做 NAT、自己从 WAN
#   lan0 ──> eth0   192.168.10.2/24   LAN（VRRP 实例绑在这个口上）
#   wan0 ──> eth1   DHCP              WAN
# lan0/wan0 是宿主侧按 MAC 锚定的名字（modules/network/links.nix），

{ config, lib, inputs, ... }:

{
  imports = [ inputs.yunshu-container.nixosModules.container ];

  yunshu.container = {
    name = "main-router";
    hostname = "main-router"; # 默认是 yunshu-router

    macvlans = [
      "lan0:eth0"
      "wan0:eth1"
    ];
    lanInterface = "eth0";
    wanInterface = "eth1";

    macAddresses = {
      eth0 = "02:00:00:02:00:11";
      eth1 = "02:00:00:02:00:12";
    };

    gateway = {
      floatIp = "192.168.10.1";
      vrrpId = 51;
      priority = 100;        # side-router 为 90
      authPass = "aio-vrrp"; # VRRPv2 认证字段只有 8 字节，别超长
      unicastSrcIp = "192.168.10.2";
      unicastPeers = [ "192.168.10.3" ]; # side-router

      # 隧道不通时降权让出 VIP（100 - 30 = 70 < 90）。
      trackTunnel = true;
      tunnelTrackWeight = -30;
    };

    guestModule = { config, lib, ... }: {
      networking = {
        interfaces.eth0.ipv4.addresses = [
          {
            address = "192.168.10.2";
            prefixLength = 24;
          }
        ];
        interfaces.eth1.useDHCP = true;

        # /etc/resolv.conf 由下面写死，禁止 dhcpcd 去写它：那是 NixOS 管理的
        # store 符号链接（只读），dhcpcd 每次续租都会报写失败。
        dhcpcd.extraConfig = "nohook resolv.conf";
      };

      # 容器自身的解析：隧道 DNS 优先、公网兜底。
      # 不能交给 WAN 的 DHCP 下发——登录 YunShu 要先把控制面域名解析出来，
      # 那个时刻隧道还没起来。
      environment.etc."resolv.conf" = {
        mode = "0644";
        text = ''
          nameserver 10.251.1.1
          nameserver 223.5.5.5
          nameserver 119.29.29.29
        '';
      };

      # 整套设计只做 IPv4；v6 显式关掉，免得半吊子转发引入难查的问题
      boot.kernel.sysctl = {
        "net.ipv6.conf.all.disable_ipv6" = 1;
        "net.ipv6.conf.default.disable_ipv6" = 1;
      };
    };
  };
}
