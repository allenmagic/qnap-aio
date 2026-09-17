# side-router —— 备份直连网关（VRRP BACKUP，常驻待命）
#
# 与 main-router 组成浮动网关：正常时 main 持有 192.168.10.1 做策略分流；
# main 失效时本容器接管 VIP，**降级为纯直连 NAT**——保连通优先，不做分流。
#
#   lan0 ──> eth0   192.168.10.3/24   LAN（VRRP 实例绑在这个口上）
#   wan0 ──> eth1   DHCP              WAN
#
# 它同时是"降级态 DNS"的转发者：客户端 DNS 由 DHCP 下发为 VIP，VIP 在本容器
# 时由本容器把 53 交给 dnsmasq-container（见 docs/gateway.md §6.7）。
{ config, lib, pkgs, ... }:

let
  # 本文件内的地址集中在这里，改动时至少不用满文件找
  lanIp = "192.168.10.3";
  vip = "192.168.10.1";
  vrid = 51;
  authPass = "aio-vrrp"; # VRRPv2 认证字段只有 8 字节

  mainRouterIp = "192.168.10.2";
  dnsmasqIp = "192.168.10.7"; # DHCP 服务器 + 降级态 DNS
in
{
  containers.side-router = {
    autoStart = true;
    privateNetwork = true;
    # 同 main-router：冒号后半段是容器内接口名，不能省
    macvlans = [
      "lan0:eth0"
      "wan0:eth1"
    ];

    config = { config, lib, pkgs, ... }: {
      system.stateVersion = "26.05"; # 与宿主机一致（yunshu 容器的默认 guestModule 用的是 26.11）
      networking.hostName = "side-router";

      # macvlan 接口是 nspawn 在宿主 netns 建好再移进来的，容器内 udev 收不到
      # 设备添加事件，.link 静默无效——必须用 oneshot 直接改
      systemd.services.fix-mac-addresses = {
        before = [ "network-pre.target" ];
        wantedBy = [ "network-pre.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${pkgs.iproute2}/bin/ip link set eth0 address 02:00:00:02:00:21
          ${pkgs.iproute2}/bin/ip link set eth1 address 02:00:00:02:00:22
        '';
      };

      boot.kernel.sysctl = {
        "net.ipv4.ip_forward" = 1;
        "net.ipv4.conf.all.rp_filter" = 0;
        "net.ipv4.conf.default.rp_filter" = 0;
        "net.ipv4.conf.all.send_redirects" = 0;
        "net.ipv4.conf.default.send_redirects" = 0;
        # 整套设计只做 IPv4
        "net.ipv6.conf.all.disable_ipv6" = 1;
        "net.ipv6.conf.default.disable_ipv6" = 1;
      };

      networking.interfaces.eth0.ipv4.addresses = [
        {
          address = lanIp;
          prefixLength = 24;
        }
      ];
      networking.interfaces.eth1.useDHCP = true;

      # 由我们自己写 /etc/resolv.conf（见下），所以要关掉 resolvconf
      # ——NixOS 有断言：两者同时启用直接报错。同时禁止 dhcpcd 去写它：
      # 那是 NixOS 管理的 store 符号链接（只读），dhcpcd 每次续租都会报写失败。
      networking.resolvconf.enable = false;
      networking.dhcpcd.extraConfig = "nohook resolv.conf";

      # 容器自身的解析：它不做分流，直连公网 DNS 即可。
      # 不能靠 WAN 的 DHCP 下发——DHCP 客户端写不写 /etc/resolv.conf 取决于
      # 后端行为，写死更确定。
      environment.etc."resolv.conf" = {
        mode = "0644";
        text = ''
          nameserver 223.5.5.5
          nameserver 119.29.29.29
        '';
      };

      networking.nftables.enable = true;

      # 直连 NAT：下游流量出 WAN 口时改源地址，否则回包从上游直接绕回下游设备
      networking.nftables.tables."side-nat" = {
        family = "ip";
        content = ''
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "eth1" masquerade
          }
        '';
      };

      # 降级态 DNS：客户端问的是 VIP，VIP 在本容器上，所以由本容器把它们
      # 交给 dnsmasq-container。只对从 LAN 口进来、且目的地址是 VIP 的 53 生效。
      # ⚠️ 目的地址限定不能省：dnsmasq 的上游查询也从 eth0 进来，一并改写就绕回它自己成环。
      # ⚠️ inet 表里必须写 `dnat ip to`：只写 `dnat to` 会报
      #    "specify `dnat ip' or `dnat ip6' in inet table to disambiguate"
      networking.nftables.tables."side-dns" = {
        family = "inet";
        content = ''
          chain prerouting {
            type nat hook prerouting priority dstnat; policy accept;
            iifname "eth0" ip daddr ${vip} udp dport 53 dnat ip to ${dnsmasqIp}:53
            iifname "eth0" ip daddr ${vip} tcp dport 53 dnat ip to ${dnsmasqIp}:53
          }
        '';
      };

      networking.firewall = {
        filterForward = true;
        extraForwardRules = ''
          tcp flags syn tcp option maxseg size set rt mtu
          iifname "eth0" accept
        '';
        # 必须显式放行：VRRP 是 IP protocol 112，NixOS 防火墙的 input 链默认
        # drop 且不会为它生成规则。同机双容器场景下尤其致命——两个 macvlan
        # 兄弟都收不到对方心跳时，谁也不会在冲突时退让。
        extraInputRules = ''
          ip protocol 112 accept comment "VRRP"
        '';
      };

      services.keepalived = {
        enable = true;

        vrrpScripts.chkWan = {
          # 探测走 HTTP 而不是 ICMP：上游丢 ICMP 的环境里，ping 会把正常的
          # WAN 判死。用国内可达的站点，因为这是**直连**出口的检查
          # （main-router 那边的探测才需要走被墙域名以验证隧道）。
          script = "${pkgs.curl}/bin/curl -sf -o /dev/null --max-time 3 --interface eth1 http://www.baidu.com";
          interval = 5;
          timeout = 3;
          # -100 是刻意的：keepalived 在"优先级 + 权重 < 1"时进入 FAULT，
          # 这样 WAN 不通时就**永远不会**接管 VIP。若只降一点权重，它会带着
          # 一个上不了网的网关接管，比不接管更糟。
          weight = -100;
          fall = 2;
          rise = 2;
          user = "root"; # 默认的 keepalived_script 用户 NixOS 并不创建
        };

        vrrpInstances.LAN = {
          state = "BACKUP";
          interface = "eth0";
          virtualRouterId = vrid;
          priority = 90; # main-router 为 100
          # 不能用 noPreempt：BACKUP 不发心跳，主节点降权时它不会接管（实测 VIP 不漂移）
          unicastSrcIp = lanIp;
          unicastPeers = [ mainRouterIp ];
          trackScripts = [ "chkWan" ];
          virtualIps = [ { addr = "${vip}/24"; } ];
          extraConfig = ''
            advert_int 1
            authentication {
              auth_type PASS
              auth_pass ${authPass}
            }
          '';
        };
      };
    };
  };
}
