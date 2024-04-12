{
  pkgs ? import <nixpkgs> {},
  ...
}: let
system = pkgs.system;
apks = {
  x86_64-linux = {
    # original: http://dl-cdn.alpinelinux.org/alpine/edge/testing/x86_64/proot-static-5.4.0-r0.apk
    url = "https://web.archive.org/web/20240412082958/http://dl-cdn.alpinelinux.org/alpine/edge/testing/x86_64/proot-static-5.4.0-r0.apk";
    sha256 = "sha256:0ljxc4waa5i1j7hcqli4z7hhpkvjr5k3xwq1qyhlm2lldmv9izqy";
  };
  aarch64-linux = {
    # original: http://dl-cdn.alpinelinux.org/alpine/edge/testing/aarch64/proot-static-5.4.0-r0.apk
    url = "https://web.archive.org/web/20240412083320/http://dl-cdn.alpinelinux.org/alpine/edge/testing/aarch64/proot-static-5.4.0-r0.apk";
    sha256 = "sha256:0nl3gnbirxkhyralqx01xwg8nxanj1bgz7pkk118nv5wrf26igyd";
  };
};
in
pkgs.stdenv.mkDerivation {
  name = "proot";
  src = builtins.fetchurl {
    url = apks.${system}.url;
    sha256 = apks.${system}.sha256;
  };
  unpackPhase = ''
    tar -xf $src
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp ./usr/bin/proot.static $out/bin/proot
  '';
}
