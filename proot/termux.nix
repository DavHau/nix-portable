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
  overlayedPkgs = import pkgs.path { overlays = [overlay]; inherit (pkgs) system; };
  static = overlayedPkgs.pkgsStatic;
  proot = static.proot.override { enablePython = false; };
in
proot.overrideAttrs (old:{
  src = pkgs.fetchFromGitHub {
    owner = "termux";
    repo = "PRoot";
    rev = "3eb0f49109391537e12c6f724706c12e8b7529d7";
    sha256 = "sha256-xGRMvf2OopfF8ek+jg7gZk2J17jRUVBBPog2I36Y9QU=";
  };
  buildInputs = with static; [ talloc ];
  nativeBuildInputs = with static; old.nativeBuildInputs ++ [
    libarchive.dev ncurses pkg-config
  ];
  PKG_CONFIG_PATH = [
    "${static.libarchive.dev}/lib/pkgconfig"
  ];
})
