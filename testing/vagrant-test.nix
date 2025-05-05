{
  runCommand,
  qemu,
  openssh,
  lib,
  pkgs,

  # arguments
  image,
  testName,
  hostScript,
  guestScript ? "",
}:
let
  qemu-common = import (pkgs.path + "/nixos/lib/qemu-common.nix") { inherit lib pkgs; };
in

runCommand "test-${testName}-x"
  {
    buildInputs = [
      qemu
      openssh
    ];
    image = image.image;
    postBoot = image.postBoot or "";
    doUnpack = image.doUnpack or true;
    __impure = true;
  }
  ''
    shopt -s nullglob

    port=$(shuf -n 1 -i 20000-30000)

    if [ -n "$doUnpack" ]; then
      echo "Unpacking Vagrant box $image..."
      tar xvf $image
    else
      cp $image ${image.rootDisk}
    fi

    image_type=$(qemu-img info ${image.rootDisk} | sed 's/file format: \(.*\)/\1/; t; d')

    qemu-img create -b ./${image.rootDisk} -F "$image_type" -f qcow2 ./disk.qcow2

    extra_qemu_opts="${image.extraQemuOpts or ""}"

    # Add the config disk, required by the Ubuntu images.
    config_drive=$(echo *configdrive.vmdk || true)
    if [[ -n $config_drive ]]; then
      extra_qemu_opts+=" -drive id=disk2,file=$config_drive,if=virtio"
    fi

    echo "Starting qemu..."
    ${qemu-common.qemuBinary qemu}\
      -m 4096 -nographic \
      -drive id=disk1,file=./disk.qcow2,if=virtio \
      -netdev user,id=net0,hostfwd=tcp::$port-:22 -device virtio-net-pci,netdev=net0 \
      $extra_qemu_opts &
    qemu_pid=$!
    trap "kill $qemu_pid" EXIT

    if ! [ -e ./vagrant_insecure_key ]; then
      cp ${./vagrant_insecure_key} vagrant_insecure_key
    fi

    chmod 0400 ./vagrant_insecure_key

    export HOME=$(realpath .)
    ssh_opts="-o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -i ./vagrant_insecure_key"
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
  ''
