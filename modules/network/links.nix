{ config, lib, ... }:

{
  # 物理网口按 MAC 锚定命名（NixOS 手册对"同型号多网卡"的推荐做法）。
  systemd.network.links = {
    "10-wan" = {
      matchConfig.MACAddress = "24:5e:be:88:1e:79"; # 原 enp2s0，接上游光猫
      linkConfig.Name = "wan";
    };
    "10-lan" = {
      matchConfig.MACAddress = "24:5e:be:88:1e:78"; # 原 enp3s0，接内网
      linkConfig.Name = "lan";
    };
  };
}
