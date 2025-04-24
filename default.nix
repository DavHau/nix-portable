with builtins;
{
  bubblewrap,
  nix,
  unzip,
  zip,
  unixtools,
  substituteAll,
  lib,
  perl,
  cacert,
  pkgs,
  # no. pkgsStatic.nix and pkgsStatic.proot are not cached
  # still an issue: https://github.com/NixOS/nixpkgs/issues/81137
  # pkgsStatic,
  busybox,
  gnutar,
  xz,
  zstd,
  proot,
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
      nativeBuildInputs = [ pkgsBuild.perl pkgsBuild.zstd ];
      exportReferencesGraph = map (x: [("closure-" + baseNameOf x) x]) targets;
      buildCommand = ''
        mkdir $out
        cp -r ${pkgsBuild.closureInfo { rootPaths = targets; }} $out/closureInfo
        tar -cf - \
          --owner=0 --group=0 --mode=u+rw,uga+r \
          --hard-dereference \
          $(cat $out/closureInfo/store-paths) | ${compression} > $out/tar
      '';
    };

  packStaticBin = binPath: let
      binName = (last (splitString "/" binPath)); in
    pkgs.runCommand
    binName
    { nativeBuildInputs = [ pkgs.upx ]; }
    ''
      mkdir -p $out/bin
      upx -9 -o $out/bin/${binName} ${binPath}
    '';

  caBundleZstd = pkgs.runCommand "cacerts" {} "cat ${cacert}/etc/ssl/certs/ca-bundle.crt | ${zstd}/bin/zstd -19 > $out";


  # the default nix store contents to extract when first used
  storeTar = maketar ([ cacert nix nixpkgsSrc ] ++ lib.optional (bundledPackage != null) bundledPackage);


  # The runtime script which unpacks the necessary files to $HOME/.nix-portable
  # and then executes nix via proot or bwrap
  # Some shell expressions will be evaluated at build time and some at run time.
  # Variables/expressions escaped via `\$` will be evaluated at run time

  bwrapStaticBin = packStaticBin "${bubblewrap}/bin/bwrap";
  nixStaticBin = packStaticBin "${nix}/bin/nix";
  prootStaticBin = packStaticBin "${proot}/bin/proot";
  zstdStaticBin = packStaticBin "${zstd}/bin/zstd";
  busyboxStaticBin = packStaticBin "${busybox}/bin/busybox";

  runtimeScript = substituteAll {
    src = ./runtimeScript.sh;
    busyboxBins = lib.escapeShellArgs (attrNames (filterAttrs (d: type: type == "symlink") (readDir "${busybox}/bin")));
    bundledExe = if bundledPackage == null then "" else bundledExe;
    git = git.out; # TODO why not just "git"
    inherit
      bwrapStaticBin
      nix
      nixStaticBin
      prootStaticBin
      zstdStaticBin
      busyboxStaticBin
      caBundleZstd
      storeTar
      nixpkgsSrc
      gitAttribute
    ;
  };

  nixPortable = pkgs.runCommand pname {nativeBuildInputs = [unixtools.xxd unzip];} ''
    mkdir -p $out/bin
    cp ${runtimeScript} $out/bin/nix-portable.zip
    chmod +w $out/bin/nix-portable.zip

    sizeA=$(printf "%08x" `stat -c "%s" $out/bin/nix-portable.zip` | tac -rs ..)
    echo 504b 0304 0000 0000 0000 0000 0000 0000 | xxd -r -p >> $out/bin/nix-portable.zip
    echo 0000 0000 0000 0000 0000 0200 0000 4242 | xxd -r -p >> $out/bin/nix-portable.zip

    sizeB=$(printf "%08x" `stat -c "%s" $out/bin/nix-portable.zip` | tac -rs ..)
    echo 504b 0102 0000 0000 0000 0000 0000 0000 | xxd -r -p >> $out/bin/nix-portable.zip
    echo 0000 0000 0000 0000 0000 0000 0200 0000 | xxd -r -p >> $out/bin/nix-portable.zip
    echo 0000 0000 0000 0000 0000 $sizeA 4242 | xxd -r -p >> $out/bin/nix-portable.zip

    echo 504b 0506 0000 0000 0000 0100 3000 0000 | xxd -r -p >> $out/bin/nix-portable.zip
    echo $sizeB 0000 0000 0000 0000 0000 0000 | xxd -r -p >> $out/bin/nix-portable.zip

    unzip -vl $out/bin/nix-portable.zip

    zip="${zip}/bin/zip -0"
    $zip $out/bin/nix-portable.zip ${bwrapStaticBin}/bin/bwrap
    $zip $out/bin/nix-portable.zip ${nixStaticBin}/bin/nix
    $zip $out/bin/nix-portable.zip ${prootStaticBin}/bin/proot
    $zip $out/bin/nix-portable.zip ${zstdStaticBin}/bin/zstd
    $zip $out/bin/nix-portable.zip ${busyboxStaticBin}/bin/busybox
    $zip $out/bin/nix-portable.zip ${storeTar}/tar
    $zip $out/bin/nix-portable.zip ${caBundleZstd}

    # create fingerprint
    fp=$(sha256sum $out/bin/nix-portable.zip | head -c64)
    sed -i "0,/_FINGERPRINT_PLACEHOLDER_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/s//$fp/" $out/bin/nix-portable.zip

    executable=${if bundledPackage == null then "" else bundledExe}
    if [ "$executable" == "" ]; then
      target="$out/bin/nix-portable"
    else
      target="$out/bin/$(basename "$executable")"
    fi
    mv $out/bin/nix-portable.zip "$target"
    chmod +x "$target"
  '';
in
nixPortable.overrideAttrs (prev: {
  passthru = (prev.passthru or {}) // {
    bwrap = bwrapStaticBin;
    proot = prootStaticBin;
  };
})
