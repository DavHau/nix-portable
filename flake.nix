{
  inputs = {

    nixpkgs.follows = "defaultChannel";

    # the nixpkgs version shipped with the nix-portable executable
    # TODO: find out why updating this leads to error when building pkgs.hello:
    # Error: checking whether build environment is sane... ls: cannot access './configure': No such file or directory
    defaultChannel.url = "nixpkgs/nixos-unstable";

    nix.url = "nix/2.20.6";

    nix-github-actions.url = "github:nix-community/nix-github-actions";
    nix-github-actions.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nix-github-actions, ... }@inp:
    with builtins;
    with inp.nixpkgs.lib;
    let

      lib = inp.nixpkgs.lib;

      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      forAllSystems = f: genAttrs supportedSystems
        (system: f system (import inp.nixpkgs { inherit system; }));

      nixPortableForSystem = { system, crossSystem ? null,  } @ args:
        let
          pkgsDefaultChannel = import inp.defaultChannel { inherit system crossSystem; };
          pkgs = import inp.nixpkgs { inherit system crossSystem; };

          # the static proot built with nix somehow didn't work on other systems,
          # therefore using the proot static build from proot gitlab
          proot = import ./proot/alpine.nix { inherit pkgs; };
        in
          # crashes if nixpkgs updated: error: executing 'git': No such file or directory
          pkgs.callPackage ./default.nix {

            inherit proot;

            pkgs = pkgsDefaultChannel;

            lib = inp.nixpkgs.lib;
            compression = "zstd -3 -T1";

            nix = inp.nix.packages.${pkgs.stdenv.buildPlatform.system}.nix;
            nixStatic = inp.nix.packages.${pkgs.stdenv.buildPlatform.system}.nix-static;

            busybox = pkgs.pkgsStatic.busybox;
            bwrap = pkgs.pkgsStatic.bubblewrap;
            gnutar = pkgs.pkgsStatic.gnutar;
            perl = pkgs.pkgsBuildBuild.perl;
            xz = pkgs.pkgsStatic.xz;
            zstd = pkgs.pkgsStatic.zstd;
          };
  in
    recursiveUpdate
      ({

        bundlers = forAllSystems (system: pkgs: {
          # bundle with fast compression by default
          default = self.bundlers.${system}.zstd-fast;
          zstd-fast = drv: self.packages.${system}.nix-portable.override {
            bundledPackage = drv;
            compression = "zstd -3 -T0";
          };
          zstd-max = drv: self.packages.${system}.nix-portable.override {
            bundledPackage = drv;
            compression = "zstd -19 -T0";
          };
        });

        devShell = forAllSystems (system: pkgs:
          pkgs.mkShell {
            buildInputs = with pkgs; [
              bashInteractive
              guestfs-tools
              parallel
              proot
              qemu
            ];
          }
        );

        apps = forAllSystems (system: pkgs: {
          test-local.type = "app";
          test-local.program = toString (pkgs.writeScript "test-local" ''
            #!/usr/bin/env bash
            set -e
            export NP_DEBUG=''${NP_DEBUG:-1}
            ${concatStringsSep "\n\n" (forEach [ "bwrap" "proot" ] (runtime:
              concatStringsSep "\n" (map (cmd:
                ''${self.packages."${system}".nix-portable}/bin/nix-portable ${cmd}''
              ) (import ./testing/test-commands.nix))
            ))}
            echo "all tests succeeded"
          '');
        });

        checks =
          lib.recursiveUpdate
          (forAllSystems (system: pkgs:
            pkgs.callPackages ./testing/vm-tests.nix {inherit (self.packages.${system}) nix-portable;}
          ))
          # github doesn't have KVM in aarch64 runners. -> run aarch64 vm tests on x86_64
          {
            x86_64-linux =
              let
                system = "x86_64-linux";
                crossSystem = "aarch64-linux";
                pkgs = import inp.nixpkgs { inherit system crossSystem; };
              in
              lib.mapAttrs'
              (name: drv: {name = name + "-aarch64-linux"; value = drv;})
              (pkgs.callPackages ./testing/vm-tests.nix {
                nix-portable = self.packages.${crossSystem}.nix-portable;
                pkgsNative = inp.nixpkgs.legacyPackages.${crossSystem};
              });
          };

        packages = forAllSystems (system: pkgs: {
          default = self.packages.${system}.nix-portable;
          nix-portable = (nixPortableForSystem { inherit system; }).override {
            # all non x86_64-linux systems are built via emulation
            #   -> decrease compression level to reduce CI build time
            compression =
              if system == "x86_64-linux"
              then "zstd -19 -T0"
              else "zstd -9 -T0";
          };
          # dev version that builds faster
          nix-portable-dev = self.packages.${system}.nix-portable.override {
            compression = "zstd -3 -T1";
          };
          release = pkgs.runCommand "all-nix-portable-release-files" {} ''
            mkdir $out
            cp ${self.packages.x86_64-linux.nix-portable}/bin/nix-portable $out/nix-portable-x86_64
            cp ${self.packages.aarch64-linux.nix-portable}/bin/nix-portable $out/nix-portable-aarch64
          '';
          qemu-efi-aarch64 = pkgs.callPackage ./testing/qemu-efi.nix {};
        });
      })
      { packages = (genAttrs [ "x86_64-linux" ] (system:
          (listToAttrs (map (crossSystem:
            nameValuePair "nix-portable-${crossSystem}" (nixPortableForSystem { inherit crossSystem system; } )
          ) [ "aarch64-linux" ]))
        ));

        githubActions = nix-github-actions.lib.mkGithubMatrix {
          checks =
            lib.getAttrs
              [ "x86_64-linux" ]
              self.checks;
        };
      };
}
