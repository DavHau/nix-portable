{
  inputs = {
    tb.url = "github:DavHau/nix-toolbox";
    nixpkgs.url = "nixpkgs/nixos-20.09";
    nixpkgsUnstable.url = "nixpkgs/nixos-unstable";
    nixpkgsOld.url = "nixpkgs/4fe23ed6cae572b295d0595ad4a4b39021a1468a";
    nixpkgsOld.flake = false;
    nix.url = "nix/480426a364f09e7992230b32f2941a09fb52d729";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, ... }@inp: inp.flake-utils.lib.eachDefaultSystem (system: rec {
    packages.nix-portable = import ./default.nix rec {
      nix = inp.nix.defaultPackage."${system}";
      
      # nix = (import inp.nixpkgsOld { inherit (pkgs) system; }).nix ;
      pkgs = inp.nixpkgs.legacyPackages."${system}";

      # libcap static is broken on recent nixpkgs,
      # therefore basing bwrap static off of older nixpkgs
      # bwrap with musl requires a recent fix in musl, see:
      # https://github.com/flathub/org.signal.Signal/issues/129
      # https://github.com/containers/bubblewrap/issues/387
      pkgsBwrapStatic = import inp.nixpkgsOld {
        inherit system;
        overlays = [(curr: prev: {
          musl = pkgsUnstable.musl.overrideAttrs (_:{
            version = "1.2.2";
            src = builtins.fetchTarball {
              url = "https://www.musl-libc.org/releases/musl-1.2.2.tar.gz";
              sha256 = "0c1mbadligmi02r180l0qx4ixwrf372zl5mivb1axmjgpd612ylp";
            };
            # CVE-2020-28928 already fixed in this version
            patches = builtins.filter (p: ! pkgs.lib.hasSuffix "CVE-2020-28928.patch" "${p}" ) _.patches;
          });
          bwrap = pkgsBwrapStatic.pkgsStatic.bubblewrap.overrideAttrs (_:{
            # TODO: enable priv mode setuid to improve compatibility
            configureFlags = _.configureFlags ++ [
              # "--with-priv-mode=setuid"
            ];
          });
        })];
      };
      pkgsUnstable = inp.nixpkgsUnstable.legacyPackages."${system}";
      tb = inp.tb.lib;
    };
    defaultPackage = packages.nix-portable;
  });
}