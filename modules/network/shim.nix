{ config, lib, ... }:

{
  # 宿主机网络：两个物理口做纯二层，三层归容器；宿主自己只留一个 macvlan shim。
  systemd.network = {
    netdevs."10-mv-shim" = {
      netdevConfig = {
        Kind = "macvlan";
        Name = "mv-shim";
      };
      # bridge 模式：同父口的 macvlan 兄弟之间可以直通。
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
