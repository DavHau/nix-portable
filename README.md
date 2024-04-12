<p align="center">
<img width="400" src="https://gist.githubusercontent.com/DavHau/755fed3774e89c0b9b8953a0a25309fa/raw/fdb8b96eeb94d3b8a79481fa6fad53281e10b15d/nix_portable_2021-04-28_bw.png">
</p>

Nix as a static executable requiring no configuration, privileges, or (user) namespaces.

For binary downloads check the [releases](https://github.com/DavHau/nix-portable/releases) page.

### Goals:
  - make it extremely simple to install nix
  - make nix work in restricted environments (containers, HPC, ...)
  - be able to use the official binary cache (by virtualizing the /nix/store)
  - make it easy to distribute nix as a dependency of other projects

### Tested continuously on the following systems/environments:
  * Distros (x86_64):
    - Arch Linux
    - CentOS 7
    - Debian
    - Fedora
    - NixOS
    - Ubuntu 22.04
    - Ubuntu 23.10
    - Ubuntu 24.04
  * Distros (aarch64):
    - Debian
  * Other Environments:
    - Github Actions
    - Docker (debian image)

### Under the hood:
  - The nix-portable executable is a self extracting archive, caching its contents in $HOME/.nix-portable
  - Either nix, bubblewrap or proot is used to virtualize the /nix/store directory which actually resides in $HOME/.nix-portable/store
  - A default nixpkgs channel is included and the NIX_PATH variable is set accordingly.
  - Features `flakes` and `nix-command` are enabled out of the box.


### Drawbacks / Considerations:
If user namespaces are not available on a system, nix-portable will fall back to using proot as an alternative mechanism to virtualize /nix.
Proot can introduce significant performance overhead depending on the workload.
In that situation, it might be beneficial to use a remote builder or alternatively build the derivations on another host and sync them via a cache like cachix.org.


### Missing Features:
  - managing nix profiles via `nix-env`
  - managing nix channels via `nix-channel`
  - support MacOS


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
To simulate the /nix/store, nix-portable supports the following runtimes, preferred in this order:
  - nix (shipped via nix-portable)
  - bwrap (existing installation)
  - bwrap (shipped via nix-portable)
  - proot (existing installation)
  - proot (shipped via nix-portable)

nix-portable will auto select the best runtime for your system.
In case the auto selected runtime doesn't work, please open an issue.
The default runtime can be overridden via [Environment Variables](#environment-variables).

### Environment Variables
The following environment variables are optional and can be used to override the default behavior of nix-portable
```
NP_DEBUG      (1 = debug msgs; 2 = 'set -x' for nix-portable)
NP_GIT        specify path to the git executable
NP_LOCATION   where to put the `.nix-portable` dir. (defaults to `$HOME`)
NP_RUNTIME    which runtime to use (must be one of: nix, bwrap, proot)
NP_NIX        specify the path to the static nix executable to use in case nix is selected as runtime
NP_BWRAP      specify the path to the bwrap executable to use in case bwrap is selected as runtime
NP_PROOT      specify the path to the proot executable to use in case proot is selected as runtime
NP_RUN        override the complete command to run nix
              (to use an unsupported runtime, or for debugging)
              nix will then be executed like: $NP_RUN {nix-binary} {args...}

```

### Building / Contributing
To speed up builds, add the nix-portable cache:
```
nix-shell -p cachix --run "cachix use nix-portable"
```
