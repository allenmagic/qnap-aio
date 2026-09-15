{ config, lib, ... }:

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
    # ./cockpit.nix   # 剔除（不引用）：配置文件保留在 services/cockpit.nix，
    #                 # 需要恢复时取消注释；注意 network/default.nix 里的
    #                 # 9090 端口放行是独立的，目前仍保留
    # YunShu 透明网关已移出 services/：改成 macvlan 接入后归到
    # modules/gateway/main-router.nix
  ];
}
