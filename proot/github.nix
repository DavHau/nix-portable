{
  pkgs ? import <nixpkgs> {},
  ...
}:

with builtins;

let
  version = "5.3.0";

  systems = {
    x86_64-linux = {
      url = "https://github.com/proot-me/proot/releases/download/v${version}/proot-v${version}-x86_64-static";
      sha256 = "1nmllvdhlbdlgffq6x351p0zfgv202qfy8vhf26z0v8y435j1syi";
    };
    aarch64-linux = {
      url = "https://github.com/proot-me/proot/releases/download/v${version}/proot-v${version}-aarch64-static";
      sha256 = "0icaag29a6v214am4cbdyvncjs63f02lad2qrcfmnbwch6kv247s";
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
