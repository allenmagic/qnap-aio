{ config, lib, ... }:

{
  imports = [
    ./ssh.nix
    ./sops.nix
  ];
}
