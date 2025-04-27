with builtins;
{
  bubblewrapStatic ? pkgsStatic.bubblewrap,
  # fix: builder failed to produce output path for output 'man'
  # https://github.com/milahu/nixpkgs/issues/83
  #nixStatic ? pkgsStatic.nix,
  nixGitStatic ? pkgsStatic.nixVersions.nixComponents_git.nix-everything,
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
  storeTar = maketar ([ cacert nix nixpkgsSrc ] ++ lib.optional (bundledPackage != null) bundledPackage);


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
