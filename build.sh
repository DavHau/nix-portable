#!/bin/sh
set -x
export NIX_BUILD_CORES=1
exec nix-build -E 'with import <nixpkgs> { }; callPackage ./. { }'
