{
  lib,
  nix-portable,
  callPackage,
  system,
  nixos,
}:
let
  inherit (builtins // lib)
    concatStringsSep
    flip
    forEach
    map
    mapAttrs'
    replaceStrings
    filter
    elem
    ;

  vagrantUrl = kind: name: version:
    "https://app.vagrantup.com/${kind}/boxes/${name}/versions/${version}/providers/libvirt.box";

  noUserNs = [
    "nix"
    "bwrap"
  ];

  images.aarch64-linux = {
    nixos = {
      image = (toString (nixos {
        imports = [
          ./nixos-iso.nix
        ];
      }).config.system.build.isoImage) + "/iso/nixos.iso";
      system = "aarch64-linux";
      rootDisk = "nixos.qcow2";
      doUnpack = false;
    };
    arch = {
      image = import <nix/fetchurl.nix> {
        # retrieved url via:
        # - browse https://portal.cloud.hashicorp.com/vagrant/discover/generic/debian12
        # - open dev tools
        # - click download link
        # - inspect response of first request
        url = "https://api.cloud.hashicorp.com/vagrant-archivist/v1/object/eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXkiOiI3YzM1MzViMy05YzYwLTQ5MTYtYjdiYy1lN2E4ZjUyNmJiOWQiLCJtb2RlIjoiciIsImZpbGVuYW1lIjoiZGViaWFuMTJfNC4zLjEyX2xpYnZpcnRfYXJtNjQuYm94In0.h6VetZYYrRt3TzlBBHpX71ZQGlY-FgAciuqrW8fnJJs";
        name = "arch-libvirt.box";
        hash = "sha256-BzeallAt7BArTqp7qx1yfuAQhNoPuPEeZM1CHCdD5Mg=";
      };
      rootDisk = "box_0.img";
      system = "aarch64-linux";
      postBoot = ''
        sudo rm -f /etc/resolv.conf
        sudo ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
      '';
    };
  };

  images.x86_64-linux = {
    nixos = {
      image = (toString (nixos {
        imports = [
          ./nixos-iso.nix
        ];
      }).config.system.build.isoImage) + "/iso/nixos.iso";
      system = "x86_64-linux";
      rootDisk = "nixos.qcow2";
      doUnpack = false;
    };
    arch = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "generic" "arch" "4.3.12";
        hash = "sha256-LmXwLuJlVeAqPOw/KV/oHBPsyhuUCDQz0eLlWUTZ0BE=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
      postBoot = ''
        sudo rm -f /etc/resolv.conf
        sudo ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
      '';
    };
    debian11 = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "generic" "debian11" "4.3.12";
        hash = "sha256-Sfsfo3VyfUcDhEa2Fr6OODlGoOuDLJo8YHvbyWjqJmY=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
    };
    debian12 = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "generic" "debian12" "4.3.12";
        hash = "sha256-kj5NFLvyB/u0Dpeyc0kDD59UssP7gu3Yrl1KyQDTcFw=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
    };

    fedora-36 = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "generic" "fedora36" "4.1.12";
        hash = "sha256-rxPgnDnFkTDwvdqn2CV3ZUo3re9AdPtSZ9SvOHNvaks=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
    };

    fedora-42 = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "cloud-image" "fedora-42" "1.1.0";
        hash = "sha256-q84cWJEOFP42P3pPLOzN5IcPXYEmxieKTqX6rlwbvL8=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
    };

    ubuntu-16-04 = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "generic" "ubuntu1604" "4.1.12";
        hash = "sha256-lO4oYQR2tCh5auxAYe6bPOgEqOgv3Y3GC1QM1tEEEU8=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
      disabledRuntimes = ["nix"];
    };

    ubuntu-22-04 = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "generic" "ubuntu2204" "4.1.12";
        hash = "sha256-HNll0Qikw/xGIcogni5lz01vUv+R3o8xowP2EtqjuUQ=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
    };

    ubuntu-24-04 = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "cloud-image" "ubuntu-24.04" "20250502.1.0";
        hash = "sha256-GBvMo4kJfWfpH9qPZSyyCgOvDxkrS8fzCZxl9omSmbs=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
      disabledRuntimes = noUserNs;
    };

    rhel-7 = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "generic" "rhel7" "4.1.12";
        hash = "sha256-b4afnqKCO9oWXgYHb9DeQ2berSwOjS27rSd9TxXDc/U=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
      disabledRuntimes = noUserNs;
    };

    rhel-8 = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "generic" "rhel8" "4.1.12";
        hash = "sha256-zFOPjSputy1dPgrQRixBXmlyN88cAKjJ21VvjSWUCUY=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
    };

    rhel-9 = {
      image = import <nix/fetchurl.nix> {
        url = vagrantUrl "generic" "rhel9" "4.1.12";
        hash = "sha256-vL/FbB3kK1rcSaR627nWmScYGKGk4seSmAdq6N5diMg=";
      };
      rootDisk = "box.img";
      system = "x86_64-linux";
      extraQemuOpts = "-cpu Westmere-v2";
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
  runtimes = [ "nix" "bwrap" "proot" ];
  announce = cmd: ''echo -e "\ntesting cmd: ${cmd}"'';
  escape = cmd: replaceStrings [''"''] [''\"''] cmd;
  mkCmd = runtime: cmd: let
    vars = "NP_RUNTIME=${runtime} NP_DEBUG=$NP_DEBUG NP_MINIMAL=$NP_MINIMAL NP_LOCATION=/np_tmp";
  in ''
    ${announce (escape cmd)}
    $ssh "${vars} /home/vagrant/nix-portable ${escape cmd}"
  '';
  modCommand = anyStr: forEach commandsToTest (cmd: replaceStrings [ "_var_" ] [ anyStr ] cmd);
  testCommands = runtime:
    concatStringsSep "\n" (map (mkCmd runtime) (modCommand runtime));

  runtimesFor = image:
    filter (r: ! elem r image.disabledRuntimes or []) runtimes;

  makeTest = name: image: callPackage ./vagrant-test.nix {
    inherit image;
    testName = name;
    hostScript = ''
      set -x
      echo hello
      # change root password via ssh
      $ssh "sudo mkdir -p /root/.ssh && sudo cp -r /home/vagrant/.ssh/* /root/.ssh/" || echo "failed to copy ssh keys to root"
      $sshRoot mkdir -p /np_tmp
      $sshRoot "test -e /np_tmp/.nix-portable || mount -t tmpfs -o size=3g /bin/true /np_tmp"
      echo "uploading ssh key"


      echo "upload the nix-portable executable"
      $scp ${nix-portable}/bin/nix-portable vagrant@localhost:nix-portable
      $ssh chmod +w /home/vagrant/nix-portable

      echo -e "\n\nstarting to test nix-portable"
      # test some nix commands
      NP_DEBUG=''${NP_DEBUG:-1}
      # test if automatic runtime selection works
      echo "testing automatic runtime selection..."
      if ! $ssh "NP_DEBUG=$NP_DEBUG /home/vagrant/nix-portable nix-shell -p hello --run hello"; then
        echo "Error: automatic runtime selection failed"
        exit 1
      fi
      ${concatStringsSep "\n\n" (forEach (runtimesFor image) testCommands)}
    '';
  };
in
  flip mapAttrs' images.${system} or {} (
    name: image:
    {
      name = "vm-test-${name}";
      value = makeTest name image;
    }
  )
