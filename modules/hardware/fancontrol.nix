{ config, pkgs, inputs, ... }:

{
  # qnap8528 内核模块：默认硬件检测（读 Super I/O 0x2e 的 EC ID）在 6.18
  # 内核下失败（"Could not locate IT8528 EC device"），但 EC 实际可用。
  # skip_hw_check=1 跳过检测直接加载（TS-564 实测：模型识别、hwmon、
  # LED、按钮全部正常）。
  boot.extraModprobeConfig = ''
    options qnap8528 skip_hw_check=1
  '';

  # fancontrol：修正后的 TS-564 配置（lm-sensors 3.6 的 DEVPATH/DEVNAME +
  # hwmonN/pwm 相对路径格式）。上游 qnap8528 examples/fancontrol.conf 用
  # 裸全路径 + 通配符（FCTEMPS/FCFANS 顺序也反），fancontrol 解析失败。
  # hwmon 编号随加载顺序：此处 coretemp=hwmon1、qnap8528=hwmon2（实测）。
  # 若重启后编号变化，用 `sensors` 或 ls /sys/class/hwmon/ 校准。
  hardware.fancontrol = {
    enable = true;
    config = ''
      INTERVAL=5
      # DEVPATH 值须匹配 fancontrol 的 DevicePath()（readlink -f hwmonN/device
      # 去 /sys/ 前缀 → devices/platform/<name>），用 /sys/.../hwmon 会报
      # "Device path has changed"
      DEVPATH=hwmon1=devices/platform/coretemp.0
      DEVPATH=hwmon2=devices/platform/qnap8528
      DEVNAME=hwmon1=coretemp
      DEVNAME=hwmon2=qnap8528
      FCTEMPS=hwmon2/pwm1=hwmon1/temp1_input
      FCFANS=hwmon2/pwm1=hwmon2/fan1_input
      MINTEMP=hwmon2/pwm1=40
      MAXTEMP=hwmon2/pwm1=70
      MINSTOP=hwmon2/pwm1=30
      MINSTART=hwmon2/pwm1=60
    '';
  };

  # 确保 lm_sensors 已安装
  environment.systemPackages = with pkgs; [
    lm_sensors
  ];
}
