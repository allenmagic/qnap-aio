{ config, lib, ... }:

{
  # sops-nix 密钥管理配置
  sops = {
    # 默认密钥文件位置
    defaultSopsFile = ../../secrets/secrets.yaml;

    # age 密钥文件路径
    age = {
      keyFile = "/var/lib/sops-nix/key.txt";
      # 首次部署时需要生成：
      # mkdir -p /var/lib/sops-nix
      # age-keygen -o /var/lib/sops-nix/key.txt
      # 然后用公钥加密 secrets.yaml
    };

    # 定义密钥（示例，实际使用时取消注释并配置）
    secrets = {
      # nas 系统密码 hash（Cockpit/sudo/内网与 Tailscale SSH 密码登录共用）
      # secrets.yaml 内容：nas-password: $6$...（mkpasswd -m sha-512 生成）
      nas-password = {
        neededForUsers = true;  # 用户激活前解密，配合 hashedPasswordFile 使用
        owner = "root";
        mode = "0400";
      };

      # root 密码 hash（串口/本地登录兜底；SSH 默认密钥登录）。
      # secrets.yaml 条目待真机添加（见 modules/users/nas-user.nix 的部署顺序）：
      #   sops -k /var/lib/sops-nix/key.txt set secrets/secrets.yaml \
      #     root-password-hash '<$6$hash>'
      root-password-hash = {
        neededForUsers = true;
        owner = "root";
        mode = "0400";
      };

      # Samba 密码
      # samba-password = {
      #   owner = "nas";
      #   mode = "0400";
      # };

      # Syncthing GUI 密码
      syncthing-password = {
        owner = "nas";
        mode = "0400";
      };

      # WebDAV 认证密码。内容为 EnvironmentFile 格式（hacdias/webdav 用
      # {env} 占位读取，配置文件里不含明文）：
      #   WEBDAV_PASSWORD=<明文密码>
      # 添加：sops -k /var/lib/sops-nix/key.txt set secrets/secrets.yaml \
      #         webdav-password 'WEBDAV_PASSWORD=<明文密码>'
      webdav-password = {
        owner = "root";   # 由 systemd（PID 1）读取 EnvironmentFile
        mode = "0400";
      };

      # Glance 仪表盘认证。两个值由 services/glance.nix 的 settings 以
      # { _secret = ...; } 引用，模块 ExecStartPre（root 跑 jq）替换进配置：
      #   glance-secret-key    = base64 的 64 随机字节（`glance secret:make`）
      #   glance-password-hash = bcrypt（`glance password:hash <密码>`）
      # ⚠️ 值不能带尾换行（多 1 字节 → secret-key 长度校验失败 / bcrypt 比对失败）。
      glance-secret-key = {
        owner = "root";
        mode = "0400";
      };
      glance-password-hash = {
        owner = "root";
        mode = "0400";
      };

      # Tailscale 认证密钥
      # tailscale-authkey = {
      #   owner = "root";
      #   mode = "0400";
      # };

      # ── 路由 VM 密钥（services.router-vm 的 deploy 通道）──────────
      # 文件名必须与 router-image 模块的 secretsDir 约定一致
      # （<secretsDir>/ssh-public-key 等，默认 /run/secrets）。
      # secrets.yaml 内容示例：
      #   ssh-public-key: |
      #     ssh-ed25519 AAAA... deploy-key
      #   tailscale-auth-key: tskey-auth-xxxxxxxxxxxxxxxx
      #   headscale-auth-key: tskey-auth-xxxxxxxxxxxxxxxx（自建控制面 hs.zyx1986.icu）
      #   cloudflared-token: eyJhIjoi...
      # 注入语义：router-vm-deploy 在每次 VM 启动后自动 scp 进 guest
      # /run（guest 无状态，重启即清、重新注入）；tailscale/headscale 注入后自动登录。
      ssh-public-key = {
        owner = "root";
        mode = "0400";
      };
      tailscale-auth-key = {
        owner = "root";
        mode = "0400";
      };
      headscale-auth-key = {
        owner = "root";
        mode = "0400";
      };
      cloudflared-token = {
        owner = "root";
        mode = "0400";
      };

      # Beszel agent 认证。内容来自 hub UI「Add System」给出的 SSH 公钥，
      # 为 EnvironmentFile 格式（`KEY=ssh-ed25519 AAAA...`）。
      # 由 services/beszel.nix 的 agent.environmentFile 引用（经 systemd
      # EnvironmentFile 读取，因此 0400 也可用）。
      beszel-agent-key = {
        owner = "root";
        mode = "0400";
      };

      # NAS 本机 git 操作用的 GitHub SSH 私钥（ed25519，账号级）。
      # 对应公钥需上传到 GitHub 账号 Settings → SSH and GPG keys。
      # 落点 /run/secrets/github-ssh-key（tmpfs，不落盘）；由
      # modules/security/ssh.nix 的 programs.ssh.extraConfig 引用。
      github-ssh-key = {
        owner = "root";
        mode = "0400";
      };

      # qBittorrent Web UI 密码（明文）。services/downloads.nix 的 ExecStartPre
      # 在启动前把它算成 PBKDF2 哈希写进 qBittorrent.conf——配置模板本身在
      # nix store（全员可读），所以密码不能直接进 serverConfig。
      # owner 必须是 nas：ExecStartPre 以服务用户身份执行，要读得到。
      qbittorrent-password = {
        owner = "nas";
        mode = "0400";
      };

      # OpenList（网盘聚合）管理员 admin 的密码（明文）。services/openlist.nix
      # 的 ExecStartPre 用 `OpenList admin set` 写进它的数据库；值没变则不重设
      # （admin set 会让已登录会话失效）。owner 必须是 nas：ExecStartPre 以
      # 服务用户身份执行，要读得到。
      openlist-admin-password = {
        owner = "nas";
        mode = "0400";
      };

      # aria2 JSON-RPC 密钥（明文随机串）。由 services.aria2 的 rpcSecretFile
      # 经 systemd LoadCredential 读取（PID 1 以 root 读，故 owner=root）。
      # AriaNg 首次打开时填这个值即可。
      aria2-rpc-secret = {
        owner = "root";
        mode = "0400";
      };
    };
  };
}
