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
  gnutar ? pkgs.pkgsStatic.gnutar,
  lib ? pkgs.lib,
  perl ? pkgs.perl,
  pkgs ? import <nixpkgs> {},
  xz ? pkgs.pkgsStatic.xz,
  zstd ? pkgs.pkgsStatic.zstd,

  buildSystem ? builtins.currentSystem,
  ...
}@inp:
with lib;
let

  nixpkgsSrc = pkgs.path;

  pkgsBuild = import pkgs.path { system = buildSystem; };

  # TODO: git could be more minimal via:
  # perlSupport=false; guiSupport=false; nlsSupport=false;
  gitAttribute = "gitMinimal";
  git = pkgs."${gitAttribute}";

  maketar = targets:
    pkgsBuild.stdenv.mkDerivation {
      name = "maketar";
      nativeBuildInputs = [ pkgsBuild.perl pkgsBuild.zstd ];
      exportReferencesGraph = map (x: [("closure-" + baseNameOf x) x]) targets;
      buildCommand = ''
        storePaths=$(perl ${pkgsBuild.pathsFromGraph} ./closure-*)
        mkdir $out
        echo $storePaths > $out/index
        cp -r ${pkgsBuild.closureInfo { rootPaths = targets; }} $out/closureInfo

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

  caBundleZstd = pkgs.runCommand "cacerts" {} "cat ${cacert}/etc/ssl/certs/ca-bundle.crt | ${inp.zstd}/bin/zstd -19 > $out";

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

    # there seem to be less issues with proot when disabling seccomp
    export PROOT_NO_SECCOMP=\''${PROOT_NO_SECCOMP:-1}

    set -e
    if [ -n "\$NP_DEBUG" ] && [ "\$NP_DEBUG" -ge 2 ]; then
      set -x
    fi

    # &3 is our error out which we either forward to &2 or to /dev/null
    # depending on the setting
    if [ -n "\$NP_DEBUG" ] && [ "\$NP_DEBUG" -ge 1 ]; then
      debug(){
        echo \$@ || true
      }
      exec 3>&2
    else
      debug(){
        true
      }
      exec 3>/dev/null
    fi

    # to reference this script's file
    self="\$(realpath \''${BASH_SOURCE[0]})"

    # fingerprint will be inserted by builder
    fingerprint="_FINGERPRINT_PLACEHOLDER_"

    # user specified location for program files and nix store
    [ -z "\$NP_LOCATION" ] && NP_LOCATION="\$HOME"
    dir="\$NP_LOCATION/.nix-portable"
    mkdir -p \$dir/bin
    # santize the tmpbin directory
    rm -rf "\$dir/tmpbin"
    # create a directory to hold executable symlinks for overriding
    mkdir -p "\$dir/tmpbin"

    # the fingerprint being present inside a file indicates that
    # this version of nix-portable has already been initialized
    if test -e \$dir/conf/fingerprint && [ "\$(cat \$dir/conf/fingerprint)" == "\$fingerprint" ]; then
      newNPVersion=false
    else
      newNPVersion=true
    fi

    # Nix portable ships its own nix.conf
    export NIX_CONF_DIR=\$dir/conf/

    create_nix_conf(){
      sandbox=\$1

      mkdir -p \$dir/conf/
      rm -f \$dir/conf/nix.conf

      echo "build-users-group = " > \$dir/conf/nix.conf
      echo "experimental-features = nix-command flakes" >> \$dir/conf/nix.conf
      echo "ignored-acls = security.selinux system.nfs4_acl security.csm" >> \$dir/conf/nix.conf
      echo "use-sqlite-wal = false" >> \$dir/conf/nix.conf
      echo "sandbox-paths = /bin/sh=\$dir/busybox/bin/busybox" >> \$dir/conf/nix.conf

      echo "sandbox = \$sandbox" >> \$dir/conf/nix.conf
    }


    ### install files

    PATH_OLD="\$PATH"

    # as soon as busybox is unpacked, restrict PATH to busybox to ensure reproducibility of this script
    # only unpack binaries if necessary
    if [ "\$newNPVersion" == "false" ]; then

      debug "binaries already installed"
      export PATH="\$dir/busybox/bin"

    else

      debug "installing files"

      mkdir -p \$dir/emptyroot

      # install busybox
      mkdir -p \$dir/busybox/bin
      (base64 -d> "\$dir/busybox/bin/busybox" && chmod +x "\$dir/busybox/bin/busybox") << END
    $(cat ${busybox}/bin/busybox | base64)
    END
      busyBins="${toString (attrNames (filterAttrs (d: type: type == "symlink") (readDir "${inp.busybox}/bin")))}"
      for bin in \$busyBins; do
        [ ! -e "\$dir/busybox/bin/\$bin" ] && ln -s busybox "\$dir/busybox/bin/\$bin"
      done

      export PATH="\$dir/busybox/bin"

      # install other binaries
      ${installBin zstd "zstd"}
      ${installBin proot "proot"}
      ${installBin bwrap "bwrap"}

      # install ssl cert bundle
      unzip -poj "\$self" ${ lib.removePrefix "/" "${caBundleZstd}"} | \$dir/bin/zstd -d > \$dir/ca-bundle.crt

      create_nix_conf false

    fi



    ### setup SSL
    # find ssl certs or use from nixpkgs
    debug "figuring out ssl certs"
    if [ -z "\$SSL_CERT_FILE" ]; then
      debug "SSL_CERT_FILE not defined. trying to find certs automatically"
      if [ -e /etc/ssl/certs/ca-bundle.crt ]; then
        export SSL_CERT_FILE=\$(realpath /etc/ssl/certs/ca-bundle.crt)
        debug "found /etc/ssl/certs/ca-bundle.crt with real path \$SSL_CERT_FILE"
      elif [ -e /etc/ssl/certs/ca-certificates.crt ]; then
        export SSL_CERT_FILE=\$(realpath /etc/ssl/certs/ca-certificates.crt)
        debug "found /etc/ssl/certs/ca-certificates.crt with real path \$SSL_CERT_FILE"
      elif [ ! -e /etc/ssl/certs ]; then
        debug "/etc/ssl/certs does not exist. Will use certs from nixpkgs."
        export SSL_CERT_FILE=\$dir/ca-bundle.crt
      else
        debug "certs seem to reside in /etc/ssl/certs. No need to set up anything"
      fi
    fi
    if [ -n "\$SSL_CERT_FILE" ]; then
      sslBind="\$(realpath \$SSL_CERT_FILE) \$dir/ca-bundle.crt"
      export SSL_CERT_FILE="\$dir/ca-bundle.crt"
    else
      sslBind="/etc/ssl /etc/ssl"
    fi



    ### detecting existing git installation
    # we need to install git inside the wrapped environment
    # unless custom git executable path is specified in NP_GIT,
    # since the existing git might be incompatible to Nix (e.g. v1.x)
    if [ -n "\$NP_GIT" ]; then
      doInstallGit=false
      ln -s "\$NP_GIT" "\$dir/tmpbin/git"
    else
      doInstallGit=true
    fi



    storePathOfFile(){
      file=\$(realpath \$1)
      sPath="\$(echo \$file | awk -F "/" 'BEGIN{OFS="/";}{print \$2,\$3,\$4}')"
      echo "/\$sPath"
    }


    collectBinds(){
      ### gather paths to bind for proot
      # we cannot bind / to / without running into a lot of trouble, therefore
      # we need to collect all top level directories and bind them inside an empty root
      pathsTopLevel="\$(find / -mindepth 1 -maxdepth 1 -not -name nix -not -name dev)"


      toBind=""
      for p in \$pathsTopLevel; do
        if [ -e "\$p" ]; then
          real=\$(realpath \$p)
          if [ -e "\$real" ]; then
            if [[ "\$real" == /nix/store/* ]]; then
              storePath=\$(storePathOfFile \$real)
              toBind="\$toBind \$storePath \$storePath"
            else
              toBind="\$toBind \$real \$p"
            fi
          fi
        fi
      done


      # TODO: add /var/run/dbus/system_bus_socket
      paths="/etc/host.conf /etc/hosts /etc/hosts.equiv /etc/mtab /etc/netgroup /etc/networks /etc/passwd /etc/group /etc/nsswitch.conf /etc/resolv.conf /etc/localtime \$HOME"

      for p in \$paths; do
        if [ -e "\$p" ]; then
          real=\$(realpath \$p)
          if [ -e "\$real" ]; then
            if [[ "\$real" == /nix/store/* ]]; then
              storePath=\$(storePathOfFile \$real)
              toBind="\$toBind \$storePath \$storePath"
            else
              toBind="\$toBind \$real \$real"
            fi
          fi
        fi
      done

      # if we're on a nixos, the /bin/sh symlink will point
      # to a /nix/store path which doesn't exit inside the wrapped env
      # we fix this by binding busybox/bin to /bin
      if test -s /bin/sh && [[ "\$(realpath /bin/sh)" == /nix/store/* ]]; then
        toBind="\$toBind \$dir/busybox/bin /bin"
      fi
    }


    makeBindArgs(){
      arg=\$1; shift
      sep=\$1; shift
      binds=""
      while :; do
        if [ -n "\$1" ]; then
          from="\$1"; shift
          to="\$1"; shift || { echo "no bind destination provided for \$from!"; exit 3; }
          binds="\$binds \$arg \$from\$sep\$to";
        else
          break
        fi
      done
    }



    ### select container runtime
    debug "figuring out which runtime to use"
    [ -z "\$NP_BWRAP" ] && NP_BWRAP=\$(PATH="\$PATH_OLD:\$PATH" which bwrap 2>/dev/null) || true
    [ -z "\$NP_BWRAP" ] && NP_BWRAP=\$dir/bin/bwrap
    debug "bwrap executable: \$NP_BWRAP"
    [ -z "\$NP_PROOT" ] && NP_PROOT=\$(PATH="\$PATH_OLD:\$PATH" which proot 2>/dev/null) || true
    [ -z "\$NP_PROOT" ] && NP_PROOT=\$dir/bin/proot
    debug "proot executable: \$NP_PROOT"
    if [ -z "\$NP_RUNTIME" ]; then
      # check if bwrap works properly
      if \$NP_BWRAP --bind \$dir/emptyroot / --bind \$dir/ /nix --bind \$dir/busybox/bin/busybox "\$dir/true" "\$dir/true" 2>&3 ; then
        debug "bwrap seems to work on this system -> will use bwrap"
        NP_RUNTIME=bwrap
      else
        debug "bwrap doesn't work on this system -> will use proot"
        NP_RUNTIME=proot
      fi
    else
      debug "runtime selected via NP_RUNTIME : \$NP_RUNTIME"
    fi
    if [ "\$NP_RUNTIME" == "bwrap" ]; then
      collectBinds
      makeBindArgs --bind " " \$toBind \$sslBind
      run="\$NP_BWRAP \$BWRAP_ARGS \\
        --bind \$dir/emptyroot /\\
        --dev-bind /dev /dev\\
        --bind \$dir/ /nix\\
        \$binds"
        # --bind \$dir/busybox/bin/busybox /bin/sh\\
    else
      # proot
      collectBinds
      makeBindArgs -b ":" \$toBind \$sslBind
      run="\$NP_PROOT \$PROOT_ARGS\\
        -r \$dir/emptyroot\\
        -b /dev:/dev\\
        -b \$dir/store:/nix/store\\
        \$binds"
        # -b \$dir/busybox/bin/busybox:/bin/sh\\
    fi
    debug "base command will be: \$run"



    ### setup environment
    export NIX_PATH="\$dir/channels:nixpkgs=\$dir/channels/nixpkgs"
    mkdir -p \$dir/channels
    [ -h \$dir/channels/nixpkgs ] || ln -s ${nixpkgsSrc} \$dir/channels/nixpkgs


    ### install nix store
    # Install all the nix store paths necessary for the current nix-portable version
    # We only unpack missing store paths from the tar archive.
    # xz must be in PATH
    index="$(cat ${storeTar}/index)"

    export missing=\$(
      for path in \$index; do
        if [ ! -e \$dir/store/\$(basename \$path) ]; then
          echo "nix/store/\$(basename \$path)"
        fi
      done
    )

    if [ -n "\$missing" ]; then
      debug "extracting missing store paths"
      (
        mkdir -p \$dir/tmp \$dir/store/
        rm -rf \$dir/tmp/*
        cd \$dir/tmp
        unzip -qqp "\$self" ${ lib.removePrefix "/" "${storeTar}/tar"} \
          | \$dir/bin/zstd -d \
          | tar -x \$missing --strip-components 2
        mv \$dir/tmp/* \$dir/store/
      )
      rm -rf \$dir/tmp
    fi

    if [ -n "\$missing" ]; then
      debug "registering new store paths to DB"
      reg="$(cat ${storeTar}/closureInfo/registration)"
      cmd="\$run \$dir/store${lib.removePrefix "/nix/store" nix}/bin/nix-store --load-db"
      debug "running command: \$cmd"
      echo "\$reg" | \$cmd
    fi



    ### select executable
    # the executable can either be selected by executing './nix-portable BIN_NAME',
    # or by symlinking to nix-portable, in which case the name of the symlink selectes the binary
    if [[ "\$(basename \$0)" == nix-portable* ]]; then
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



    ### check which runtime has been used previously
    lastRuntime=\$(cat "\$dir/conf/last_runtime" 2>&3) || true



    ### check if nix is funtional with or without sandbox
    # sandbox-fallback is not reliable: https://github.com/NixOS/nix/issues/4719
    if [ "\$newNPVersion" == "true" ] || [ "\$lastRuntime" != "\$NP_RUNTIME" ]; then
      nixBin="\$dir/store${lib.removePrefix "/nix/store" nix}/bin/nix-build"
      debug "Testing if nix can build stuff without sandbox"
      if ! \$run "\$nixBin" -E "(import <nixpkgs> {}).runCommand \\"test\\" {} \\"echo \$(date) > \\\$out\\"" --option sandbox false >&3 2>&3; then
        echo "Fatal error: nix is unable to build packages"
        exit 1
      fi

      debug "Testing if nix sandox is functional"
      if ! \$run "\$nixBin" -E "(import <nixpkgs> {}).runCommand \\"test\\" {} \\"echo \$(date) > \\\$out\\"" --option sandbox true >&3 2>&3; then
        debug "Sandbox doesn't work -> disabling sandbox"
        create_nix_conf false
      else
        debug "Sandboxed builds work -> enabling sandbox"
        create_nix_conf true
      fi

    fi


    ### save fingerprint and lastRuntime
    if [ "\$newNPVersion" == "true" ]; then
      echo -n "\$fingerprint" > "\$dir/conf/fingerprint"
    fi
    if [ "\$lastRuntime" != \$NP_RUNTIME ]; then
      echo -n \$NP_RUNTIME > "\$dir/conf/last_runtime"
    fi



    ### set PATH
    # restore original PATH and append busybox
    export PATH="\$PATH_OLD:\$dir/busybox/bin"
    # apply overriding executable paths in \$dir/tmpbin/
    export PATH="\$dir/tmpbin:\$PATH"



    ### install git via nix, if git installation is not in /nix path
    if \$doInstallGit && [ ! -e \$dir/store${lib.removePrefix "/nix/store" git.out} ] ; then
      echo "Installing git. Disable this by specifying the git executable path with 'NP_GIT'"
      \$run \$dir/store${lib.removePrefix "/nix/store" nix}/bin/nix build --impure --no-link --expr "
        (import ${nixpkgsSrc} {}).${gitAttribute}.out
      "
    else
      debug "git already installed or manually specified"
    fi

    ### override the possibly existing git in the environment with the installed one
    # excluding the case NP_GIT is set.
    if \$doInstallGit; then
      export PATH="${git.out}/bin:\$PATH"
    fi



    ### run commands
    [ -z "\$NP_RUN" ] && NP_RUN="\$run"
    if [ "\$NP_RUNTIME" == "proot" ]; then
      debug "running command: \$NP_RUN \$bin \$@"
      exec \$NP_RUN \$bin "\$@"
    else
      cmd="\$NP_RUN \$bin \$@"
      debug "running command: \$cmd"
      exec \$NP_RUN \$bin "\$@"
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
    $zip $out/bin/nix-portable.zip ${caBundleZstd}

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
