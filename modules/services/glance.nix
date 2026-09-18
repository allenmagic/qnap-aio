{ config, lib, ... }:

{
  # Glance 仪表盘（glanceapp/glance）：起始页，bookmarks 汇总本机各 Web 服务入口。
  # 公网访问经cloudflared 容器隧道回源到 192.168.10.2:8080，
  # 隧道 ingress 在 Cloudflare Zero Trust 面板配置（见 README）。
  services.glance = {
    enable = true;

    settings = {
      server = {
        host = "192.168.10.2"; # 只绑内网（宿主机地址在 br-lan 上）
        port = 8080;
        # 经 cloudflared 回源：按 X-Forwarded-For 认客户端 IP。Glance 自带的
        # 暴力破解防护（5 次失败封 IP 5 分钟）依赖它，不加则所有请求同源。
        proxied = true;
      };

      # 自带认证（公网暴露必需）。两个值都走 sops，由模块的 ExecStartPre
      # （以 root 跑 jq）替换进 /run/glance/glance.yaml，不进 nix store。
      # ⚠️ sops 里的值不能带尾换行：secret-key 多 1 字节即长度校验失败，
      #    password-hash 多 \n 则 bcrypt 比对恒失败。
      auth = {
        secret-key = {
          _secret = config.sops.secrets.glance-secret-key.path;
        };
        users.nas.password-hash = {
          _secret = config.sops.secrets.glance-password-hash.path;
        };
      };

      pages = [
        {
          name = "Home";
          columns = [
            {
              size = "full";
              widgets = [
                # 用 monitor 而非 bookmarks：一样可点击跳转，但额外显示在线状态，
                # 正好解决「记不住端口 / 不知道还活着没」。
                #
                # alt-status-codes 是实测值，不是猜的：Glance 自身(8080) 与
                # 音乐服务端(4533) 探测返回 303（重定向到登录页），WebDAV(4918) 返回
                # 401，不列进来会被误判成「挂了」。
                {
                  type = "monitor";
                  title = "NAS 服务";
                  # 图标前缀：si=simple-icons sh=selfh.st di=dashboard-icons mdi=Material。
                  # 下面每个都实测过对应 CDN 返回 200，不是照名字猜的——
                  # 音乐服务端与 WebDAV 在图库里都没有专用图标，所以用泛用图标代替。
                  #
                  # 不设 same-tab：该项默认 false，模板在 !SameTab 时加 target="_blank"，
                  # 也就是默认在新页签打开——从面板点进各服务后还想回面板，所以保持默认。
                  sites = [
                    # 内网地址：Glance 自身走公网访问时这些链接点不开，
                    # 需要时再补一组走 Cloudflare 子域名的「公网」链接。
                    { title = "Glance"; url = "http://192.168.10.2:8080"; icon = "sh:glance"; alt-status-codes = [ 302 303 ]; }
                    { title = "qBittorrent"; url = "http://192.168.10.2:8081"; icon = "si:qbittorrent"; }
                    { title = "AriaNg"; url = "http://192.168.10.2:6880"; icon = "sh:aria2"; }
                    # OpenList 没有自己的 simple-icons 图标（404），借用同源的 alist
                    { title = "OpenList"; url = "http://192.168.10.2:5244"; icon = "si:alist"; }
                    { title = "Feishin"; url = "http://192.168.10.2:9180"; icon = "si:musicbrainz"; }
                    { title = "Navidrome"; url = "http://192.168.10.2:4533"; icon = "mdi:music-circle"; alt-status-codes = [ 302 303 ]; }
                    { title = "Syncthing"; url = "http://192.168.10.2:8384"; icon = "si:syncthing"; }
                    { title = "Beszel"; url = "http://192.168.10.2:8090"; icon = "sh:beszel"; }
                    { title = "WebDAV"; url = "http://192.168.10.2:4918"; icon = "mdi:folder-network"; alt-status-codes = [ 401 ]; }
                  ];
                }
              ];
            }
            # small 列固定 300px，full 列吃掉剩余宽度；每页最多 3 列且必须有
            # 1~2 个 full。把紧凑卡片放侧栏、服务面板占主区，不再清一色竖排。
            {
              size = "small";
              widgets = [
                { type = "clock"; }
                { type = "weather"; location = "Beijing"; }
                { type = "server-stats"; servers = [ { type = "local"; name = "NAS"; } ]; }
              ];
            }
          ];
        }
      ];
    };
  };
}
