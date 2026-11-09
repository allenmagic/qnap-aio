# ts-ecs —— 连接 aliyun-ecs 新 headscale 的迁移实例
#
# 与现有 tailscale 容器（官方 + 旧 headscale hs.zyx1986.icu）完全隔离：
#   br-lan ──> lan  192.168.10.7/24   LAN（单口，默认网关 .1）
#
# 迁移期间两个容器并存，旧实例不动，新实例独立注册到
# https://hs-direct.allenmagic.cn:8443（客户端直连入口，不走 Cloudflare；
# hs.allenmagic.cn 仅用于管理 UI/API）。验证完成后，再由人工决定何时下线旧实例。
#
# ⚠️ 容器名必须短（这里用 ts-ecs）：nspawn 以 vb-<容器名> 命名宿主 veth，
#    超过 15 字符会被截断；tailscale-ecs 曾因此与残留 veth 冲突（File exists）。
# ⚠️ 网络走 LAN 网关 .1，而不是像旧实例那样用 WAN macvlan 直连上游：
#    迁移实例不需要网关故障时的独立性，走宿主机已验证可用的链路更稳。

{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.7";
  stateDir = "/srv/state/ts-ecs"; # data 卷的子卷，不在 NFS/Samba 导出内
  advertiseRoute = "192.168.10.0/24";
  tsHostname = "nixos-router-vm-hs-ecs";
  hsControlUrl = "https://hs-direct.allenmagic.cn:8443";

  # 密钥不落盘：sops 在宿主解密 → nspawn --load-credential 注入容器 PID 1 的
  # 凭据目录 → 下面直接从这里读。容器内不写任何持久副本。
  credDir = "/run/credentials/@system";
in
{
  # 不用 tmpfiles：它在 sysinit 跑，与 /srv/data 挂载竞态，目录会被挂载点遮住
  systemd.services.ts-ecs-state-dirs = {
    description = "创建 ts-ecs 容器的状态目录（须晚于 /srv/data 挂载）";
    wantedBy = [ "multi-user.target" ];
    before = [ "container@ts-ecs.service" ];
    requiredBy = [ "container@ts-ecs.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 755 ${stateDir}
      install -d -m 700 ${stateDir}/headscale
    '';
  };

  containers.ts-ecs = {
    autoStart = true;
    privateNetwork = true;
    enableTun = true;
    hostBridge = "br-lan";

    extraFlags = [
      "--load-credential=hs-authkey:${config.sops.secrets.headscale-ecs-auth-key.path}"
    ];

    # 节点身份持久化：容器重建/重启不重新注册，免去重复审批 subnet route
    bindMounts = {
      "/var/lib/headscale" = {
        hostPath = "${stateDir}/headscale";
        isReadOnly = false;
      };
    };

    config = { config, lib, pkgs, ... }: {
      system.stateVersion = "26.05";
      # 容器内主机名（DHCP/日志用）；与容器名 ts-ecs 区分，tailnet 主机名见 tsHostname
      networking.hostName = "tailscale-ecs";

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

        firewall = {
          allowedUDPPorts = [ 41643 ];
          allowedTCPPorts = [ 22 ];
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

      # subnet router 的 SNAT：与旧实例同理——LAN 主机的回包发给默认网关 .1，
      # 而 .1 没有 100.64.0.0/10 的路由，必须在这里把源地址伪装成 lanIp。
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

      # ── aliyun-ecs headscale 实例（ts0 / 41643）────────────────────
      # 独立 netns，接口名可与旧实例重名；容器完全隔离，不动旧服务。
      systemd.services."tailscaled-headscale-ecs" = {
        description = "tailscaled（aliyun-ecs headscale，迁移实例）";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.tailscale}/bin/tailscaled --state=/var/lib/headscale/tailscaled.state --socket=/run/headscale/tailscaled.sock --port=41643 --tun=ts0";
          StateDirectory = "headscale";
          RuntimeDirectory = "headscale";
          Restart = "on-failure";
        };
      };

      systemd.services."tailscale-headscale-ecs-autoconnect" = {
        description = "登录 aliyun-ecs headscale 并广告 LAN 网段";
        wantedBy = [ "multi-user.target" ];
        after = [
          "tailscaled-headscale-ecs.service"
          "network-online.target"
        ];
        wants = [ "network-online.target" ]; # after 了就要依赖，否则 systemd 告警
        requires = [ "tailscaled-headscale-ecs.service" ];
        serviceConfig = {
          # Type=simple：tailscale up 在首次注册时会阻塞，不能让 oneshot
          # 拖住 multi-user/nspawn 就绪；失败后由 Restart 自动重试。
          Type = "simple";
          Restart = "on-failure";
          RestartSec = 30;
          ExecStart = pkgs.writeShellScript "headscale-ecs-autoconnect" ''
            set -eu
            ts=${pkgs.tailscale}/bin/tailscale
            sock=/run/headscale/tailscaled.sock

            # tailscale 不允许在已登录状态下直接切换控制面；地址变化时先 logout。
            # 当前地址从 tailscaled prefs 读取（未登录时为空，跳过）。
            cur=$("$ts" --socket="$sock" debug prefs 2>/dev/null \
              | sed -n 's/.*"ControlURL": "\([^"]*\)".*/\1/p' | head -1)
            if [ -n "$cur" ] && [ "$cur" != "${hsControlUrl}" ]; then
              "$ts" --socket="$sock" logout || true
            fi

            # --auth-key 只用于首次注册；节点身份在 /var/lib/headscale 里持久，
            # 之后重启不再需要它（但留着无害，重新注册时才用得上）。
            # ⚠️ netfilter-mode / accept-dns 必须写在 up 里，不能事后用 set 补。
            "$ts" --socket="$sock" up \
              --auth-key "$(cat ${credDir}/hs-authkey)" \
              --login-server=${hsControlUrl} \
              --hostname=${tsHostname} \
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
