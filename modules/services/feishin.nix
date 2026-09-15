{ config, pkgs, lib, ... }:

let
  # feishin-web 前端静态文件 + 预生成 settings.js（逻辑与 nixpkgs
  # services.feishin 模块相同：window.<KEY> = "<VALUE>"）。
  # settings.js 优先（buildEnv 后者覆盖包内同名文件）。
  feishinSettingsJs = pkgs.writeTextDir "settings.js" ''
    "use strict";
    window.ANALYTICS_DISABLED = "true";
  '';
  feishinWebRoot = pkgs.buildEnv {
    name = "feishin-web-root";
    paths = [ pkgs.feishin-web feishinSettingsJs ];
  };
in
{
  # ===== Feishin Web 客户端（darkhttpd 托管静态文件）=====
  # 从 music.nix 抽出：音乐服务端在 gonic / navidrome 之间切换时，
  # 前端保持不动（feishin 两种都支持，连接时服务器类型选 subsonic）。
  #
  # 2026-09 从 nginx 方案切换：feishin-web 是 HashRouter 单页应用（深链为
  # /#/ 形式，无需服务端 tryFiles fallback），nginx 的其余职责（vhost/gzip/
  # no-store 响应头）在内网 HTTP 场景均非必需，darkhttpd 几 KB 即可承载。
  # 公网入口由 Cloudflare Tunnel 提供（VM 内 cloudflared ingress →
  # http://192.168.10.2:9180，HTTPS/域名在 Cloudflare 侧终结；用子域名
  # 而非子路径，避免 hash 路由下 assets 绝对路径在子路径下 404）。
  # 服务器地址不硬编码：内网用户填 http://192.168.10.2:4533，
  # 公网用户填 https://<域名>，浏览器里各自填写。
  services.darkhttpd = {
    enable = true;
    port = 9180;
    # darkhttpd 1.17 里 --ipv6（由 networking.enableIPv6 触发）与 IPv4 --addr
    # 冲突（报 malformed --addr argument）。改用 IPv6 通配 ::，dual-stack 下
    # 同时接受 IPv4（br-wan 无 IP，实际只暴露 br-lan 内网）。
    address = "::";
    rootDir = "${feishinWebRoot}";
  };
}
