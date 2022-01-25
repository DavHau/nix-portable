{
  pkgs ? import <nixpkgs> {},
  ...
}:

with builtins;

let
  version = "5.2.0";

  systems = {
    x86_64-linux = {
      url = "https://github.com/proot-me/proot/releases/download/v${version}/proot-v${version}-x86_64-static";
      sha256 = "1w729a5fz9wcxshn7vy4yg96qj59sxmd2by1gcl6nz57qjrl61pb";
    };
    aarch64-linux = {
      url = "https://github.com/proot-me/proot/releases/download/v${version}/proot-v${version}-aarch64-static";
      sha256 = "17ghp5n2jz38c4qk88yjc9cvdx9pcinmf2v7i7klnmzq5wzbkrzi";
    };
    armv7l-linux = {
      url = "https://github.com/proot-me/proot/releases/download/v${version}/proot-v${version}-arm-static";
      sha256 = "";
    };
  };
in

pkgs.runCommand "proot-x86_46" {} ''
  bin=${builtins.fetchurl {
    inherit (systems."${pkgs.buildPlatform.system}") url sha256;
  }}
  mkdir -p $out/bin
  cp $bin $out/bin/proot
  chmod +x $out/bin/proot
''
