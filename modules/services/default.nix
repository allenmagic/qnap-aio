{ config, lib, ... }:

let
  # 这些服务把监听地址钉在 mv-shim 的静态地址（.2）上，而 networkd 配上该地址
  # 比它们启动晚（macvlan 要等 lan 出 carrier，实测差约 3 秒）。不排序的话开机
  # 会以 "cannot assign requested address" 失败，而且两种失败都不会自愈：
  # navidrome 以 0 退出（Restart=on-failure 不触发），webdav 撞 start-limit。
  bindToShim = [
    "aria2"
    "glance"
    "navidrome"
    "openlist"
    "qbittorrent"
    "syncthing"
    "webdav"
  ];
in
{
  imports = [
    ./samba.nix
    ./nfs.nix
    ./syncthing.nix
    # 音乐服务端：Navidrome（2026-09-14 从 gonic 回退，gonic 功能支持不足）。
    # 前端 feishin 独立成文件，两种服务端共用。
    # 切回 gonic：把下面这行换成 ./music.nix
    #            （注意两者的数据库互不兼容，切换后会重新扫描）
    ./music-navidrome.nix
    # ./music.nix   # 剔除（不引用）：gonic 配置保留在 services/music.nix，
    #               # 需要恢复时取消注释，并屏蔽上面的 ./music-navidrome.nix
    ./feishin.nix
    ./beszel.nix
    ./glance.nix
    ./backup.nix
    ./downloads.nix
    # 网盘聚合（百度/阿里/夸克/GDrive）：Web UI + WebDAV
    ./openlist.nix
    ./webdav.nix
    # cockpit 已删除（含其 9090 端口放行）：系统 Web 管理改用 SSH +
    # services/glance.nix 的仪表盘
    # YunShu 透明网关已移出 services/：改成 macvlan 接入后归到
    # modules/gateway/main-router.nix
  ];

  systemd.services = lib.genAttrs bindToShim (name: {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
  });
}
