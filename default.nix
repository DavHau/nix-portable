with builtins;
{
  bwrap,
  nix,
  proot,
  unzip,
  zip,
  unixtools,

  busybox ? pkgs.pkgsStatic.busybox,
  cacert ? pkgs.cacert,
  compression ? "zstd -19 -T0",
  git ? pkgs.git,
  gnutar ? pkgs.pkgsStatic.gnutar,
  lib ? pkgs.lib,
  mkDerivation ? pkgs.stdenv.mkDerivation,
  nixpkgsSrc ? pkgs.path,
  perl ? pkgs.perl,
  pkgs ? import <nixpkgs> {},
  xz ? pkgs.pkgsStatic.xz,
  zstd ? pkgs.pkgsStatic.zstd,
  ...
}@inp:
with lib;
let

  maketar = targets:
    mkDerivation {
      name = "maketar";
      nativeBuildInputs = [ perl zstd ];
      exportReferencesGraph = map (x: [("closure-" + baseNameOf x) x]) targets;
      buildCommand = ''
        storePaths=$(perl ${pkgs.pathsFromGraph} ./closure-*)
        mkdir $out
        echo $storePaths > $out/index
        cp -r ${pkgs.closureInfo { rootPaths = targets; }} $out/closureInfo

        tar -cf - \
          --owner=0 --group=0 --mode=u+rw,uga+r \
          --hard-dereference \
          $storePaths | ${compression} > $out/tar
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

  installBin = pkg: bin: ''
    unzip -qqoj "\$self" ${ lib.removePrefix "/" "${pkg}/bin/${bin}"} -d \$dir/bin
    chmod +wx \$dir/bin/${bin};
  '';

  installBinBase64 = pkg: bin: ''
    (base64 -d> \$dir/bin/${bin} && chmod +x \$dir/bin/${bin}) << END
    $(cat ${pkg}/bin/${bin} | base64)
    END
  '';

  bwrap = packStaticBin "${inp.bwrap}/bin/bwrap";
  proot = packStaticBin "${inp.proot}/bin/proot";
  zstd = packStaticBin "${inp.zstd}/bin/zstd";

  # the default nix store contents to extract when first used
  storeTar = maketar ([ cacert nix nixpkgsSrc ]);


  # The runtime script which unpacks the necessary files to $HOME/.nix-portable
  # and then executes nix via proot or bwrap
  # Some shell expressions will be evaluated at build time and some at run time.
  # Variables/expressions escaped via `\$` will be evaluated at run time
  runtimeScript = ''
    #!/usr/bin/env bash

    set -e

    self="\$(realpath \''${BASH_SOURCE[0]})"
    fingerprint="_FINGERPRINT_PLACEHOLDER_"

    debug(){
      [ -n "\$NP_DEBUG" ] && echo \$@ || true
    }

    [ -z "\$NP_LOCATION" ] && NP_LOCATION="\$HOME"
    dir="\$NP_LOCATION/.nix-portable"
    mkdir -p \$dir/bin


    ### setup SSL
    # find ssl certs or use from nixpkgs
    debug "figuring out ssl certs"
    if [ -z "\$SSL_CERT_FILE" ]; then
      debug "SSL_CERT_FILE not defined. trying to find certs automatically"
      if [ -e /etc/ssl/certs/ca-bundle.crt ]; then
        debug "found /etc/ssl/certs/ca-bundle.crt"
        export SSL_CERT_FILE=\$(realpath /etc/ssl/certs/ca-bundle.crt)
      elif [ ! -e /etc/ssl/certs ]; then
        debug "/etc/ssl/certs does not exist, using certs from nixpkgs"
        export SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt
      else
        debug "certs seem to reside in /etc/ssl/certs. No need to set up anything"
      fi
    fi


    ### install binaries
    if test -e \$dir/fingerprint && [ "\$(cat \$dir/fingerprint)" == "\$fingerprint" ]; then
      debug "binaries already installed"
    else
      debug "installing binaries"

      # install busybox
      mkdir -p \$dir/busybox/bin
      (base64 -d> "\$dir/busybox/bin/busybox" && chmod +x "\$dir/busybox/bin/busybox") << END
    $(cat ${busybox}/bin/busybox | base64)
    END
      busyBins="${toString (attrNames (filterAttrs (d: type: type == "symlink") (readDir "${inp.busybox}/bin")))}"
      for bin in \$busyBins; do
        [ ! -e "\$dir/busybox/bin/\$bin" ] && ln -s busybox "\$dir/busybox/bin/\$bin"
      done

      # install other binaries
      ${installBinBase64 zstd "zstd"}
      ${installBin proot "proot"}
      ${installBin bwrap "bwrap"}
      ${installBin zstd "zstd"}

      # save fingerprint
      echo -n "\$fingerprint" > "\$dir/fingerprint"
    fi


    ### add busybox to PATH
    export PATH="\$PATH:\$dir/busybox/bin"


    ### gather paths to bind for proot
    paths="\$(find / -mindepth 1 -maxdepth 1 -not -name etc)"
    paths="\$paths /etc/host.conf /etc/hosts /etc/hosts.equiv /etc/mtab /etc/netgroup /etc/networks /etc/passwd /etc/group /etc/nsswitch.conf /etc/resolv.conf /etc/localtime $HOME"
    toBind=""
    mkdir -p \$dir/shared-files
    for p in \$paths; do
      if [ -e "\$p" ]; then
        real=\$(realpath \$p)
        [ -e "\$real" ] && toBind="\$toBind \$real \$p"
      fi
    done

    makeBindArgs(){
      arg=\$1; shift
      sep=\$1; shift
      binds=""
      while :; do
        if [ -n "\$1" ]; then
          from="\$1"; shift
          to="\$1"; shift
          binds="\$binds \$arg \$from\$sep\$to";
        else
          break
        fi
      done
    }


    ### select container runtime
    debug "figuring out which runtime to use"
    [ -z "\$NP_BWRAP" ] && NP_BWRAP=\$(which bwrap 2>/dev/null) || true
    [ -z "\$NP_BWRAP" ] && NP_BWRAP=\$dir/bin/bwrap
    debug "bwrap executable: \$NP_BWRAP"
    [ -z "\$NP_PROOT" ] && NP_PROOT=\$(which proot 2>/dev/null) || true
    [ -z "\$NP_PROOT" ] && NP_PROOT=\$dir/bin/proot
    debug "proot executable: \$NP_PROOT"
    if [ -z "\$NP_RUNTIME" ]; then
      # check if bwrap works properly
      if \$NP_BWRAP --bind / / --bind \$dir/busybox/bin/busybox "\$HOME/.nix-portable/true" "\$HOME/.nix-portable/true" 2>/dev/null ; then
        debug "bwrap seems to work on this system -> will use bwrap"
        NP_RUNTIME=bwrap
      else
        debug "bwrap doesn't work on this system -> will use proot"
        NP_RUNTIME=proot
      fi
    else
      debug "runtime selected via NP_RUNTIME : \$NP_RUNTIME"
    fi
    mkdir -p \$dir/emptyroot
    if [ "\$NP_RUNTIME" == "bwrap" ]; then
      # makeBindArgs --bind " " \$toBind
      if [ -n "\$SSL_CERT_FILE" ]; then
        makeBindArgs --bind " " \$SSL_CERT_FILE \$SSL_CERT_FILE
      fi
      run="\$NP_BWRAP \$BWRAP_ARGS \\
        --bind / /\\
        --dev-bind /dev /dev\\
        --bind \$dir/ /nix\\
        \$binds"
    else
      makeBindArgs -b ":" \$toBind
      binds_1="\$binds"
      if [ -n "\$SSL_CERT_FILE" ]; then
        debug "creating bind args for \$SSL_CERT_FILE"
        makeBindArgs -b ":" \$SSL_CERT_FILE \$SSL_CERT_FILE
      else
        debug "creating bind args for /etc/ssl"
        makeBindArgs -b ":" /etc/ssl /etc/ssl
      fi
      binds="\$binds_1 \$binds"
      run="\$NP_PROOT \$PROOT_ARGS\\
        -R \$dir/emptyroot
        -b \$dir/store:/nix/store
        \$binds"
    fi


    ### generate nix config
    mkdir -p \$dir/conf/
    echo "build-users-group = " > \$dir/conf/nix.conf
    echo "experimental-features = nix-command flakes" >> \$dir/conf/nix.conf
    echo "sandbox = true" >> \$dir/conf/nix.conf
    echo "sandbox-fallback = true" >> \$dir/conf/nix.conf
    echo "use-sqlite-wal = false" >> \$dir/conf/nix.conf
    export NIX_CONF_DIR=\$dir/conf/


    ### setup environment
    export NIX_PATH="\$dir/channels:nixpkgs=\$dir/channels/nixpkgs"
    mkdir -p \$dir/channels
    [ -h \$dir/channels/nixpkgs ] || ln -s ${nixpkgsSrc} \$dir/channels/nixpkgs


    ### install nix store
    # Install all the nix store paths necessary for the current nix-portable version
    # We only unpack missing store paths from the tar archive.
    # xz must be in PATH
    PATH_OLD="\$PATH"
    PATH="\$dir/bin/:\$PATH"
    index="$(cat ${storeTar}/index)"

    export missing=\$(
      for path in \$index; do
        if [ ! -e \$dir/store/\$(basename \$path) ]; then
          echo "nix/store/\$(basename \$path)"
        fi
      done
    )

    if [ -n "\$missing" ]; then
      (
        mkdir -p \$dir/tmp \$dir/store/
        rm -rf \$dir/tmp/*
        cd \$dir/tmp
        unzip -qqp "\$self" ${ lib.removePrefix "/" "${storeTar}/tar"} \
         | tar -x --zstd \$missing --strip-components 2
        mv \$dir/tmp/* \$dir/store/
      )
    fi

    PATH="\$PATH_OLD"

    if [ -n "\$missing" ]; then
      debug "loading new store paths"
      reg="$(cat ${storeTar}/closureInfo/registration)"
      cmd="\$run \$dir/store${lib.removePrefix "/nix/store" nix}/bin/nix-store --load-db"
      debug "running command: \$cmd"
      echo "\$reg" | \$cmd
    fi


    ### install git via nix, if git not installed yet or git installation is in /nix path
    if [ -z "\$NP_MINIMAL" ] && ( ! which git &>/dev/null || [[ "\$(realpath \$(which git))" == /nix/* ]] ); then
      needGit=true
    else
      needGit=false
    fi
    debug "needGit: \$needGit"
    if \$needGit && [ ! -e \$dir/store${lib.removePrefix "/nix/store" git.out} ] ; then
      echo "Installing git. Disable this by setting 'NP_MINIMAL=1'"
      \$run \$dir/store${lib.removePrefix "/nix/store" nix}/bin/nix build --impure --no-link --expr "
        (import ${nixpkgsSrc} {}).git.out
      "
    else
      debug "git already installed or not required"
    fi


    ### select executable
    # the executable can either be selected by executing './nix-portable BIN_NAME',
    # or by symlinking to nix-portable, in which case the name of the symlink selectes the binary
    if [ "\$(basename \$0)" == "nix-portable" ]; then
      if [ -z "\$1" ]; then
        echo "Error: please specify the nix binary to execute"
        echo "Alternatively symlink against \$0"
        exit 1
      elif [ "\$1" == "debug" ]; then
        bin="\$(which \$2)"
        shift; shift
      else
        bin="\$dir/store${lib.removePrefix "/nix/store" nix}/bin/\$1"
        shift
      fi
    else
      bin="\$dir/store${lib.removePrefix "/nix/store" nix}/bin/\$(basename \$0)"
    fi


    ### set PATH
    # add git
    \$needGit && export PATH="\$PATH:${git.out}/bin"


    ### run commands
    [ -z "\$NP_RUN" ] && NP_RUN="\$run"
    if [ "\$NP_RUNTIME" == "proot" ]; then
      debug "running command: \$NP_RUN \$bin \$@"
      exec  \$NP_RUN \$bin "\$@"
    else
      cmd="\$NP_RUN \$bin \$@"
      debug "running command: \$cmd"
      exec  \$cmd
    fi
  '';

  runtimeScriptEscaped = replaceStrings ["\""] ["\\\""] runtimeScript;

  nixPortable = pkgs.runCommand "nix-portable" {nativeBuildInputs = [unixtools.xxd unzip];} ''
    mkdir -p $out/bin
    echo "${runtimeScriptEscaped}" > $out/bin/nix-portable.zip
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
    $zip $out/bin/nix-portable.zip ${proot}/bin/proot
    $zip $out/bin/nix-portable.zip ${bwrap}/bin/bwrap
    $zip $out/bin/nix-portable.zip ${zstd}/bin/zstd
    $zip $out/bin/nix-portable.zip ${storeTar}/tar

    # create fingerprint
    fp=$(sha256sum $out/bin/nix-portable.zip | cut -d " "  -f 1)
    sed -i "s/_FINGERPRINT_PLACEHOLDER_/$fp/g" $out/bin/nix-portable.zip
    # fix broken zip header due to manual modification
    ${zip}/bin/zip -F $out/bin/nix-portable.zip --out $out/bin/nix-portable-fixed.zip

    rm $out/bin/nix-portable.zip
    mv $out/bin/nix-portable-fixed.zip $out/bin/nix-portable

    chmod +x $out/bin/nix-portable
  '';
in
nixPortable.overrideAttrs (prev: {
  passthru = (prev.passthru or {}) // {
    inherit bwrap proot;
  };
})
