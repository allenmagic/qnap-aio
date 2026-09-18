# main-router —— 唯一网关，由 router-container 构建
#
#   LAN 走 bridge（宿主能 tcpdump 容器间流量），WAN 走 macvlan
#   VPN 是 YunShu，以契约接入——路由器本体不认识它，换实现只改下面那一行
#
# 地址约定见 modules/network/：lan = 内网物理口，wan = 外网物理口。
{ config, lib, inputs, ... }:

{
  imports = [ inputs.router-container.nixosModules.router ];

  router = {
    enable = true;
    name = "main-router";

    # ── LAN：桥。宿主地址从 macvlan shim 搬到桥上 ──
    hostLanPort = "lan";
    hostBridge = "br-lan";
    hostAddress = "192.168.10.2/24";
    hostDefaultGateway = "192.168.10.1";

    # ── WAN：macvlan，容器自己向上游要 DHCP ──
    wanParent = "wan";

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

  # 状态落 /srv/state（data 卷上的独立子卷）。
  #
  # 不能用 /srv/data：那是 NFS/Samba 的导出范围，YunShu 的登录 token 会暴露在
  # 网络共享里。也不能不挂：容器 /var 虽然默认持久（ephemeral = false），但那份
  # 落在宿主根文件系统上。
  containers.main-router.bindMounts = {
    "/var/lib/yunshu" = {
      hostPath = "/srv/state/router/yunshu";
      isReadOnly = false;
    };
    "/var/lib/dnsmasq" = {
      hostPath = "/srv/state/router/dnsmasq";
      isReadOnly = false;
    };
  };

  # 目录必须先存在：bindMounts 的 hostPath 不存在时 nspawn 直接启动失败。
  # 不用 tmpfiles——它在 sysinit 跑，与 /srv 子卷挂载竞态，目录会被挂载点遮住
  # （与 dnsmasq/tailscale 的状态目录同一个坑）。
  systemd.services.router-state-dirs = {
    description = "创建 router 容器的状态目录（须晚于 /srv 子卷挂载）";
    wantedBy = [ "multi-user.target" ];
    before = [ "container@main-router.service" ];
    requiredBy = [ "container@main-router.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 755 /srv/state/router/yunshu
      install -d -m 755 /srv/state/router/dnsmasq
    '';
  };
}
