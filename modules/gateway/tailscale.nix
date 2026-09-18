# tailscale —— 两个 tailscale 实例合并在一个容器里
#
#   lan0 ──> eth0   192.168.10.4/24   LAN（单口，出站直连）
#
# 两个实例互为独立 tailnet，不是主备关系（Tailscale 没有 failover 语义）：
#   - 官方控制面：接口 tailscale0，UDP 41641
#   - 自建 Headscale：接口 ts0，UDP 41642，控制面 hs.zyx1986.icu
#
# ⚠️ 两个实例都广告 192.168.10.0/24。这是现状的延续（router-image 的
# network.env 里 TS_ADVERTISE_ROUTES 与 HEADSCALE_ADVERTISE_ROUTES 相同），
# 但两个 tailnet 的客户端会各自看到一条重叠路由——它们分属不同 tailnet，
# 互不影响；别把两个实例理解成"同一张网里的两个出口"。

{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.4";
  gatewayIp = "192.168.10.1";
  mac = "02:00:00:02:00:41";

  stateDir = "/srv/state/tailscale"; # data 卷的子卷，不在 NFS/Samba 导出内
  advertiseRoute = "192.168.10.0/24";

  # 沿用 router-image/network.env 里的设备名，保持 tailnet 里的身份连续
  tsHostname = "router-vm";
  hsHostname = "nixos-router-vm-hs";
  hsControlUrl = "https://hs.zyx1986.icu";

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
      install -d -m 700 ${stateDir}/official ${stateDir}/headscale
    '';
  };

  containers.tailscale = {
    autoStart = true;
    privateNetwork = true;
    enableTun = true;
    macvlans = [ "lan0:eth0" ];

    extraFlags = [
      "--load-credential=ts-authkey:${config.sops.secrets.tailscale-auth-key.path}"
      "--load-credential=hs-authkey:${config.sops.secrets.headscale-auth-key.path}"
    ];

    # 节点身份持久化：容器重建/重启不重新注册，免去反复重新审批 subnet route
    bindMounts = {
      "/var/lib/tailscale" = {
        hostPath = "${stateDir}/official";
        isReadOnly = false;
      };
      "/var/lib/headscale" = {
        hostPath = "${stateDir}/headscale";
        isReadOnly = false;
      };
    };

    config = { config, lib, pkgs, ... }: {
      system.stateVersion = "26.05";
      networking.hostName = "tailscale";

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
          address = gatewayIp;
          interface = "eth0";
        };
        resolvconf.enable = false;

        firewall = {
          # 官方实例的 41641 由 services.tailscale.openFirewall 打开；
          # 41642 是 headscale 实例的，得自己加
          allowedUDPPorts = [ 41642 ];
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

      # ── 自建 Headscale 实例（ts0 / 41642）───────────────────────────
      # 官方模块不支持多实例，所以这一份手写；与上面保持同样的
      # "tailscaled 常驻 + up 登录 + set 收尾"结构。
      systemd.services."tailscaled-headscale" = {
        description = "tailscaled（自建 Headscale 控制面，第二实例 ts0）";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.tailscale}/bin/tailscaled --state=/var/lib/headscale/tailscaled.state --socket=/run/headscale/tailscaled.sock --port=41642 --tun=ts0";
          StateDirectory = "headscale";
          RuntimeDirectory = "headscale";
          Restart = "on-failure";
        };
      };

      systemd.services."tailscale-headscale-autoconnect" = {
        description = "登录自建 Headscale 并广告 LAN 网段";
        wantedBy = [ "multi-user.target" ];
        after = [
          "tailscaled-headscale.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ]; # after 了就要依赖，否则 systemd 告警
        requires = [ "tailscaled-headscale.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "headscale-autoconnect" ''
            set -eu
            ts=${pkgs.tailscale}/bin/tailscale
            sock=/run/headscale/tailscaled.sock

            # --auth-key 只用于首次注册；节点身份在 /var/lib/headscale 里持久，
            # 之后重启不再需要它（但留着无害，重新注册时才用得上）。
            # ⚠️ netfilter-mode / accept-dns 必须写在 up 里，不能事后用 set 补：
            #    节点上已经存在这两个非默认设置后，下次开机的 up 会因为
            #    "requires mentioning all non-default flags" 直接报错退出。
            "$ts" --socket="$sock" up \
              --auth-key "$(cat ${credDir}/hs-authkey)" \
              --login-server=${hsControlUrl} \
              --hostname=${hsHostname} \
              --advertise-routes=${advertiseRoute} \
              --accept-routes \
              --netfilter-mode=off \
              --accept-dns=false
          '';
        };
      };
    };
  };
}
