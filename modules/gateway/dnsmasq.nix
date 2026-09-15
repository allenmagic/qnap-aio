# dnsmasq —— 全网唯一的 DHCP 服务器 + 降级态 DNS 解析器
#
#   lan0 ──> eth0   192.168.10.7/24   LAN（单口，不需要 WAN）
#
# 两个职责都**不随 VIP 漂移**，所以放在固定地址的独立容器上：
#   - DHCP 应答走广播，不需要持有 VIP；
#   - 客户端 DNS 由 DHCP 下发为 VIP（见 docs/gateway.md §6.7），VIP 在
#     main-router 时由 YunShu 隧道 DNS 接管做分流，漂到 side-router 时由它把
#     53 转到这里——所以本容器只在降级态真正被用到。
#
# 出站默认网关指向 side-router（.3）而不是 VIP：它的上游 DNS 查询必须走直连，
# 不能被当成"该走代理的流量"。副作用是它依赖 side-router，但两者本来就在
# 同一场景下成对出现（side 接管 VIP 时本容器才被使用），不引入新的故障面。
{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.7";
  vip = "192.168.10.1"; # DHCP 下发的网关与 DNS 都指它
  sideRouterIp = "192.168.10.3";

  stateDir = "/srv/data/dnsmasq"; # 租约库：丢了不是"配置丢失"，是会把已发出的地址再发一遍
  mac = "02:00:00:02:00:31";
in
{
  # 容器状态的宿主目录（bindMount 的源必须存在，否则容器起不来）
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 root root -"
  ];

  containers.dnsmasq = {
    autoStart = true;
    privateNetwork = true;
    macvlans = [ "lan0:eth0" ];

    # 租约库落宿主持久目录：容器重建后不能忘记发过哪些地址，
    # 否则会把还在用的地址再分配出去，直接制造冲突。
    bindMounts."/var/lib/dnsmasq" = {
      hostPath = stateDir;
      isReadOnly = false;
    };

    config = { config, lib, pkgs, ... }: {
      system.stateVersion = "26.05";
      networking.hostName = "dnsmasq";

      # 前缀 10- 排在 NixOS 自动生成的 40-<接口名> 之前（udev 只应用最靠前的那个）
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

        # 静态地址、无 DHCP 客户端，但仍然要关 resolvconf 才能自己写 resolv.conf
        # ——NixOS 对两者同时存在有断言。
        resolvconf.enable = false;

        firewall = {
          # 53 给 side-router 转过来的降级态查询；67 是 DHCP 服务端
          # （NixOS 不会因为启用 dnsmasq 就自动放行，不写这条 DHCP 直接被丢）。
          allowedTCPPorts = [ 53 ];
          allowedUDPPorts = [
            53
            67
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

      services.dnsmasq = {
        enable = true;
        # 不让它接管容器自身的解析：本容器的上游就是公网 DNS，
        # 走本地回环只会绕一圈（而且会去动 networking.nameservers）。
        resolveLocalQueries = false;

        settings = {
          interface = "eth0";
          # bind-dynamic 而非 bind-interfaces：接口/地址变化时自动跟随，
          # 以后调整网络不用重启服务。
          bind-dynamic = true;

          dhcp-authoritative = true;
          dhcp-range = [ "eth0,192.168.10.100,192.168.10.200,255.255.255.0,12h" ];
          # 3 = 默认网关，6 = DNS，两者都必须是 VIP。
          # 写死成某个容器的固定地址就等于放弃分流：DNS 绕开 VIP 后
          # YunShu 的 fake-IP 不会触发，被墙域名拿不到代理路径。
          dhcp-option = [
            "eth0,3,${vip}"
            "eth0,6,${vip}"
            "eth0,28,192.168.10.0/24"
          ];

          no-resolv = true;
          server = [
            "223.5.5.5"
            "119.29.29.29"
          ];
        };
      };
    };
  };
}
