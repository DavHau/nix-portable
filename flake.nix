{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-20.09";
    nixpkgsUnstable.url = "nixpkgs/nixos-unstable";
    nixpkgsOld.url = "nixpkgs/4fe23ed6cae572b295d0595ad4a4b39021a1468a";
    nixpkgsOld.flake = false;
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, ... }@inp:
    with builtins;
    with inp.nixpkgs.lib;
    let

      testImages = {
        centos = {
          url = "https://cloud.centos.org/altarch/7/images/CentOS-7-x86_64-GenericCloud-2009.qcow2c";
          sha256 = "09wqzlhb858qm548ak4jj4adchxn7rgf5fq778hrc52rjqym393v";
        };
        debian = {
          url = "https://cdimage.debian.org/cdimage/openstack/archive/10.9.0/debian-10.9.0-openstack-amd64.qcow2";
          sha256 = "0mf9k3pgzighibly1sy3cjq7c761r3akp8mlgd878lwf006vqrky";
        };
        arch = {
          # from https://gitlab.archlinux.org/archlinux/arch-boxes/-/jobs/artifacts/master/browse/output?job=build:secure
          url = "https://gitlab.archlinux.org/archlinux/arch-boxes/-/jobs/20342/artifacts/raw/output/Arch-Linux-x86_64-cloudimg-20210420.20342.qcow2";
          sha256 = "794410309266af9f6da4b3c92f4fc37b744d51916dbe1f6f35b1842866193ebc";
        };
      };
    
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

            busybox = pkgs.pkgsStatic.busybox;
            compression = "zstd -18 -T0";
            gnutar = pkgs.pkgsStatic.gnutar;
            lib = inp.nixpkgs.lib;
            mkDerivation = pkgs.stdenv.mkDerivation;
            nixpkgsSrc = pkgs.path;
            perl = pkgs.pkgsBuildBuild.perl;
            xz = pkgs.pkgsStatic.xz;
            zstd = pkgs.pkgsStatic.zstd;
          };
      
      prepareCloudImage = pkgs: qcowImg: pkgs.runCommand "img-with-ssh" {} ''
        ${pkgs.libguestfs-with-appliance}/virt-sysprep --version exit 1
      '';

  in
    recursiveUpdate
      (inp.flake-utils.lib.eachDefaultSystem (system: let pkgs = inp.nixpkgs.legacyPackages."${system}"; in rec {
        devShell = pkgs.mkShell {
          buildInputs = with pkgs; [
            libguestfs-with-appliance
            qemu
          ];
        };
        packages.nix-portable = nixPortableForSystem { inherit system; };
        packages.test = let
            nixPortable = nixPortableForSystem { inherit system; };
            pkgs = inp.nixpkgs.legacyPackages."${system}"; in
          runCommand
            "test"
            {
              buildInputs = with pkgs; [ qemu ];
            }
            ''
              qemu-system-x86_64 -hda CentOS-7-x86_64-GenericCloud-2003.qcow2 -m 2048 -net nic -net user -cpu max
            '';
        defaultPackage = packages.nix-portable;
        apps = mapAttrs' (os: img:
          nameValuePair
            "pipeline-qemu-${os}"
            {
              type = "app";
              program = toString (pkgs.writeScript "pipeline-qemu-${os}" ''
                #!/usr/bin/env bash
                set -e

                img=${fetchurl { inherit (testImages."${os}") url sha256 ;}}
                pubKey=${./testing/id_ed25519.pub}
                privKey=${./testing/id_ed25519}
                nixPortable=${packages.nix-portable}/bin/nix-portable
                ssh="${pkgs.openssh}/bin/ssh -p 10022 -i $privKey -o StrictHostKeyChecking=no test@localhost"

                cat $img > ./img

                ${pkgs.libguestfs-with-appliance}/bin/virt-customize -a ./img \
                  --run-command 'useradd test && mkdir -p /home/test && chown test.test /home/test' \
                  --ssh-inject test:file:$pubKey \
                  --copy-in $nixPortable:/ \
                  --selinux-relabel

                ${pkgs.qemu}/bin/qemu-system-x86_64 -hda ./img -m 2048 -net user,hostfwd=tcp::10022-:22 -net nic -nographic &

                while ! $ssh -o ConnectTimeout=2 true 2>/dev/null ; do
                  echo "waiting for ssh"
                  sleep 1
                done

                echo -e "\n\nstarting to test nix-portable"

                succ=false
                $ssh NP_DEBUG=1 NP_MINIMAL=1 /nix-portable nix --version && succ=true

                $succ || echo "test failed"
                exit $succ
              '');
            }
        ) testImages;  
      }))
      { packages = (genAttrs [ "x86_64-linux" ] (system:
          (listToAttrs (map (crossSystem: 
            nameValuePair "nix-portable-${crossSystem}" (nixPortableForSystem { inherit crossSystem system; } )
          ) [ "aarch64-linux" ]))
        ));
      };

      
}