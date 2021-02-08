{
  pkgs ? import <nixpkgs> {},
  ...
}:

with builtins;

pkgs.runCommand "proot-x86_46" {} ''
  zip=${builtins.fetchurl {
    url = "https://gitlab.com/proot/proot/-/jobs/981080848/artifacts/download";
    sha256 = "05biwh64rjs7bnxvqmb2s2sik83al84sbp34mk8z4qjcm7ddgxd0";
  }}
  mkdir -p $out/bin
  ${pkgs.unzip}/bin/unzip $zip public/bin/proot
  mv public/bin/proot $out/bin/proot
''