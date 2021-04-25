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

      # Linux distro images to test nix-portable against
      # After adding a new system, don't forget to add the name also in ./.github/workflows
      testImages = {
        arch = {
          url = "https://gitlab.archlinux.org/archlinux/arch-boxes/-/jobs/20342/artifacts/raw/output/Arch-Linux-x86_64-basic-20210420.20342.qcow2";
          sha256 = "b59f7218df206b135a0cd9a288e79e35cf892bca0c71373588d0d10b029d50a4";
          extraVirtCustomizeCommands = [
            "--run-command 'systemctl disable pacman-init'"
            "--run-command 'systemctl disable reflector-init'"
          ];
        };
        centos7 = {
          url = "https://cloud.centos.org/altarch/7/images/CentOS-7-x86_64-GenericCloud-2009.qcow2c";
          sha256 = "09wqzlhb858qm548ak4jj4adchxn7rgf5fq778hrc52rjqym393v";
        };
        centos8 = {
          url = "https://cloud.centos.org/altarch/8/x86_64/images/CentOS-8-GenericCloud-8.3.2011-20201204.2.x86_64.qcow2";
          sha256 = "7ec97062618dc0a7ebf211864abf63629da1f325578868579ee70c495bed3ba0";
        };
        debian = {
          url = "https://cdimage.debian.org/cdimage/openstack/archive/10.9.0/debian-10.9.0-openstack-amd64.qcow2";
          sha256 = "0mf9k3pgzighibly1sy3cjq7c761r3akp8mlgd878lwf006vqrky";
        };
        ubuntu = {
          url = "https://cloud-images.ubuntu.com/focal/20210415/focal-server-cloudimg-amd64.img";
          sha256 = "38b82727bfc1b36d9784bf07b8368c1d777450e978837e1cd7fa32b31837e77c";
          extraVirtCustomizeCommands = [
            "--copy-in ${./testing/ubuntu}/01-netplan.yaml:/etc/netplan/"
          ];
        };
      };

      commandsToTest = [
        "nix --version"
        "nix-shell -p hello --run hello"
        "nix build --impure --expr '(import <nixpkgs> {}).hello.overrideAttrs(_:{change=1;})'"
      ];
    
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
            bashInteractive
          ];
        };
        packages.nix-portable = nixPortableForSystem { inherit system; };
        defaultPackage = packages.nix-portable;
        apps =
          let
            makeQemuPipelines = debug: mapAttrs' (os: img:
              nameValuePair
                "pipeline-qemu-${os}${optionalString debug "-debug"}"
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

                    cat $img > /tmp/img

                    ${pkgs.libguestfs-with-appliance}/bin/virt-customize -a /tmp/img \
                      --run-command 'useradd test && mkdir -p /home/test && chown test.test /home/test' \
                      --run-command 'ssh-keygen -A' \
                      --ssh-inject test:file:$pubKey \
                      --copy-in $nixPortable:/ \
                      ${concatStringsSep " " (testImages."${os}".extraVirtCustomizeCommands or [])} \
                      ${optionalString debug "--root-password file:${pkgs.writeText "pw" "root"}"} \
                      --selinux-relabel

                    ${pkgs.qemu}/bin/qemu-system-x86_64 \
                      -hda /tmp/img \
                      -m 2048 \
                      -netdev user,hostfwd=tcp::10022-:22,id=n1 \
                      -device virtio-net-pci,netdev=n1 \
                      ${optionalString (! debug) "-nographic"} \
                      &

                    while ! $ssh -o ConnectTimeout=2 true 2>/dev/null ; do
                      echo "waiting for ssh"
                      sleep 1
                    done

                    echo -e "\n\nstarting to test nix-portable"

                    # test some nix commands
                    ${concatStringsSep "\n" (map (cmd: "$ssh ${cmd}") commandsToTest)}

                    echo "all tests succeeded"
                  '');
                }
            ) testImages;
        in
          # generate pipelines with and without debug settings
          makeQemuPipelines true // makeQemuPipelines false
          // {
            pipeline-docker-debian.type = "app";
            pipeline-docker-debian.program = toString (pkgs.writeScript "pipeline-docker-debian" ''
              #!/usr/bin/env bash

              DOCKER_CMD="''${DOCKER_CMD:-docker run}"

              baseCmd="\
                $DOCKER_CMD run -it --rm \
                  -v ${packages.nix-portable}/bin/nix-portable:/nix-portable \
                  -e "NP_MINIMAL=1" \
                  -e "NP_DEBUG=1" \
                  debian /nix-portable"
              
              ${concatStringsSep "\n" (map (cmd: "$baseCmd ${cmd}") commandsToTest)}
            '');
          };
      }))
      { packages = (genAttrs [ "x86_64-linux" ] (system:
          (listToAttrs (map (crossSystem: 
            nameValuePair "nix-portable-${crossSystem}" (nixPortableForSystem { inherit crossSystem system; } )
          ) [ "aarch64-linux" ]))
        ));
      };

      
}