{ config, lib, pkgs, modulesPath, ... }:
with builtins;
{
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };

  boot.loader.grub.device = lib.mkDefault "/dev/vda";
  boot.loader.timeout = 0;

  users.users.test.isNormalUser = true;
  users.users.test.openssh.authorizedKeys.keys = [ (readFile ./id_ed25519.pub) ];
  users.users.root.openssh.authorizedKeys.keys = config.users.users.test.openssh.authorizedKeys.keys;
  services.openssh.enable = true;
  
  system.build.qcow = import "${toString modulesPath}/../lib/make-disk-image.nix" {
    inherit lib config pkgs;
    diskSize = 8192;
    format = "qcow2";
  };
}