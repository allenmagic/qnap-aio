{ config, lib, ... }:

# ============================================================
# Beszel 服务器监控（hub + agent，仅监控本机）
#
# 架构：hub（Web 面板，PocketBase 底座）跑在 qnap；agent 采集本机
# 指标（CPU/内存/磁盘/温度 + systemd 服务状态）并经回环供 hub 拉取。
# 数据落 /var/lib/beszel-hub（sqlite 历史，systemd 自动管理属主），
# 镜像升级不影响。
#
# ── 状态：已启用（hub + agent）─────────────────────────────────
#
# 配对流程（已走完，供重建/迁移时参考）：agent 的 KEY 是 **hub 生成的
# SSH 公钥**，必须先有 hub 才能拿到，所以分两步：
#   1. 先只跑 hub（agentEnable=false）→ 浏览器打开
#      http://192.168.10.2:8090 → 建管理员 → Add System → 复制公钥
#   2. 写入 sops（EnvironmentFile 格式，一行）：
#        sops set secrets/secrets.yaml '["beszel-agent-key"]' \
#          '"KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI..."'
#      再在 modules/security/sops.nix 定义同名 secret，最后把
#      agentEnable 改为 true
#
# ⚠️ KEY 不是随机串，是 SSH 公钥（"Public SSH key(s) to use for
#    authentication. Provided in hub."）——见
#    https://www.beszel.dev/guide/environment-variables
#    敏感的是 WebSocket 模式的 TOKEN（hub /settings/tokens），两者别混淆。
# ============================================================
let
  # 方案 A 第 1 步：先只跑 hub；拿到公钥并写入 sops 后改为 true
  agentEnable = true;
in
{
  services.beszel = {
    # ---- hub：Web 面板（8090，br-lan 放行见 network/default.nix） ----
    hub = {
      enable = true;
      host = "0.0.0.0";    # 默认 127.0.0.1；对外访问需全接口
      port = 8090;         # 未与现有服务冲突（见 network/default.nix 端口清单）
      # dataDir 默认 /var/lib/beszel-hub，模块自动 StateDirectory 创建
    };

    # ---- agent：本机采集（KEY 由 hub UI 生成后经 sops 注入） ----
    agent = {
      enable = agentEnable;
      # 密钥不进 nix store（agent.environment 会明文落 store），故用
      # environmentFile 走 /run/secrets；默认端口 45876 仅回环访问，
      # 无需 openFirewall。
      # mkIf 保证 agent 关闭时不去引用尚未定义的 sops secret，
      # 否则求值会报 attribute 'beszel-agent-key' missing。
      environmentFile = lib.mkIf agentEnable config.sops.secrets.beszel-agent-key.path;

      # 磁盘 SMART 监控（默认 false，不开就看不到磁盘健康）。开启后模块会：
      #   - 把 smartmontools 加进 agent 的 PATH
      #   - 把 agent 加入 disk 组，并授予 CAP_SYS_RAWIO / CAP_SYS_ADMIN
      #   - 代价：NoNewPrivileges / PrivateDevices 被关闭（沙箱放宽，属必要）
      smartmon.enable = true;

      # 显式指定 SMART 设备，绕过 agent 的自动探测。
      # 原因：本机 `smartctl --scan` 把 SATA 盘报成 `-d scsi` 而非 `-d sat`，
      # beszel 的自动探测因此认不出它们——面板上只剩 mmcblk（eMMC 的磨损
      # 数据走独立路径，不依赖 smartctl 探测）。见 henrygd/beszel#1345。
      # 格式：<设备>[:<类型>]，逗号分隔；类型用 sat（`smartctl --scan-open`
      # 实测这几块盘都是 SAT）。
      # /dev/sdf 是 USB 外接盘，桥接芯片不透传 SMART，故不列（列了会报错）。
      environment.SMART_DEVICES = "/dev/sda:sat,/dev/sdb:sat,/dev/sdc:sat,/dev/sdd:sat,/dev/sde:sat";

      # 不展示板载 eMMC（/dev/mmcblk0）。
      # 它的磨损/寿命数据由 scanEmmcDevices() 读 sysfs 得到，不经过 smartctl，
      # 所以 SMART_DEVICES 管不到它；但源码里 eMMC 设备同样会经过
      # filterExcludedDevices()，故 EXCLUDE_SMART 有效（见 agent/smart.go）。
      environment.EXCLUDE_SMART = "/dev/mmcblk0";
    };
  };
}
