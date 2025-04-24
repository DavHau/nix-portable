with builtins;
{
  bubblewrap,
  nix,
  # TODO use pkgs.pkgsStatic.proot
  prootStatic ? pkgs.pkgsStatic.proot,
  unzip,
  zip,
  unixtools,
  substituteAll,
  lib,
  perl,
  cacert,
  pkgs,
  pkgsStatic,
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

  proot = prootStatic;

  inherit (pkgsStatic)
    busybox
    gnutar
    xz
    zstd
    #proot
  ;

  # TODO do we need both nix and nixStatic?
  nixStatic = pkgs.pkgsStatic.nix;

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

  runtimeScript = substituteAll {
    src = ./runtimeScript.sh;
    bwrapStaticBin = packStaticBin "${bubblewrap}/bin/bwrap";
    nixStaticBin = packStaticBin "${nixStatic}/bin/nix";
    prootStaticBin = packStaticBin "${proot}/bin/proot";
    zstdStaticBin = packStaticBin "${zstd}/bin/zstd";
    busyboxBins = toString (attrNames (filterAttrs (d: type: type == "symlink") (readDir "${busybox}/bin")));
    bundledExe = if bundledPackage == null then "" else bundledExe;
    git = git.out; # TODO why not just "git"
    inherit
      nix
      caBundleZstd
      storeTar
      nixpkgsSrc
      gitAttribute
    ;
  };

  nixPortable = pkgs.runCommand pname {nativeBuildInputs = [unixtools.xxd unzip];} ''
    mkdir -p $out/bin
    cp ${runtimeScript} $out/bin/nix-portable.zip
    xxd $out/bin/nix-portable.zip | tail

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
    $zip $out/bin/nix-portable.zip ${bwrap}/bin/bwrap
    $zip $out/bin/nix-portable.zip ${nixStatic}/bin/nix
    $zip $out/bin/nix-portable.zip ${proot}/bin/proot
    $zip $out/bin/nix-portable.zip ${zstd}/bin/zstd
    $zip $out/bin/nix-portable.zip ${storeTar}/tar
    $zip $out/bin/nix-portable.zip ${caBundleZstd}

    # create fingerprint
    fp=$(sha256sum $out/bin/nix-portable.zip | cut -d " "  -f 1)
    sed -i "s/_FINGERPRINT_PLACEHOLDER_/$fp/g" $out/bin/nix-portable.zip
    # fix broken zip header due to manual modification
    ${zip}/bin/zip -F $out/bin/nix-portable.zip --out $out/bin/nix-portable-fixed.zip

    rm $out/bin/nix-portable.zip
    executable=${if bundledPackage == null then "" else bundledExe}
    if [ "$executable" == "" ]; then
      target="$out/bin/nix-portable"
    else
      target="$out/bin/$(basename "$executable")"
    fi
    mv $out/bin/nix-portable-fixed.zip "$target"
    chmod +x "$target"
  '';
in
nixPortable.overrideAttrs (prev: {
  passthru = (prev.passthru or {}) // {
    inherit bwrap proot;
  };
})
