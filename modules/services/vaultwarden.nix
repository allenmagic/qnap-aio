{ config, lib, ... }:

let
  dataDir = "/srv/data/application/vaultwarden";
  backupDir = "/srv/data/application/vaultwarden-backup";
in
{
  # Vaultwarden：Bitwarden 兼容密码库。经 cloudflared 隧道以
  # https://vault.allenmagic.cn 对外——Bitwarden 客户端强制要求有效 HTTPS。
  services.vaultwarden = {
    enable = true;
    # 这里只写主机名，模块会自己拼 https://
    domain = "vault.allenmagic.cn";
    dbBackend = "sqlite";
    backupDir = backupDir;

    config = {
      ROCKET_ADDRESS = "192.168.10.2";
      ROCKET_PORT = 8222;
      # 不开放注册；首个账号用 admin 面板邀请
      SIGNUPS_ALLOWED = false;
      INVITATIONS_ALLOWED = true;
      SHOW_PASSWORD_HINT = false;
      WEBSOCKET_ENABLED = true;
      # Cloudflare 免费版请求体上限 100 MiB，留余量
      ATTACHMENT_SIZE_LIMIT = 52428800;
    };

    environmentFile = [ config.sops.secrets.vaultwarden-admin-token.path ];
  };

  # 模块把数据写死在 /var/lib/vaultwarden；bind 到 /srv/data 才能进 RAID1 与备份
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0750 vaultwarden vaultwarden -"
    # 首次启动时备份单元先于 vaultwarden 运行，数据目录为空会让 backup.sh
    # 的 cp 通配失败；放一个占位文件保证备份脚本始终有内容可复制
    "f ${dataDir}/.keep 0600 vaultwarden vaultwarden -"
  ];
  systemd.services.vaultwarden.serviceConfig = {
    BindPaths = [ "${dataDir}:/var/lib/vaultwarden" ];
    # BindPaths 与 PrivateUsers 的 UID 映射冲突
    PrivateUsers = lib.mkForce false;
  };
  # 备份单元是独立进程，同样要挂这个目录，否则备份的是空的 StateDirectory
  systemd.services.backup-vaultwarden.serviceConfig.BindPaths = [
    "${dataDir}:/var/lib/vaultwarden"
  ];
}
