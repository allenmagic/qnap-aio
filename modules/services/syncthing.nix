{ config, lib, ... }:

{
  # Syncthing 文件同步服务
  services.syncthing = {
    enable = true;
    user = "nas";
    group = "nas";
    dataDir = "/srv/data/syncthing";
    configDir = "/srv/data/syncthing/.config";

    # 开放默认端口
    openDefaultPorts = true;

    # Web UI 配置
    guiAddress = "192.168.10.2:8384";

    # GUI 密码来自 sops（syncthing-password，明文，syncthing 启动时自己哈希）。
    # 配合 settings.gui.user 完成认证，避免 8384 对内网裸奔。
    guiPasswordFile = config.sops.secrets.syncthing-password.path;

    # 配置
    settings = {
      gui = {
        user = "nas";
        # 密码已由 services.syncthing.guiPasswordFile（sops syncthing-password）提供，
        # 不再用明文 password = "..."（那会写进 nix store）。
      };

      options = {
        urAccepted = -1;  # 禁用使用统计报告
        globalAnnounceEnabled = true;
        localAnnounceEnabled = true;
        relaysEnabled = true;
      };

      # 设备和文件夹配置需要在 Web UI 中添加
      # 或通过 settings.devices 和 settings.folders 声明式配置
    };
  };

  # 确保数据目录存在且权限正确
  systemd.tmpfiles.rules = [
    "d /srv/data/syncthing 0755 nas nas -"
  ];
}
