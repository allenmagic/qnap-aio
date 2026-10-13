{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.2";
  httpPort = 3000;
  sshPort = 2222;
  publicHost = "gitea.allenmagic.cn";
  stateDir = "/srv/data/gitea";

  adminUser = "nas";
  adminEmail = "nas@allenmagic.cn";

  # 管理员账号初始化。gitea 模块只管建库和迁移，不建用户，而
  # DISABLE_REGISTRATION=true 之后没人能注册——不初始化就进不去。
  #
  # 密码经 systemd LoadCredential 传入（PID 1 以 root 读，故 sops 里
  # owner=root）：以 gitea 身份直接读 /run/secrets 会依赖 sops 激活脚本与
  # 系统用户创建的先后顺序，不可靠。
  #
  # 只在密码值变化时动作：change-password 会让已登录会话失效。
  adminInit = pkgs.writeShellApplication {
    name = "gitea-admin-init";
    runtimeInputs = [ pkgs.coreutils pkgs.gitea ];
    text = ''
      set -euo pipefail

      pw=$(cat "$CREDENTIALS_DIRECTORY/admin-pw")
      marker=${lib.escapeShellArg "${stateDir}/custom/conf/.admin-password-sha256"}
      cur=$(printf %s "$pw" | sha256sum | cut -d' ' -f1)

      if [ "$(cat "$marker" 2>/dev/null || true)" = "$cur" ]; then
        exit 0
      fi

      # 已存在时 create 失败，回退到改密码。命令输出先接住再决定是否落
      # journal，避免把凭据打进日志。
      if ! out=$(gitea admin user create --admin \
        --username ${adminUser} --email ${adminEmail} --password "$pw" 2>&1); then
        if ! out=$(gitea admin user change-password \
          --username ${adminUser} --password "$pw" 2>&1); then
          printf '%s\n' "$out" >&2
          exit 1
        fi
      fi
      printf %s "$cur" > "$marker"
    '';
  };
in
{
  # ===== Gitea：自建 Git 托管 =====
  # 内网 http://192.168.10.2:3000，公网 https://gitea.allenmagic.cn（经
  # cloudflared 容器隧道回源，ingress 在 Cloudflare 面板配置，见 README）。
  #
  # 仓库是不可再生数据，因此整个 stateDir 放在 /srv/data（Btrfs RAID1），
  # 并由 services/backup.nix 的 nas 任务一并备份。stateDir 一处赋值会带动
  # repositoryRoot / sqlite 库 / LFS / dump 目录全部搬过去。
  services.gitea = {
    enable = true;
    stateDir = stateDir;
    lfs.enable = true;

    settings = {
      server = {
        PROTOCOL = "http";
        HTTP_ADDR = lanIp;
        HTTP_PORT = httpPort;

        DOMAIN = publicHost;
        ROOT_URL = "https://${publicHost}/";

        # SSH 克隆只在局域网可用——隧道只代理 HTTP。SSH_DOMAIN 必须钉在内网
        # IP：跟着 DOMAIN 走的话界面会给出 ssh://git@gitea.allenmagic.cn:2222
        # 这种公网根本连不上的地址。
        SSH_DOMAIN = lanIp;
        SSH_PORT = sshPort;
        SSH_LISTEN_HOST = lanIp;
        SSH_LISTEN_PORT = sshPort;
        DISABLE_SSH = false;
        # 用 Gitea 自带 SSH 服务，宿主 sshd 一个字都不动
        START_SSH_SERVER = true;
      };

      # 公网侧是 https：不带 Secure 的会话 cookie 浏览器不会回传
      session.COOKIE_SECURE = true;

      # 实例公网可达，不留开放注册；建号只走管理员
      service.DISABLE_REGISTRATION = true;

      repository.DEFAULT_BRANCH = "main";
    };
  };

  systemd.services.gitea-admin-init = {
    description = "初始化 Gitea 管理员账号";
    wantedBy = [ "multi-user.target" ];
    after = [ "gitea.service" ];
    requires = [ "gitea.service" ];
    environment = {
      GITEA_WORK_DIR = stateDir;
      HOME = stateDir;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "gitea";
      Group = "gitea";
      WorkingDirectory = stateDir;
      ExecStart = lib.getExe adminInit;
      LoadCredential = "admin-pw:${config.sops.secrets.gitea-admin-password.path}";
    };
  };
}
