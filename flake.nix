{
  inputs = {

    nixpkgs.follows = "defaultChannel";

    # the nixpkgs version shipped with the nix-portable executable
    # TODO: find out why updating this leads to error when building pkgs.hello:
    # Error: checking whether build environment is sane... ls: cannot access './configure': No such file or directory
    defaultChannel.url = "nixpkgs/nixos-unstable";

    nix.url = "nix/2.20.6";
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
      testImages = rec {
        arch = {
          system = "x86_64-linux";
          url = "https://web.archive.org/web/20230924202157/https://mirror.pkgbuild.com/images/v20230915.178838/Arch-Linux-x86_64-basic.qcow2";
          sha256 = "1aw0vxmv8mzsw8mb8sdchjci5bbchhpfhcld63gfv9lgw6pwh3vi";
          extraVirtCustomizeCommands = [
            "--run-command 'systemctl disable pacman-init'"
          ];
        };
        centos7 = {
          system = "x86_64-linux";
          url = "https://cloud.centos.org/altarch/7/images/CentOS-7-x86_64-GenericCloud-2009.qcow2c";
          sha256 = "09wqzlhb858qm548ak4jj4adchxn7rgf5fq778hrc52rjqym393v";
          # user namespaces are disabled on centos 7
          excludeRuntimes = [ "nix" "bwrap" ];
        };
        debian = {
          system = "x86_64-linux";
          url = "https://cdimage.debian.org/cdimage/openstack/archive/10.9.0/debian-10.9.0-openstack-amd64.qcow2";
          sha256 = "0mf9k3pgzighibly1sy3cjq7c761r3akp8mlgd878lwf006vqrky";
          # permissions for user namespaces not enabled by default
          excludeRuntimes = [ "nix" "bwrap" ];
        };
        fedora = {
          system = "x86_64-linux";
          url = "https://download.fedoraproject.org/pub/fedora/linux/releases/37/Cloud/x86_64/images/Fedora-Cloud-Base-37-1.7.x86_64.qcow2";
          sha256 = "187k05x1a2r0rq0lbsxircvk7ckk0mifxxj5ayd4hrgf3v4vxfdm";
        };
        nixos = {
          system = "x86_64-linux";
          # use iso image for nixos because building a qcow2 would require KVM
          img = (toString (nixosSystem {
            system = "x86_64-linux";
            modules = [
              (import ./testing/nixos-iso.nix)
              {boot.loader.timeout = lib.mkOverride 49 1;}
            ];
          }).config.system.build.isoImage) + "/iso/nixos.iso";
        };
        ubuntu_22_04 = {
          system = "x86_64-linux";
          # original: https://cloud-images.ubuntu.com/jammy/20240403/jammy-server-cloudimg-amd64.img
          url = "https://web.archive.org/web/20240412120257/https://cloud-images.ubuntu.com/jammy/20240403/jammy-server-cloudimg-amd64.img";
          sha256 = "sha256:1qvgqx9xavzpqvm7wghag79ilqchkvmcj73510xypca2yl0zpb6f";
          extraVirtCustomizeCommands = [
            "--copy-in ${./testing/ubuntu}/01-netplan.yaml:/etc/netplan/"
            "--upload ${./testing}/id_ed25519:/etc/ssh/ssh_host_ed25519_key"
            "--upload ${./testing}/id_ed25519.pub:/etc/ssh/ssh_host_ed25519_key.pub"
            "--run-command 'chmod 400 /etc/ssh/ssh_host_ed25519_key'"
          ];
        };
        ubuntu_23_10 = {
          system = "x86_64-linux";
          # original: https://cloud-images.ubuntu.com/mantic/20240410/mantic-server-cloudimg-amd64.img
          url = "https://web.archive.org/web/20240412085046/https://cloud-images.ubuntu.com/mantic/20240410/mantic-server-cloudimg-amd64.img";  # 23.10
          sha256 = "00lv3rypaxhfryds3bdl8709lav7rj44a7ifvrhrpc2i5lnh62my";
          inherit (ubuntu_22_04) extraVirtCustomizeCommands;
        };
        ubuntu_24_04 = {
          system = "x86_64-linux";
          # original https://cloud-images.ubuntu.com/noble/20240410/noble-server-cloudimg-amd64.img"
          url = "https://web.archive.org/web/20240412085322/https://cloud-images.ubuntu.com/noble/20240410/noble-server-cloudimg-amd64.img";  # 24.04
          sha256 = "0gb5fsm5sb3abalp24cmygnkinhzkf7vj73pdg80j67l9zdfg2w1";
          inherit (ubuntu_22_04) extraVirtCustomizeCommands;
          excludeRuntimes = [ "nix" "bwrap" ];
        };

        # aarch64 tests
        nixos-aarch64 = {
          system = "aarch64-linux";
          # use iso image for nixos because building a qcow2 would require KVM
          img = (toString (nixosSystem {
            system = "aarch64-linux";
            modules = [
              (import ./testing/nixos-iso.nix)
              {boot.loader.timeout = lib.mkOverride 49 1;}
            ];
          }).config.system.build.isoImage) + "/iso/nixos.iso";
        };
        debian-aarch64 = {
          system = "aarch64-linux";
          url = "https://cdimage.debian.org/cdimage/openstack/archive/10.9.0/debian-10.9.0-openstack-arm64.qcow2";
          sha256 = "0mz868j1k8jwhgg9a21dv7dr4rsy1bhklbqqw3qig06acy0vg8yi";
          # permissions for user namespaces not enabled by default
          excludeRuntimes = [ "nix" "bwrap" ];
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

      modCommand = anyStr: forEach commandsToTest (cmd: replaceStrings [ "_var_" ] [ anyStr ] cmd);

      nixPortableForSystem = { system, crossSystem ? null,  }:
        let
          pkgsDefaultChannel = import inp.defaultChannel { inherit system crossSystem; };
          pkgs = import inp.nixpkgs { inherit system crossSystem; };

          # the static proot built with nix somehow didn't work on other systems,
          # therefore using the proot static build from proot gitlab
          proot = if crossSystem != null then throw "fix proot for crossSytem" else import ./proot/alpine.nix { inherit pkgs; };
        in
          # crashes if nixpkgs updated: error: executing 'git': No such file or directory
          pkgs.callPackage ./default.nix {

            inherit proot;

            pkgs = pkgsDefaultChannel;

            lib = inp.nixpkgs.lib;
            compression = "zstd -3 -T1";

            nix = inp.nix.packages.${system}.nix;
            nixStatic = inp.nix.packages.${system}.nix-static;

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
              guestfs-tools
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
            makeQemuPipelines = mode: mapAttrs' (os: img: let
              debug = mode == "debug";
              suffix = if mode == "normal" then "" else "-${mode}";
              runtimes = filter (runtime: ! elem runtime (testImages."${os}".excludeRuntimes or []) ) [ "nix" "bwrap" "proot" ];
              img =
                if testImages."${os}" ? img then testImages."${os}".img
                else fetchurl { inherit (testImages."${os}") url sha256 ;};
              system = testImages."${os}".system;
              qemu-bin =
                if pkgs.buildPlatform.system == system then
                  "qemu-kvm"
                else
                  "qemu-system-${lib.head (lib.splitString "-" system)}";
              announce = cmd: ''echo -e "\ntesting cmd: ${cmd}"'';
              escape = cmd: replaceStrings [''"''] [''\"''] cmd;
              mkCmd = runtime: cmd: let
                vars = "NP_RUNTIME=${runtime} NP_DEBUG=$NP_DEBUG NP_MINIMAL=$NP_MINIMAL NP_LOCATION=/np_tmp";
              in ''
                ${announce (escape cmd)}
                $ssh "${vars} /home/test/nix-portable ${escape cmd}"
              '';
              testCommands = runtime:
                concatStringsSep "\n" (map (mkCmd runtime) (modCommand runtime));
            in
              nameValuePair
                "job-qemu-${os}${suffix}"
                {
                  type = "app";
                  program = toString (pkgs.writeScript "job-qemu-${os}" ''
                    #!/usr/bin/env bash
                    set -e

                    export TMPDIR=$(${pkgs.coreutils}/bin/mktemp -d)
                    trap "${pkgs.coreutils}/bin/chmod -R +w '$TMPDIR'; ${pkgs.coreutils}/bin/rm -rf '$TMPDIR'" EXIT

                    if [ -n "$RAND_PORT" ]; then
                      # derive ssh port number from os name, to gain ability to run these jobs in parallel without collision
                      port=$(( 1024 + (0x$(echo -n "your-string" | sha256sum | cut -c 1-8) % (65535 - 1024 + 1)) ))
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

                    echo "ssh command: $ssh"

                    cp "$privKey" $TMPDIR/privKey
                    chmod 400 $TMPDIR/privKey

                    setup_and_start_vm() {
                      cat $img > /tmp/${os}-img

                      if [[ "${os}" != nixos* ]]; then
                        ${pkgs.guestfs-tools}/bin/virt-customize -a /tmp/${os}-img \
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

                    # if debug, don't init/run VM if already running
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
                    $sshRoot "mount -t tmpfs -o size=3g /bin/true /home"
                    $sshRoot "mkdir -p /home/test/.ssh && chown -R test /home/test && chmod 700 /home/test/.ssh"
                    echo "uploading ssh key"
                    $scp ${./testing}/id_ed25519.pub root@localhost:/home/test/.ssh/authorized_keys
                    $sshRoot chown -R test /home/test
                    $sshRoot chmod 600 /home/test/.ssh/authorized_keys
                    echo "finished uploading ssh key"

                    echo "upload the nix-portable executable"
                    $scp ${self.packages."${system}".nix-portable}/bin/nix-portable test@localhost:/home/test/nix-portable
                    $ssh chmod +w /home/test/nix-portable

                    ${optionalString (mode != "nix-static") ''
                      echo -e "\n\nstarting to test nix-portable"
                      # test some nix commands
                      NP_DEBUG=''${NP_DEBUG:-1}
                      # test if automatic runtime selection works
                      echo "testing automatic runtime selection..."
                      if ! $ssh "NP_DEBUG=$NP_DEBUG /home/test/nix-portable nix-shell -p hello --run hello"; then
                        echo "Error: automatic runtime selection failed"
                        exit 1
                      fi
                      ${concatStringsSep "\n\n" (forEach runtimes testCommands)}
                    ''}

                    ${optionalString (mode == "nix-static") ''
                      echo -e "\n\nstarting to test nix-static"
                      # test some nix commands
                      set -e
                      $scp -r ${inp.nix.packages."${system}".nix-static}/bin test@localhost:/home/test/nix-static
                      ${concatStringsSep "\n\n" (flip map (tail commandsToTest) (cmd: ''
                        echo "testing cmd: ${escape cmd}"
                        NIX_PATH="nixpkgs=https://github.com/nixos/nixpkgs/tarball/${inp.defaultChannel.rev}"
                        $ssh "NIX_PATH=$NIX_PATH PATH= \$HOME/nix-static/${escape cmd} --extra-experimental-features 'nix-command flakes'"
                      ''
                      ))}
                    ''}

                    echo "all tests succeeded"

                    ${optionalString (! debug) ''
                      timeout 3 $sshRoot "echo o > /proc/sysrq-trigger" || :
                    ''}
                  '');
                }
            ) testImages;
        in
          # generate jobs with and without debug settings
          makeQemuPipelines "debug" // makeQemuPipelines "normal" // makeQemuPipelines "nix-static"
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
