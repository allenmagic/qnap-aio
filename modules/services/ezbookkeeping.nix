{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.2";
  port = 8082;
  publicHost = "account.allenmagic.cn";
  version = "2.1.1";
  stateDir = "/srv/data/application/ezbookkeeping";

  # 官方发布版是静态链接的单个 ELF，不依赖 glibc；直接解包运行，
  # 不需要引入 Docker/Podman。升级只改 version/hash。
  src = pkgs.fetchurl {
    url = "https://github.com/mayswind/ezbookkeeping/releases/download/v${version}/ezbookkeeping-v${version}-linux-amd64.tar.gz";
    hash = "sha256-OUHWc0cmp7LvzrWGbSmIOYhjrA+jBCNYg9imlG0B45w=";
  };

  package = pkgs.runCommand "ezbookkeeping-${version}" {
    nativeBuildInputs = with pkgs; [ gnutar gzip ];
  } ''
    mkdir -p $out/bin $out/share/ezbookkeeping
    tar -xzf ${src} --no-same-owner -C $out/share/ezbookkeeping
    chmod +x $out/share/ezbookkeeping/ezbookkeeping
    ln -s $out/share/ezbookkeeping/ezbookkeeping $out/bin/ezbookkeeping
  '';

  # 服务端和 CLI 共用同一套配置，避免 admin-init 连错数据库。
  commonEnv = {
    TZ = "Asia/Shanghai";
    EBK_SERVER_PROTOCOL = "http"; # 对外由 cloudflared 终止 TLS
    EBK_SERVER_HTTP_ADDR = lanIp;
    EBK_SERVER_HTTP_PORT = toString port;
    EBK_SERVER_DOMAIN = publicHost;
    EBK_SERVER_ROOT_URL = "https://${publicHost}/";
    EBK_SERVER_ENABLE_GZIP = "true";
    EBK_DATABASE_TYPE = "sqlite3";
    EBK_DATABASE_DB_PATH = "${stateDir}/data/ezbookkeeping.db";
    EBK_STORAGE_TYPE = "local_filesystem";
    EBK_STORAGE_LOCAL_FILESYSTEM_PATH = "${stateDir}/storage/";
    EBK_LOG_LOG_PATH = "${stateDir}/log/ezbookkeeping.log";
    EBK_LOG_LOG_FILE_ROTATE = "true";

    # 内置 MCP server：公网端点 https://account.allenmagic.cn/mcp。
    # 不设 MCP_ALLOWED_REMOTE_IPS：cloudflared 会转发真实客户端 IP，
    # 公网访问必须放行；鉴权靠 MCP token（必要时再加 Cloudflare Access）。
    EBK_MCP_ENABLE_MCP = "true";

    # 临时开启 API token，仅用于本次历史数据导入的账户/分类批量创建；
    # 导入完成后会改回 "false" 并 switch。
    EBK_SECURITY_ENABLE_API_TOKEN = "true";

    # 管理员由 admin-init 创建，禁止公网注册。
    EBK_USER_ENABLE_REGISTER = "false";
  };

  # secret_key 只在运行时从 LoadCredential 读，不进 nix store / 环境文件。
  startScript = pkgs.writeShellApplication {
    name = "ezbookkeeping-start";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      secret_key=$(cat "$CREDENTIALS_DIRECTORY/secret-key")
      export EBK_SECURITY_SECRET_KEY="$secret_key"
      exec ${package}/bin/ezbookkeeping server run \
        --conf-path ${package}/share/ezbookkeeping/conf/ezbookkeeping.ini
    '';
  };

in
{
  # ===== ezBookkeeping：个人记账 =====
  # 数据（SQLite + 附件）放 /srv/data/application 下，不进 NFS/Samba 导出；
  # 每晚 02:50 生成一致性快照，03:00 的 nas 备份任务会把它一起带走。
  #
  # 公网访问：cloudflared 隧道 → account.allenmagic.cn → 192.168.10.2:8082。
  # 账号由用户自行注册；注册已关闭，已有用户（allenmagic）不受影响。
  users.users.ezbookkeeping = {
    isSystemUser = true;
    group = "ezbookkeeping";
    home = stateDir;
    description = "ezBookkeeping";
  };
  users.groups.ezbookkeeping = { };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 ezbookkeeping ezbookkeeping -"
    "d ${stateDir}/data 0700 ezbookkeeping ezbookkeeping -"
    "d ${stateDir}/storage 0700 ezbookkeeping ezbookkeeping -"
    "d ${stateDir}/log 0700 ezbookkeeping ezbookkeeping -"
    "d ${stateDir}/snapshots 0700 ezbookkeeping ezbookkeeping -"
  ];

  systemd.services.ezbookkeeping = {
    description = "ezBookkeeping personal finance";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    environment = commonEnv;

    serviceConfig = {
      Type = "simple";
      User = "ezbookkeeping";
      Group = "ezbookkeeping";
      WorkingDirectory = "${package}/share/ezbookkeeping";
      ExecStart = lib.getExe startScript;
      Restart = "on-failure";
      RestartSec = 5;
      LoadCredential = "secret-key:${config.sops.secrets.ezbookkeeping-secret-key.path}";

      UMask = "0077";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ stateDir ];
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      CapabilityBoundingSet = "";
      AmbientCapabilities = [ ];
      MemoryMax = "256M";
      TasksMax = 64;
    };
  };

  # rsync 直接拷正在写的 SQLite 有小概率拿到不一致状态；用 .backup
  # 生成一致副本，备份时优先用 snapshots/ 下的文件恢复。
  systemd.services.ezbookkeeping-db-snapshot = {
    description = "生成 ezBookkeeping SQLite 一致性快照";
    path = [ pkgs.sqlite pkgs.coreutils pkgs.findutils ];
    serviceConfig = {
      Type = "oneshot";
      User = "ezbookkeeping";
      Group = "ezbookkeeping";
    };
    script = ''
      set -euo pipefail
      mkdir -p ${stateDir}/snapshots
      sqlite3 ${stateDir}/data/ezbookkeeping.db \
        ".backup '${stateDir}/snapshots/ezbookkeeping-$(date +%F).db'"
      find ${stateDir}/snapshots -type f -name 'ezbookkeeping-*.db' -mtime +7 -delete
    '';
  };

  systemd.timers.ezbookkeeping-db-snapshot = {
    description = "每日 02:50 生成 ezBookkeeping SQLite 快照";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "02:50";
      Persistent = true;
    };
  };
}
