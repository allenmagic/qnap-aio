{ config, lib, ... }:

let
  # iOS 18+/macOS 客户端的 Apple 扩展兼容层。
  # 缺这层时 iOS「文件」App 会把共享判定为只读（服务端权限/协议都正常，
  # Windows 客户端也只读不了），是客户端 bug。
  # fruit = AAPL 扩展 + AppleDouble，streams_xattr = 把元数据流落到 xattr。
  appleCompat = {
    "vfs objects" = "fruit streams_xattr";
    "fruit:metadata" = "stream";   # 元数据进 xattr，不在共享里生成 ._ 文件
    "fruit:resource" = "stream";
    "fruit:nfs_aces" = "no";
  };
in
{
  # Samba 文件共享服务
  services.samba = {
    enable = true;

    # 配置采用 smb.conf 的 INI 段格式：
    # settings.<段名>.<键> = <值>，每个共享目录对应一个段
    settings = {
      # 全局配置（对应 [global] 段）
      global = {
        # 安全模式（user = 每连接用户名+密码认证）
        # 注意：Samba 用独立的密码库（tdbsam），与系统 shadow 无关。
        # nas 用户需手动设置 Samba 密码（sudo smbpasswd -a nas）；
        # hashedPassword 只影响 PAM 登录（SSH/Cockpit），Nix 无法声明式配置 Samba 密码。
        "security" = "user";

        # 全局设置
        "workgroup" = "WORKGROUP";
        "server string" = "QNAP TS-564 NAS";
        "netbios name" = "TS564";

        # 安全设置
        "server min protocol" = "SMB3";
        "smb encrypt" = "desired";

        # 空闲连接超时（分钟）
        "dead time" = 15;

        # 访问控制
        "hosts allow" = "192.168.10.0/24 127.0.0.1";
        "hosts deny" = "0.0.0.0/0";

        # 日志
        "log level" = 1;
        "max log size" = 1000;

        # 其他
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";
        "disable spoolss" = "yes";
      };

      # 数据共享（主要存储）
      data = {
        "path" = "/srv/data";
        "browseable" = "yes";
        "read only" = "no";
        "valid users" = "nas";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "nas";
        "force group" = "nas";
        "comment" = "Main data storage";
      } // appleCompat;

      # 缓存共享（临时/高速存储）
      cache = {
        "path" = "/srv/cache";
        "browseable" = "yes";
        "read only" = "no";
        "valid users" = "nas";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "nas";
        "force group" = "nas";
        "comment" = "Cache storage (SSD)";
      } // appleCompat;

      # 备份共享（只读）：该盘仅供备份服务写入，内网挂载只看不改，
      # 避免误删或被勒索软件连带加密。备份本身的属主是 nas:nas，
      # 所以这里必须显式限制，不能靠文件权限兜底。
      backup = {
        "path" = "/srv/backup";
        "browseable" = "yes";
        "read only" = "yes";
        "valid users" = "nas";
        "create mask" = "0664";
        "directory mask" = "0775";
        "force user" = "nas";
        "force group" = "nas";
        "comment" = "Backup storage";
      } // appleCompat;
    };

    # 启用 WINS 支持（可选）
    winbindd.enable = false;
  };

  # 在防火墙中开放 Samba 端口（已在 network/default.nix 中配置）
  # networking.firewall.allowedTCPPorts = [ 139 445 ];
  # networking.firewall.allowedUDPPorts = [ 137 138 ];
}
