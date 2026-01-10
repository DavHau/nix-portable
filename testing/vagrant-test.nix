{
  qemu,
  openssh,
  lib,
  pkgs,
  pkgsBuildBuild,
  system,
  stdenv,

  # arguments
  image,
  testName,
  hostScript,
  guestScript ? "",
}:
let
  qemu-common = import (pkgs.path + "/nixos/lib/qemu-common.nix") { inherit lib pkgs; };
in

stdenv.mkDerivation (finalAttrs: {
  __impure = true;
  name = "test-${testName}";
  src = image.image;
  depsBuildBuild = [
    qemu
    openssh
  ];
  postBoot = image.postBoot or "";
  dontUnpack = image.dontUnpack or false;
  preBuild = image.preBuild or "";
  dontInstall = true;

  rootDisk = if finalAttrs.dontUnpack then finalAttrs.src else image.rootDisk;

  unpackPhase = ''
    tar -xf $src
  '';

  buildPhase = ''
    runHook preBuild

    shopt -s nullglob

    port=$(shuf -n 1 -i 20000-30000)

    echo "Image is: $rootDisk"

    image_type=$(qemu-img info $rootDisk | sed 's/file format: \(.*\)/\1/; t; d')

    qemu-img create -b $rootDisk -F "$image_type" -f qcow2 ./disk.qcow2

    cp ${pkgsBuildBuild.qemu}/share/qemu/edk2-aarch64-code.fd QEMU_EFI.fd
    chmod +w QEMU_EFI.fd

    extra_qemu_opts="${image.extraQemuOpts or ""}"

    # Add the config disk, required by the Ubuntu images.
    config_drive=$(echo *configdrive.vmdk || true)
    if [[ -n $config_drive ]]; then
      extra_qemu_opts+=" -drive id=disk2,file=$config_drive,if=virtio"
    fi

    echo "Starting qemu..."
    ${qemu-common.qemuBinary pkgsBuildBuild.qemu}\
      -m 4096 -nographic \
      -smp 2 \
      -drive id=disk1,file=./disk.qcow2,if=virtio \
      -netdev user,id=net0,hostfwd=tcp::$port-:22 -device virtio-net-pci,netdev=net0 \
      ${lib.optionalString (system == "aarch64-linux")
        "-cpu cortex-a53 -machine virt -pflash ./QEMU_EFI.fd"
      } \
      $extra_qemu_opts &
    qemu_pid=$!
    trap "kill $qemu_pid" EXIT

    if ! [ -e ./vagrant_insecure_key ]; then
      cp ${./vagrant_insecure_key} vagrant_insecure_key
    fi

    chmod 0400 ./vagrant_insecure_key

    export HOME=$(realpath .)
    ssh_opts="-o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -o ControlPath=none -i ./vagrant_insecure_key"
    ssh="ssh -p $port -q $ssh_opts vagrant@localhost"
    echo "ssh command: $ssh"
    sshRoot="ssh -p $port -q $ssh_opts root@localhost"
    scp="scp -P $port $ssh_opts"

    echo "Waiting for SSH..."
    for ((i = 0; i < 120; i++)); do
      echo "[ssh] Trying to connect..."
      if $ssh -- true; then
        echo "[ssh] Connected!"
        break
      fi
      if ! kill -0 $qemu_pid; then
        echo "qemu died unexpectedly"
        exit 1
      fi
      sleep 1
    done

    if [[ -n $postBoot ]]; then
      echo "Running post-boot commands..."
      $ssh "set -ex; $postBoot"
    fi

    echo "executing host script"
    ${hostScript}

    echo "Executing script for test ${testName}..."
    $ssh <<EOF
      set -ex

      ${guestScript}
    EOF

    echo "Done!"
    touch $out

    runHook postBuild
  '';
})
