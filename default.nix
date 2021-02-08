with builtins;
{
  pkgs ? import <nixpkgs> {},
  nix ? (builtins.getFlake "nix/480426a364f09e7992230b32f2941a09fb52d729").packages.x86_64-linux.nix-static,
  ...
}:
let
  proot = import ./proot/gitlab.nix { inherit pkgs; };

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

  storeTar = maketar (with pkgs; [ cacert nix path gnutar gzip ]);


  # The runtime script which unpacks the necessary files to $HOME/.nix-portable
  # and then executes nix via proot
  # Some shell expressions will be evaluated at build time and some at run time.
  # Variables/expressions escaped via `\$` will be evaluated at run time
  runtimeScript = ''
    #!/usr/bin/env bash

    debug(){
      [ -n "\$NIX_PORTABLE_DEBUG" ] && echo $@
    }
      
    dir=\$HOME/.nix-portable
    mkdir -p \$dir/bin


    ### install proot
    (base64 -d > \$dir/bin/proot && chmod +x \$dir/bin/proot) << END
    $(cat ${proot}/bin/proot | base64)
    END


    ### install xz and tar
    (base64 -d > \$dir/bin/xz && chmod +x \$dir/bin/xz) << END
    $(cat ${pkgs.pkgsStatic.xz}/bin/xz | base64)
    END
    export PATH="\$dir/bin/:\$PATH"

    (base64 -d > \$dir/bin/tar && chmod +x \$dir/bin/tar) << END
    $(cat ${pkgs.pkgsStatic.gnutar}/bin/tar | base64)
    END

    export PATH="\$dir/bin/:\$PATH"


    ### generate nix config
    mkdir -p \$dir/conf/
    # echo "" > \$dir/conf/nix.conf
    echo "build-users-group = " > \$dir/conf/nix.conf
    echo "experimental-features = nix-command" >> \$dir/conf/nix.conf
    if (which unshare &>/dev/null && unshare --user --pid true &>/dev/null); then
      debug using sandbox
      echo "sandbox = false" >> \$dir/conf/nix.conf
    else
      echo "sandbox = false" >> \$dir/conf/nix.conf
    fi
    export NIX_CONF_DIR=\$dir/conf/


    ### setup environment
    export PATH="\$HOME/.nix-profile/bin:\$PATH"
    export NIX_PATH="\$dir/channels:nixpkgs=\$dir/channels/nixpkgs"
    mkdir -p \$dir/channels
    [ -h \$dir/channels/nixpkgs ] || ln -s ${pkgs.path} \$dir/channels/nixpkgs 
    [ -e /etc/ssl/certs ] || export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt


    ### install nix store
    # This installs all the nix store paths necessary for the current nix-portable version
    # We only unpack missing store paths from the tar archive.
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

    if [ -n "\$missing" ]; then
      debug loading new store paths
      reg="$(cat ${storeTar}/closureInfo/registration)"
      echo "\$reg" | \$dir/bin/proot -b \$dir:/nix \$dir/store${pkgs.lib.removePrefix "/nix/store" nix}/bin/nix-store --load-db 2>/dev/null
    fi


    ### select executable
    # the executable can either be selected by executing `./nix-portable BIN_NAME`,
    # or by symlinking to nix-portable, while the name of the symlink selectes the binary
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


    ### run executable
    export PROOT_NO_SECCOMP=1
    \$dir/bin/proot -b \$dir/store:/nix/store \$bin "\$@"
  '';

  runtimeScriptEscaped = replaceStrings ["\""] ["\\\""] runtimeScript;

  nixPortable = pkgs.runCommand "nix-portable" {} ''
    mkdir -p $out/bin
    echo "${runtimeScriptEscaped}" > $out/bin/nix-portable
    chmod +x $out/bin/nix-portable
  '';
in
nixPortable
