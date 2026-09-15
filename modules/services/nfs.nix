{ config, lib, ... }:

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
    # NFSv4 只有一个根，客户端挂 server:/ 即可看到 data/cache/backup 三个子共享；
    # 三个子目录是 bind mount 点（见下方 fileSystems），必须显式导出才能被伪文件系统呈现。
    # root_squash：客户端 root 映射为 nobody，避免局域网内任何设备以 root 身份读写。
    # 客户端以普通用户（uid 与 nas 一致，通常 1000）挂载即可正常读写。
    # backup 例外：导出为 ro——该盘只作备份盘，仅本机备份服务写入。
    exports = ''
      # NFSv4 根
      /srv/nfs        192.168.10.0/24(rw,sync,no_subtree_check,root_squash,fsid=0)

      # 子共享
      /srv/nfs/data   192.168.10.0/24(rw,sync,no_subtree_check,root_squash)
      /srv/nfs/cache  192.168.10.0/24(rw,sync,no_subtree_check,root_squash)
      /srv/nfs/backup 192.168.10.0/24(ro,sync,no_subtree_check,root_squash)
    '';

    nproc = 8;
  };

  # NFS 对外视图：bind mount 把 data/cache/backup 拼到统一根 /srv/nfs 下。
  # NFSv4 只有一个伪文件系统根，而 data/cache/backup 彼此平级、无法直接组成一个根，
  # 必须 bind 到同一根目录下。depends 保证源挂载点先挂好再 bind。
  fileSystems = {
    # bind mount 必须显式 fsType = "none"，否则求值报 "fsType has no value defined"
    "/srv/nfs/data" = {
      device = "/srv/data";
      fsType = "none";
      options = [ "bind" ];
      depends = [ "/srv/data" ];
    };
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
  };

  # 建 NFS 根目录及挂载点目录（bind 后权限由源目录元数据覆盖）
  systemd.tmpfiles.rules = [
    "d /srv/nfs 0755 root root -"
    "d /srv/nfs/data 0755 root root -"
    "d /srv/nfs/cache 0755 root root -"
    "d /srv/nfs/backup 0755 root root -"
  ];
}
