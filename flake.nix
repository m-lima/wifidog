{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
    gomod2nix = {
      url = "github:nix-community/gomod2nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    helper.url = "github:m-lima/nix-template";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "flake-utils/systems";
      };
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      helper,
      zig,
      ...
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        go = helper.lib.go.helper inputs system ./go {
          pname = "wifidog";
          version = "0.0.1";

          formatters = {
            zig.enable = true;
          };
          fmtExcludes = [
            ".zig-cache/*"
            "zig-build/*"
          ];
        };

        zigPkg = zig.packages.${system}.default;
        zigSrc =
          let
            fs = lib.fileset;
          in
          fs.toSource {
            root = ./zig;
            fileset = fs.intersection (fs.fromSource (lib.sources.cleanSource ./zig)) (
              fs.unions [
                ./zig/src
                ./zig/build.zig
                ./zig/build.zig.zon
              ]
            );
          };
      in
      go
      // {
        packages = {
          go = go.packages.default;
          zig = pkgs.stdenv.mkDerivation {
            pname = "wifidog";
            version = "0.0.1";

            src = zigSrc;

            nativeBuildInputs = [ zigPkg ];

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
        };
        checks = (builtins.removeAttrs go.checks [ "lint" ]) // {
          goLint = go.checks.lint // {
            name = "go-lint";
          };

          zigTest = pkgs.stdenv.mkDerivation {
            name = "test";

            src = zigSrc;

            nativeBuildInputs = [ zigPkg ];

            dontBuild = true;
            doCheck = true;

            configurePhase = ''
              runHook preConfigure
              export ZIG_GLOBAL_CACHE_DIR=$TEMP/.cache
              runHook postConfigure
            '';

            buildPhase = ''
              runHook preBuild
              zig build test --color off
              runHook postBuild
            '';

            installPhase = "mkdir $out";
          };
        };
      }
    );
}
