{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.2";
  port = 2284;
  dumpDir = "/srv/data/application/photoview";

  # nixpkgs 26.05 的 photoview 2.4.0 仍使用 libheif Go 绑定 v1.15.1，
  # 而系统 libheif 已到 1.23.1：枚举参数不再是 uint32，直接编译会报
  # cannot use uint32(...) as _Ctype_heif_*。vendor 生成后加显式类型转换。
  photoview = pkgs.photoview.overrideAttrs (old: {
    preBuild = (old.preBuild or "") + lib.optionalString (old.version == "2.4.0") ''
      substituteInPlace vendor/github.com/strukturag/libheif/go/heif/heif.go \
        --replace-fail 'uint32(compression)' 'C.heif_compression_format(compression)' \
        --replace-fail 'uint32(colorspace)' 'C.heif_colorspace(colorspace)' \
        --replace-fail 'uint32(chroma)' 'C.heif_chroma(chroma)' \
        --replace-fail 'uint32(channel)' 'C.heif_channel(channel)'
    '';
  });
in
{
  # ===== Photoview：只读照片浏览 =====
  # 媒体文件放 HDD RAID1，服务以只读方式挂载；缩略图缓存和数据库留在 SSD。
  # Immich 的托管库是 0700 且与这里内容重复，不作为 mediaPath。
  services.photoview = {
    enable = true;
    package = photoview;
    host = lanIp;
    port = port;
    mediaPath = "/srv/data/photos/iphone";

    database = {
      type = "postgres";
      host = "127.0.0.1";
      port = 5432;
      name = "photoview";
      user = "photoview";
      passwordFile = config.sops.secrets.photoview-db-password.path;
    };

    # N5095 无 AVX、整机 8GB；只做人脸识别/RAW/视频转码会白白吃 CPU 和内存。
    settings = {
      disableFaceRecognition = true;
      disableRawProcessing = true;
      disableVideoEncoding = true;
    };
  };

  systemd.tmpfiles.rules = [
    # pg_dump 由 postgres 用户执行，目录也只让 postgres 写；备份以 root 读取。
    "d ${dumpDir} 0700 postgres postgres -"
  ];

  systemd.services.photoview = {
    # 数据盘未挂载时 /srv/data 是根盘上的空目录，mediaPath 会指向错误内容。
    unitConfig.RequiresMountsFor = [ "/srv/data" ];
    after = [ "photoview-db-password.service" ];
    requires = [ "photoview-db-password.service" ];
    serviceConfig = {
      MemoryHigh = "768M";
      MemoryMax = "1G";
      TasksMax = 256;
    };
  };

  # ensureUsers 只建角色，不设密码；每次启动从 sops 读取并写入 PostgreSQL。
  # 密码用 hex 生成，避免模块把密码拼进 postgres:// URL 时被特殊字符破坏。
  systemd.services.photoview-db-password = {
    description = "Set Photoview PostgreSQL role password";
    after = [ "postgresql-setup.service" ];
    requires = [ "postgresql-setup.service" ];
    before = [ "photoview.service" ];
    path = [ pkgs.postgresql_17 ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      Group = "postgres";
      LoadCredential = "db-password:${config.sops.secrets.photoview-db-password.path}";
    };
    script = ''
      set -euo pipefail
      pw=$(cat "$CREDENTIALS_DIRECTORY/db-password")
      psql -v ON_ERROR_STOP=1 --no-psqlrc -d postgres <<SQL
      ALTER ROLE photoview WITH PASSWORD '$pw';
      SQL
    '';
  };

  # PostgreSQL 数据在 SSD 的 /var/lib/postgresql，不在现有 nas 备份任务里；
  # 每日先 dump 到 HDD，再由 03:00 的备份任务一起带走。
  systemd.services.photoview-db-dump = {
    description = "Dump Photoview PostgreSQL database";
    after = [ "postgresql-setup.service" ];
    requires = [ "postgresql-setup.service" ];
    unitConfig.RequiresMountsFor = [ "/srv/data" ];
    path = [ pkgs.postgresql_17 pkgs.coreutils pkgs.findutils ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      Group = "postgres";
      UMask = "0077";
    };
    script = ''
      set -euo pipefail
      mkdir -p ${dumpDir}
      pg_dump --format=custom \
        --file=${dumpDir}/photoview-$(date +%F).dump photoview
      find ${dumpDir} -type f -name 'photoview-*.dump' -mtime +7 -delete
    '';
  };

  systemd.timers.photoview-db-dump = {
    description = "每日 02:40 生成 Photoview PostgreSQL 备份";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "02:40";
      Persistent = true;
    };
  };
}
