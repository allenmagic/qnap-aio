{ config, lib, ... }:

{
  # 物理网口按 MAC 锚定命名（NixOS 手册对"同型号多网卡"的推荐做法）。
  #
  # 为什么不沿用系统的 enpXsY：那是"可预测命名"，但只对 **PCI 位置**稳定——
  # 换槽位、改固件设置、换内核都可能变。更不能用 eth0/eth1：那由内核发现
  # 顺序决定，两台同型号网卡互换是常有的事，而这里 enp2s0/enp3s0 分别挂着
  # WAN 和 LAN，互换的后果是内外网直接对调。
  #
  # ⚠️ 改名是破坏性的：生效后旧名字（enp2s0/enp3s0）从系统里消失。
  #    所有引用旧名的地方必须一次改完（bridges.nix、macvlan 映射、防火墙
  #    接口名），且**必须重启**才生效——.link 由 udev 在设备出现时处理，
  #    nixos-rebuild switch 不会重命名一个正在使用的接口。
  #
  # 用 MACAddress 而非手册示例里的 PermanentMACAddress：这对 igc 网卡在
  # 当前内核上不暴露 /sys/class/net/*/perm_address，PermanentMACAddress 匹配不到。
  systemd.network.links = {
    "10-wan0" = {
      matchConfig.MACAddress = "24:5e:be:88:1e:79"; # 原 enp2s0，接上游光猫
      linkConfig.Name = "wan0";
    };
    "10-lan0" = {
      matchConfig.MACAddress = "24:5e:be:88:1e:78"; # 原 enp3s0，接内网
      linkConfig.Name = "lan0";
    };
  };
}
