{ config, lib, ... }:

# ============================================================
# Beszel 服务器监控（hub + agent，仅监控本机）
#
# ============================================================
let
  agentEnable = true;
in
{
  services.beszel = {
    hub = {
      enable = true;
      host = "0.0.0.0";    # 默认 127.0.0.1；对外访问需全接口
      port = 8090;         # 端口
    };

    # ---- agent：本机采集（KEY 由 hub UI 生成后经 sops 注入） ----
    agent = {
      enable = agentEnable;
      environmentFile = lib.mkIf agentEnable config.sops.secrets.beszel-agent-key.path;
      smartmon.enable = true;
      environment.SMART_DEVICES = "/dev/sda:sat,/dev/sdb:sat,/dev/sdc:sat,/dev/sdd:sat,/dev/sde:sat";
      environment.EXCLUDE_SMART = "/dev/mmcblk0";
    };
  };
}
