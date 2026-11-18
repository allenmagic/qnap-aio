{ config, lib, pkgs, ... }:

let
  port = 3001;
  dataDir = "/srv/data/application/chronoframe";
in
{
  # ===== ChronoFrame：照片上传与浏览 =====
  # 官方只提供 OCI 镜像；没有 nixpkgs 包，直接用 Podman 运行。
  # 注意：ChronoFrame 的上传在浏览器里依赖 crypto.randomUUID()，
  # 只有 HTTPS / localhost 才是 Secure Context。局域网 HTTP 下页面能看，
  # 但上传按钮不会发请求；生产使用必须加 HTTPS 或走 SSH 端口转发。
  virtualisation.podman.enable = true;

  virtualisation.oci-containers = {
    backend = "podman";
    containers.chronoframe = {
      image = "ghcr.io/hoshinosuzumi/chronoframe:latest";
      autoStart = true;

      volumes = [
        "${dataDir}:/app/data"
      ];

      # host 网络避免额外 NAT；端口由宿主防火墙限制在 br-lan。
      extraOptions = [
        "--network=host"
        "--memory=1g"
        "--cpus=2"
      ];

      environment = {
        TZ = "Asia/Shanghai";
        NITRO_HOST = "0.0.0.0";
        NITRO_PORT = toString port;
      };
    };
  };

  systemd.tmpfiles.rules = [
    "d ${dataDir} 0700 root root -"
  ];

  # 数据目录在 /srv/data 上；盘未挂载时不要让容器在根盘上建库。
  systemd.services."podman-chronoframe".unitConfig.RequiresMountsFor = [
    "/srv/data"
  ];
}
