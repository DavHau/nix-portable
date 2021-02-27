{
  inputs = {
    tb.url = "github:DavHau/nix-toolbox";
    nixpkgs.url = "nixpkgs/nixos-20.09";
    nixpkgsUnstable.url = "nixpkgs/nixos-unstable";
    nixpkgsOld.url = "nixpkgs/4fe23ed6cae572b295d0595ad4a4b39021a1468a";
    nixpkgsOld.flake = false;
    nix.url = "nix";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, ... }@inp: inp.flake-utils.lib.eachDefaultSystem (system: rec {
    packages.nix-portable = import ./default.nix rec {
      nix = inp.nix.defaultPackage."${system}";
      # nix = (import inp.nixpkgsOld { inherit (pkgs) system; }).nix ;
      pkgs = inp.nixpkgs.legacyPackages."${system}";
      pkgsOverlayed = import inp.nixpkgsOld {
        inherit system;
        overlays = [(curr: prev: {
          # libcap = pkgsOld.libcap;
          musl = pkgsUnstable.musl;
        })];
      };
      pkgsUnstable = inp.nixpkgsUnstable.legacyPackages."${system}";
      tb = inp.tb.lib;
    };
    defaultPackage = packages.nix-portable;
  });
}