{ config, pkgs, lib, ... }:

# ============================================================================
# Navidrome —— 当前启用的音乐服务端（2026-09-14 从 gonic 回退）。
# 回退原因：gonic 功能支持不足（客户端/API 兼容性、元数据与播放列表等）。
# 代价：常驻内存高于 gonic（曾测 900MB+ / 峰值 1.1GB）。
#
# 切回 gonic：把 default.nix 里的 ./music-navidrome.nix 换成 ./music.nix
# （feishin.nix 保持不动，两种服务端都用同一个前端）。
#
# ⚠️ 注意：Navidrome 的 /var/lib/navidrome 数据与 gonic 的数据库不兼容，
# 切换后会重新扫描；反之亦然。播放列表/收藏/播放次数在两者之间无法迁移。
# 切换后 4533 端口仍由同一个服务持有，客户端只需改服务器类型
# （navidrome ↔ subsonic）。
# ============================================================================

{
  # ===== Navidrome 音乐服务端 =====
  services.navidrome = {
    enable = true;

    settings = {
      # 音乐库路径
      MusicFolder = "/srv/data/music";

      # 数据存储路径
      DataFolder = "/var/lib/navidrome";

      # 网络配置
      Address = "192.168.10.2";
      Port = 4533;

      # 日志级别
      LogLevel = "info";

      # 扫描配置
      ScanSchedule = "@every 1h";

      # 转码配置（可选）
      # TranscodingCacheSize = "100MB";
    };
  };

  # Navidrome 以 navidrome 用户运行，给予访问音乐目录的权限
  # （music 目录由 users/nas-user.nix 的 tmpfiles 统一创建）
  users.users.navidrome = {
    extraGroups = [ "nas" ];
  };
}
