{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./filesystem.nix
  ];

  # 系统基础配置
  system.stateVersion = "26.05";

  networking.hostName = "allenmagic-nas";

  # 启用 Flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # 启用 QNAP 硬件支持
  # qnap8528 内核模块包由其模块自带的 overlay 注入 boot.kernelPackages
  # （上游已修复 nixos-26.05 下 overlay 失效的问题，见 flake.lock 锁定的版本）
  hardware.qnap8528 = {
    enable = true;
    preserveLeds = true;
  };

  # 时区和本地化
  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_TIME = "zh_CN.UTF-8";
  };

  # 控制台配置
  console = {
    font = "Lat2-Terminus16";
    keyMap = "us";
  };

  # Boot loader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
