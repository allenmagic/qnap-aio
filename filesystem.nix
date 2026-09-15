{ config, lib, ... }:

{
  # 数据盘使用 Btrfs 原生 RAID1（不用 mdadm）：数据带 checksum，
  # 定期 scrub 可检测并自动修复静默损坏；多设备由内核自动组装，无需 ARRAY 配置。
  #
  # 注意：device/fsType 用 lib.mkForce —— nixos-generate-config 生成的
  # hardware-configuration.nix 会以 by-uuid 声明 / 与 /boot 等挂载点，
  # 与本仓库的 by-label 定义冲突（error: conflicting definition values）。
  # 本仓库以 label 为唯一约定（INSTALL.md 创建磁盘时按此打标），故强制覆盖。

  # 文件系统挂载点
  fileSystems = {
    # 系统盘（256GB SSD）
    "/" = {
      device = lib.mkForce "/dev/disk/by-label/nixos";
      fsType = lib.mkForce "ext4";
    };

    "/boot" = {
      device = lib.mkForce "/dev/disk/by-label/boot";
      fsType = lib.mkForce "vfat";
    };

    # 数据盘（2×3TB HDD，Btrfs 原生 RAID1）
    # device 指向任一成员的卷标即可，内核自动发现并组装全部成员
    "/srv/data" = {
      device = lib.mkForce "/dev/disk/by-label/data";
      fsType = lib.mkForce "btrfs";
      options = [ "defaults" "noatime" ];
    };

    # 缓存盘（1TB SSD）
    "/srv/cache" = {
      device = lib.mkForce "/dev/disk/by-label/cache";
      fsType = lib.mkForce "ext4";
      options = [ "defaults" "noatime" ];
    };

    # 备份盘（2TB HDD）
    "/srv/backup" = {
      device = lib.mkForce "/dev/disk/by-label/backup";
      fsType = lib.mkForce "ext4";
      options = [ "defaults" "noatime" ];
    };
  };

  # 启用定期 SSD Trim
  services.fstrim = {
    enable = true;
    interval = "weekly";
  };

  # Btrfs 数据卷：每月自动 scrub（校验数据完整性，自动修复 RAID1 损坏副本）
  services.btrfs.autoScrub = {
    enable = true;
    fileSystems = [ "/srv/data" ];
    interval = "monthly";
  };

  # Swap 配置（可选，8GB 内存可能不需要）
  swapDevices = [ ];
  # swapDevices = [{
  #   device = "/var/swapfile";
  #   size = 4096;  # 4GB
  # }];
}
