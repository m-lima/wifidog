{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs = {
        systems.follows = "systems";
      };
    };
    systems.url = "github:nix-systems/default";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      zig,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        zigPkg = zig.packages.${system}.default;
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            zigPkg
            pkgs.zls
          ];
        };
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "wifidog";
          version = "0.0.1";

          src =
            let
              fs = lib.fileset;
            in
            fs.toSource {
              root = ./.;
              fileset = fs.intersection (fs.fromSource (lib.sources.cleanSource ./.)) (
                fs.unions [
                  ./src
                  ./build.zig
                  ./build.zig.zon
                ]
              );
            };

          nativeBuildInputs = [
            zigPkg
          ];

          dontInstall = true;

          configurePhase = ''
            runHook preConfigure
            export ZIG_GLOBAL_CACHE_DIR=$TEMP/.cache
            runHook postConfigure
          '';

          buildPhase = ''
            runHook preBuild
            zig build install --color off --prefix $out
            runHook postBuild
          '';
        };
      }
    );
}
