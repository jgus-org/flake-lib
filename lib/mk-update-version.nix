# Generates the `update-version` package.
#   hashMode     : "prefetch" (default) or "build-failure" (vendor hashes that can't be prefetched)
#   buildFailureHash  : the one pin field name whose value the build's hash mismatch can name
#   buildFailureHashes : the pin field names any of which the build's hash mismatch can name
#   extraHashes  : extra pin field names whose values the artifactHook emits (e.g. [ "npmDepsHash" ])
#   artifactHook : consumer script (path) that regenerates vendored files + prints name=value extra hashes
#   formatter    : the repository's own formatter package (e.g. self.formatter.${system}). Required when a pin field name carries a dot: that field is written as a nested attribute, and only the org formatter defines that shape.
#   siblings     : sibling-cascade specs
#   markerEnvironment : overrides for the explicit PEP 508 marker environment sibling resolution evaluates under
#
# This tool evaluates what the flake publishes and starts no package build of its own: the
# publication path runs flake-lib's `build-and-check`, the same command that gates a pull request,
# so the tree a run commits is the tree a pull request would have gated. There is no argument
# naming a build target because the target is what that path standardizes on. Hash discovery is the
# exception: `hashMode = "build-failure"` builds what the flake publishes and mines the mismatch
# out of that log, which is the one place this tool starts a build of its own.
{
  artifactFingerprint ? "",
  artifactHook ? null,
  buildFailureHash ?
    if hashMode == "build-failure" && buildFailureHashes == [ ] then "sourceHash" else null,
  buildFailureHashes ? [ ],
  extraHashes ? [ ],
  formatter ? null,
  hashMode ? "prefetch",
  markerEnvironment ? { },
  meta ? {
    license = pkgs.lib.licenses.mit;
  },
  pkgs,
  siblingRefsInPin ? false,
  siblings ? [ ],
  source,
}:
assert artifactFingerprint == "" || artifactHook != null;
assert !(source ? versions) || (source.type == "oci" && source.versions.type == "github");
let
  oci = if source.type == "oci" then import ./oci-image.nix { inherit pkgs source; } else null;
  versionSource = source.versions or source;
  hfManifest = source.manifest or null;
  hfManifestHashField = if hfManifest == null then null else hfManifest.hashField or "manifestHash";
  buildFailureFields = pkgs.lib.unique (
    pkgs.lib.optional (buildFailureHash != null) buildFailureHash ++ buildFailureHashes
  );
  effectiveExtraHashes = pkgs.lib.unique (
    extraHashes
    ++ pkgs.lib.optional (artifactFingerprint != "") "artifactFingerprint"
    ++ pkgs.lib.optional (hfManifestHashField != null) hfManifestHashField
  );
  defaultMarkerEnvironment = {
    extra = "";
    implementation_name = "cpython";
    implementation_version = pkgs.python3.version;
    os_name = "posix";
    platform_machine = "x86_64";
    platform_python_implementation = "CPython";
    platform_release = "";
    platform_system = "Linux";
    platform_version = "";
    python_full_version = pkgs.python3.version;
    python_version = pkgs.python3.pythonVersion;
    sys_platform = "linux";
    sys_version = "";
  };
in
assert hfManifest == null || source.type == "huggingface";
assert hfManifest == null || hfManifest ? path;
assert hfManifestHashField == null || hfManifestHashField != "";
# A dotted pin field is a nested attribute, and the pin written flat is only canonical once the org formatter
# has had it.
assert
  formatter != null
  || !pkgs.lib.any (name: pkgs.lib.hasInfix "." name) (effectiveExtraHashes ++ buildFailureFields);
assert
  oci == null
  || (
    siblings == [ ]
    && artifactHook == null
    && extraHashes == [ ]
    && buildFailureFields == [ ]
    && hashMode == "prefetch"
  );
pkgs.writeShellApplication {
  inherit meta;
  # EXTRA_HASHES / SIBLINGS are JSON strings (quotes/brackets) consumed via jq at runtime (SC2089/SC2090); GH_ASSET/GH_TAG carry a literal ${version}/${tag} token the script substitutes at runtime, intentionally single-quoted (SC2016). All false positives on the generated export.
  excludeShellChecks = [
    "SC2016"
    "SC2089"
    "SC2090"
  ];
  name = "update-version";
  runtimeEnv = {
    ARTIFACT_FINGERPRINT = artifactFingerprint;
    ARTIFACT_HOOK = if artifactHook == null then "" else "${artifactHook}";
    BUILD_FAILURE_HASHES = builtins.toJSON buildFailureFields;
    CASCADE_PY = "${pkgs.copyPathToStore ../scripts/cascade.py}";
    DEPS_CORE = "${pkgs.copyPathToStore ../scripts/deps_core.py}";
    EXTRA_HASHES = builtins.toJSON effectiveExtraHashes;
    FORMATTER = if formatter == null then "" else pkgs.lib.getExe formatter;
    GH_ASSET = source.asset or ""; # github-release-asset: filename template, tokens ${version} and ${tag}
    GH_BRANCH = source.branch or ""; # commit-tracking: branch to follow (default: repo's default branch)
    GH_FETCH_SUBMODULES = if (source.fetchSubmodules or false) then "1" else ""; # hash the tree with submodules (src must set fetchSubmodules = true)
    GH_OWNER = versionSource.owner or "";
    GH_REPO = versionSource.repo or "";
    GH_TAG = source.tag or ""; # github-release-asset: tag template, token ${version} (default v${version})
    GH_TAG_PREFIXES = builtins.toJSON (
      if versionSource ? tagPrefix then
        [ versionSource.tagPrefix ]
      else
        [
          "v"
          "V"
          ""
        ]
    );
    GH_TRACK = source.track or "release"; # release (Releases API) | tag (latest version git tag) | commit (default-branch HEAD -> 0-unstable-DATE)
    GITLAB_OWNER = source.owner or "";
    GITLAB_REPO = source.repo or "";
    GITLAB_TRACK = source.track or "commit"; # release (tags -> X.Y.Z) | commit (master HEAD -> 0-unstable-DATE)
    HASH_MODE = hashMode;
    HF_FILES = builtins.toJSON (source.files or [ ]);
    HF_MANIFEST_EXCLUDE = builtins.toJSON (
      if hfManifest == null then [ ] else hfManifest.exclude or [ ]
    );
    HF_MANIFEST_HASH_FIELD = if hfManifestHashField == null then "" else hfManifestHashField;
    HF_MANIFEST_INCLUDE = builtins.toJSON (
      if hfManifest == null then [ ] else hfManifest.include or [ ]
    );
    HF_MANIFEST_PATH = if hfManifest == null then "" else hfManifest.path;
    HF_REPO = if source.type == "huggingface" then source.repo else "";
    HF_REVISION = source.revision or "main";
    MARKER_ENV = builtins.toJSON (defaultMarkerEnvironment // markerEnvironment);
    MUTABLE_URL = source.url or "";
    NIX_PATH = "nixpkgs=${pkgs.path}";
    OCI_SETTINGS = if oci == null then "" else builtins.toJSON oci.settings;
    OCI_SKOPEO = if oci == null then "" else pkgs.lib.getExe oci.skopeo;
    PIN_HASHES = builtins.toJSON (
      pkgs.lib.unique (
        effectiveExtraHashes ++ pkgs.lib.filter (name: name != "sourceHash") buildFailureFields
      )
    );
    PYPI_FORMAT = source.format or "sdist";
    PYPI_NAME = source.pname or "";
    SIBLINGS = builtins.toJSON siblings;
    SIBLING_REFS_IN_PIN = pkgs.lib.optionalString siblingRefsInPin "1";
    SOURCE_TYPE = source.type;
    VERSION_SOURCE_TYPE = source.versions.type or "";
  };
  runtimeInputs = [
    pkgs.git
  ]
  ++ pkgs.lib.optional (siblings != [ ]) (pkgs.python3.withPackages (p: [ p.packaging ]))
  ++ pkgs.lib.optional (formatter != null) formatter;
  text = ''exec ${../scripts/update-version.sh} "$@"'';
}
