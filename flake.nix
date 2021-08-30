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
          # user namespaces are disabled on centos 7
          excludeRuntimes = [ "bwrap" ];
        };
        centos8 = {
          url = "https://cloud.centos.org/altarch/8/x86_64/images/CentOS-8-GenericCloud-8.3.2011-20201204.2.x86_64.qcow2";
          sha256 = "7ec97062618dc0a7ebf211864abf63629da1f325578868579ee70c495bed3ba0";
        };
        debian = {
          url = "https://cdimage.debian.org/cdimage/openstack/archive/10.9.0/debian-10.9.0-openstack-amd64.qcow2";
          sha256 = "0mf9k3pgzighibly1sy3cjq7c761r3akp8mlgd878lwf006vqrky";
          # permissions for user namespaces not enabled by default
          excludeRuntimes = [ "bwrap" ];
        };
        nixos = {
          # use iso image for nixos because building a qcow2 would require KVM
          img = (toString (nixosSystem {
            system = "x86_64-linux";
            modules = [(import ./testing/nixos-iso.nix)];
          }).config.system.build.isoImage) + "/iso/nixos.iso";
        };
        ubuntu = {
          url = "https://cloud-images.ubuntu.com/releases/focal/release-20210825/ubuntu-20.04-server-cloudimg-amd64.img";
          sha256 = "0w4s6frx5xf189y5wadsckpkqrayjgfmxi7srqvdj42jmxwrzfwp";
          extraVirtCustomizeCommands = [
            "--copy-in ${./testing/ubuntu}/01-netplan.yaml:/etc/netplan/"
          ];
        };
      };

      commandsToTest = [
        # test git
        ''nix eval --impure --expr 'builtins.fetchGit {url="https://github.com/davhau/nix-portable"; rev="7ebf4ca972c6613983b2698ab7ecda35308e9886";}' ''
        # test importing <nixpkgs> and building hello works
        ''nix build -L --impure --expr '(import <nixpkgs> {}).hello.overrideAttrs(_:{change="_var_";})' ''
        # test running a program from the nix store
        "nix-shell -p hello --run hello"
      ];

      varyCommands = anyStr: forEach commandsToTest (cmd: replaceStrings [ "_var_" ] [ anyStr ] cmd);
    
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
            bashInteractive
            libguestfs-with-appliance
            parallel
            proot
            qemu
          ];
        };
        packages.nix-portable = nixPortableForSystem { inherit system; };
        defaultPackage = packages.nix-portable;
        apps =
          let
            makeQemuPipelines = debug: mapAttrs' (os: img: let
              runtimes = filter (runtime: ! elem runtime (testImages."${os}".excludeRuntimes or []) ) [ "bwrap" "proot" ];
              img =
                if testImages."${os}" ? img then testImages."${os}".img
                else fetchurl { inherit (testImages."${os}") url sha256 ;};
            in
              nameValuePair
                "job-qemu-${os}${optionalString debug "-debug"}"
                {
                  type = "app";
                  program = toString (pkgs.writeScript "job-qemu-${os}" ''
                    #!/usr/bin/env bash
                    set -e

                    if [ -n "$RAND_PORT" ]; then
                      # derive ssh port number from os name, to gain ability to run these jobs in parallel without collision
                      osHash=$((0x"$(echo ${os} | sha256sum | cut -d " " -f 1)")) && [ "$r" -lt 0 ] && ((r *= -1))
                      port=$(( ($osHash % 55535) + 10000 ))
                    else
                      port=10022
                    fi

                    img=${img}
                    pubKey=${./testing}/id_ed25519.pub
                    privKey=${./testing}/id_ed25519
                    nixPortable=${packages.nix-portable}/bin/nix-portable
                    ssh="${pkgs.openssh}/bin/ssh -p $port -i $privKey -o StrictHostKeyChecking=no test@localhost"
                    sshRoot="${pkgs.openssh}/bin/ssh -p $port -i $privKey -o StrictHostKeyChecking=no root@localhost"

                    setup_and_start_vm() {
                      cat $img > /tmp/${os}-img
                      
                      if [ "${os}" != "nixos" ]; then
                        ${pkgs.libguestfs-with-appliance}/bin/virt-customize -a /tmp/${os}-img \
                          --run-command 'useradd test && mkdir -p /home/test && chown test.test /home/test' \
                          --run-command 'ssh-keygen -A' \
                          --ssh-inject test:file:$pubKey \
                          --ssh-inject root:file:$pubKey \
                          ${concatStringsSep " " (testImages."${os}".extraVirtCustomizeCommands or [])} \
                          ${optionalString debug "--root-password file:${pkgs.writeText "pw" "root"}"} \
                          --selinux-relabel
                      fi

                      ${pkgs.qemu}/bin/qemu-kvm \
                        -hda /tmp/${os}-img \
                        -m 1500 \
                        -cpu max \
                        -netdev user,hostfwd=tcp::$port-:22,id=n1 \
                        -device virtio-net-pci,netdev=n1 \
                        ${optionalString (! debug) "-nographic"} \
                        &
                    }

                    # if debug, dont init/run VM if already running
                    ${optionalString debug ''
                      ${pkgs.busybox}/bin/pgrep qemu >/dev/null || \
                    ''}
                      setup_and_start_vm

                    while ! $ssh -o ConnectTimeout=2 true 2>/dev/null ; do
                      echo "waiting for ssh"
                      sleep 1
                    done

                    # upload the nix-portable executable
                    ${pkgs.openssh}/bin/scp -P $port -i $privKey -o StrictHostKeyChecking=no ${packages.nix-portable}/bin/nix-portable test@localhost:/home/test/nix-portable


                    echo -e "\n\nstarting to test nix-portable"

                    # test some nix commands
                    NP_DEBUG=''${NP_DEBUG:-1}
                    ${concatStringsSep "\n\n" (forEach runtimes (runtime:
                      concatStringsSep "\n" (map (cmd:
                        ''$ssh "NP_RUNTIME=${runtime} NP_DEBUG=$NP_DEBUG NP_MINIMAL=$NP_MINIMAL /home/test/nix-portable ${replaceStrings [''"''] [''\"''] cmd} " ''
                      ) (varyCommands runtime))
                    ))}

                    echo "all tests succeeded"
                  '');
                }
            ) testImages;
        in
          # generate jobs with and without debug settings
          makeQemuPipelines true // makeQemuPipelines false
          # add 
          // {
            job-qemu-all.type = "app";
            job-qemu-all.program = let
              jobs = (mapAttrsToList (n: v: v.program) (filterAttrs (n: v: 
                hasPrefix "job-qemu" n && ! hasSuffix "debug" n && ! hasSuffix "all" n
              ) apps));
            in
              toString (pkgs.writeScript "job-docker-debian" ''
                #!/usr/bin/env bash
                RAND_PORT=y ${pkgs.parallel}/bin/parallel bash ::: ${toString jobs}
              '');
            job-docker-debian.type = "app";
            job-docker-debian.program = toString (pkgs.writeScript "job-docker-debian" ''
              #!/usr/bin/env bash
              set -e
              DOCKER_CMD="''${DOCKER_CMD:-docker}"
              export NP_DEBUG=''${NP_DEBUG:-1}
              baseCmd="\
                $DOCKER_CMD run -i --rm \
                  -v ${packages.nix-portable}/bin/nix-portable:/nix-portable \
                  -e NP_DEBUG \
                  -e NP_MINIMAL"
              ${concatStringsSep "\n" (map (cmd: "$baseCmd debian /nix-portable ${cmd}") commandsToTest)}
              echo "all tests succeeded"
            '');
            job-docker-debian-debug.type = "app";
            job-docker-debian-debug.program = toString (pkgs.writeScript "job-docker-debian-debug" ''
              #!/usr/bin/env bash
              set -e
              DOCKER_CMD="''${DOCKER_CMD:-docker}"
              export NP_DEBUG=${NP_DEBUG:-1}
              baseCmd="\
                $DOCKER_CMD run -i --rm \
                  -v ${packages.nix-portable}/bin/nix-portable:/nix-portable \
                  -e NP_DEBUG \
                  -e NP_MINIMAL"
              if [ -n "$1" ]; then
                $baseCmd -it debian $1
              else
                ${concatStringsSep "\n" (map (cmd: "$baseCmd -it debian /nix-portable ${cmd}") commandsToTest)}
              fi
              echo "all tests succeeded"
            '');
            job-local.type = "app";
            job-local.program = toString (pkgs.writeScript "job-local" ''
              #!/usr/bin/env bash
              set -e
              export NP_DEBUG=''${NP_DEBUG:-1}
              ${concatStringsSep "\n\n" (forEach [ "bwrap" "proot" ] (runtime:
                concatStringsSep "\n" (map (cmd:
                  ''${packages.nix-portable}/bin/nix-portable ${cmd}''
                ) commandsToTest)
              ))}
              echo "all tests succeeded"
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