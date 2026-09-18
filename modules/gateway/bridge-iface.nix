{ config, lib, pkgs, ... }:

let
  # 桥接容器的接口整备。main-router 那份在 router-container 里，这两个不用它，
  # 所以在这里单独补。
  #
  # ⚠️ 必须按接口类型找出来改名，不能写死名字：nspawn 在容器侧建的 veth 叫
  #    什么随 systemd 版本变——man 页写的是 host0，systemd 260 实测给的是
  #    eth0。写死任何一个，换了版本就静默失配：地址配不上、MAC 改不了、
  #    dnsmasq 报 "interface ... does not currently exist"，症状和"没配"一样。
  #
  # 🚫 也别改回容器内 udev 的 `.link`：这类接口是 nspawn 在宿主 netns 建好再
  #    移进来的，容器内 udev 收不到设备添加事件，`.link` 静默无效。
  mkPrepare = { iface, mac }: { pkgs, ... }: {
    systemd.services.prepare-lan-iface = {
      description = "把 nspawn 的 veth 改成预期名字并固定 MAC";
      before = [ "network-pre.target" ];
      wantedBy = [ "network-pre.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        ip=${pkgs.iproute2}/bin/ip
        for i in $(${pkgs.coreutils}/bin/ls /sys/class/net); do
          [ "$i" = "lo" ] && continue
          [ "$i" = "${iface}" ] && continue
          if "$ip" -d link show "$i" 2>/dev/null | grep -qw veth; then
            "$ip" link set "$i" down
            "$ip" link set "$i" name "${iface}"
            "$ip" link set "${iface}" up
          fi
        done
        "$ip" link set ${iface} address ${mac}
      '';
    };
  };
in
{
  containers.tailscale.config = mkPrepare {
    iface = "host0";
    mac = "02:00:00:02:00:41";
  };

  containers.cloudflared.config = mkPrepare {
    iface = "host0";
    mac = "02:00:00:02:00:51";
  };
}
