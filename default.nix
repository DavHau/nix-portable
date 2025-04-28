with builtins;
{
  bubblewrapStatic ? pkgsStatic.bubblewrap,
  # fix: builder failed to produce output path for output 'man'
  # https://github.com/milahu/nixpkgs/issues/83
  #nixStatic ? pkgsStatic.nix,
  # use nix 2.21.0
  # https://discourse.nixos.org/t/where-can-i-get-a-statically-built-nix/34253/15
  # https://hydra.nixos.org/job/nix/master/buildStatic.x86_64-linux/all
  stdenv,
  nix,
  nixGitStatic ? (stdenv.mkDerivation {
    name = "nix-static-x86_64-unknown-linux-musl-2.21.0pre20240311_25bf671";
    src = fetchurl {
      url = "https://hydra.nixos.org/build/252984554/download/1/nix";
      sha256 = "sha256:0rcxm2p38lhxz4cbxwbw432mpi8i5lmkmw6gzrw4i48ra90hn89q";
    };
    # ls -l $(dirname $(readlink -f $(which nix))) | grep -- '->' | cut -d' ' -f17 | xargs echo
    nixBins = lib.escapeShellArgs (attrNames (lib.filterAttrs (d: type: type == "symlink") (readDir "${nix}/bin")));
    buildCommand = ''
      mkdir -p $out/bin
      cp $src $out/bin/nix
      chmod +x $out/bin/nix
      for bin in $nixBins; do
        ln -s nix $out/bin/$bin
      done
    '';
  }),
  unzip,
  zip,
  unixtools,
  substituteAll,
  lib,
  glibc,
  ripgrep,
  patchelf,
  cacert,
  pkgs,
  pkgsStatic,
  busyboxStatic ? pkgsStatic.busybox,
  gnutar,
  xz,
  zstdStatic ? pkgsStatic.zstd,
  # fix: ld: attempted static link of dynamic object
  # https://gitlab.com/ita1024/waf/-/issues/2467
  #prootStatic ? pkgsStatic.proot,
  callPackage,
  prootStatic ? (callPackage ./proot/alpine.nix { }),
  compression ? "zstd -3 -T1",
  buildSystem ? builtins.currentSystem,
  # # tar crashed on emulated aarch64 system
  # buildSystem ? "x86_64-linux",
  # hardcode executable to run. Useful when creating a bundle.
  bundledPackage ? null,
  ...
}:

with lib;
let

  nixStatic = nixGitStatic;

  # stage1 bins
  busybox = busyboxStatic;
  zstd = zstdStatic;
  nix = nixStatic;
  bubblewrap = bubblewrapStatic;
  proot = prootStatic;

  pname =
    if bundledPackage == null
    then "nix-portable"
    else lib.getName bundledPackage;

  bundledExe = lib.getExe bundledPackage;

  nixpkgsSrc = pkgs.path;

  pkgsBuild = import pkgs.path { system = buildSystem; };

  # TODO: git could be more minimal via:
  # perlSupport=false; guiSupport=false; nlsSupport=false;
  gitAttribute = "gitMinimal";
  git = pkgs."${gitAttribute}";

  maketar = targets:
    pkgsBuild.stdenv.mkDerivation {
      name = "nix-portable-store-tarball";
      nativeBuildInputs = [ pkgsBuild.zstd ];
      buildCommand = ''
        mkdir $out
        cp -r ${pkgsBuild.closureInfo { rootPaths = targets; }} $out/closureInfo
        tar -cf - \
          --owner=0 --group=0 --mode=u+rw,uga+r \
          --hard-dereference \
          $(cat $out/closureInfo/store-paths) | ${compression} > $out/tar
      '';
    };

  caBundleZstd = pkgs.runCommand "cacerts" {} "cat ${cacert}/etc/ssl/certs/ca-bundle.crt | ${zstd}/bin/zstd -19 > $out";


  # the default nix store contents to extract when first used
  storeTar = maketar ([
    cacert
    nix
    # nix.man # not with nix 2.21.0
    nixpkgsSrc
  ] ++ lib.optional (bundledPackage != null) bundledPackage);


  # The runtime script which unpacks the necessary files to $HOME/.nix-portable
  # and then executes nix via proot or bwrap
  # Some shell expressions will be evaluated at build time and some at run time.
  # Variables/expressions escaped via `\$` will be evaluated at run time

  runtimeScript = substituteAll {
    src = ./runtimeScript.sh;
    busyboxBins = lib.escapeShellArgs (attrNames (filterAttrs (d: type: type == "symlink") (readDir "${busybox}/bin")));
    bundledExe = if bundledPackage == null then "" else bundledExe;
    git = git.out; # TODO why not just "git"
    inherit
      bubblewrap
      nix
      proot
      zstd
      busybox
      caBundleZstd
      storeTar
      nixpkgsSrc
      gitAttribute
    ;
  };

  builderScript = substituteAll {
    src = ./builder.sh;
    executable = true;
    bundledExe = if bundledPackage == null then "" else bundledExe;
    inherit
      runtimeScript
      zip
      bubblewrap
      nix
      proot
      zstd
      busybox
      caBundleZstd
      storeTar
      patchelf
    ;
  };

  nixPortable = pkgs.runCommand pname {
    nativeBuildInputs = [
      unixtools.xxd
      unzip
      glibc # ldd
      ripgrep # rg
    ];
  }
  ''
    bash ${builderScript}
  '';

in
nixPortable
