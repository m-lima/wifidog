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
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      gomod2nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        go2nix = gomod2nix.legacyPackages.${system};
        treefmt =
          (treefmt-nix.lib.evalModule pkgs {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              gofumpt.enable = true;
              goimports.enable = true;
              yamlfmt.enable = true;
            };
            settings = {
              on-unmatched = "warn";
              excludes = [
                "*.lock"
                ".direnv/*"
                ".envrc"
                ".gitignore"
                "LICENSE"
                "result*/*"
                "gomod2nix.toml"
              ];
            };
          }).config.build;
      in
      {
        packages.default = go2nix.buildGoApplication {
          pname = "wifidog";
          version = "0.0.1";
          src = ./.;
          pwd = ./.;
        };
        checks = {
          formatting = treefmt.check self;
          lint = go2nix.buildGoApplication {
            name = "lint";
            src = ./.;
            pwd = ./.;
            dontBuild = true;
            doCheck = true;
            nativeBuildInputs = [
              pkgs.golangci-lint
              pkgs.writableTmpDirAsHomeHook
            ];
            checkPhase = "golangci-lint run";
            installPhase = "mkdir $out";
          };
        };
        formatter = treefmt.wrapper;
        devShells.default = pkgs.mkShell {
          buildInputs = [
            go2nix.gomod2nix
            pkgs.go
            pkgs.gopls
            pkgs.gofumpt
            pkgs.golangci-lint
            pkgs.golangci-lint-langserver
          ];
        };
      }
    );
}
