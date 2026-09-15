{ config, lib, ... }:

{
  # WebDAV 文件服务（hacdias/webdav）：给 iOS「文件」App、Infuse、RaiDrive、
  # rclone 等 WebDAV 客户端提供 /srv/data/webdav 的读写入口。
  # 公网访问经路由 VM 的 cloudflared 隧道回源到 192.168.10.2:4918，
  # 隧道 ingress 在 Cloudflare Zero Trust 面板配置（见 README）。
  services.webdav = {
    enable = true;

    # 以 nas 运行，与 Samba/NFS 属主约定一致（客户端写入的文件归 nas:nas）；
    # 同时因 user != "webdav"，模块不会另建服务用户。
    user = "nas";
    group = "nas";

    # 认证密码走 sops：EnvironmentFile 内容为 WEBDAV_PASSWORD=<明文>，
    # 配置文件里只留 {env} 占位符，密码不进 nix store。
    environmentFile = config.sops.secrets.webdav-password.path;

    settings = {
      address = "192.168.10.2"; # 只绑 br-lan，不在 br-wan 上暴露
      port = 4918;              # RFC 4918 的 WebDAV 惯用端口
      directory = "/srv/data/webdav";
      permissions = "CRUD";     # 读写（C/R/U/D），级联给下面的用户
      behindProxy = true;       # 经 cloudflared 回源，按 X-Forwarded-For 记真实客户端 IP
      users = [
        {
          username = "nas";
          password = "{env}WEBDAV_PASSWORD";
        }
      ];
    };
  };

  # 共享目录（nas:nas，与 Samba 的 force user/group 约定一致）
  systemd.tmpfiles.rules = [
    "d /srv/data/webdav 0775 nas nas -"
  ];
}
