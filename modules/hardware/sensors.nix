{ config, pkgs, ... }:

let
  # 遍历所有块设备做 SMART 健康检查（不硬编码 /dev/sda，避免设备名漂移或漏检 RAID 成员盘）
  smart-health-check = pkgs.writeShellScriptBin "smart-health-check" ''
    for _d_ in $(${pkgs.util-linux}/bin/lsblk -dn -o PATH); do
      ${pkgs.smartmontools}/bin/smartctl --all --json "$_d_" || true
    done
  '';
in
{
  # SMART 磁盘监控
  services.smartd = {
    enable = true;
    autodetect = true;

    # 监控配置
    defaults.monitored = "-a -o on -s (S/../.././02|L/../../7/04)";

    # 邮件通知（可选，需要配置 MTA）
    notifications = {
      mail = {
        enable = false;  # 默认禁用，需要时启用并配置邮箱
        sender = "smartd@ts564.local";
        recipient = "admin@example.com";
      };
      # 使用 wall 通知到所有登录用户
      wall.enable = true;
    };
  };

  # 定期检查磁盘健康（遍历全部块设备）
  systemd.services.smart-health-check = {
    description = "Check disk SMART health";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${smart-health-check}/bin/smart-health-check";
    };
  };

  systemd.timers.smart-health-check = {
    description = "Daily SMART health check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
