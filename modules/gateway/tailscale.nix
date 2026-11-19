# tailscale —— 官方 Tailscale 实例
#
#   br-lan ──> lan     192.168.10.4/24   LAN（单口，出站直连）
#
# 官方控制面：接口 tailscale0，UDP 41641。
# 旧的 Headscale 实例（hs.zyx1986.icu）已移除；新的 aliyun-ecs Headscale
# 在 ts-ecs 容器中，见 modules/gateway/tailscale-ecs.nix。

{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.4";
  # WAN 侧 macvlan 的 MAC：上游按 MAC 认租约，nspawn 每次重建都随机生成，必须固定
  wanMac = "02:00:00:02:00:42";


  stateDir = "/srv/state/tailscale"; # data 卷的子卷，不在 NFS/Samba 导出内
  advertiseRoute = "192.168.10.0/24";

  # 沿用 router-image/network.env 里的设备名，保持 tailnet 里的身份连续
  tsHostname = "router-vm";

  # 密钥不落盘：sops 在宿主解密 → nspawn --load-credential 注入容器 PID 1 的
  # 凭据目录 → 下面直接从这里读。容器内不写任何持久副本。
  credDir = "/run/credentials/@system";
in
{
  # 不用 tmpfiles：它在 sysinit 跑，与 /srv/data 挂载竞态，目录会被挂载点遮住
  systemd.services.tailscale-state-dirs = {
    description = "创建 tailscale 容器的状态目录（须晚于 /srv/data 挂载）";
    wantedBy = [ "multi-user.target" ];
    before = [ "container@tailscale.service" ];
    requiredBy = [ "container@tailscale.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 755 ${stateDir}
      install -d -m 700 ${stateDir}/official
    '';
  };

  containers.tailscale = {
    autoStart = true;
    privateNetwork = true;
    enableTun = true;
    hostBridge = "br-lan";
    # 自己在 WAN 上也要一个地址：让隧道**不依赖网关出网**。
    # 网关挂掉时隧道仍在，从外面还能进内网修机器（内网设备的网关/DNS 此时都失效，
    # 但 tailnet→内网的入站不经过网关，NAS 宿主机仍是可达的）。
    macvlans = [ "wan:wan" ];

    extraFlags = [
      "--load-credential=ts-authkey:${config.sops.secrets.tailscale-auth-key.path}"
    ];

    # 节点身份持久化：容器重建/重启不重新注册，免去反复重新审批 subnet route
    bindMounts = {
      "/var/lib/tailscale" = {
        hostPath = "${stateDir}/official";
        isReadOnly = false;
      };
    };

    config = { config, lib, pkgs, ... }: {
      system.stateVersion = "26.05";
      networking.hostName = "tailscale";

      systemd.services.fix-wan-mac = {
        description = "固定 WAN 口 MAC（nspawn 每次重建都随机生成）";
        before = [ "network-pre.target" ];
        wantedBy = [ "network-pre.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = "${pkgs.iproute2}/bin/ip link set wan address ${wanMac}";
      };

      networking = {
        interfaces.lan.ipv4.addresses = [
          {
            address = lanIp;
            prefixLength = 24;
          }
        ];

        # 默认路由走**自己的 WAN 口**（DHCP 提供），不指向网关 .1：
        # 这是本容器唯一依赖 .1 的地方，去掉之后网关故障不影响隧道存活。
        # 内网不受影响——靠 lan 的直连路由。
        interfaces.wan.useDHCP = true;
        # nohook：resolv.conf 下面写死了，dhcpcd 写它会报错。
        # hostname：dhcpcd 默认不发 hostname，上游设备列表里只会看到 MAC。
        dhcpcd.extraConfig = ''
          nohook resolv.conf
          hostname tailscale
        '';
        resolvconf.enable = false;

        firewall = {
          # 41641 由 services.tailscale.openFirewall 打开。
          allowedTCPPorts = [ 22 ]; # 远程经 tailnet SSH 进来
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

      # subnet router 的 SNAT。tailscaled 设了 netfilter-mode=off，
      # 于是不装任何 NAT 规则；缺了它，LAN 主机的回包会发给默认网关（.1），
      # 而网关没有 100.64.0.0/10 的路由 → subnet routing 整个不通。
      # 不给 tailscale 接管 nftables，只显式补这一条。
      # lan 是本容器的 LAN 口，由 bridge-iface.nix 把 nspawn 的 veth 改名而来。
      networking.nftables.enable = true;
      networking.nftables.tables.ts-subnet = {
        family = "ip";
        content = ''
          chain postrouting {
            type nat hook postrouting priority srcnat; policy accept;
            oifname "lan" ip saddr 100.64.0.0/10 masquerade
          }
        '';
      };

      # ── 官方控制面实例（tailscale0 / 41641）──────────────────────────
      # 用 NixOS 原生模块：它负责 tailscaled 单元、"up + set"的时序、
      # 以及 useRoutingFeatures 带出的转发 sysctl 与防火墙规则。
      services.tailscale = {
        enable = true;
        port = 41641;
        interfaceName = "tailscale0";
        openFirewall = true;
        # 子网路由器：需要转发 LAN 流量
        useRoutingFeatures = "server";

        authKeyFile = "${credDir}/ts-authkey";
        extraUpFlags = [
          "--hostname=${tsHostname}"
          "--advertise-routes=${advertiseRoute}"
          "--accept-routes"
        ];
        # netfilterMode=off：不让 tailscale 自己接管防火墙链。
        # 这套拓扑的转发/过滤由本模块显式声明，交给它管理会与既有规则打架。
        extraSetFlags = [
          "--netfilter-mode=off"
          "--accept-dns=false"
        ];
      };

    };
  };
}
