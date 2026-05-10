{
  description = "Development shell for Zig with ZLS and QEMU";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    utils.url = "github:numtide/flake-utils";
    zigpkg = { url = "github:mitchellh/zig-overlay"; inputs.nixpkgs.follows = "nixpkgs"; };
    zlspkg = { url = "github:zigtools/zls"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  outputs = { self, nixpkgs, zigpkg, zlspkg, utils }:
    utils.lib.eachDefaultSystem(system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zigpkg.packages.${system}."0.16.0";
        zls = zlspkg.packages.${system}.default;

        dev_tools = with pkgs; [
          binutils
          qemu
          just
          gdb
        ];

        package = pkgs.stdenvNoCC.mkDerivation {
          pname = "zeros";
          version = "0.0.0";
          src = self;
          strictDeps = true;
          dontConfigure = true;

          nativeBuildInputs = [
            zig
            pkgs.qemu
          ];
        };

      in {
        packages.default = package;
        checks.default = package;

        devShells.default = pkgs.mkShellNoCC {
          nativeBuildInputs = [ zig ];
          buildInputs = dev_tools;
        };

        devShells.ide = pkgs.mkShellNoCC {
          nativeBuildInputs = [ zig zls ];
          buildInputs = dev_tools;
        };
      });
}
