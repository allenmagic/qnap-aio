{ config, lib, ... }:

let
  # 对外共享的用户数据目录（/srv/data 下）。**逐个列出、逐个导出**，而不是整个
  # /srv/data：应用内部（application/ 下的 gitea/syncthing、state 子卷）不在此列，
  # 因此不出网。这不是洁癖——Samba 的 data 共享是 force user=nas，凡是 nas 能读的，
  # 任何能登录该共享的局域网设备都能读（gitea 的 app.ini/secret_key 是组可读）。
  sharedDirs = [
    "documents"
    "downloads"
    "models"
    "music"
    "photos"
    "projects"
    "templates"
    "videos"
    "webdav"
  ];
in
{
  # NFS 服务器配置
  services.nfs.server = {
    enable = true;

    # 固定端口（配合 network/default.nix 防火墙放行）
    # NFSv4 只需 2049；保留 mountd/statd/lockd 端口以便 NFSv3 客户端也能挂载子导出。
    mountdPort = 20048;
    lockdPort = 4001;
    statdPort = 4000;

    # 导出：NFSv4 伪文件系统根（fsid=0）+ 子导出。
    # NFSv4 只有一个根，客户端挂 server:/ 即可看到 data/cache/backup；
    # 子目录是 bind mount 点（见下方 fileSystems），**必须逐个显式导出**——
    # NFS 不穿过挂载点，只导出父目录的话子目录在客户端看来是空的。
    # root_squash：客户端 root 映射为 nobody，避免局域网内任何设备以 root 身份读写。
    # 客户端以普通用户（uid 与 nas 一致，通常 1000）挂载即可正常读写。
    # backup 例外：导出为 ro——该盘只作备份盘，仅本机备份服务写入。
    exports = ''
      # NFSv4 根
      /srv/nfs        192.168.10.0/24(rw,sync,no_subtree_check,root_squash,fsid=0)

      # 整盘共享
      /srv/nfs/cache  192.168.10.0/24(rw,sync,no_subtree_check,root_squash)
      /srv/nfs/backup 192.168.10.0/24(ro,sync,no_subtree_check,root_squash)

      # data：逐个用户目录（清单见文件头 sharedDirs）
${lib.concatMapStringsSep "\n" (d:
  "      /srv/nfs/data/${d}  192.168.10.0/24(rw,sync,no_subtree_check,root_squash)"
) sharedDirs}
    '';

    nproc = 8;
  };

  # NFS 对外视图：bind mount 把各共享拼到统一根 /srv/nfs 下。
  # NFSv4 只有一个伪文件系统根，而各共享彼此平级、无法直接组成一个根，
  # 必须 bind 到同一根目录下。depends 保证源挂载点先挂好再 bind。
  #
  # ⚠️ /srv/nfs/data 本身**不是**挂载点，只是个普通目录，里面挂 9 个 bind。
  # 改这里时注意：若它曾作为 bind 挂载点存在过，必须先 umount 再切换，
  # 否则旧 bind 会遮蔽新目录、application/ 会重新露出来。
  fileSystems =
    {
      # bind mount 必须显式 fsType = "none"，否则求值报 "fsType has no value defined"
      "/srv/nfs/cache" = {
        device = "/srv/cache";
        fsType = "none";
        options = [ "bind" ];
        depends = [ "/srv/cache" ];
      };
      "/srv/nfs/backup" = {
        device = "/srv/backup";
        fsType = "none";
        options = [ "bind" ];
        depends = [ "/srv/backup" ];
      };
    }
    // lib.listToAttrs (map (d: lib.nameValuePair "/srv/nfs/data/${d}" {
      device = "/srv/data/${d}";
      fsType = "none";
      options = [ "bind" ];
      depends = [ "/srv/data" ];
    }) sharedDirs);

  # 建 NFS 根目录及各挂载点目录（bind 后权限由源目录元数据覆盖）
  systemd.tmpfiles.rules = [
    "d /srv/nfs 0755 root root -"
    "d /srv/nfs/data 0755 root root -"
    "d /srv/nfs/cache 0755 root root -"
    "d /srv/nfs/backup 0755 root root -"
  ] ++ map (d: "d /srv/nfs/data/${d} 0755 root root -") sharedDirs;
}
