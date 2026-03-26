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
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      zig,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        zigPkg = zig.packages.${system}.default;

        fmtConfig = {
          projectRootFile = "flake.nix";
          programs = {
            nixfmt.enable = true;
            yamlfmt.enable = true;
            zig.enable = true;
          };
          settings = {
            on-unmatched = "warn";
            excludes = [
              "**/.direnv/*"
              "**/.envrc"
              "**/.gitignore"
              "*.lock"
              ".direnv/*"
              ".envrc"
              ".git-crypt/*"
              ".gitattributes"
              ".gitignore"
              ".zig-cache/*"
              "LICENSE"
              "result*/*"
              "zig-build/*"
            ];
          };

        };

        treefmt = (treefmt-nix.lib.evalModule pkgs fmtConfig).config.build;
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
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "wifidog";
          version = "0.0.1";

          inherit src;

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

        checks = {
          formatting = treefmt.check self;
          test = pkgs.stdenv.mkDerivation {
            name = "test";

            inherit src;

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

        formatter = treefmt.wrapper;

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            zigPkg
            pkgs.zls
            # pkgs.zig-zlint
          ];
        };
      }
    );
}
