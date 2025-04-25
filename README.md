<p align="center">
<img width="400" src="https://gist.githubusercontent.com/DavHau/755fed3774e89c0b9b8953a0a25309fa/raw/fdb8b96eeb94d3b8a79481fa6fad53281e10b15d/nix_portable_2021-04-28_bw.png">
</p>

🪩 Use nix on any linux system, rootless and configuration free.

🔥 new:  [Create software bundles](#bundle-programs) that work on any linux distribution.

[💾 Downloads](https://github.com/DavHau/nix-portable/releases)

---

### Get nix-portable
```shellSession
curl -L https://github.com/DavHau/nix-portable/releases/latest/download/nix-portable-$(uname -m) > ./nix-portable

chmod +x ./nix-portable
```

### Use nix via nix-portable

There are two ways to run nix:

#### Method 1: Pass nix command line:

```shellSession
./nix-portable nix-shell --help
```

#### Method 2: Symlink against nix-portable:

To create a `nix-shell` executable, create a symlink `./nix-shell` against `./nix-portable`.

```shellSession
ln -s ./nix-portable ./nix-shell
```

Then use the symlink as an executable:

```shellSession
./nix-shell --help
```

This works for any other nix native executable.

### Get and execute programs

Hint: Use [search.nixos.org](https://search.nixos.org/packages) to find available programs.

#### Run a program without installing it

```shellSession
./nix-portable nix run nixpkgs#htop
```

#### Create a temporary environment with multiple programs

1. Enter a temporary environment with `htop` and `vim`:

    ```shellSession
    ./nix-portable nix shell nixpkgs#{htop,vim}
    ```

2. execute htop

    ```shellSession
    htop
    ```

### Bundle programs
nix-portable can bundle arbitrary software into a static executable that runs on [any*](#supported-platforms) linux distribution.

Prerequisites: Your software is already packaged for nix.

**Optional**: If you don't have nix yet, [get nix-portable](#get-nix-portable), then enter a temporary environment with nix and bash:

```shellSession
./nix-portable nix shell nixpkgs#{bashInteractive,nix} -c bash
```

Examples:

#### Bundle gnu hello:


Create a bundle containing [hello](https://search.nixos.org/packages?channel=unstable&from=0&size=50&sort=relevance&type=packages&query=hello) that will work on any machine:

```shellSession
$ nix bundle --bundler github:DavHau/nix-portable -o bundle nixpkgs#hello
$ cp ./bundle/bin/hello ./hello && chmod +w hello
$ ./hello
Hello World!
```

#### Bundle python + libraries

Bundle python with arbitrary libraries as a static executable

```shellSession
# create the bundle
$ nix bundle --bundler github:DavHau/nix-portable -o bundle --impure --expr \
  '(import <nixpkgs> {}).python3.withPackages (ps: [ ps.numpy ps.scipy ps.pandas ])'
$ cp ./bundle/bin/python3 ./python3 && chmod +w ./python3

# try it out
$ ./python3 -c 'import numpy, scipy, pandas; print("Success !")'
Success !
```

#### Bundle whole dev environment

Bundle a complex development environment including tools like compilers, linters, interpreters, etc. into a static executable.

Prerequisites:
- use [numtide/devshell](https://github.com/numtide/devshell) to define your devShell (`mkShell` from nixpkgs won't work because it is not executable)
- expose the devShell via a flake.nix based repo on github

```shellSession
$ nix bundle --bundler github:DavHau/nix-portable -o devshell github:<user>/<repo>#devShells.<system>.default 
$ cp ./devshell/bin/devshell ./devshell && chmod +w ./devshell
$ ./devshell
🔨 Welcome to devshell

[[general commands]]
[...]
```

#### Bundle compression

To create smaller bundles specify `--bundler github:DavHau/nix-portable#zstd-max`.

### Supported platforms

Potentially any linux system with an **x86_64** or **aarch64** CPU is supported.

nix-portable is tested continuously on the following platforms:

- Distros (x86_64):
  - Arch Linux
  - CentOS 7
  - Debian
  - Fedora
  - NixOS
  - Ubuntu 22.04
  - Ubuntu 23.10
  - Ubuntu 24.04
- Distros (aarch64):
  - Debian
- Other Environments:
  - Github Actions
  - Docker (debian image)

### Under the hood

- The nix-portable executable is a self extracting archive, caching its contents in $HOME/.nix-portable
- Either nix, bubblewrap or proot is used to virtualize the /nix/store directory which actually resides in $HOME/.nix-portable/nix/store
- A default nixpkgs channel is included and the NIX_PATH variable is set accordingly.
- Features `flakes` and `nix-command` are enabled out of the box.


#### Virtualization

To virtualize the /nix/store, nix-portable supports the following runtimes, preferred in this order:

- nix (shipped via nix-portable)
- bwrap (existing installation)
- bwrap (shipped via nix-portable)
- proot (existing installation)
- proot (shipped via nix-portable)

nix-portable will auto select the best runtime for your system.
In case the auto selected runtime doesn't work, please open an issue.
The default runtime can be overridden via [Environment Variables](#environment-variables).

### Environment Variables

The following environment variables are optional and can be used to override the default behavior of nix-portable at run-time.

```txt
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

### Drawbacks / Considerations

Programs obtained outside nix-portable cannot link against or call programs obtained via nix-portable. This is because nix-portable uses a virtualized directory to store its programs which cannot be accessed by other software on the system.

If user namespaces are not available on a system, nix-portable will fall back to using proot as an alternative mechanism to virtualize /nix.
Proot can introduce significant performance overhead depending on the workload.
In that situation, it might be beneficial to use a remote builder or alternatively build the derivations on another host and sync them via a cache like cachix.org.


### Missing Features

- managing nix profiles via `nix-env`
- managing nix channels via `nix-channel`
- support MacOS

### Building / Contributing

To speed up builds, add the nix-portable cache:

```shellSession
nix-shell -p cachix --run "cachix use nix-portable"
```
