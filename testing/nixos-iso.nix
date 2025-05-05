{ config, lib, pkgs, modulesPath, ... }:
with builtins;
with lib;
{
  imports = [
    "${toString modulesPath}/installer/cd-dvd/iso-image.nix"
  ];

  boot.initrd.availableKernelModules = [
    "virtio_net"
    "virtio_pci"
    "virtio_mmio"
    "virtio_blk"
    "virtio_scsi"
    "virtio_balloon"
    "virtio_console"
  ];

  boot.loader.timeout = mkOverride 49 1;

  fileSystems."/" = {
    fsType = "tmpfs";
    options = [ "mode=0755" "size=2G" ];
  };

  # EFI booting
  isoImage.makeEfiBootable = true;

  # USB booting
  isoImage.makeUsbBootable = true;

  isoImage.squashfsCompression = "zstd -Xcompression-level 5";

  users.users.vagrant.isNormalUser = true;
  users.users.vagrant.openssh.authorizedKeys.keyFiles = [ ./vagrant_insecure_key.pub ];
  users.users.root.openssh.authorizedKeys.keyFiles = config.users.users.vagrant.openssh.authorizedKeys.keyFiles;
  services.openssh.enable = true;
}
