# main-router —— 唯一网关，由 router-container 构建
#
#   LAN 走 bridge（宿主能 tcpdump 容器间流量），WAN 走 macvlan
#   VPN 是 YunShu，以契约接入——路由器本体不认识它，换实现只改下面那一行
#
# 地址约定见 modules/network/：lan0 = 内网物理口，wan0 = 外网物理口。
{ config, lib, inputs, ... }:

{
  imports = [ inputs.router-container.nixosModules.router ];

  router = {
    enable = true;
    name = "main-router";

    # ── LAN：桥。宿主地址从 macvlan shim 搬到桥上 ──
    hostLanPort = "lan0";
    hostBridge = "br-lan";
    hostAddress = "192.168.10.2/24";
    hostDefaultGateway = "192.168.10.1";

    # ── WAN：macvlan，容器自己向上游要 DHCP ──
    wanParent = "wan0";

    # ── 客户端视角：网关与 DNS 都是 .1，由 DHCP 下发 ──
    address = "192.168.10.1";
    dhcpRange = "host0,192.168.10.100,192.168.10.200,255.255.255.0,12h";
    dhcpOptions = [
      "3,192.168.10.1"
      "6,192.168.10.1"
      "28,192.168.10.0/24"
    ];

    # 与改造前保持一致：上游按 MAC 记住了 192.168.1.52 这个租约，
    # 换 MAC 会拿新地址。
    macAddresses = {
      host0 = "02:00:00:02:00:11";
      eth1 = "02:00:00:02:00:12";
    };

    # 整个 VPN 就这一行。transit（tun0 / 198.18.0.0/15 / 10.251.1.1）
    # 和要注入容器的模块都在描述符里。
    vpn = inputs.router-container.vpns.yunshu;
  };
}
