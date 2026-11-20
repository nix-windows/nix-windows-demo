{
  description = "Windows VM tooling for testing Nix on Windows";

  inputs = {
    nix.url = "github:nix-windows/nix/windows-demo-1";
    nixpkgs.follows = "nix/nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      nix,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        # The ValidationOS image, and the images made from it, are the
        # only unfree things needed, so allow just them, rather than
        # needing `NIXPKGS_ALLOW_UNFREE=1` and `--impure`.
        config.allowUnfreePredicate =
          pkg:
          let
            name = pkg.name or "";
          in
          nixpkgs.lib.hasSuffix "_VALIDATIONOS.iso" name
          || builtins.elem name [
            "ValidationOS.vhdx"
            "nix-windows"
          ];
      };

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

      # The Windows VM runs record their log whether or not they succeed;
      # check that it has a line matching `pattern` (the lines end in CRLF,
      # coming from Windows).
      checkLog =
        name: log: pattern:
        pkgs.runCommand name { } ''
          if tr -d '\r' < ${log} | grep -qE '${pattern}'; then
            touch $out
          else
            cat ${log}
            exit 1
          fi
        '';

      # Run one of Nix's unit test suites in ValidationOS, with the test
      # data from Nix's source.
      unitTestCheck =
        name: srcDir:
        checkLog "${name}-windows-check" (win.nixWindowsUnitTest {
          tests = nix.packages.${system}."${name}-x86_64-w64-mingw32";
          data = "${nix}/src/${srcDir}/data";
          extraDlls = [ stub-shell32 ];
        }) "^EXIT=0$";
    in
    {
      packages.${system} = {
        default = win.nixWindowsImage nixArgs;
        inherit stub-shell32;
        nixWindowsTest = win.nixWindowsTest nixArgs;
      };

      checks.${system} = {
        inherit stub-shell32;

        nixWindowsTest =
          checkLog "nix-windows-test-check" (win.nixWindowsTest nixArgs)
            "^OUT=.*[0-9a-z]{32}-hello$";

        nixUtilTests = unitTestCheck "nix-util-tests" "libutil-tests";
        nixStoreTests = unitTestCheck "nix-store-tests" "libstore-tests";
      };

      lib = {
        inherit win stub-shell32;
      };
    };
}
