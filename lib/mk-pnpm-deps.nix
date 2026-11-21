# Fetches a pnpm workspace's offline dependencies under a name carrying the pnpm major.
#
# A fixed-output derivation's store path is a function of its name and its declared hash alone, never of the inputs that produced the content. Two instantiations that share both share the path, and whichever runs second is never executed: its output is already valid. `fetchPnpmDeps` names its output after `pname` only, so one hash pin shared between two instantiations running different pnpm majors lets the first one's tree answer for the other, and the mismatch surfaces only as a hash failure on a store that has never seen either. Carrying the major in the name gives each of them its own path.
#
# The fetcher uses `pname` for its store name and nothing else, so the rename costs a cache miss on the first build and no change to the hash value.
{
  # Value the fetcher's own contract requires, passed through unchanged.
  fetcherVersion,
  # Fixed-output hash of the fetched dependency tree.
  hash,
  # Package set the fetcher is taken from.
  pkgs,
  # Name the dependency tree is filed under. The pnpm major is appended to it before the fetcher sees it.
  pname,
  # The pnpm that fetches the tree and installs it offline. Its major is what the store path records.
  pnpm,
  ...
}@args:
pkgs.fetchPnpmDeps (
  builtins.removeAttrs args [ "pkgs" ]
  // {
    pname = "${pname}-pnpm${pkgs.lib.versions.major pnpm.version}";
  }
)
