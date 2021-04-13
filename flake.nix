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
          pkgs = import inp.nixpkgs { inherit system crossSystem; };
          pkgsUnstable = import inp.nixpkgsUnstable { inherit system crossSystem; };
          pkgsCached = if crossSystem == null then pkgs else import inp.nixpkgs { system = crossSystem; };
          pkgsUnstableCached = if crossSystem == null then pkgs else import inp.nixpkgsUnstable { system = crossSystem; };
          
          # the static proot built with nix somehow didn't work on other systems,
          # therefore using the proot static build from proot gitlab
          proot = if crossSystem != null then throw "fix proot for crossSytem" else import ./proot/gitlab.nix { inherit pkgs; };
        in
          pkgs.callPackage ./default.nix rec {

            inherit pkgs proot;

            bwrap = pkgsUnstable.pkgsStatic.bubblewrap;

            nix = pkgs.nixFlakes.overrideAttrs (_:{
              patches = (_.patches or []) ++ [ ./nix-nfs.patch ];
            });

            busybox = pkgsCached.busybox;
            compression = "xz -1 -T $(nproc)";
            gnutar = pkgs.pkgsStatic.gnutar;
            lib = inp.nixpkgs.lib;
            mkDerivation = pkgs.stdenv.mkDerivation;
            nixpkgsSrc = pkgs.path;
            perl = pkgs.pkgsBuildBuild.perl;
            xz = pkgs.pkgsStatic.xz;
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