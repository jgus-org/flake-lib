# Generates the `update-version` package.
#   hashMode     : "prefetch" (default) or "build-failure" (vendor hashes that can't be prefetched)
#   buildFailureHash  : the one pin field name whose value the build's hash mismatch can name
#   buildFailureHashes : the pin field names any of which the build's hash mismatch can name
#   buildTarget    : published package a build-failure hash is mined from (default: the whole published family)
#   extraHashes  : extra pin field names whose values the artifactHook emits (e.g. [ "npmDepsHash" ])
#   artifactHook : consumer script (path) that regenerates vendored files + prints name=value extra hashes
#   formatter    : the repository's own formatter package (e.g. self.formatter.${system}). Required when a pin field name carries a dot: that field is written as a nested attribute, and only the org formatter defines that shape.
#   siblings     : sibling-cascade specs
#   markerEnvironment : overrides for the explicit PEP 508 marker environment sibling resolution evaluates under
with builtins;
{
  artifactFingerprint ? "",
  artifactHook ? null,
  buildFailureHash ?
    if hashMode == "build-failure" && buildFailureHashes == [ ] then "sourceHash" else null,
  buildFailureHashes ? [ ],
  buildTarget ? "",
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
assert
  !(source ? versions)
  || (
    source.type == "oci"
    && builtins.elem source.versions.type [
      "github"
      "registry"
    ]
  );
# A registry names its own tags, so a version source that reads them has no endpoint to choose.
assert !(source ? versions) || source.versions.type != "registry" || !(source.versions ? track);
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
  # EXTRA_HASHES and SIBLINGS are JSON, so the generated export carries quotes and brackets that shellcheck reads as a quoting error (SC2089/SC2090). GH_ASSET and GH_TAG hold a literal ${version} or ${tag} token that the script substitutes at runtime, so they stay single-quoted (SC2016).
  excludeShellChecks = [
    "SC2016"
    "SC2089"
    "SC2090"
  ];
  name = "update-version";
  runtimeEnv = {
    ARTIFACT_FINGERPRINT = artifactFingerprint;
    ARTIFACT_HOOK = if artifactHook == null then "" else "${artifactHook}";
    BUILD_FAILURE_HASHES = toJSON buildFailureFields;
    BUILD_PACKAGES_SCRIPT = "${pkgs.copyPathToStore ../scripts/build-packages.sh}";
    BUILD_PACKAGES_SELECT = "${pkgs.copyPathToStore ../scripts/build-packages-select.nix}";
    BUILD_TARGET = buildTarget;
    CASCADE_PY = "${pkgs.copyPathToStore ../scripts/cascade.py}";
    DEPS_CORE = "${pkgs.copyPathToStore ../scripts/deps_core.py}";
    EXTRA_HASHES = toJSON effectiveExtraHashes;
    FORMATTER = if formatter == null then "" else pkgs.lib.getExe formatter;
    GH_ASSET = source.asset or ""; # github-release-asset: filename template, tokens ${version} and ${tag}
    GH_BRANCH = source.branch or ""; # commit-tracking: branch to follow (default: repo's default branch)
    GH_FETCH_SUBMODULES = if (source.fetchSubmodules or false) then "1" else ""; # hash the tree with submodules (src must set fetchSubmodules = true)
    GH_OWNER = versionSource.owner or "";
    GH_REPO = versionSource.repo or "";
    GH_TAG = source.tag or ""; # github-release-asset: tag template, token ${version} (default v${version})
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
    GH_TRACK = source.track or "release"; # release (Releases API) | tag (latest version git tag) | commit (default-branch HEAD -> 0.devDATE+gREV)
    GITLAB_DOMAIN = source.domain or "gitlab.com";
    GITLAB_OWNER = source.owner or "";
    GITLAB_REPO = source.repo or "";
    GITLAB_TRACK = source.track or "commit"; # release (tags -> X.Y.Z) | commit (master HEAD -> 0.devDATE+gREV)
    HASH_MODE = hashMode;
    HF_FILES = toJSON (source.files or [ ]);
    HF_MANIFEST_EXCLUDE = toJSON (if hfManifest == null then [ ] else hfManifest.exclude or [ ]);
    HF_MANIFEST_HASH_FIELD = if hfManifestHashField == null then "" else hfManifestHashField;
    HF_MANIFEST_INCLUDE = toJSON (if hfManifest == null then [ ] else hfManifest.include or [ ]);
    HF_MANIFEST_PATH = if hfManifest == null then "" else hfManifest.path;
    HF_REPO = if source.type == "huggingface" then source.repo else "";
    HF_REVISION = source.revision or "main";
    MARKER_ENV = toJSON (defaultMarkerEnvironment // markerEnvironment);
    MUTABLE_URL = source.url or "";
    NIX_PATH = "nixpkgs=${pkgs.path}";
    OCI_SETTINGS = if oci == null then "" else toJSON oci.settings;
    OCI_SKOPEO = if oci == null then "" else pkgs.lib.getExe oci.skopeo;
    PIN_HASHES = toJSON (
      pkgs.lib.unique (
        effectiveExtraHashes ++ pkgs.lib.filter (name: name != "sourceHash") buildFailureFields
      )
    );
    PYPI_FORMAT = source.format or "sdist";
    PYPI_NAME = source.pname or "";
    REGISTRY_TAGS_LIB = "${pkgs.copyPathToStore ../scripts/registry-tags.sh}";
    SIBLINGS = toJSON siblings;
    SIBLING_REFS_IN_PIN = pkgs.lib.optionalString siblingRefsInPin "1";
    SOURCE_TYPE = source.type;
    VERSION_SOURCE_TYPE = source.versions.type or "";
    # The prefix a registry puts on the tag it publishes a version under, which is the only way a bare version argument names an image in that registry.
    VERSION_TAG_PREFIX = versionSource.tagPrefix or "";
  };
  runtimeInputs = [
    pkgs.git
  ]
  ++ pkgs.lib.optional (siblings != [ ] || (source.versions or { }).type or "" == "registry") (
    pkgs.python3.withPackages (p: [ p.packaging ])
  )
  ++ pkgs.lib.optional (formatter != null) formatter;
  text = ''exec ${../scripts/update-version.sh} "$@"'';
}
