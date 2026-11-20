{ config, pkgs, ... }:

{
  # 系统级软件包
  environment.systemPackages = with pkgs; [
    # 编辑器
    vim
    nano

    # 系统工具
    btop
    iotop
    tmux
    fastfetch

    # 网络工具
    wget
    curl
    rsync
    nmap
    tcpdump
    iftop
    nethogs
    mtr

    # 文件系统工具
    parted
    gptfdisk
    e2fsprogs
    btrfs-progs

    # 监控工具
    lm_sensors
    smartmontools
    sysstat

    # 开发工具
    git
    tree
    file
    which
    pciutils
    usbutils

    # 压缩工具
    unzip
    p7zip
    gzip
    bzip2
  ];

  # flake 的 nixpkgs 源里没有 programs.sqlite，unstable 下开启会直接求值失败
  programs.command-not-found.enable = false;

  # Bash 配置
  programs.bash = {
    completion.enable = true;
    shellAliases = {
      ll = "ls -lhrt";      # 长格式 + 按修改时间倒序（最新的在最后）
      lla = "ls -lahrt";    # 同上，含隐藏文件
      la = "ls -A";
      l = "ls -CF";
      ".." = "cd ..";
      "..." = "cd ../..";
    };
  };
}
