{ config, lib, pkgs, inputs, ... }:

let
  # dsh 核心只监听回环；对局域网的服务由 dsh-remote-mobile 插件在 3081 提供。
  bindHost = "127.0.0.1";
  port = 3080;
  stateDir = "/var/lib/deepseek-harness";

  # deepseek-harness 只在 unstable 里；qnap-aio 已有 unstable input，
  # 不更新 flake.lock 也能用当前锁定版本（0.2.1-rc.3）。
  dsh = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.deepseek-harness;

  # API key 通过 systemd credential 传入，不落 nix store / 环境文件。
  start = pkgs.writeShellApplication {
    name = "deepseek-harness-start";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      api_key=$(cat "$CREDENTIALS_DIRECTORY/deepseek-api-key")
      export DEEPSEEK_API_KEY="$api_key"

      # dsh 的 MCP manager 用 credential 模板引用这个变量。
      mcp_token=$(cat "$CREDENTIALS_DIRECTORY/ezbookkeeping-mcp-token")
      export EZBOOKKEEPING_MCP_TOKEN="$mcp_token"

      exec ${lib.getExe dsh} --profile web --no-open \
        --host ${bindHost} --port ${toString port}
    '';
  };
in
{
  # ===== DeepSeek Harness：局域网可访问的 agent Web UI =====
  # dsh 会执行模型生成的命令，所以用专用用户、核心只监听回环，并且
  # 默认不让它看到 /srv；需要处理 NAS 文件时再单独开 workspace。
  #
  # 局域网入口由 dsh-remote-mobile 插件提供：它检测到回环核心后启动
  # 0.0.0.0:3081 认证代理，手机/平板通过配对码或长期密码访问。
  users.users.deepseek-harness = {
    isSystemUser = true;
    group = "deepseek-harness";
    home = stateDir;
    createHome = false;
    description = "DeepSeek Harness";
  };
  users.groups.deepseek-harness = { };

  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 deepseek-harness deepseek-harness -"
    "d ${stateDir}/home 0700 deepseek-harness deepseek-harness -"
    "d ${stateDir}/dsh 0700 deepseek-harness deepseek-harness -"
    "d ${stateDir}/workspace 0700 deepseek-harness deepseek-harness -"
  ];

  systemd.services.deepseek-harness = {
    description = "DeepSeek Harness web UI";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];

    # 插件管理器对 github: 规格先跑 git ls-remote；systemd 默认 PATH
    # 不含 systemPackages，缺 git 时装 GitHub 插件会报 ENOENT。
    path = [ pkgs.git pkgs.openssh ];

    environment = {
      HOME = "${stateDir}/home";
      DSH_HOME = "${stateDir}/dsh";
      # 仅关闭 OTel；DeepSeek 会话日志上传需在 Web UI 的 General 设置里单独关闭。
      DSH_TELEMETRY_MODE = "DISABLED";
    };

    serviceConfig = {
      Type = "simple";
      User = "deepseek-harness";
      Group = "deepseek-harness";
      WorkingDirectory = "${stateDir}/workspace";
      ExecStart = lib.getExe start;
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = 15;
      LoadCredential = [
        "deepseek-api-key:${config.sops.secrets.deepseek-api-key.path}"
        "ezbookkeeping-mcp-token:${config.sops.secrets.ezbookkeeping-mcp-token.path}"
      ];

      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ stateDir ];
      InaccessiblePaths = [ "/srv" "/boot" "/etc/ssh" ];
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;

      # 不要加 RestrictNamespaces / PrivateUsers / PrivateDevices：
      # dsh 自带的 bwrap 需要用户命名空间和 /proc、/dev。
      MemoryHigh = "1G";
      MemoryMax = "2G";
      TasksMax = 512;
    };
  };
}
