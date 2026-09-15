{ config, lib, ... }:

{
  # 宿主机网络：两个物理口做纯二层，三层归容器；宿主自己只留一个 macvlan shim。
  #
  # "宿主机纯二层"的准确含义是**不做转发**，不是"没有三层"——它必须有地址、
  # 默认路由和 DNS，否则 nix flake update、sops 解密、NTP 对时全都做不了。
  #
  # 为什么 shim 用 macvlan 而不是给 lan0 直接配 IP：
  #   - lan0 要作为容器 macvlan 子接口的父接口，宿主自己占着它会引入
  #     "报文先上宿主三层栈、再从容器出去"的绕行
  #   - shim 与容器的 eth0 是同父口的 macvlan 兄弟，内核内部二层直通，
  #     不经过物理线缆
  #
  # ⚠️ 防火墙按**接口名**匹配：宿主地址从 br-lan 挪到 mv-shim 时，
  #    modules/network/default.nix 里那张端口表必须同时改。漏改不会报错，
  #    只会让 Samba/NFS/Syncthing 等全部被挡在门外。
  systemd.network = {
    netdevs."10-mv-shim" = {
      netdevConfig = {
        Kind = "macvlan";
        Name = "mv-shim";
      };
      # bridge 模式：同父口的 macvlan 兄弟之间可以直通。
      # private/vepa 会让宿主与容器互相看不见（VRRP 心跳、容器服务回连宿主都会断）。
      macvlanConfig.Mode = "bridge";
    };

    networks = {
      # lan0：只作为父接口，本身不配 IP，三层归 main-router / side-router 容器
      "20-lan0" = {
        matchConfig.Name = "lan0";
        networkConfig = {
          MACVLAN = "mv-shim"; # 声明子接口，由 networkd 创建
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = "no";
        };
      };

      # wan0：宿主机在 WAN 侧完全没有地址（WAN 是两个路由器容器的事）
      "20-wan0" = {
        matchConfig.Name = "wan0";
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = "no";
        };
      };

      # shim：宿主机的唯一三层入口/出口
      "30-mv-shim" = {
        matchConfig.Name = "mv-shim";
        networkConfig = {
          Address = "192.168.10.250/24";
          # 默认路由走浮动网关：与下游设备同一出口，随 VRRP 漂移。
          # 真要一个不受漂移影响的稳定出口，把它指向 side-router（.3）。
          Gateway = "192.168.10.1";
          DNS = [ "192.168.10.1" ];
          LinkLocalAddressing = "no";
          IPv6AcceptRA = "no";
        };
      };
    };
  };
}
