{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    nix.url = "nix";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, ... }@inp: inp.flake-utils.lib.eachDefaultSystem (system: rec {
    packages.nix-portable = import ./default.nix {
      nix = inp.nix.defaultPackage."${system}";
      pkgs = inp.nixpkgs.legacyPackages."${system}";
    };
    defaultPackage = packages.nix-portable;
  });
}