{
  pkgs ? import <nixpkgs> {},
  ...
}:

with builtins;

pkgs.runCommand "proot-x86_46" {} ''
  bin=${builtins.fetchurl {
    url = "https://github.com/proot-me/proot/releases/download/v5.2.0/proot-v5.2.0-x86_64-static";
    sha256 = "1w729a5fz9wcxshn7vy4yg96qj59sxmd2by1gcl6nz57qjrl61pb";
  }}
  mkdir -p $out/bin
  cp $bin $out/bin/proot
  chmod +x $out/bin/proot
''
