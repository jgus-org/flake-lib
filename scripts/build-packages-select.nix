# The pull-request build gate's selection, applied to one system's `packages` family.
#
# Every package the flake publishes for the runner's system is built, except one that
# excuses itself with `passthru.ciBuildSkip = true`, whose reason belongs in a comment
# beside the marker. `nix flake check` already evaluates what is not selected here, so
# what this partitions is what a hosted runner realizes, not what the flake advertises.
#
# Builtins only: this text is handed to `nix eval --apply`, where nixpkgs is not in scope.
packages:
let
  excused = name: packages.${name}.passthru.ciBuildSkip or false;
  names = builtins.attrNames packages;
in
{
  build = builtins.filter (name: !excused name) names;
  skip = builtins.filter excused names;
}
