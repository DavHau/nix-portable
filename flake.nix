{
  inputs = {

    nixpkgs.url = "nixpkgs/nixos-21.11";

    nix.url = "nix/2.5.1";
    nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, ... }@inp:
    with builtins;
    with inp.nixpkgs.lib;
    let

      lib = inp.nixpkgs.lib;

      supportedSystems = [ "x86_64-linux" "aarch64-linux" "armv7l-linux" ];

      forAllSystems = f: genAttrs supportedSystems
        (system: f system (import inp.nixpkgs { inherit system; }));

      # Linux distro images to test nix-portable against
      # After adding a new system, don't forget to add the name also in ./.github/workflows
      testImages = {
        arch = {
          system = "x86_64-linux";
          url = "https://mirror.pkgbuild.com/images/v20211201.40458/Arch-Linux-x86_64-basic-20211201.40458.qcow2";
          sha256 = "0xxhb92rn2kskq9pvfmbf9h6fy75x4czl58rfq5969kbbb49yn19";
          extraVirtCustomizeCommands = [
            "--run-command 'systemctl disable pacman-init'"
            "--run-command 'systemctl disable reflector-init'"
          ];
        };
        centos7 = {
          system = "x86_64-linux";
          url = "https://cloud.centos.org/altarch/7/images/CentOS-7-x86_64-GenericCloud-2009.qcow2c";
          sha256 = "09wqzlhb858qm548ak4jj4adchxn7rgf5fq778hrc52rjqym393v";
          # user namespaces are disabled on centos 7
          excludeRuntimes = [ "bwrap" ];
        };
        centos8 = {
          system = "x86_64-linux";
          url = "https://cloud.centos.org/altarch/8/x86_64/images/CentOS-8-GenericCloud-8.3.2011-20201204.2.x86_64.qcow2";
          sha256 = "7ec97062618dc0a7ebf211864abf63629da1f325578868579ee70c495bed3ba0";
        };
        debian = {
          system = "x86_64-linux";
          url = "https://cdimage.debian.org/cdimage/openstack/archive/10.9.0/debian-10.9.0-openstack-amd64.qcow2";
          sha256 = "0mf9k3pgzighibly1sy3cjq7c761r3akp8mlgd878lwf006vqrky";
          # permissions for user namespaces not enabled by default
          excludeRuntimes = [ "bwrap" ];
        };
        nixos = {
          system = "x86_64-linux";
          # use iso image for nixos because building a qcow2 would require KVM
          img = (toString (nixosSystem {
            system = "x86_64-linux";
            modules = [(import ./testing/nixos-iso.nix)];
          }).config.system.build.isoImage) + "/iso/nixos.iso";
        };
        ubuntu = {
          system = "x86_64-linux";
          url = "https://cloud-images.ubuntu.com/releases/focal/release-20220118/ubuntu-20.04-server-cloudimg-amd64.img";
          sha256 = "05p2qbmp6sbykm1iszb2zvbwbnydqg6pdrplj9z56v3cr964s9p1";
          extraVirtCustomizeCommands = [
            "--copy-in ${./testing/ubuntu}/01-netplan.yaml:/etc/netplan/"
          ];
        };

        # aarch64 tests
        nixos-aarch64 = {
          system = "aarch64-linux";
          # use iso image for nixos because building a qcow2 would require KVM
          img = (toString (nixosSystem {
            system = "aarch64-linux";
            modules = [(import ./testing/nixos-iso.nix)];
          }).config.system.build.isoImage) + "/iso/nixos.iso";
        };
        debian-aarch64 = {
          system = "aarch64-linux";
          url = "https://cdimage.debian.org/cdimage/openstack/archive/10.9.0/debian-10.9.0-openstack-arm64.qcow2";
          sha256 = "0mz868j1k8jwhgg9a21dv7dr4rsy1bhklbqqw3qig06acy0vg8yi";
          # permissions for user namespaces not enabled by default
          excludeRuntimes = [ "bwrap" ];
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
          pkgsCached = if crossSystem == null then pkgs else import inp.nixpkgs { system = crossSystem; };

          # the static proot built with nix somehow didn't work on other systems,
          # therefore using the proot static build from proot gitlab
          proot = if crossSystem != null then throw "fix proot for crossSytem" else import ./proot/github.nix { inherit pkgs; };
        in
          # crashes if nixpkgs updated: error: executing 'git': No such file or directory
          pkgs.callPackage ./default.nix {

            inherit proot pkgs;

            lib = inp.nixpkgs.lib;
            compression = "zstd -18 -T0";

            nix = inp.nix.packages."${system}".nix;

            busybox = pkgs.pkgsStatic.busybox;
            bwrap = pkgs.pkgsStatic.bubblewrap;
            gnutar = pkgs.pkgsStatic.gnutar;
            perl = pkgs.pkgsBuildBuild.perl;
            xz = pkgs.pkgsStatic.xz;
            zstd = pkgs.pkgsStatic.zstd;

            # tar crashed on emulated aarch64 system
            buildSystem = "x86_64-linux";
          };

  in
    recursiveUpdate
      ({

        devShell = forAllSystems (system: pkgs:
          pkgs.mkShell {
            buildInputs = with pkgs; [
              bashInteractive
              libguestfs-with-appliance
              parallel
              proot
              qemu
            ];
          }
        );

        packages = forAllSystems (system: pkgs: {
          nix-portable = nixPortableForSystem { inherit system; };
        });

        defaultPackage = forAllSystems (system: pkgs:
          self.packages."${system}".nix-portable
        );

        apps = forAllSystems (system: pkgs:
          let
            makeQemuPipelines = debug: mapAttrs' (os: img: let
              runtimes = filter (runtime: ! elem runtime (testImages."${os}".excludeRuntimes or []) ) [ "bwrap" "proot" ];
              img =
                if testImages."${os}" ? img then testImages."${os}".img
                else fetchurl { inherit (testImages."${os}") url sha256 ;};
              system = testImages."${os}".system;
              qemu-bin =
                if pkgs.buildPlatform.system == system then
                  "qemu-kvm"
                else
                  "qemu-system-${lib.head (lib.splitString "-" system)}";
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
                    nixPortable=${self.packages."${system}".nix-portable}/bin/nix-portable
                    ssh="${pkgs.openssh}/bin/ssh -p $port -i $privKey -o StrictHostKeyChecking=no test@localhost"
                    sshRoot="${pkgs.openssh}/bin/ssh -p $port -i $privKey -o StrictHostKeyChecking=no root@localhost"
                    scp="${pkgs.openssh}/bin/scp -P $port -i $privKey -o StrictHostKeyChecking=no"

                    setup_and_start_vm() {
                      cat $img > /tmp/${os}-img

                      if [[ "${os}" != nixos* ]]; then
                        ${pkgs.libguestfs-with-appliance}/bin/virt-customize -a /tmp/${os}-img \
                          --firstboot ${pkgs.writeScript "firstboot" "#!/usr/bin/env bash \nuseradd test && mkdir -p /home/test && chown test.test /home/test; ssh-keygen -A"} \
                          --ssh-inject root:file:$pubKey \
                          ${concatStringsSep " " (testImages."${os}".extraVirtCustomizeCommands or [])} \
                          ${optionalString debug "--root-password file:${pkgs.writeText "pw" "root"}"} \
                          --selinux-relabel
                      fi

                      cp ${pkgs.callPackage ./testing/qemu-efi.nix {}} ./QEMU_EFI.img
                      chmod +w ./QEMU_EFI.img

                      ${pkgs.qemu}/bin/${qemu-bin} \
                        -drive file=/tmp/${os}-img \
                        -cpu max \
                        -smp 2 \
                        -m 4000 \
                        -netdev user,hostfwd=tcp::$port-:22,id=n1 \
                        -device virtio-net-pci,netdev=n1 \
                        ${optionalString (! debug) "-nographic"} \
                        ${optionalString (system == "aarch64-linux")
                          "-cpu cortex-a53 -machine virt -drive if=pflash,format=raw,file=./QEMU_EFI.img"} \
                        &
                    }

                    # if debug, dont init/run VM if already running
                    ${optionalString debug ''
                      ${pkgs.busybox}/bin/pgrep qemu >/dev/null || \
                    ''}
                      setup_and_start_vm

                    while ! $sshRoot -o ConnectTimeout=2 true 2>/dev/null ; do
                      echo "waiting for ssh"
                      sleep 1
                    done

                    echo -e "\n\nsetting up machine via ssh"
                    $sshRoot mkdir -p /np_tmp
                    $sshRoot "test -e /np_tmp/.nix-portable || mount -t tmpfs -o size=3g /bin/true /np_tmp"
                    $sshRoot mkdir -p /home/test/.ssh
                    echo "uploading ssh key"
                    $scp ${./testing}/id_ed25519.pub root@localhost:/home/test/.ssh/authorized_keys
                    $sshRoot chown -R test /home/test
                    $sshRoot chmod 600 /home/test/.ssh/authorized_keys
                    echo "finished uploading ssh key"

                    echo "upload the nix-portable executable"
                    $scp ${self.packages."${system}".nix-portable}/bin/nix-portable test@localhost:/home/test/nix-portable
                    $ssh chmod +w /home/test/nix-portable


                    echo -e "\n\nstarting to test nix-portable"

                    # test some nix commands
                    NP_DEBUG=''${NP_DEBUG:-1}
                    ${concatStringsSep "\n\n" (forEach runtimes (runtime:
                      concatStringsSep "\n" (map (cmd:
                        ''$ssh "NP_RUNTIME=${runtime} NP_DEBUG=$NP_DEBUG NP_MINIMAL=$NP_MINIMAL NP_LOCATION=/np_tmp /home/test/nix-portable ${replaceStrings [''"''] [''\"''] cmd} " ''
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
              ) self.apps."${system}"));
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
                  -v ${self.packages."${system}".nix-portable}/bin/nix-portable:/nix-portable \
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
                  -v ${self.packages."${system}".nix-portable}/bin/nix-portable:/nix-portable \
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
                  ''${self.packages."${system}".nix-portable}/bin/nix-portable ${cmd}''
                ) commandsToTest)
              ))}
              echo "all tests succeeded"
            '');
          }
        );
      })
      { packages = (genAttrs [ "x86_64-linux" ] (system:
          (listToAttrs (map (crossSystem:
            nameValuePair "nix-portable-${crossSystem}" (nixPortableForSystem { inherit crossSystem system; } )
          ) [ "aarch64-linux" ]))
        ));
      };


}
