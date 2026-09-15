{ config, lib, ... }:

{
  imports = [
    ./fancontrol.nix
    ./sensors.nix
  ];
}
