{
  description = "QNAP TS-564 一体化网关宿主（NixOS + systemd-nspawn 网关容器）";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    qnap8528.url = "github:allenmagic/qnap8528";
    qnap-kernel.url = "github:allenmagic/qnap-kernel";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    router-container = {
      url = "git+https://github.com/allenmagic/router-container";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, qnap8528, sops-nix, qnap-kernel, ... }@inputs: {
    nixosConfigurations.default = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
      };
      modules = [
        qnap8528.nixosModules.default
        # 定制内核：只替换 boot.kernelPackages 用 nixosModules.kernel
        qnap-kernel.nixosModules.kernel
        sops-nix.nixosModules.sops
        ./configuration.nix
        # Import all module groups
        ./modules/system
        ./modules/hardware
        ./modules/network
        ./modules/gateway
        ./modules/services
        ./modules/security
        ./modules/users
      ];
    };
  };
}
