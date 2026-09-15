{ config, lib, ... }:

{
  imports = [
    ./locale.nix
    ./console.nix
    ./packages.nix
    ./nix-settings.nix
  ];
}
