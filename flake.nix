{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-20.09";
    nixpkgsUnstable.url = "nixpkgs/nixos-unstable";
    nixpkgsOld.url = "nixpkgs/4fe23ed6cae572b295d0595ad4a4b39021a1468a";
    nixpkgsOld.flake = false;
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, ... }@inp: 
    with inp.nixpkgs.lib;
    let
    
      nixPortableForSystem = { system, crossSystem ? null,  }:
        let
          # libcap static is broken on recent nixpkgs,
          # therefore basing bwrap static off of older nixpkgs
          # bwrap with musl requires a recent fix in musl, see:
          # https://github.com/flathub/org.signal.Signal/issues/129
          # https://github.com/containers/bubblewrap/issues/387
          pkgsBwrapStatic = import inp.nixpkgsOld {
            inherit system crossSystem;
            overlays = [(curr: prev: {
              musl = pkgsUnstableCached.musl;
              bwrap = pkgsBwrapStatic.pkgsStatic.bubblewrap.overrideAttrs (_:{
                # TODO: enable priv mode setuid to improve compatibility
                configureFlags = _.configureFlags ++ [
                  # "--with-priv-mode=setuid"
                ];
              });
            })];
          };
          pkgs = import inp.nixpkgs { inherit system crossSystem; };
          pkgsCached = if crossSystem == null then pkgs else import inp.nixpkgs { system = crossSystem; };
          pkgsUnstableCached = if crossSystem == null then pkgs else import inp.nixpkgsUnstable { system = crossSystem; };
        in
          pkgs.callPackage ./default.nix rec {

            inherit pkgs;

            # frankensteined static bubblewrap
            bwrap = pkgsBwrapStatic.pkgsStatic.bwrap;

            nix = pkgsCached.nixFlakes.overrideAttrs (_:{
              patches = [ ./nix-nfs.patch ];
            });

            # the static proot built with nix somehow didn't work on other systems,
            # therefore using the proot static build from proot gitlab
            proot = if crossSystem != null then throw "fix proot for crossSytem" else import ./proot/gitlab.nix { inherit pkgs; };

            busybox = pkgsCached.busybox;
            compression = "xz -1 -T $(nproc)";
            gnutar = pkgs.pkgsStatic.gnutar;
            lib = inp.nixpkgs.lib;
            mkDerivation = pkgs.stdenv.mkDerivation;
            nixpkgsSrc = pkgs.path;
            perl = pkgs.pkgsBuildBuild.perl;
            xz = pkgs.pkgsStatic.xz;
            zstd = pkgs.pkgsStatic.zstd;
          };

  in
    recursiveUpdate
      (inp.flake-utils.lib.eachDefaultSystem (system: rec {
        packages.nix-portable = nixPortableForSystem { inherit system; };
        defaultPackage = packages.nix-portable;
      }))
      { packages = (genAttrs [ "x86_64-linux" ] (system:
          (listToAttrs (map (crossSystem: 
            nameValuePair "nix-portable-${crossSystem}" (nixPortableForSystem { inherit crossSystem system; } )
          ) [ "aarch64-linux" ]))
        ));
      };

      
}