{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.2";
  httpPort = 3000;
  sshPort = 2222;
  publicHost = "gitea.allenmagic.cn";
  stateDir = "/srv/data/application/gitea";

  adminUser = "nas";
  adminEmail = "nas@allenmagic.cn";

  # 管理员初始化：gitea 模块不建用户，而 DISABLE_REGISTRATION=true 后没人能注册。
  # 密码走 LoadCredential：以 gitea 身份直读 /run/secrets 依赖 sops 激活与建用户的先后。
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

      # create 在用户已存在时失败，故回退 change-password；输出先接住，避免凭据进 journal
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
  # 内网 :3000，公网 https://gitea.allenmagic.cn（cloudflared 隧道，ingress 见 README）。
  # stateDir 放 /srv/data（RAID1）并进 nas 备份——仓库不可再生；一处赋值连带
  # repositoryRoot / sqlite 库 / LFS 一起搬。
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

        # SSH_DOMAIN 必须钉内网 IP：隧道只代理 HTTP，跟随 DOMAIN 会给出
        # 公网连不上的 ssh://git@gitea.allenmagic.cn:2222
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
