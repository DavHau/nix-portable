{ config, lib, pkgs, modulesPath, ... }:
with builtins;
with lib;
{
  imports = [
    "${toString modulesPath}/installer/cd-dvd/iso-image.nix"
  ];

  boot.loader.timeout = mkForce 0;

  fileSystems."/" = {
    fsType = "tmpfs";
    options = [ "mode=0755" "size=2G" ];
  };

  # EFI booting
  isoImage.makeEfiBootable = true;

  # USB booting
  isoImage.makeUsbBootable = true;

  isoImage.squashfsCompression = "zstd -Xcompression-level 5";

  users.users.test.isNormalUser = true;
  users.users.test.openssh.authorizedKeys.keys = [ (readFile ./id_ed25519.pub) ];
  users.users.root.openssh.authorizedKeys.keys = config.users.users.test.openssh.authorizedKeys.keys;
  services.openssh.enable = true;

}