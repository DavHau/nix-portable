## Nix Portable
Nix - Static, Permissionless, Installation-free, Pre-configured

Nix as a single binary which works without previous installation/configuration and without super user privileges or user namespaces.

### Goals:
  - make it extremely simple to install nix
  - make nix work in restricted environments (containers, HPC, ...)
  - be able to use the official binary cache (by simulating the /nix/store)
  - make it easy to distribute nix (via other package managers)

### Systems confirmed working (Please add yours via PR):
  - CentOS 7
  - Debian (in docker)
  - NixOS

### Under the hood:
  - the nix-portable binary is a self extracting archive, caching its contents under $HOME/.nix-portable
  - either bublewrap (bwrap) or proot is used to simulate the /nix/store directory which actually resides in $HOME/.nix-portable/store
  - a default nixpkgs channel is included and the NIX_PATH variable is set accordingly.
  - nix version 2.4 is used and configured to enable `flakes` and `nix-command` out of the box.


### Missing Features:
  - managing nix profiles via `nix-env`
  - managing nix channels via `nix-channel`
  - MacOS
  - support other architecutres than x86_64 


### Executing nix-portable
After obtaining the binary, there are two options:
1. Specify the nix executable via cmdline argument:
    ```
    ./nix-portable nix-shell ...
    ```
1. Select the nix executable via symlinking, similar to busybox:
    ```
    # create a symlink from ./nix-shell to ./nix-portable
    ln -s ./nix-portable ./nix-shell
    # execute nix-shell
    ./nix-shell
    ```

### Executing installed programs
All programs installed via nix-portable will only work inside the wrapped environment.  
To enter the wrapped environment just use nix-shell:
```
  nix-portable nix-shell -p bash
```

... or use `nix run` to execute a program:
```
  nix-portable nix run {flake-spec}
```

### Container Runtimes
To simulate the /nix/store and a few other directories, nix-portable supports the following container runtimes.
  - bwrap (existing installation)
  - bwrap (shipped via nix-portable)
  - proot (existing installation)
  - proot (shipped via nix-portable)

bwrap is preferred over proot and existing installations are preferred over the nix-portable included binaries.
nix-portable will try to figure out which runtime is best for your system.
In case the automatically selected runtime doesn't work, use the follwing environment variables to specify the runtime, but pleaae also open an issue, so we can improve the automatic selection.

### Environmant Variables
The following environment variables are optional and can be used to override the default behaviour of running nix-portable
```
NP_DEBUG    enable debug logging (to stdout)
NP_RUNTIME  which runtime to use (must be either 'bwrap' or 'proot') 
NP_BWRAP    specify the path to the bwrap executable
NP_PROOT    specify the path to the proot executable
NP_RUN      override the complete command to run nix
            (to use an unsupported runtime, or for debugging)
            nix will then be executed like: $NP_RUN {nix-binary} {args...}
          
```
