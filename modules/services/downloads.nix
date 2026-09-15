{ config, lib, pkgs, ... }:

let
  # 下载目录分三个子目录：三个工具运行身份不同（qBittorrent 以 nas 跑、
  # aria2 用模块自建的 aria2 系统用户），混在一起会互相 chown 打架。
  #   torrent/ qBittorrent（BT/PT）  aria2/ 模块自管属主   video/ yt-dlp
  downloadRoot = "/srv/data/downloads";
  torrentDir = "${downloadRoot}/torrent";
  aria2Dir = "${downloadRoot}/aria2";
  videoDir = "${downloadRoot}/video";

  lanIp = "192.168.10.250";

  # qBittorrent 的 serverConfig 会经 nix store 落盘（全员可读），不能放密码。
  # 这里放占位符，启动前由下面的 ExecStartPre 用 sops 里的明文算 PBKDF2 覆盖。
  qbPasswordPlaceholder = "QBITTORRENT_PASSWORD_PLACEHOLDER";

  # 用 writeShellApplication 而非 writeShellScript：后者不设 PATH，
  # 而 systemd 的默认 PATH 在 NixOS 上并不存在，脚本里的 cat 会找不到。
  qbSetPassword = pkgs.writeShellApplication {
    name = "qbittorrent-set-password";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.python3
    ];
    text = ''
      set -euo pipefail
      conf=${lib.escapeShellArg "${config.services.qbittorrent.profileDir}/qBittorrent/config/qBittorrent.conf"}
      secret=$(cat ${lib.escapeShellArg config.sops.secrets.qbittorrent-password.path})

      # qBittorrent 的密码格式：PBKDF2-HMAC-SHA512，10 万轮，64 字节，
      # 存成 @ByteArray(<salt_b64>:<hash_b64>)。每次启动重算（盐随机），无副作用。
      hash=$(python3 -c "
import base64, hashlib, os, sys
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000, 64)
print('@ByteArray(%s:%s)' % (base64.b64encode(salt).decode(), base64.b64encode(key).decode()))
" "$secret")

      sed -i "s|${qbPasswordPlaceholder}|$hash|" "$conf"
    '';
  };
in
{
  # ===== qBittorrent：BT / PT =====
  # PT 站基本都放行它；aria2 常因客户端行为上报不合规被 PT 站封禁，所以两者分工。
  services.qbittorrent = {
    enable = true;
    user = "nas";
    group = "nas";
    webuiPort = 8081;
    torrentingPort = 6881;

    serverConfig = {
      LegalNotice.Accepted = true;

      BitTorrent.Session = {
        DefaultSavePath = torrentDir;
        # 未完成的文件留在同一分区，避免完成时跨盘搬运 35G
        TempPathEnabled = true;
        TempPath = "${torrentDir}/.incomplete";
      };

      Preferences = {
        WebUI = {
          Address = lanIp; # 只绑内网 shim
          Username = "nas";
          Password_PBKDF2 = qbPasswordPlaceholder;
        };
        General.Locale = "zh_CN";
      };
    };
  };

  # 模块自带的 ExecStartPre 把 store 里的配置拷进可写目录，这里追加第二个覆盖密码占位符。
  # sops 里 qbittorrent-password 的 owner 必须是 nas，否则服务用户读不到。
  systemd.services.qbittorrent.serviceConfig = {
    ExecStartPre = lib.mkAfter [ (lib.getExe qbSetPassword) ];

    # 运行中 qBittorrent 自己重写 conf 时按 umask 落盘，会把 install 的 600 放宽成 644
    # （conf 里有 WebUI 口令的 PBKDF2 哈希）
    UMask = "0077";
  };

  # ===== aria2：HTTP / FTP 直链 =====
  # 注意：模块自建 aria2 系统用户并用 tmpfiles 把 settings.dir chown 成 aria2:aria2，
  # 所以 dir 必须指向专属子目录，不能是共享的 downloads 根。
  services.aria2 = {
    enable = true;
    rpcSecretFile = config.sops.secrets.aria2-rpc-secret.path;
    openPorts = false; # 端口统一在 network/default.nix 放行
    serviceUMask = "0002"; # 组可写，配合把 nas 加进 aria2 组

    settings = {
      dir = aria2Dir;
      enable-rpc = true;
      rpc-listen-port = 6800;
      rpc-listen-all = true; # 宿主在 WAN 侧无地址，实际只在内网可达
      rpc-allow-origin-all = true; # AriaNg 是同源页面但仍需放行
      continue = true;
      "max-concurrent-downloads" = 5;
      "file-allocation" = "none"; # Btrfs 上预分配无意义且拖慢启动
    };
  };

  # ===== AriaNg：aria2 的网页面 =====
  # AriaNg 是纯静态 SPA，nginx 直接托管；没有它 aria2 只剩命令行。
  services.nginx = {
    enable = true;
    virtualHosts."ariang" = {
      listen = [
        {
          addr = lanIp;
          port = 6880;
        }
      ];
      root = "${pkgs.ariang}/share/ariang";
      locations."/".tryFiles = "$uri $uri/ /index.html";
    };
  };

  # ===== yt-dlp：视频网站 =====
  # nixpkgs 没有 MeTube（视频下载网页面），用上游命令行本体 + 一个落到 video/ 的包装。
  environment.systemPackages = [
    pkgs.yt-dlp
    (pkgs.writeShellScriptBin "ytdl" ''
      exec ${lib.getExe pkgs.yt-dlp} \
        -o ${lib.escapeShellArg "${videoDir}/%(title)s.%(ext)s"} \
        -P temp:${lib.escapeShellArg "${videoDir}/.part"} \
        "$@"
    '')
  ];

  # 目录与属主：torrent/video 归 nas（qBittorrent 与 yt-dlp 都以 nas 跑），
  # aria2/ 交给 aria2 模块自己的 tmpfiles 规则，这里不重复声明。
  systemd.tmpfiles.rules = [
    "d ${downloadRoot} 0755 nas nas -"
    "d ${torrentDir} 0755 nas nas -"
    "d ${videoDir} 0755 nas nas -"
  ];
}
