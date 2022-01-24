{
  pkgs ? import <nixpkgs> {},
  ...
}:

with builtins;

pkgs.runCommand "proot-x86_46" {} ''
  bin=${builtins.fetchurl {
    url = "https://github.com/proot-me/proot/releases/download/v5.3.0/proot-v5.3.0-x86_64-static";
    sha256 = "1nmllvdhlbdlgffq6x351p0zfgv202qfy8vhf26z0v8y435j1syi";
  }}
  mkdir -p $out/bin
  cp $bin $out/bin/proot
  chmod +x $out/bin/proot
''
