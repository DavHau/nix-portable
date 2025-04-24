#!/usr/bin/env bash

# substituteAll interface
zstdStaticBin=@zstdStaticBin@
prootStaticBin=@prootStaticBin@
bwrapStaticBin=@bwrapStaticBin@
nixStaticBin=@nixStaticBin@
busyboxStaticBin=@busyboxStaticBin@
busyboxBins=(@busyboxBins@)
caBundleZstd=@caBundleZstd@
storeTar=@storeTar@
git=@git@
gitAttribute=@gitAttribute@
nixpkgsSrc=@nixpkgsSrc@
bundledExe=@bundledExe@

set -eo pipefail

start="$(date +%s%N)"  # start time in nanoseconds

# dump environment on exit if debug is enabled
if [ -n "$NP_DEBUG" ] && [ "$NP_DEBUG" -ge 1 ]; then
  trap "declare -p > /tmp/np_env" EXIT
fi

# there seem to be less issues with proot when disabling seccomp
export PROOT_NO_SECCOMP="${PROOT_NO_SECCOMP:-1}"

set -e
if [ -n "$NP_DEBUG" ] && [ "$NP_DEBUG" -ge 2 ]; then
  set -x
fi

# &3 is our error out which we either forward to &2 or to /dev/null
# depending on the setting
if [ -n "$NP_DEBUG" ] && [ "$NP_DEBUG" -ge 1 ]; then
  debug(){
    echo "$@" || true
  }
  exec 3>&2
else
  debug(){
    true
  }
  exec 3>/dev/null
fi

# to reference this script's file
self="$(realpath "${BASH_SOURCE[0]}")"

# fingerprint will be inserted by builder
fingerprint="_FINGERPRINT_PLACEHOLDER_"

# user specified location for program files and nix store
[ -z "$NP_LOCATION" ] && NP_LOCATION="$HOME"
NP_LOCATION="$(readlink -f "$NP_LOCATION")"
dir="$NP_LOCATION/.nix-portable"
store="$dir/nix/store"
# create /nix/var/nix to prevent nix from falling back to chroot store.
mkdir -p "$dir"/{bin,nix/var/nix,nix/store}
# sanitize the tmpbin directory
rm -rf "$dir/tmpbin"
# create a directory to hold executable symlinks for overriding
mkdir -p "$dir/tmpbin"

# create minimal drv file for nix to spawn a nix shell
cat >"$dir/mini-drv.nix" <<'EOF'
builtins.derivation {
  name = "foo";
  builder = "/bin/sh";
  args = [
    "-c"
    "echo hello >$out"
  ];
  system = builtins.currentSystem;
}
EOF

# the fingerprint being present inside a file indicates that
# this version of nix-portable has already been initialized
if test -e "$dir"/conf/fingerprint && [ "$(cat "$dir"/conf/fingerprint)" == "$fingerprint" ]; then
  newNPVersion=false
else
  newNPVersion=true
fi

# Nix portable ships its own nix.conf
export NIX_CONF_DIR="$dir"/conf/

NP_CONF_SANDBOX="${NP_CONF_SANDBOX:-false}"
NP_CONF_STORE="${NP_CONF_STORE:-auto}"


recreate_nix_conf(){
  mkdir -p "$NIX_CONF_DIR"
  rm -f "$NIX_CONF_DIR/nix.conf"

  {
    # static config
    echo "build-users-group = "
    echo "experimental-features = nix-command flakes"
    echo "ignored-acls = security.selinux system.nfs4_acl"
    echo "use-sqlite-wal = false"
    echo "sandbox-paths = /bin/sh=$dir/busybox/bin/busybox"

    # configurable config
    echo "sandbox = $NP_CONF_SANDBOX"
    echo "store = $NP_CONF_STORE"
  } > "$NIX_CONF_DIR/nix.conf"
}


### install files

# https://github.com/NixOS/nixpkgs/blob/e101e9465d47dd7a7eb95b0477ae67091c02773c/lib/strings.nix#L1716
function removePrefix() {
  local prefix="$1"
  local str="$2"
  local preLen=${#prefix}
  if [[ "${str:0:$preLen}" == "$prefix" ]]; then
    echo "${str:$preLen}"
  else
    echo "$str"
  fi
}

function installBin() {
  local pkg="$1"
  local bin="$2"
  unzip -qqoj "$self" "$(removePrefix "/" "$pkg/bin/$bin")" -d "$dir"/bin
  chmod +wx "$dir"/bin/"$bin";
}

PATH_OLD="$PATH"

# as soon as busybox is unpacked, restrict PATH to busybox to ensure reproducibility of this script
# only unpack binaries if necessary
if [ "$newNPVersion" == "false" ]; then

  debug "binaries already installed"
  export PATH="$dir/busybox/bin"

else

  debug "installing files"

  mkdir -p "$dir"/emptyroot

  # install busybox
  mkdir -p "$dir"/busybox/bin
  # TODO why not: cp "$busyboxStaticBin"/bin/busybox "$dir/busybox/bin/busybox"
  (base64 -d> "$dir/busybox/bin/busybox" && chmod +x "$dir/busybox/bin/busybox") << END
$(base64 < "$busyboxStaticBin"/bin/busybox)
END
  for bin in ${busyboxBins[@]}; do
    [ ! -e "$dir/busybox/bin/$bin" ] && ln -s busybox "$dir/busybox/bin/$bin"
  done

  export PATH="$dir/busybox/bin"

  # install other binaries
  installBin $zstdStaticBin "zstd"
  installBin $prootStaticBin "proot"
  installBin $bwrapStaticBin "bwrap"
  installBin $nixStaticBin "nix"

  # install ssl cert bundle
  unzip -poj "$self" "$(removePrefix "/" "$caBundleZstd")" | "$dir"/bin/zstd -d > "$dir"/ca-bundle.crt

  recreate_nix_conf
fi



### setup SSL
# find ssl certs or use from nixpkgs
debug "figuring out ssl certs"
if [ -z "$SSL_CERT_FILE" ]; then
  debug "SSL_CERT_FILE not defined. trying to find certs automatically"
  if [ -e /etc/ssl/certs/ca-bundle.crt ]; then
    SSL_CERT_FILE="$(realpath /etc/ssl/certs/ca-bundle.crt)"
    export SSL_CERT_FILE
    debug "found /etc/ssl/certs/ca-bundle.crt with real path $SSL_CERT_FILE"
  elif [ -e /etc/ssl/certs/ca-certificates.crt ]; then
    SSL_CERT_FILE="$(realpath /etc/ssl/certs/ca-certificates.crt)"
    export SSL_CERT_FILE
    debug "found /etc/ssl/certs/ca-certificates.crt with real path $SSL_CERT_FILE"
  elif [ ! -e /etc/ssl/certs ]; then
    debug "/etc/ssl/certs does not exist. Will use certs from nixpkgs."
    export SSL_CERT_FILE="$dir"/ca-bundle.crt
  else
    debug "certs seem to reside in /etc/ssl/certs. No need to set up anything"
  fi
fi
if [ -n "$SSL_CERT_FILE" ]; then
  sslBind="$(realpath "$SSL_CERT_FILE") $dir/ca-bundle.crt"
  export SSL_CERT_FILE="$dir/ca-bundle.crt"
else
  sslBind="/etc/ssl /etc/ssl"
fi



### detecting existing git installation
# we need to install git inside the wrapped environment
# unless custom git executable path is specified in NP_GIT,
# since the existing git might be incompatible to Nix (e.g. v1.x)
if [ -n "$NP_GIT" ]; then
  doInstallGit=false
  ln -s "$NP_GIT" "$dir/tmpbin/git"
else
  doInstallGit=true
fi



storePathOfFile(){
  file="$(realpath "$1")"
  sPath="$(echo "$file" | awk -F "/" 'BEGIN{OFS="/";}{print $2,$3,$4}')"
  echo "/$sPath"
}


collectBinds(){
  ### gather paths to bind for proot
  # we cannot bind / to / without running into a lot of trouble, therefore
  # we need to collect all top level directories and bind them inside an empty root
  pathsTopLevel="$(find / -mindepth 1 -maxdepth 1 -not -name nix -not -name dev)"


  toBind=""
  for p in $pathsTopLevel; do
    if [ -e "$p" ]; then
      real="$(realpath "$p")"
      if [ -e "$real" ]; then
        if [[ "$real" == /nix/store/* ]]; then
          storePath="$(storePathOfFile "$real")"
          toBind="$toBind $storePath $storePath"
        else
          toBind="$toBind $real $p"
        fi
      fi
    fi
  done


  # TODO: add /var/run/dbus/system_bus_socket
  paths="/etc/host.conf /etc/hosts /etc/hosts.equiv /etc/mtab /etc/netgroup /etc/networks /etc/passwd /etc/group /etc/nsswitch.conf /etc/resolv.conf /etc/localtime $HOME"

  for p in $paths; do
    if [ -e "$p" ]; then
      real="$(realpath "$p")"
      if [ -e "$real" ]; then
        if [[ "$real" == /nix/store/* ]]; then
          storePath="$(storePathOfFile "$real")"
          toBind="$toBind $storePath $storePath"
        else
          toBind="$toBind $real $real"
        fi
      fi
    fi
  done

  # if we're on a nixos, the /bin/sh symlink will point
  # to a /nix/store path which doesn't exit inside the wrapped env
  # we fix this by binding busybox/bin to /bin
  if test -s /bin/sh && [[ "$(realpath /bin/sh)" == /nix/store/* ]]; then
    toBind="$toBind $dir/busybox/bin /bin"
  fi
}


makeBindArgs(){
  arg="$1"; shift
  sep="$1"; shift
  binds=""
  while :; do
    if [ -n "$1" ]; then
      from="$1"; shift
      to="$1"; shift || { echo "no bind destination provided for $from!"; exit 3; }
      binds="$binds $arg $from$sep$to";
    else
      break
    fi
  done
}



### select container runtime
debug "figuring out which runtime to use"
if [ -z "$NP_BWRAP" ]; then NP_BWRAP="$(PATH="$PATH_OLD:$PATH" which bwrap 2>/dev/null)"; fi
if [ -z "$NP_BWRAP" ]; then NP_BWRAP="$dir"/bin/bwrap; fi
debug "bwrap executable: $NP_BWRAP"
# if [ -z "$NP_NIX ]; then NP_NIX="$(PATH="$PATH_OLD:$PATH" which nix 2>/dev/null)"; fi
if [ -z "$NP_NIX" ]; then NP_NIX="$dir"/bin/nix; fi
debug "nix executable: $NP_NIX"
if [ -z "$NP_PROOT" ]; then NP_PROOT="$(PATH="$PATH_OLD:$PATH" which proot 2>/dev/null)"; fi
if [ -z "$NP_PROOT" ]; then NP_PROOT="$dir"/bin/proot; fi
debug "proot executable: $NP_PROOT"
debug "testing all available runtimes..."
if [ -z "$NP_RUNTIME" ]; then
  # read last automatic selected runtime from disk
  if [ "$newNPVersion" == "true" ]; then
    debug "removing cached auto selected runtime"
    rm -f "$dir/conf/last_auto_runtime"
  fi
  if [ -f "$dir/conf/last_auto_runtime" ]; then
    last_auto_runtime="$(cat "$dir/conf/last_auto_runtime")"
  else
    last_auto_runtime=
  fi
  debug "last auto selected runtime: $last_auto_runtime"
  if [ "$last_auto_runtime" != "" ]; then
    NP_RUNTIME="$last_auto_runtime"
  # check if nix --store works
  elif \
      debug "testing nix --store" \
      && mkdir -p "$dir"/tmp/ \
      && touch "$dir"/tmp/testfile \
      && "$NP_NIX" --store "$dir/tmp/__store" shell -f "$dir/mini-drv.nix" -c "$dir/bin/nix" store add-file --store "$dir/tmp/__store" "$dir/tmp/testfile" >/dev/null 2>&3; then
    chmod -R +w "$dir"/tmp/__store
    rm -r "$dir"/tmp/__store
    debug "nix --store works on this system -> will use nix as runtime"
    NP_RUNTIME=nix
  # check if bwrap works properly
  elif \
      debug "nix --store failed -> testing bwrap" \
      && $NP_BWRAP --bind "$dir"/emptyroot / --bind "$dir"/ /nix --bind "$dir"/busybox/bin/busybox "$dir/true" "$dir/true" 2>&3 ; then
    debug "bwrap seems to work on this system -> will use bwrap"
    NP_RUNTIME=bwrap
  else
    debug "bwrap doesn't work on this system -> will use proot"
    NP_RUNTIME=proot
  fi
  echo -n "$NP_RUNTIME" > "$dir/conf/last_auto_runtime"
else
  debug "runtime selected via NP_RUNTIME: $NP_RUNTIME"
fi
debug "NP_RUNTIME: $NP_RUNTIME"
if [ "$NP_RUNTIME" == "nix" ]; then
  run="$NP_NIX shell -f $dir/mini-drv.nix -c"
  PATH="$PATH:$store$(removePrefix "/nix/store" $nixStaticBin)/bin"
  export PATH
  NP_CONF_STORE="$dir"
  recreate_nix_conf
elif [ "$NP_RUNTIME" == "bwrap" ]; then
  collectBinds
  makeBindArgs --bind " " "$toBind" "$sslBind"
  run="$NP_BWRAP $BWRAP_ARGS \
    --bind $dir/emptyroot / \
    --dev-bind /dev /dev \
    --bind $dir/nix /nix \
    $binds"
    # --bind $dir/busybox/bin/busybox /bin/sh \
else
  # proot
  collectBinds
  makeBindArgs -b ":" "$toBind" "$sslBind"
  run="$NP_PROOT $PROOT_ARGS \
    -r $dir/emptyroot \
    -b /dev:/dev \
    -b $dir/nix:/nix \
    $binds"
    # -b $dir/busybox/bin/busybox:/bin/sh \
fi
debug "base command will be: $run"



### setup environment
export NIX_PATH="$dir/channels:nixpkgs=$dir/channels/nixpkgs"
mkdir -p "$dir"/channels
[ -h "$dir"/channels/nixpkgs ] || ln -s $nixpkgsSrc "$dir"/channels/nixpkgs


### install nix store
# Install all the nix store paths necessary for the current nix-portable version
# We only unpack missing store paths from the tar archive.
index="$(cat $storeTar/index)"

# if [ ! "$NP_RUNTIME" == "nix" ]; then
  missing="$(
    for path in $index; do
      if [ ! -e "$store/$(basename "$path")" ]; then
        echo "nix/store/$(basename "$path")"
      fi
    done
  )"
  export missing

  if [ -n "$missing" ]; then
    debug "extracting missing store paths"
    (
      mkdir -p "$dir"/tmp "$store"/
      rm -rf "$dir"/tmp/*
      cd "$dir"/tmp
      unzip -qqp "$self" "$(removePrefix "/" "$storeTar/tar")" \
        | "$dir"/bin/zstd -d \
        | tar -x "$missing" --strip-components 2
      mv "$dir"/tmp/* "$store"/
    )
    rm -rf "$dir"/tmp
  fi

  if [ -n "$missing" ]; then
    debug "registering new store paths to DB"
    # reg="$(cat $storeTar/closureInfo/registration)"
    cmd="$run $store$(removePrefix "/nix/store" $nixStaticBin)/bin/nix-store --load-db"
    debug "running command: $cmd"
    # echo "$reg" | $cmd
  fi
# fi


### select executable
# the executable can either be selected by
# - executing './nix-portable BIN_NAME',
# - symlinking to nix-portable, in which case the name of the symlink selects the nix executable
# Alternatively the executable can be hardcoded by specifying the argument 'executable' of nix-portable's default.nix file.
executable="$bundledExe"
if [ "$executable" != "" ]; then
  bin="$executable"
  debug "executable is hardcoded to: $bin"
elif [[ "$(basename "$0")" == nix-portable* ]]; then\
  if [ -z "$1" ]; then
    echo "Error: please specify the nix binary to execute"
    echo "Alternatively symlink against $0"
    exit 1
  elif [ "$1" == "debug" ]; then
    bin="$(which "$2")"
    shift; shift
  else
    bin="$store$(removePrefix "/nix/store" $nixStaticBin)/bin/$1"
    shift
  fi
else
  bin="$store$(removePrefix "/nix/store" $nixStaticBin)/bin/$(basename "$0")"
fi



### check which runtime has been used previously
if [ -f "$dir/conf/last_runtime" ]; then
  lastRuntime="$(cat "$dir/conf/last_runtime")"
else
  lastRuntime=
fi



### check if nix is functional with or without sandbox
# sandbox-fallback is not reliable: https://github.com/NixOS/nix/issues/4719
if [ "$newNPVersion" == "true" ] || [ "$lastRuntime" != "$NP_RUNTIME" ]; then
  nixBin="$store$(removePrefix "/nix/store" $nixStaticBin)/bin/nix"
  # if [ "$NP_RUNTIME" == "nix" ]; then
  #   nixBin="nix"
  # else
  # fi
  debug "Testing if nix can build stuff without sandbox"
  if ! $run "$nixBin" build --no-link -f "$dir/mini-drv.nix" --option sandbox false >&3 2>&3; then
    echo "Fatal error: nix is unable to build packages"
    exit 1
  fi

  debug "Testing if nix sandbox is functional"
  if ! $run "$nixBin" build --no-link -f "$dir/mini-drv.nix" --option sandbox true >&3 2>&3; then
    debug "Sandbox doesn't work -> disabling sandbox"
    NP_CONF_SANDBOX=false
    recreate_nix_conf
  else
    debug "Sandboxed builds work -> enabling sandbox"
    NP_CONF_SANDBOX=true
    recreate_nix_conf
  fi

fi


### save fingerprint and lastRuntime
if [ "$newNPVersion" == "true" ]; then
  echo -n "$fingerprint" > "$dir/conf/fingerprint"
fi
if [ "$lastRuntime" != "$NP_RUNTIME" ]; then
  echo -n "$NP_RUNTIME" > "$dir/conf/last_runtime"
fi



### set PATH
# restore original PATH and append busybox
export PATH="$PATH_OLD:$dir/busybox/bin"
# apply overriding executable paths in $dir/tmpbin/
export PATH="$dir/tmpbin:$PATH"



### install git via nix, if git installation is not in /nix path
if $doInstallGit && [ ! -e "$store$(removePrefix "/nix/store" $git)" ] ; then
  echo "Installing git. Disable this by specifying the git executable path with 'NP_GIT'"
  $run "$store$(removePrefix "/nix/store" $nixStaticBin)/bin/nix" build --impure --no-link --expr "
    (import $nixpkgsSrc {}).$gitAttribute.out
  "
else
  debug "git already installed or manually specified"
fi

### override the possibly existing git in the environment with the installed one
# excluding the case NP_GIT is set.
if $doInstallGit; then
  export PATH="$git/bin:$PATH"
fi


### print elapsed time
end="$(date +%s%N)"  # end time in nanoseconds
# time elapsed in millis with two decimal places
# elapsed="$(echo "scale=2; ($end - $start)/1000000000" | bc)"
elapsed="$(echo "scale=2; ($end - $start)/1000000" | bc)"
debug "Time to initialize nix-portable: $elapsed millis"



### run commands
[ -z "$NP_RUN" ] && NP_RUN="$run"
debug "running command: $NP_RUN $bin $*"
exec $NP_RUN "$bin" "$@"
exit
