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
      helper,
      ...
    }@inputs:
    helper.lib.go.helper inputs ./. {
      pname = "wifidog";
      version = "0.0.1";
      devPackages = pkgs: [ pkgs.zig ];
    };
}
