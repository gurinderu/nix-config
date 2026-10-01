# cloud-vm — a generic x86_64-linux cloud VM (Ubuntu or similar) where nix is
# installed on top of the distro OS. Not NixOS: the OS stays the provider's
# image, and only the user environment is ours, via standalone home-manager.
#
#   home-manager switch --flake .#cloud-vm
{
  inputs,
  nixpkgs,
  home-manager,
}:

home-manager.lib.homeManagerConfiguration {
  pkgs = import nixpkgs {
    system = "x86_64-linux";
    config.allowUnfree = true;
  };
  extraSpecialArgs = { inherit inputs; };
  modules = [ ./home.nix ];
}
