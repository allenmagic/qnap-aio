{ config, lib, ... }:

{
  # SSH 服务配置
  services.openssh = {
    enable = true;

    settings = {
      # 安全设置
      PermitRootLogin = "prohibit-password";  # 禁止 root 密码登录，只允许密钥
      PasswordAuthentication = false;  # 默认禁用密码认证；仅内网通过下方 Match 放行
      PubkeyAuthentication = true;     # 启用公钥认证

      # 其他安全选项
      X11Forwarding = false;
      AllowTcpForwarding = "yes";
      GatewayPorts = "no";

      # 性能优化
      UseDns = false;
    };

    # 监听端口（默认 22）
    ports = [ 22 ];

    # 不在全局放行 22 端口：br-lan 已在 network/default.nix 显式放行，
    # openFirewall = true 会把 22 加到全局 allowedTCPPorts（作用于 br-wan 等所有接口）
    openFirewall = false;

    # 内网与 Tailscale 网段允许密码登录（内网设备配置密钥麻烦；Tailscale 自带
    # 加密隧道与设备认证，密码登录风险可控）；其余来源保持默认禁用密码、只认密钥。
    extraConfig = ''
      Match Address 192.168.10.0/24,100.64.0.0/10
        PasswordAuthentication yes
    '';
  };

  # SSH 密钥管理
  # 用户密钥在 users 模块中配置

  # ===== 出站：NAS 本机 git 访问 GitHub =====
  # 私钥由 sops 解密到 /run/secrets/github-ssh-key（tmpfs，不落盘，
  # 重启后由 sops-nix 重新解密）。公钥需上传到 GitHub 账号
  # Settings → SSH and GPG keys。
  #
  # 用途：root 直接在 NAS 上 git pull/push（仓库都是 public，拉取用
  # HTTPS 也行；需要推送时才必须走密钥）。
  programs.ssh = {
    # ⚠️ known_hosts 必须声明式配置：/root/.ssh/known_hosts 是空的，
    # 之前 `git ls-remote git@github.com:...` 报 "Host key verification
    # failed" 就是这个原因。写进 /etc/ssh/ssh_known_hosts（全局可读）。
    knownHosts = {
      github-ed25519 = {
        hostNames = [ "github.com" ];
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
      };
      github-ecdsa = {
        hostNames = [ "github.com" ];
        publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
      };
      github-rsa = {
        hostNames = [ "github.com" ];
        publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=";
      };
    };

    extraConfig = ''
      Host github.com
        HostName github.com
        User git
        IdentityFile /run/secrets/github-ssh-key
        IdentitiesOnly yes
    '';
  };
}
