{ config, pkgs, lib, ... }:

# ============================================================================
# Navidrome —— 当前启用的音乐服务端
# ============================================================================

{
  services.navidrome = {
    enable = true;
    settings = {
      MusicFolder = "/srv/data/music";
      DataFolder = "/var/lib/navidrome";
      Address = "192.168.10.2";
      Port = 4533;
      LogLevel = "info";
      ScanSchedule = "@every 1d";

      # 转码配置（可选）
      # TranscodingCacheSize = "100MB";
    };
  };

  # Navidrome 以 navidrome 用户运行，给予访问音乐目录的权限
  users.users.navidrome = {
    extraGroups = [ "nas" ];
  };
}
