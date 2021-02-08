{
  pkgs ? import <nixpkgs> {},
  ...
}:

pkgs.stdenv.mkDerivation {
  name = "proot";
  src = builtins.fetchurl {
    url = "http://dl-cdn.alpinelinux.org/alpine/edge/testing/x86_64/proot-static-5.2.0_alpha-r0.apk";
  };
  unpackPhase = ''
    tar -xf $src
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp ./usr/bin/proot.static $out/bin/proot
  '';
}
