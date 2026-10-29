# cloudflare-mesh —— Cloudflare Mesh 节点（原 WARP Connector）
#
#   br-lan ──> lan   192.168.10.5/24   LAN（单口，出站直连 Cloudflare）
#
# 与 cloudflared 隧道是两件事：Tunnel 是 L7 按域名发布；Mesh 是 L3 双向，
# 每个参与者有 100.96.0.0/12 的 Mesh IP，节点可把 LAN 网段广告给 Mesh。
# LAN 网段的路由在 Cloudflare 面板的节点 Routes 里配，仓库里没有。
#
# 回程必须 SNAT：本节点不是默认网关（.1 是 main-router），LAN 主机收到
# Mesh 客户端（100.96.0.0/12）的包后会把回包发给 .1，而 .1 没有这条路由。
# 这与 tailscale 容器的 subnet router 是同一个坑，规则也照抄。
# 若以后要保留源 IP，改成 DHCP option 121 下发 `100.96.0.0/12 via .5`，
# 代价是静态设备仍要手加路由。
{ config, ... }:

let
  lanIp = "192.168.10.5";
  gatewayIp = "192.168.10.1";

  credDir = "/run/credentials/@system";
  stateDir = "/srv/state/cloudflare-mesh";
in
{
  # 状态目录必须先存在：bindMounts 的 hostPath 缺失时 nspawn 直接启动失败。
  # 不用 tmpfiles——它在 sysinit 跑，与 /srv 子卷挂载竞态（与 tailscale 同坑）。
  systemd.services.cloudflare-mesh-state-dirs = {
    description = "创建 cloudflare-mesh 容器的状态目录（须晚于 /srv 子卷挂载）";
    wantedBy = [ "multi-user.target" ];
    before = [ "container@cloudflare-mesh.service" ];
    requiredBy = [ "container@cloudflare-mesh.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      install -d -m 700 ${stateDir}
    '';
  };

  containers.cloudflare-mesh = {
    autoStart = true;
    privateNetwork = true;
    enableTun = true;
    hostBridge = "br-lan";

    # token 从宿主 sops 解密后经 nspawn 注入，容器内不留持久副本
    extraFlags = [
      "--load-credential=mesh-token:${config.sops.secrets.cloudflare-mesh-token.path}"
    ];

    # 注册身份持久化：容器重建/重启不重新注册
    bindMounts."/var/lib/cloudflare-warp" = {
      hostPath = stateDir;
      isReadOnly = false;
    };

    config = { pkgs, ... }:
      let
        # 无 GUI 版本：不拉 gtk3，warp-svc / warp-cli 与完整版相同。
        warpPkg = pkgs.cloudflare-warp.override { headless = true; };
      in
      {
        system.stateVersion = "26.05";
        networking.hostName = "cloudflare-mesh";

        # 容器是独立的 nixpkgs 求值，不继承宿主的 nixpkgs.config；
        # cloudflare-warp 是 unfree，必须在这里再放行一次。
        nixpkgs.config.allowUnfree = true;

        networking = {
          interfaces.lan.ipv4.addresses = [
            {
              address = lanIp;
              prefixLength = 24;
            }
          ];
          defaultGateway = {
            address = gatewayIp;
            interface = "lan";
          };
          resolvconf.enable = false;
          # 纯出站连接，不需要放行任何入站端口（包括 2408）
        };

        # 初始 DNS 必须直连公网：WARP 端点一旦被 YunShu 解析成 fake-IP
        # 就会被塞进 tun0，隧道建立不起来。连接后 warp-svc 会接管
        # /etc/resolv.conf，改用自己的 DoH 代理。
        environment.etc."resolv.conf" = {
          mode = "0644";
          text = ''
            nameserver 223.5.5.5
            nameserver 119.29.29.29
          '';
        };

        boot.kernel.sysctl = {
          "net.ipv4.ip_forward" = 1;
          # 与 tailscale 同理：Mesh 流量从 tun 进来、从 lan 出去，
          # 反向路径过滤会把它当伪造源地址丢掉。
          "net.ipv4.conf.all.rp_filter" = 0;
          "net.ipv4.conf.default.rp_filter" = 0;
          "net.ipv6.conf.all.disable_ipv6" = 1;
          "net.ipv6.conf.default.disable_ipv6" = 1;
        };

        # NixOS 模块只负责起 warp-svc；connector 注册/连接要自己补。
        services.cloudflare-warp = {
          enable = true;
          openFirewall = false;
          package = warpPkg;
        };

        systemd.services.cloudflare-mesh-enroll = {
          description = "注册并连接 Cloudflare Mesh 节点";
          wantedBy = [ "multi-user.target" ];
          after = [
            "cloudflare-warp.service"
            "network-online.target"
          ];
          wants = [
            "cloudflare-warp.service"
            "network-online.target"
          ];
          requires = [ "cloudflare-warp.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            # 必须与 warp-svc 的 RuntimeDirectory 一致：warp-cli 从
            # $RUNTIME_DIRECTORY/warp_service 找 IPC socket，不设就找不到。
            Environment = [ "RUNTIME_DIRECTORY=/run/cloudflare-warp" ];
          };
          script = ''
            set -eu
            cli=${warpPkg}/bin/warp-cli

            for i in {1..30}; do
              [ -S /run/cloudflare-warp/warp_service ] && break
              sleep 1
            done

            # 有持久化注册就只连接，不再消费 token。daemon 刚起来时
            # registration show 可能短暂报 "Daemon Startup"，所以多等几秒。
            registered=0
            for i in {1..30}; do
              if "$cli" --accept-tos registration show >/dev/null 2>&1; then
                registered=1
                break
              fi
              sleep 1
            done

            if [ "$registered" -eq 0 ]; then
              "$cli" --accept-tos connector new "$(cat ${credDir}/mesh-token)"
            fi

            "$cli" --accept-tos connect || true
            "$cli" --accept-tos status || true
          '';
        };

        # SNAT：Mesh 源地址从 lan 出去时换成容器地址。没有这条，LAN 主机
        # 的回包走 .1，Mesh 单向不通。
        networking.nftables.enable = true;
        networking.nftables.tables.mesh-subnet = {
          family = "ip";
          content = ''
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              oifname "lan" ip saddr 100.96.0.0/12 masquerade
            }
          '';
        };
      };
  };
}
