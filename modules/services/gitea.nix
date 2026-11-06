{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.2";
  httpPort = 3000;
  sshPort = 2222;
  publicHost = "gitea.allenmagic.cn";
  stateDir = "/srv/data/application/gitea";

  adminUser = "nas";
  adminEmail = "nas@allenmagic.cn";

  # 第三方主题（Gitea 1.27/1.28 系列）。构建时要下载；GFW 会间歇性拦 GitHub
  # （见 deploy-nas.sh），失败时在工作站构建后 nix copy 过去。
  themeMechiland = pkgs.fetchzip {
    url = "https://github.com/mechiland/gitea-theme-github/releases/download/v0.3.0/gitea-theme-github-0.3.0-gitea1.27-28.tar.gz";
    hash = "sha256-bPq1scpPvVyUvp15S1UJeMLZnd+iHH1rRMlESp0OAQs=";
    # 归档是平铺的（./public、./templates），没有单一顶层目录
    stripRoot = false;
  };

  # 第二个 GitHub 风格主题，版本号 = 对应的 Gitea 系列（1.27.3 适用于 1.27.x）。
  # 归档只有一个顶层 dist/，fetchzip 默认会剥掉。
  themeLuting = pkgs.fetchzip {
    url = "https://github.com/lutinglt/gitea-github-theme/releases/download/v1.27.3/theme-github-base.tar.gz";
    hash = "sha256-kuxECCkJ2jAexD3uCHdr3UZHRki+TEmR1xQN1AX+zuA=";
  };

  # 两个主题都用 github-* 文件名，不能直接叠加；合并成一份 assets 再整体链入。
  # luting 的 auto 主题靠 @import "./theme-github-dark.css" 引同目录文件，
  # 改名成 luting-* 时必须同步改 CSS 里的引用。
  themeAssets = pkgs.runCommand "gitea-theme-assets" { } ''
    mkdir -p $out/public
    cp -r ${themeMechiland}/public/assets $out/public/assets
    chmod -R u+w $out/public/assets

    for f in ${themeLuting}/theme-github-*.css; do
      name=$(basename "$f")
      newname=$(echo "$name" | sed 's/^theme-github-/theme-luting-/')
      sed 's#theme-github-#theme-luting-#g' "$f" > "$out/public/assets/css/$newname"
    done
  '';

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

      ui = {
        THEMES = "gitea-auto,gitea-light,gitea-dark,github-auto,github-light,github-dark,luting-auto,luting-light,luting-dark,luting-soft-dark";
        DEFAULT_THEME = "github-auto";
      };
    };
  };

  # 主题文件从 store 链入 customDir。用 preStart（以 gitea 运行）而不是 tmpfiles：
  # 父目录本来就归 gitea，不依赖激活阶段的规则时序。
  systemd.services.gitea.preStart = lib.mkAfter ''
    mkdir -p ${config.services.gitea.customDir}/public
    ln -sfn ${themeAssets}/public/assets ${config.services.gitea.customDir}/public/assets
    ln -sfn ${themeMechiland}/templates ${config.services.gitea.customDir}/templates
  '';

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
