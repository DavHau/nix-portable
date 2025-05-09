[
  # test git
  ''nix eval --impure --expr 'builtins.fetchGit {url="https://github.com/davhau/nix-portable"; rev="7ebf4ca972c6613983b2698ab7ecda35308e9886";}' ''
  # test importing <nixpkgs> and building hello works
  ''nix build -L --impure --expr '(import <nixpkgs> {}).hello.overrideAttrs(_:{change="_var_";})' ''
  # test running a program from the nix store
  "nix-shell -p hello --run hello"
]
