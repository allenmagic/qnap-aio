{ config, lib, pkgs, ... }:

{
  # root 密码（hash）由 sops-nix 的 root-password-hash secret 提供
  # （secrets/secrets.yaml，值 = mkpasswd -m sha-512 / openssl passwd -6 生成的
  #  $6$... hash）。用途：串口/本地登录兜底——SSH 默认密钥登录，
  # 密码登录仅内网与 Tailscale 网段（modules/security/ssh.nix 的 Match）。
  #
  # ⚠️ 部署顺序（真机有 age 私钥时执行）：
  #   1. sops -k /var/lib/sops-nix/key.txt set secrets/secrets.yaml root-password-hash '<$6$hash>'
  #   2. nixos-rebuild switch
  # 若跳过第 1 步直接部署，/run/secrets/root-password-hash 不存在，
  # activation 会因 hashedPasswordFile 指向缺失文件而失败。
  users.users.root.hashedPasswordFile =
    config.sops.secrets.root-password-hash.path;

  # "nas" 组：多服务以其为属主组（syncthing Group、samba force-group、music 用户），
  # 必须显式声明并设为 nas 主组，否则服务启动报 216/GROUP（无此组）。
  users.groups.nas = { };

  # 定义 NAS 服务用户
  users.users.nas = {
    isNormalUser = true;
    group = "nas";           # 主组 = nas（服务按 nas:nas 属主运行）
    description = "NAS service user";
    home = "/home/nas";

    # 用户组
    extraGroups = [
      "wheel"      # sudo 权限
      "storage"    # 存储访问
      "aria2"      # services/aria2.nix 用独立 aria2 用户跑，加组才能读写它的下载目录
      "gitea"      # 只读浏览 /srv/data/application/gitea（0750 gitea:gitea，组内可进可读不可写）
    ];

    # SSH 公钥（替换为你的实际公钥）
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDxOVLqS8pbklbsF+dM+frmUC4nFD9czNqkx5XsuEVE9 allenmagic@163.com"
    ];

    # 系统密码（hash）用途：Cockpit Web 登录（PAM）、sudo、SSH 密码登录
    # （密码仅内网与 Tailscale 网段放行，见 modules/security/ssh.nix 的 Match；
    #   其他来源只认密钥）。
    #
    # 密码 hash 不再进本仓库：由 sops-nix 的 nas-password secret 提供
    # （secrets/secrets.yaml，值 = mkpasswd -m sha-512 / openssl passwd -6 生成的
    #  $6$... hash）。sops.nix 里 nas-password 已设 neededForUsers=true，保证用户
    # 激活前解密。改密码：编辑 sops secret 即可，hash 不进 git。
    hashedPasswordFile = config.sops.secrets.nas-password.path;
  };

  # 创建 storage 组
  users.groups.storage = {};

  # 创建服务目录并设置权限
  # 路径约定：性能敏感/可重建的应用状态放 /srv/cache（SSD），
  # 不可再生数据放 /srv/data（Btrfs RAID1），无独立的 /srv/app 目录
  systemd.tmpfiles.rules = [
    # /srv/data 必须归 root：tmpfiles 的安全检查只允许 root→任意属主，
    # 父目录是 nas 时 application/（root）、gitea/（gitea）等子树会被判
    # unsafe 并 exit 73，整批规则静默失效。用户数据子目录仍归 nas。
    "d /srv/data 0755 root storage -"
    "d /srv/backup 0755 nas storage -"
    "d /srv/cache 0755 nas storage -"

    # /srv/data 下的默认数据分类目录（Samba/NFS 共享 data 时自动可见）
    "d /srv/data/music 0755 nas nas -"
    "d /srv/data/videos 0755 nas nas -"
    "d /srv/data/photos 0755 nas nas -"
    "d /srv/data/documents 0755 nas nas -"
    "d /srv/data/downloads 0755 nas nas -"
    "d /srv/data/projects 0755 nas nas -"
    "d /srv/data/templates 0755 nas nas -"
    "d /srv/data/models 0755 nas nas -"
  ];

  # 挂载后补一次 chown：tmpfiles 与挂载的时序不保证（实测全量 --create 时
  # cache/backup 没被处理），共享根不可写会让 Samba(force user=nas) 写不进去。
  # /srv/data 保持 root，理由见上面的 tmpfiles 规则。
  #
  # partOf：挂载单元被重挂/重启时跟着重跑。只有 after/requires 的话服务一生只跑
  # 一次，挂载后来变了它不会补。脚本里的 mountpoint 断言是配套的兜底——未挂载时
  # chown 会打在**被挂载遮蔽的底层目录**上，看起来成功、挂载一上来就失效。
  systemd.services.srv-mount-owner = {
    description = "修正 /srv 挂载点属主";
    wantedBy = [ "multi-user.target" ];
    after = [ "srv-data.mount" "srv-cache.mount" "srv-backup.mount" ];
    requires = [ "srv-data.mount" "srv-cache.mount" "srv-backup.mount" ];
    partOf = [ "srv-data.mount" "srv-cache.mount" "srv-backup.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for d in /srv/data /srv/cache /srv/backup; do
        ${pkgs.util-linux}/bin/mountpoint -q "$d" || {
          echo "$d 未挂载，拒绝 chown（会打在遮蔽的底层目录上）" >&2
          exit 1
        }
      done
      ${pkgs.coreutils}/bin/chown root:storage /srv/data
      ${pkgs.coreutils}/bin/chown nas:storage /srv/cache /srv/backup
      ${pkgs.coreutils}/bin/chmod 0755 /srv/data /srv/cache /srv/backup
    '';
  };

  # sudo 配置（允许 wheel 组成员无密码执行 sudo）
  security.sudo = {
    enable = true;
    wheelNeedsPassword = true;  # 改为 false 可以无密码 sudo
  };
}
