# main-router —— 唯一网关：策略分流 + NAT + DHCP/DNS
#   lan0 ──> eth0   192.168.10.1/24   LAN（网关、DNS、DHCP 都在它上）
#   wan0 ──> eth1   DHCP              WAN
# lan0/wan0 是宿主侧按 MAC 锚定的名字（modules/network/links.nix）

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
      address = "192.168.10.1";
      dnsFallbackServers = [
        "223.5.5.5"
        "119.29.29.29"
      ];
    };

    guestModule = { config, lib, ... }: {
      networking = {
        interfaces.eth1.useDHCP = true;
        # dhcpcd 别去写 /etc/resolv.conf：那是只读的 store 符号链接
        dhcpcd.extraConfig = "nohook resolv.conf";
        # 67 = DHCP 服务端（53 由 yunshu-container 的 dns 模块放行）
        firewall.allowedUDPPorts = [ 67 ];
      };

      # 容器自身的解析：隧道 DNS 优先、公网兜底。不能交给 WAN 的 DHCP 下发
      # ——登录 YunShu 要先把控制面域名解析出来，那时隧道还没起来。
      environment.etc."resolv.conf" = {
        mode = "0644";
        text = ''
          nameserver 10.251.1.1
          nameserver 223.5.5.5
          nameserver 119.29.29.29
        '';
      };

      services.dnsmasq.settings = {
        dhcp-authoritative = true;
        dhcp-range = [ "eth0,192.168.10.100,192.168.10.200,255.255.255.0,12h" ];
        # 3 = 网关，6 = DNS，两者必须都是 .1：客户端 DNS 绕开网关就拿不到
        # fake-IP，域名级分流直接失效。
        dhcp-option = [
          "eth0,3,192.168.10.1"
          "eth0,6,192.168.10.1"
          "eth0,28,192.168.10.0/24"
        ];
      };

      boot.kernel.sysctl = {
        "net.ipv6.conf.all.disable_ipv6" = 1;
        "net.ipv6.conf.default.disable_ipv6" = 1;
      };
    };
  };
}
