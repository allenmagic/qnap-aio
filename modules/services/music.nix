{ config, pkgs, lib, ... }:

let
  # 尽量削减 gonic 的依赖体积。两个方向：
  #   transcodingSupport = false → 去掉 gonic 对 ffmpeg 的直接依赖
  #   mpv 传瘦身版            → 去掉 mpv 的 GUI 链（wayland/x11/gtk）与 yt-dlp
  #
  # 转码交给客户端解码（库是 35GB 无损 WAV/FLAC，播放端处理即可）；
  # jukebox 是「服务端出声」模式（NAS 接功放、手机当遥控器），本场景在客户端
  # 听歌，用不到——所以 mpv 永远不会被执行，只需让它别把 GUI 栈带进来。
  #
  # 26.05 的 gonic 0.21.0 没有 jukeboxSupport 构建开关：包内会**无条件**把
  # jukebox/jukebox.go 里的 "mpv" 替换成绝对路径，于是真实 mpv 连同
  # gtk+3 / gtk4 / wayland / x11 / ffmpeg 整条链都会进闭包。
  #
  # 但 gonic 源码本身是 exec.LookPath("mpv")（从 PATH 找），且在 Start() 里
  # 只用 --idle --no-config --no-video --audio-display=no —— 即运行时是纯音频、
  # 那些 GUI 库根本不会被加载。加上本文件已设 jukebox-enabled = false，
  # mpv 永远不会被调用。
  #
  # 所以这里传一个占位实现，把这整条链从闭包中移除。
  # ⚠️ 将来若要启用 jukebox（settings 里 jukebox-enabled = true），
  #    必须把这里换回真实 mpv，例如：
  #      pkgs.mpv.override {
  #        youtubeSupport = false;
  #        mpv-unwrapped = pkgs.mpv-unwrapped.override {
  #          waylandSupport = false; x11Support = false; cacaSupport = false;
  #        };
  #      }
  stubMpv = pkgs.writeShellScriptBin "mpv" ''
    echo "gonic: jukebox 未启用（见 qnap-nixos-nas 的 modules/services/music.nix），mpv 未安装" >&2
    exit 1
  '';

  gonicSlim = pkgs.gonic.override {
    transcodingSupport = false;   # 去掉 ffmpeg（转码交给客户端解码）
    mpv = stubMpv;
  };
in
{
  # ===== Gonic 音乐服务端 =====
  # 本文件**刻意不在 services/default.nix 里 import**，仅作保留。
  # 2026-09-14：gonic 功能支持不足，回退到 Navidrome（./music-navidrome.nix）。
  #
  # 恢复方法：把 default.nix 里的 ./music-navidrome.nix 换成 ./music.nix。
  # ⚠️ 两者的数据库互不兼容（gonic 的 /var/lib/gonic 与 Navidrome 的
  #    /var/lib/navidrome），切换后会重新扫描；播放列表/收藏无法迁移。
  # 配置项对照：https://github.com/sentriz/gonic#configuration-options
  services.gonic = {
    enable = true;
    package = gonicSlim;

    settings = {
      # 音乐库路径。该键可重复声明多个目录，也支持 "别名->路径" 语法让客户端
      # 显示友好名称。目录结构要求见 gonic README（同一专辑的文件需在同一目录）；
      # 本库是扁平的 <艺术家>/<文件>，但文件带有完整 ID3 标签（artist/album/
      # album_artist/track/disc），按标签浏览不受影响，只是「按目录浏览」会
      # 显示 13 个艺术家大目录。
      music-path = [ "/srv/data/music" ];

      # 运行时状态。三个目录都在 /var/lib/gonic 下：模块用 systemd 的
      # StateDirectory 机制创建并授予服务用户属主；playlists/podcasts 还会被
      # BindPaths 进沙箱，所以必须先存在（见下方 tmpfiles 规则）。
      db-path = "/var/lib/gonic/gonic.db";
      playlists-path = "/var/lib/gonic/playlists";
      podcast-path = "/var/lib/gonic/podcasts";
      cache-path = "/var/cache/gonic";

      # 沿用 Navidrome 的地址与端口，客户端与防火墙均无需改动
      listen-addr = "192.168.10.250:4533";

      # 扫描：等价于原 Navidrome 的 ScanSchedule = "@every 1h"
      # （注意 gonic 的 scan-interval 单位是分钟，不是 "@every" 时长字符串）
      scan-interval = 60;
      scan-at-start-enabled = true;
      # 已有定时扫描，不再额外挂 inotify 监视
      scan-watcher-enabled = false;

      # 关闭 jukebox API（服务端出声模式，本场景在客户端听歌用不到）。
      # 注意：这只关掉 API，并不能把 mpv 移出闭包——nixpkgs 的包是无条件把
      # mpv 路径替换进 jukebox/jukebox.go 的（0.21.0 没有 jukeboxSupport
      # 构建开关）。mpv 的体积问题由上面的 slimMpv 处理。
      jukebox-enabled = false;
    };
  };

  # gonic 由模块以 DynamicUser 运行（模块未设 User=，但设了 StateDirectory），
  # 因此不能像 Navidrome 那样用 extraGroups = [ "nas" ] 授权；音乐文件是
  # 644、目录 755，动态用户可直接读取，无需额外授权。
  #
  # 这两个目录被模块 BindPaths 进沙箱，必须先于服务存在，否则挂载命名空间
  # 建立失败。属主会在服务启动时由 StateDirectory 机制调整为服务用户。
  systemd.tmpfiles.rules = [
    "d /var/lib/gonic/podcasts 0755 root root -"
    "d /var/lib/gonic/playlists 0755 root root -"
  ];
}
