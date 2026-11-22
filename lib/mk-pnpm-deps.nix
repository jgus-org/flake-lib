# Fetches a pnpm workspace's offline dependencies under a name carrying the pnpm major and, when the producer declares one, a fingerprint of the source the fetch reads.
#
# A fixed-output derivation's store path is a function of its name and its declared hash alone, never of the inputs that produced the content. Two instantiations that share both share the path, and whichever runs second is never executed: its output is already valid. `fetchPnpmDeps` names its output after `pname` only, so one hash pin shared between two instantiations running different pnpm majors lets the first one's tree answer for the other, and the mismatch surfaces only as a hash failure on a store that has never seen either. Carrying the major in the name gives each of them its own path.
#
# The same keying hides a stale hash pin from `update-version`. Its build-failure path takes the mismatch a build reports and rewrites the pin field holding the specified hash, but a fetch whose name and declared hash already resolve to a valid path never runs to report one. The bump's tree then goes unverified: the build either dies inside `pnpmConfigHook`'s offline install, which is a build failure rather than a hash mismatch the updater can attribute, or succeeds against the previous revision's dependencies. A fingerprint that changes when the source does gives the fetch a new path at every bump, which is what makes the mismatch reachable.
#
# The fetcher uses `pname` for its store name and nothing else, so either half of the name costs a cache miss on the first build and no change to the hash value.
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
  # String that changes whenever the fetched tree's input does, the source hash already in the pin being the usual one. It reaches the store name and nothing else, so declaring it costs a refetch on any source change. With none, the name carries the major alone and a source change under an unchanged hash pin reuses whatever tree the store already holds.
  sourceFingerprint ? null,
  ...
}@args:
let
  # A store path name carries neither `/` nor `=`, and an SRI hash carries both.
  nameSafeFingerprint = pkgs.lib.replaceStrings [ "/" "=" ] [ "-" "-" ] sourceFingerprint;
in
pkgs.fetchPnpmDeps (
  builtins.removeAttrs args [
    "pkgs"
    "sourceFingerprint"
  ]
  // {
    pname = "${pname}-pnpm${pkgs.lib.versions.major pnpm.version}${
      pkgs.lib.optionalString (sourceFingerprint != null) "-${nameSafeFingerprint}"
    }";
  }
)
