{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.zls

            pkgs.pkg-config
            pkgs.clang

            pkgs.luajit
            pkgs.lua-language-server
            pkgs.git
            pkgs.ripgrep
            pkgs.fd
            pkgs.curl
          ];
        };
      }
    );
}
