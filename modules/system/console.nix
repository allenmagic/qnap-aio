{ config, pkgs, lib, ... }:

{
  # 物理控制台（HDMI）中文显示：
  # 内核 fbcon 只支持拉丁位图字体，无法渲染 CJK；kmscon 是用户态终端模拟器，
  # 通过 fontconfig 渲染字体，配合 Noto Sans CJK 实现控制台中文显示。
  # 注意：kmscon 依赖 iGPU 的 KMS/DRM 驱动（QNAP TS-564 为 Intel i915）。
  # 若 kmscon 启动失败只影响本地控制台，SSH/网络服务不受影响；
  # 开机早期（initrd/急救 shell）仍由内核 fbcon 接管（见 configuration.nix 的 console.font）。
  services.kmscon = {
    enable = true;
    hwRender = true;  # 硬件加速渲染

    # 字体按优先级回退：拉丁用等宽 DejaVu Sans Mono，中文回退到 Noto Sans CJK SC
    fonts = [
      {
        name = "DejaVu Sans Mono";
        package = pkgs.dejavu_fonts;
      }
      {
        name = "Noto Sans CJK SC";
        package = pkgs.noto-fonts-cjk-sans;
      }
    ];

    extraConfig = ''
      font-size=14
      xkb-layout=us
    '';
  };
}
