with builtins;
{
  bwrap,
  nix,
  pkgs ? import <nixpkgs> {},
  proot,
  ...
}:
let

  zstd = pkgs.pkgsStatic.zstd;

  maketar = targets:
    pkgs.stdenv.mkDerivation {
      name = "maketar";
      buildInputs = with pkgs; [ perl ];
      exportReferencesGraph = map (x: [("closure-" + baseNameOf x) x]) targets;
      buildCommand = ''
        storePaths=$(perl ${pkgs.pathsFromGraph} ./closure-*)
        mkdir $out
        echo $storePaths > $out/index
        cp -r ${pkgs.closureInfo { rootPaths = targets; }} $out/closureInfo

        tar -cf - \
          --owner=0 --group=0 --mode=u+rw,uga+r \
          --hard-dereference \
          $storePaths | xz -1 -T $(nproc) > $out/tar
      '';
    };

  installBin = pkg: bin: ''
    (base64 -d> \$dir/bin/${bin} && chmod +x \$dir/bin/${bin}) << END
    $(cat ${pkg}/bin/${bin} | base64)
    END
  '';

  # the default nix store contents to extract when first used
  storeTar = maketar (with pkgs; [ busybox cacert nix path gnutar gzip ]);


  # The runtime script which unpacks the necessary files to $HOME/.nix-portable
  # and then executes nix via proot or bwrap
  # Some shell expressions will be evaluated at build time and some at run time.
  # Variables/expressions escaped via `\$` will be evaluated at run time
  runtimeScript = ''
    #!/usr/bin/env bash

    set -e

    debug(){
      [ -n "\$NP_DEBUG" ] && echo \$@ || true
    }
      
    dir=\$HOME/.nix-portable
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
        export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      fi
    fi


    ### install binaries
    ${installBin proot "proot"}
    ${installBin bwrap "bwrap"}
    ${installBin pkgs.pkgsStatic.xz "xz"}
    ${installBin pkgs.pkgsStatic.gnutar "tar"}


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
      if \$NP_BWRAP --bind / / --bind ${pkgs.busybox}/bin/busybox \$HOME/testxyz/true \$HOME/testxyz/true 2>/dev/null; then
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
        --bind \$dir/store${pkgs.lib.removePrefix "/nix/store" pkgs.busybox}/bin/ /bin\\
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
        -b \$dir/store:/nix/store\\
        -b \$dir/store${pkgs.lib.removePrefix "/nix/store" pkgs.busybox}/bin/:/bin
        \$binds"
    fi


    ### generate nix config
    mkdir -p \$dir/conf/
    echo "build-users-group = " > \$dir/conf/nix.conf
    echo "experimental-features = nix-command flakes" >> \$dir/conf/nix.conf
    echo "sandbox = true" >> \$dir/conf/nix.conf
    echo "sandbox-fallback = true" >> \$dir/conf/nix.conf
    export NIX_CONF_DIR=\$dir/conf/


    ### setup environment
    export NIX_PATH="\$dir/channels:nixpkgs=\$dir/channels/nixpkgs"
    mkdir -p \$dir/channels
    [ -h \$dir/channels/nixpkgs ] || ln -s ${pkgs.path} \$dir/channels/nixpkgs


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
        base64 -d | tar -xJ \$missing --strip-components 2
        mv \$dir/tmp/* \$dir/store/
      ) << END
    $(cat ${storeTar}/tar | base64)
    END
    fi

    PATH="\$PATH_OLD"

    if [ -n "\$missing" ]; then
      debug "loading new store paths"
      reg="$(cat ${storeTar}/closureInfo/registration)"
      cmd="\$run \$dir/store${pkgs.lib.removePrefix "/nix/store" nix}/bin/nix-store --load-db"
      debug "running command: \$cmd"
      echo "\$reg" | \$cmd 2>/dev/null
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
        bin="\$dir/store${pkgs.lib.removePrefix "/nix/store" nix}/bin/\$1"
        shift
      fi
    else
      bin="\$dir/store${pkgs.lib.removePrefix "/nix/store" nix}/bin/\$(basename \$0)"
    fi


    ### run commands
    [ -z "\$NP_RUN" ] && NP_RUN="\$run"
    if [ "\$NP_RUNTIME" == "proot" ]; then
      debug "running command: \$NP_RUN \$bin \$@"
      \$NP_RUN \$bin "\$@"
    else
      cmd="\$NP_RUN \$bin \$@"
      debug "running command: \$cmd"
      \$cmd
    fi
  '';

  runtimeScriptEscaped = replaceStrings ["\""] ["\\\""] runtimeScript;

  nixPortable = pkgs.runCommand "nix-portable" {} ''
    mkdir -p $out/bin
    echo "${runtimeScriptEscaped}" > $out/bin/nix-portable
    chmod +x $out/bin/nix-portable
  '';
in
nixPortable
