{ config, lib, ... }:

{
  # 启用 systemd-networkd
  systemd.network = {
    enable = true;

    # 创建网络桥接设备
    netdevs = {
      # WAN 桥接（连接到 Router VM 的 WAN 侧）
      "10-br-wan" = {
        netdevConfig = {
          Kind = "bridge";
          Name = "br-wan";
        };
        bridgeConfig = {
          STP = false;
        };
      };

      # LAN 桥接（连接到 Router VM 的 LAN 侧）
      "10-br-lan" = {
        netdevConfig = {
          Kind = "bridge";
          Name = "br-lan";
        };
        bridgeConfig = {
          STP = false;
        };
      };
    };

    # 网络配置
    networks = {
      # 物理网口 wan0（原 enp2s0）绑定到 br-wan
      "20-wan0-wan" = {
        matchConfig.Name = "wan0";
        networkConfig = {
          Bridge = "br-wan";
          # 宿主机不在 WAN 口配置 IP（由 Router VM 管理）
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = "no";
        };
      };

      # 物理网口 lan0（原 enp3s0）绑定到 br-lan
      "20-lan0-lan" = {
        matchConfig.Name = "lan0";
        networkConfig = {
          Bridge = "br-lan";
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = "no";
        };
      };

      # br-wan：正式运行不配 IP（WAN 完全归 router-vm 管理）。
      # 路由 VM 的 WAN 仍经此桥 DHCP（共享同一物理口）。
      "30-br-wan" = {
        matchConfig.Name = "br-wan";
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = "no";
        };
      };

      # br-lan：NAS 内网 IP + 默认网关走浮动网关 .254（yunshu 透明网关 VRRP MASTER，
      # 容器不可用时 router-vm BACKUP 兜底）。DNS 同样指向 .254，走 yunshu 的 DNS 分流。
      "30-br-lan" = {
        matchConfig.Name = "br-lan";
        networkConfig = {
          Address = "192.168.10.2/24";
          Gateway = "192.168.10.254";
          DNS = [ "192.168.10.254" ];
        };
      };
    };
  };
}
