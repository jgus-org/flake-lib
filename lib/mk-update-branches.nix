# Generates the `update-branches` orchestrator package. The executable supports `list`, one-version `refresh`, and independent `publish` modes. See README.md.
#   pinSchema        : pypi | github | github-npm | github-pnpm | github-yarn | github-asset | oci | version-only
#   branchOwnedFiles : files update-version mutates (diffed, added, committed per branch). Defaults to the pin and its lock. Unmatched patterns are skipped.
#   extraBranchOwnedFiles : additional branchOwnedFiles beyond the default, for consumers that vendored extra per-branch artifacts
#   formatter      : the repository's own formatter package (e.g. self.formatter.${system}). Required when a declared extraHashes name carries a dot: that field is written as a nested attribute, and only the org formatter defines that shape.
#   versionOverrides : map of raw upstream version -> canonical version, for upstreams whose tag numbering doesn't sort right (e.g. { "0.1.405-beta" = "0.1.40.5-beta"; }). The canonical form drives sorting, branch naming, and the pin's version field. The raw form remains what update-version fetches.
#   versionCanon     : list of `sed -E` expressions applied in order to each raw version to derive its canonical form, for a tag-numbering scheme too general to enumerate in versionOverrides (e.g. every 0.1.XXX-beta hotfix -> 0.1.XX.X-beta). A matching versionOverrides entry takes precedence over these rules.
#   minVersionComponents : fewest dot-separated numeric components a tag may have and still be tracked (default 3, i.e. X.Y.Z only). Lower it for upstreams with short version tags (e.g. bare datestamps like 20260711162202).
#   minimumTrackingVersion : lowest upstream version to track, baked into the package (default "0.0.0").
#   trackStableOnly    : true excludes prereleases from branches, maintenance, and publication (default false).
#   buildVerificationSkip : true publishes a refreshed version branch without running the gate a pull request would have passed (default false). [Build verification](../AGENTS.md#build-verification) owns when to set it.
with builtins;
{
  branchOwnedFiles ? [
    "pin.nix"
    "flake.lock"
  ],
  buildVerificationSkip ? false,
  extraBranchOwnedFiles ? [ ],
  extraHashes ? [ ],
  formatter ? null,
  meta ? {
    license = pkgs.lib.licenses.mit;
  },
  minVersionComponents ? 3,
  minimumTrackingVersion ? "0.0.0",
  pinSchema,
  pkgs,
  source,
  trackStableOnly ? false,
  versionCanon ? [ ],
  versionOverrides ? { },
}:
assert elem minVersionComponents [
  1
  2
  3
];
assert isString minimumTrackingVersion;
assert isBool buildVerificationSkip;
assert formatter != null || !pkgs.lib.any (name: pkgs.lib.hasInfix "." name) extraHashes;
assert !(source ? versions) || (source.type == "oci" && source.versions.type == "github");
let
  versionSource = source.versions or source;
  versionSourceTrack = versionSource.track or "release";
in
assert elem versionSourceTrack [
  "release"
  "tag"
];
assert versionSource.type != "github-release-asset" || versionSourceTrack == "release";
# Where a source's version names live is a github-only choice: a gitlab project names its versions as its git tags, which is also where its updater resolves a release from.
assert versionSourceTrack != "tag" || versionSource.type == "github";
pkgs.writeShellApplication {
  inherit meta;
  # VERSION_OVERRIDES is JSON, so the generated export carries quotes and braces that shellcheck reads as a quoting error (SC2089/SC2090).
  excludeShellChecks = [
    "SC2089"
    "SC2090"
  ];
  name = "update-branches";
  runtimeEnv = {
    BRANCH_OWNED_FILES = pkgs.lib.concatStringsSep " " (
      pkgs.lib.unique (branchOwnedFiles ++ extraBranchOwnedFiles)
    );
    # The published tools wrap the same script text, so a run applies the gate a pull request would have run without defining it a second time.
    BUILD_AND_CHECK_SCRIPT = "${pkgs.copyPathToStore ../scripts/build-and-check.sh}";
    BUILD_PACKAGES_SCRIPT = "${pkgs.copyPathToStore ../scripts/build-packages.sh}";
    BUILD_PACKAGES_SELECT = "${pkgs.copyPathToStore ../scripts/build-packages-select.nix}";
    BUILD_VERIFICATION_SKIP = pkgs.lib.boolToString buildVerificationSkip;
    CASCADE_PY = "${pkgs.copyPathToStore ../scripts/cascade.py}";
    DEPS_CORE = "${pkgs.copyPathToStore ../scripts/deps_core.py}";
    EXTRA_HASHES = toJSON extraHashes;
    FORMATTER = if formatter == null then "" else pkgs.lib.getExe formatter;
    GH_OWNER = versionSource.owner or "";
    GH_REPO = versionSource.repo or "";
    GH_TAG_PREFIXES = toJSON (
      if versionSource ? tagPrefix then
        [ versionSource.tagPrefix ]
      else
        [
          "v"
          "V"
          ""
        ]
    );
    GITLAB_DOMAIN = versionSource.domain or "gitlab.com";
    GITLAB_OWNER = versionSource.owner or "";
    GITLAB_REPO = versionSource.repo or "";
    GIT_PUSH_LIB = "${pkgs.copyPathToStore ../scripts/git-push.sh}";
    MINIMUM_TRACKING_VERSION = minimumTrackingVersion;
    MIN_VERSION_COMPONENTS = toString minVersionComponents;
    PIN_SCHEMA = pinSchema;
    PYPI_FORMAT = source.format or "sdist";
    PYPI_NAME = source.pname or "";
    SOURCE_TYPE = source.type;
    TRACK_STABLE_ONLY = pkgs.lib.boolToString trackStableOnly;
    VERSION_CANON = pkgs.lib.concatStringsSep "\n" versionCanon;
    VERSION_OVERRIDES = toJSON versionOverrides;
    VERSION_SOURCE_TYPE = versionSource.type;
    VERSION_TRACK = versionSourceTrack;
  };
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.jq
    (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ]))
  ]
  ++ pkgs.lib.optional (formatter != null) formatter;
  text = ''exec ${../scripts/update-branches-core.sh} "$@"'';
}
