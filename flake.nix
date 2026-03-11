{
  description = "Windows VM tooling for testing Nix on Windows";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    nix.url = "github:puffnfresh/nix/windows-integration";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      qemu-common = import (nixpkgs + "/nixos/lib/qemu-common.nix") {
        inherit (pkgs) lib stdenv;
      };

      win = pkgs.callPackage ./windows {
        inherit qemu-common;
      };

      pkgsCross = pkgs.pkgsCross.mingwW64;

      stub-shell32 = pkgsCross.callPackage ./windows/stub-shell32 { };

      nix-cli = nix.packages.${system}.nix-cli-x86_64-w64-mingw32;

      nixArgs = {
        inherit nix-cli;
        extraDlls = [ stub-shell32 ];
      };
    in
    {
      packages.${system} = {
        default = win.nixWindowsImage nixArgs;
        inherit stub-shell32;
        nixWindowsTest = win.nixWindowsTest nixArgs;
      };

      lib = {
        inherit win stub-shell32;
      };
    };
}
