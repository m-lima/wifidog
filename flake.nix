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
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        treefmt =
          (treefmt-nix.lib.evalModule pkgs {
            projectRootFile = "flake.nix";
            programs = {
              nixfmt.enable = true;
              gofumpt.enable = true;
              goimports.enable = true;
              golangci-lint.enable = true;
            };
            settings = {
              excludes = [
                "*.lock"
                ".direnv/*"
                ".envrc"
                ".gitignore"
                "LICENSE"
                "result*/*"
              ];
            };
          }).config.build;
      in
      {
        formatter = treefmt.wrapper;
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.go
            pkgs.gopls
            pkgs.gofumpt
            pkgs.golangci-lint-langserver
            pkgs.golangci-lint
          ];
        };
      }
    );
}
