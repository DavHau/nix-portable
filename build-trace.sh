#!/bin/sh
set -eux
nix-build -E 'with import <nixpkgs> { }; callPackage ./. { }'
mkdir -p ~/.nix-portable/bin/
unzip -jo result/bin/nix-portable -d ~/.nix-portable/bin/
ldd ~/.nix-portable/bin/proot
strace -ff ~/.nix-portable/bin/proot 2>&1 | grep /nix/store | grep -v -i "no such file" | cut -d'"' -f2 | grep -v '^none$' | sort -u
