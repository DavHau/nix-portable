{
  pkgs ? import <nixpkgs> {},
  ...
}:

with builtins;
let
  overlay = curr: prev: {
    talloc = prev.talloc.overrideAttrs (old: {
      wafConfigureFlags = old.wafConfigureFlags ++ [
        "--disable-python"
      ];
    });
  };
  overlayedPkgs = import pkgs.path { overlays = [overlay]; };
  static = overlayedPkgs.pkgsStatic;
  proot = static.proot.override { enablePython = false; };
in
proot.overrideAttrs (old:{
  src = pkgs.fetchFromGitHub {
    repo = "proot";
    owner = "proot-me";
    rev = "8c0ccf7db18b5d5ca2f47e1afba7897fb1bb39c0";
    sha256 = "sha256-vFdUH1WrW6+MfdlW9s+9LOhk2chPxKJUjaFy01+r49Q=";
  };
  buildInputs = with static; [ talloc ];
  nativeBuildInputs = with static; old.nativeBuildInputs ++ [
    libarchive.dev ncurses pkg-config
  ];
  PKG_CONFIG_PATH = [
    "${static.libarchive.dev}/lib/pkgconfig"
  ];
})
