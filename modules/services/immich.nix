{ config, lib, pkgs, ... }:

let
  lanIp = "192.168.10.2";
  port = 2283;
  mediaDir = "/srv/data/photos/immich";
in
{
  # ===== Immich：照片/视频备份 =====
  # 托管库放 /srv/data/photos/immich（Btrfs RAID1）；整棵 photos 已在备份的 nas
  # 任务里，所以不用另加备份源。tmpfiles 会把 immich 目录设成 immich:immich 0700，
  # 因此它虽然位于导出的 photos 下，Samba/NFS 用户实际读不到（备份以 root 跑，不受影响）。
  #
  # 机器学习保持关闭：人脸识别、智能搜索（CLIP）、OCR 同属一个 Python+ONNX 进程，
  # N5095 没有 AVX、整机 8GB，常驻不划算。关掉后上传/时间线/相册/按日期与文件名
  # 搜索、分享都正常，只是没有按人脸或语义搜索。
  services.immich = {
    enable = true;
    host = lanIp;
    port = port;
    mediaLocation = mediaDir;

    machine-learning.enable = false;
    # 只停服务不够：server 的 IMMICH_MACHINE_LEARNING_URL 仍指向 localhost:3003，
    # 会不断派发 ML 任务并失败刷日志，所以同时把 server 侧的功能开关关掉。
    environment.IMMICH_MACHINE_LEARNING_ENABLED = "false";

    # 可选：N5095 核显转码。默认 [] 会启用 PrivateDevices，改为设备列表才放行；
    # 开启后还需在 Immich 后台「视频转码」里选硬件加速。
    # accelerationDevices = [ "/dev/dri/renderD128" ];
  };
}
