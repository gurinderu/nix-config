{
  inputs,
  nixpkgs,
  home-manager,
}:

nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = { inherit inputs; };
  modules = [
    ./configuration.nix
    inputs.sops-nix.nixosModules.sops
    home-manager.nixosModules.home-manager
  ];
}
