## nix-portable
Nix - Static, Permissionless, Installation-free, Pre-configured

The goal of this project is to provide Nix as a single binary which just works without any previous installation/configuration and without the need of super user privileges.

### Under the hood:
  - the nix-portable binary is a self extracting archive, caching its contents under $HOME/.nix-portable
  - proot is used to simulate the /nix/store directory which actually resides in $HOME/.nix-portable/store
  - a default nixpkgs channel is included and the NIX_PATH variable is set accordingly.
  - nix version 2.4 is used and configured to enable `flakes` and `nix-command` out of the box.


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
All programs installed via nix-portable will only work inside the proot environment.  
To enter the proot environment just use nix-shell:
```
  nix-portable nix-shell -p bash
```

... or use `nix run`:
```
  nix-portable nix run ...
```

