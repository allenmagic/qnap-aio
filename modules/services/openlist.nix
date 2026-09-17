{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.2";
  httpPort = 5244;

  dataDir = "/var/lib/openlist/data";
  downloadDir = "/srv/data/downloads/openlist";

  # 绑定地址/端口只能写进 config.json（实测 OPENLIST_* 环境变量对嵌套键无效，
  # 覆盖不到 scheme.http_port），且空/半截的 config.json 会让 OpenList 直接
  # FATA 退出——所以写临时文件再 mv，绝不原地截断。
  #
  # 管理员密码跟随 sops，但只在值变化时重设：admin set 会刷新 pwd_ts，
  # 使已登录的浏览器会话立刻失效，每次重启都重设会很烦。
  # 首次全新目录也能直接跑通（admin set 自己会建库并创建 admin 用户）。
  openlistInit = pkgs.writeShellApplication {
    name = "openlist-init";
    runtimeInputs = [ pkgs.coreutils pkgs.jq ];
    text = ''
      set -euo pipefail
      conf=${lib.escapeShellArg "${dataDir}/config.json"}
      data=${lib.escapeShellArg dataDir}
      openlist=${lib.getExe pkgs.openlist}
      address=${lib.escapeShellArg lanIp}
      port=${toString httpPort}

      mkdir -p "$data"
      tmp=$(mktemp)
      if [ -f "$conf" ]; then
        jq --arg a "$address" --argjson p "$port" \
          '.scheme.address = $a | .scheme.http_port = $p' "$conf" > "$tmp"
      else
        jq -n --arg a "$address" --argjson p "$port" \
          '{scheme: {address: $a, http_port: $p}}' > "$tmp"
      fi
      mv "$tmp" "$conf"

      pw=$(cat ${lib.escapeShellArg config.sops.secrets.openlist-admin-password.path})
      marker="$data/.password-sha256"
      cur=$(printf %s "$pw" | sha256sum | cut -d' ' -f1)
      if [ "$(cat "$marker" 2>/dev/null || true)" != "$cur" ]; then
        # admin set 会把密码明文打到 stdout，成功路径不接管道，避免进 journal
        if ! out=$("$openlist" admin set "$pw" --data "$data" 2>&1); then
          printf '%s\n' "$out" >&2
          exit 1
        fi
        printf %s "$cur" > "$marker"
      fi
    '';
  };
in
{
  # ===== OpenList：网盘聚合（Web UI + WebDAV） =====
  # AList 的社区 fork（AList 原仓库 2025 年被公司接手，社区另起 OpenList）。
  # 把百度/阿里/夸克/Google Drive 等挂进来统一浏览与下载；自带 /dav，
  # 加完存储后 aria2 / rclone 等可把它当普通 WebDAV 用。
  #
  # 网盘凭据不进 sops 也不进 nix store：在 Web UI 里添加存储即可，落在
  # data/config.json（StateDirectory 0700 + UMask 0077，只有 nas 读得到）。
  systemd.services.openlist = {
    description = "OpenList (cloud drive aggregator, AList fork)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      # 与 qBittorrent 一致用 nas：它写进 /srv/data 的文件属主才与共享一致
      User = "nas";
      Group = "nas";
      StateDirectory = "openlist";
      StateDirectoryMode = "0700";
      ExecStartPre = lib.getExe openlistInit;
      ExecStart = "${lib.getExe pkgs.openlist} server --data ${dataDir}";
      Restart = "on-failure";
      RestartSec = 5;
      UMask = "0077";

      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      # 只列 downloadDir：stateDir 由 StateDirectory= 负责（systemd 文档明确它
      # 排除在 ProtectSystem= 之外）。⚠️ 列还没被创建的路径会让服务起不来——
      # 命名空间在 ExecStartPre 之前就装好了，路径不存在直接 226/NAMESPACE。
      # 这里 data 子目录是 init 脚本现建的，所以必须带 "-" 前缀或干脆别列。
      ReadWritePaths = [ "-${downloadDir}" ];
      RestrictRealtime = true;
      SystemCallArchitectures = "native";
    };
  };

  # 网盘文件落盘目录（在 Web UI 里挂「本机存储」指向它）。与其它下载工具
  # 的子目录同级，nas 属主，Samba/NFS 里直接可见。
  systemd.tmpfiles.rules = [
    "d ${downloadDir} 0755 nas nas -"
  ];
}
