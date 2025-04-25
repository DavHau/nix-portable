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

  nixPortable = pkgs.runCommand pname {nativeBuildInputs = [unixtools.xxd unzip];} ''
    mkdir -p $out/bin
    cp ${runtimeScript} $out/bin/nix-portable.zip
    chmod +w $out/bin/nix-portable.zip

    # Local file header
    sizeA=$(printf "%08x" `stat -c "%s" $out/bin/nix-portable.zip` | tac -rs ..)
    echo 504b 0304 0000 0000 0000 0000 0000 0000 | xxd -r -p >> $out/bin/nix-portable.zip
    echo 0000 0000 0000 0000 0000 0200 0000 4242 | xxd -r -p >> $out/bin/nix-portable.zip

    # Central directory file header
    sizeB=$(printf "%08x" `stat -c "%s" $out/bin/nix-portable.zip` | tac -rs ..)
    echo 504b 0102 0000 0000 0000 0000 0000 0000 | xxd -r -p >> $out/bin/nix-portable.zip
    echo 0000 0000 0000 0000 0000 0000 0200 0000 | xxd -r -p >> $out/bin/nix-portable.zip
    echo 0000 0000 0000 0000 0000 $sizeA 4242 | xxd -r -p >> $out/bin/nix-portable.zip

    # End of central directory record
    echo 504b 0506 0000 0000 0000 0100 3000 0000 | xxd -r -p >> $out/bin/nix-portable.zip
    echo $sizeB 0000 0000 0000 0000 0000 0000 | xxd -r -p >> $out/bin/nix-portable.zip

    unzip -vl $out/bin/nix-portable.zip

    zip="${zip}/bin/zip -0"

    $zip $out/bin/nix-portable.zip ${busybox}/bin/busybox

    # we cannot unzip busybox, so we need offset and size
    # locate the first 1000 bytes of busybox in the zip archive
    busyboxOffset=$(
      cat $out/bin/nix-portable.zip | xxd -p -c0 |
      grep -bo -m1 $(head -c1000 ${busybox}/bin/busybox | xxd -p -c0) |
      cut -d: -f1
    )
    # hex to bin
    busyboxOffset=$((busyboxOffset / 2))
    busyboxSize=$(stat -c %s ${busybox}/bin/busybox)
    sed -i "0,/@busyboxOffset@/s//$(printf "%-15s" $busyboxOffset)/; \
      0,/@busyboxSize@/s//$(printf "%-13s" $busyboxSize)/" $out/bin/nix-portable.zip

    $zip $out/bin/nix-portable.zip ${bwrap}/bin/bwrap
    $zip $out/bin/nix-portable.zip ${nix}/bin/nix
    $zip $out/bin/nix-portable.zip ${proot}/bin/proot
    $zip $out/bin/nix-portable.zip ${zstd}/bin/zstd
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
nixPortable
