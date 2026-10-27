# flake-lib

Shared library for the `jgus-org/*-flake` family of pinned-dependency sub-flakes. It generates the boilerplate those repos would otherwise hand-copy: the per-version-branch orchestrator, the `update-version` machinery, and PyPI package builders all come from a small declarative spec.

Consumers pin it as an input (`github:jgus-org/flake-lib/v1`) and pull improvements by
bumping that pin — the same `nix flake update` the orchestrator already runs per
branch. There is no copy-and-merge of scripts between repos.

## API (`flake-lib.lib`)

```nix
# High-level: a simple PyPI leaf collapses to one call.
flake-lib.lib.mkLeafFlake {
  inherit nixpkgs;
  source  = { type = "pypi"; pname = "iso639_lang"; format = "sdist"; };  # pname = PyPI dist (underscore form)
  package = { attr = "iso639-lang"; description = "..."; };               # attr = nix attr (dash form)
  pin     = import ./pin.nix;
}
# => packages.<system> = { <attr>; update-version; update-branches; default; }

# The org-standard formatter, so a repo carries no treefmt config, no treefmt-nix input,
# and no formatter config files of its own.
flake-lib.lib.mkFormatting {
  inherit self system;
  excludes = [ "secrets/**" ];  # repo-specific paths, merged with treefmt's own defaults
}
# => { formatter; check; }

# Per-system outputs, over the systems this fleet builds for.
flake-lib.lib.eachDefaultSystem      (system: { packages.default = ...; })  # x86_64-linux, aarch64-linux, aarch64-darwin
flake-lib.lib.eachDefaultLinuxSystem (system: { packages.default = ...; })  # x86_64-linux, aarch64-linux
flake-lib.lib.defaultSystems       # [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ]
flake-lib.lib.defaultLinuxSystems  # [ "aarch64-linux" "x86_64-linux" ]

# Low-level: bespoke flakes supply their own package derivation.
flake-lib.lib.mkUpdateVersion  { pkgs; source; siblings ? []; siblingRefsInPin ? false; hashMode ? "prefetch"; extraHashes ? []; buildFailureHash ? null; buildFailureHashes ? []; artifactHook ? null; markerEnvironment ? {}; artifactFingerprint ? ""; meta ? { license = mit; }; }
flake-lib.lib.mkUpdateBranches { pkgs; source; pinSchema; branchOwnedFiles ? [ "pin.nix" "flake.lock" "requirements.in" "requirements-*.lock" "wheels-*.json" "python-readiness.json" ]; extraBranchOwnedFiles ? []; extraHashes ? []; versionOverrides ? {}; versionCanon ? []; minVersionComponents ? 3; meta ? { license = mit; }; }
flake-lib.lib.mkPypiPackage    { pkgs; source; package; pin; }
flake-lib.lib.mkRevalidateHash { pkgs; hashField ? "hash"; meta ? { license = mit; }; }
flake-lib.lib.mkJsDepsHook     { pkgs; manager; source ? "shipped"; field ? null; fetcherVersion ? null; }
flake-lib.lib.mkComposedHook   { pkgs; hooks; }
flake-lib.lib.mkHuggingFaceModelManager { pkgs; name; manifest; model; meta ? { license = mit; }; stampName ? ".${name}-verified.json"; }
flake-lib.lib.mkOciImage       { pkgs; source; pin; meta ? {}; }
flake-lib.lib.versionMatchesComparison actual { operator; version; }
flake-lib.lib.depsCore                                                   # store path of the shared python dep-resolution module; load via the DEPS_CORE env var
flake-lib.lib.pythonEnvironments                                         # prepared wheelhouse environments: pythonVersions + systems + targets
flake-lib.lib.platformTags     { pythonVersion; platform; }              # "3.13" + "x86_64-manylinux_2_28" -> uv/pip tag attrs
flake-lib.lib.mkPythonWheelhouse { pkgs; sources; extraRequirements ? []; noEmit ? []; pythonVersions ? pythonEnvironments.pythonVersions; systems ? pythonEnvironments.systems; index ? "https://pypi.org/simple"; depsCore ? flake-lib.lib.depsCore; }  # -> { hook; fingerprint; }
flake-lib.lib.wheelhouseArtifactPaths { root; pythonVersion; system; pythonVersions ? pythonEnvironments.pythonVersions; } # -> { requirementsLock; wheelManifest; }
flake-lib.lib.mkWheelhouse     { pkgs; wheels; noEmit ? []; }             # target-qualified wheels JSON path or list -> { files; wheelhouse; }
flake-lib.lib.installWheelhouse { python; target; wheelhouse; }          # bash snippet installing a wheelhouse into a target dir
flake-lib.lib.mkWheelhouseSiteTree { pkgs; python; wheelhouse; checkImports ? []; nativeBuildInputs ? []; buildInputs ? []; .. } # -> derivation installing a wheelhouse as a site tree, ELF-patched, with a clean-interpreter import check

# Returns pkgs.${name}, emitting an eval warning when a version-numbered nixpkgs
# package (postgresql_18, php83, jdk21_headless, …) has a higher major available.
flake-lib.lib.warnIfNewerMajor { pkgs; name; lib ? pkgs.lib; }
```

`source.type` is `pypi`, `github`, `github-release-asset`, `huggingface`, `gitlab`, `mutable-url`, or `oci`. `github`
hashes the source _tree_ at a release tag (`{ version, sourceRev, sourceHash }`);
GitHub sources whose release tags have an additional prefix set `tagPrefix`, such as `source = { type = "github"; owner = "openai"; repo = "codex"; tagPrefix = "rust-v"; };`. Pins and version branches use the version without that prefix.
A `github` source names its versions in exactly one of two places, and `track` says which: `release` (the default) reads the GitHub Releases API, and `tag` reads the repository's git tags. An upstream that ships tags without opening GitHub Releases for them has an empty releases list, so a producer for one tracks `tag` — otherwise its versions are invisible to both the updater and the orchestrator.
A `gitlab` source names its versions as the project's git tags, which is also where its updater resolves a release from, so there is no endpoint for `track` to choose between; `mkUpdateBranches` enumerates those tags and refuses a gitlab source that asks for `tag`.
`github-release-asset` instead prefetches a single prebuilt release asset into a
`{ version, hash }` pin (`pinSchema = "github-asset"`), for upstreams shipped as a
ready-to-run binary/jar rather than built from source:

```nix
source = {
  type = "github-release-asset";
  owner = "Suwayomi"; repo = "Suwayomi-Server";
  asset = "Suwayomi-Server-v\${version}.jar";  # tokens: \${version} (tag minus leading v), \${tag}
  # tag = "\${version}";                        # optional; default "v\${version}"
};
```

`mutable-url` tracks a small artifact whose URL remains stable while its contents change. It is single-branch and has no meaningful upstream version. The updater compares the final response's `Last-Modified` header with the `{ lastModified, hash }` pin and downloads the artifact only when that header changes.

```nix
source = {
  type = "mutable-url";
  url = "https://downloads.example.test/artifact.bin";
};
```

`oci` tracks a public registry tag and pins `{ imageDigest, imageHash }`. `imageName` must include the registry hostname. The updater accepts an optional tag or `sha256:...` digest in the configured repository, resolves an image index to one platform manifest, checks its platform, and copies that immutable manifest with its config and layers unchanged. `imageHash` is the recursive Nix hash of the resulting Skopeo directory.

```nix
source = {
  type = "oci";
  imageName = "docker.io/vendor/runtime";
  tag = "latest-sm86";
  os = "linux";
  arch = "amd64";
  finalImageName = "vendor/runtime";
};
image = flake-lib.lib.mkOciImage { inherit pkgs source; pin = import ./pin.nix; };
update-version = flake-lib.lib.mkUpdateVersion { inherit pkgs source; };
```

`tag`, `os`, and `arch` default to `latest`, `linux`, and `amd64`; `variant` is optional. The returned package is the image directory, with `imageName`, `imageTag`, `copyTo`, and `copyToPodman` attributes for loading it. Its local name defaults to `imageName`, and its local tag defaults to the manifest digest without `sha256:`; `finalImageName` and `finalImageTag` can override them. `copyTo` accepts a Skopeo destination and additional copy arguments. Public fetches use isolated registry configuration and an empty authentication file. Pulling and loading preserve the original image manifest, config, and compressed layers rather than rebuilding a base image. OCI updates skip downloads for a matching platform manifest digest and populated hash, preserve dependency locks, and restore the original pin and lock if updating or verification fails. A versioned producer skips only once its pin also names the version being resolved. A legacy `archiveFingerprint` triggers one fetch to migrate the hash to the directory format and remove that field. OCI source updates do not support sibling cascades, artifact hooks, or extra hash fields.

An `oci` producer opts into the version tree by adding `versions` to the same spec, whose `type` selects the discovery path already implemented for that vocabulary (`github` reads the endpoint that source's `track` names; a registry-tag source would be a new arm, not a producer-shape change). Its pin is `{ version, imageDigest, imageHash }`; a producer without `versions` keeps pinning exactly `{ imageDigest, imageHash }`. Absence of `versions` is the single-branch signal, so an existing producer is untouched by construction, still rejects a second positional argument, and still pins no version.

```nix
source = {
  type = "oci";
  imageName = "ghcr.io/home-assistant/home-assistant";
  os = "linux";
  arch = "amd64";
  versions = { type = "github"; owner = "home-assistant"; repo = "core"; };
};
image = flake-lib.lib.mkOciImage { inherit pkgs source; pin = import ./pin.nix; };
update-version = flake-lib.lib.mkUpdateVersion { inherit pkgs source; };
update-branches = flake-lib.lib.mkUpdateBranches { inherit pkgs source; pinSchema = "oci"; };
```

A versioned producer pins no `tag`: it publishes its image under its version, so the registry reference is the release version with any GitHub version prefix removed, which is also the version recorded in the pin. Invoking its `update-version` with no arguments resolves the newest upstream release through GitHub's `releases/latest` endpoint, which excludes drafts and prereleases; publish the whole tree with `update-branches`, whose `pinSchema = "oci"` seeds a new exact branch from the base pin's `imageDigest` and `imageHash` alone. A seed claims no version, because `mkOciImage` asserts the digest's shape at evaluation and the branch must not name a release before its image has been resolved. The updater then writes that branch's own version, and reuses the already-pinned content when the resolved image is the one the branch was seeded with. Several releases sharing one image digest is a correct pairing rather than a stale pin, and a version branch counts as unchanged only once its pin names the version it is being resolved for.

`versions` therefore requires the registry to publish the bare release version as a tag. `versionOverrides` and `versionCanon` rename the canonical version — the branch and the pin's `version` — but the updater pulls the tag named by the upstream release version, so neither redirects the image reference. An upstream whose registry tag is spelled differently has no mechanism here and remains a single-branch producer until a version source that reads registry tags exists. The loaded image's local name and tag follow `finalImageName`/`finalImageTag` as usual; with neither set, a versioned pin tags the image with its own version, and a branch seeded before its image resolved falls back to the digest.

`meta.sourceProvenance` on the image defaults to `binaryNativeCode`: the layers arrive as upstream's binaries and nothing in the build reads them. A caller's own `meta` overrides it. No license is defaulted, because the content is upstream's and neither `pin` nor `source` names its terms — writing one into the image's config would also change the config digest the pin pins, so image metadata belongs on the derivation.

`huggingface` tracks a model repository revision and writes a `{ version,
sourceRev }` pin. An optional `files` list adds a `hashes` attribute containing
the Nix content hash of each selected repository file:

```nix
source = {
  type = "huggingface";
  repo = "BAAI/bge-reranker-v2-m3";
  files = [ "config.json" "model.safetensors" ];
};
```

For checkpoints too large to import into the Nix store, `manifest` writes immutable blob metadata without downloading the artifacts. `include` and `exclude` contain jq regular expressions matched against repository-relative paths. An empty `include` selects every file. The generated pin records the manifest's SHA256 in `manifestHash` by default; set `hashField` to choose another field name.

```nix
source = {
  type = "huggingface";
  repo = "example/large-model";
  manifest = {
    path = "model-manifest.json";
    exclude = [ "^\\." "\\.complete\\.json$" ];
  };
};
```

`mkHuggingFaceModelManager` builds the matching runtime downloader from one manifest file path. It exposes the supplied `model` value as `passthru.model`; `stampName` defaults to `.${name}-verified.json`. `meta` defaults to the MIT license, because the downloader is flake-lib's own script, and a caller passing `meta` replaces it. Its executable accepts `download DIRECTORY`, `verify DIRECTORY`, and `check DIRECTORY`. `download` fetches the manifest files and verifies them, `verify` hashes them, and `check` validates the current manifest stamp plus file sizes without rehashing. `download` authenticates against Hugging Face only when the caller's environment exports `HF_TOKEN`; the local HF token store is never picked up implicitly.

```nix
modelManager = flake-lib.lib.mkHuggingFaceModelManager {
  inherit pkgs;
  name = "example-model";
  manifest = ./model-manifest.json;
  model = { repository = "example/large-model"; };
};
```

The update machinery and the orchestrator's per-flake bits
(`list_upstream_versions`, `prepare_new_branch_pin`, and sibling cascades) are all driven from that spec. `version-only` preserves the current complete pin while creating a branch so a bespoke updater can evaluate and atomically replace it with the target version's complete pin. `oci` seeds a content-only placeholder pin, and an `oci` producer discovers its versions from `source.versions` rather than from `source.type`.

PyPI producers resolve sibling requirements from their release metadata. Exact pins select exact branches, unbounded minimums select `main`, and bounded ranges select a compatible aggregate. Prerelease exact branches are always maintained. A prerelease advances each aggregate independently only when that aggregate is absent or already tracks a prerelease; stable aggregates remain stable until a newer stable release replaces them.

GitHub producers read sibling requirements from `reqFile = "requirements.txt"` by default. Set `reqFormat = "pyproject"`, `reqFile = "pyproject.toml"`, and `reqGroups = [ "extra-name" ]` to combine `[project].dependencies` with selected optional-dependency groups. Environment markers are evaluated before the compatible branch is selected.

Set `siblingRefsInPin = true` to write the resolved refs under `pin.nix.dependencies` instead of rewriting `flake.nix`. The updater applies those refs while regenerating `flake.lock`, so each historical branch owns its complete source and dependency selection through `pin.nix` and `flake.lock` while `flake.nix` retains generic input URLs.

The updater evaluates `packages.default` on every run and builds nothing of its own; the publisher builds, see [Publication builds the tracked package](#publication-builds-the-tracked-package). The one build the updater does start is hash discovery: a fixed-output hash that cannot be prefetched is recovered from `packages.default`'s hash-mismatch error, which is what `hashMode = "build-failure"` and `buildFailureHash`/`buildFailureHashes` select.

`buildFailureHash` names one additional pin field whose value is populated from
the package build's fixed-output hash mismatch. This supports dependency fetchers
such as `fetchPnpmDeps` while the source tree continues to use normal prefetching.
For PyPI sources, pass the same field through `mkUpdateBranches.extraHashes` so
new version branches include it in their placeholder pins.
Use `pinSchema = "github-pnpm"` for the corresponding `{ version, sourceRev,
sourceHash, pnpmDepsHash }` branch placeholders.

`buildFailureHashes` declares the set of pin fields the build's hash mismatch may name, for a package whose build fails on whichever of its unprefetchable dependencies is stale first: `{ buildFailureHashes = [ "pnpmDepsHash" "vendorHash" ]; }` covers a `fetchPnpmDeps` tree and a `buildGoModule` vendor tree in one bump. A mismatch is attributed to the declared field already holding the hash the build reported as specified, and while no declared field is resolved yet, to the first declared field. `buildFailureHash` and `buildFailureHashes` combine, and each declared field is resolved at most once, so the build runs at most one more time than there are declared fields. A build that still reports a hash mismatch once every declared field is resolved ends the run, as does a mismatch belonging to a pin field no declaration covers.

### Supported systems

`eachDefaultSystem` and `eachDefaultLinuxSystem` replace `flake-utils.lib.eachDefaultSystem`, which still iterates `x86_64-darwin`. Nixpkgs 26.11 dropped that platform. On `nixpkgs-unstable` a revision from late August 2026 on, `import nixpkgs { system = "x86_64-darwin"; }` throws `Nixpkgs 26.11 has dropped support for x86_64-darwin.` from `pkgs/top-level/default.nix`; `nixos-26.05` and earlier 26.11 revisions only warn that 26.05 is the last release to support it, which a verification build run with `--option abort-on-warn true` already turns into an abort. Either way a flake naming that host keeps evaluating until something forces its attributes — `nix flake check`, `nix flake show --all-systems`, a CI matrix over systems, or a consumer resolving `packages.x86_64-darwin.*`. What goes away here is the build host only: a producer can still ship an Intel macOS artifact by cross-compiling or pinning an upstream prebuilt, and the wheel targets below keep naming it as an artifact target.

Reach for `eachDefaultLinuxSystem` when the producer cannot run on macOS at all — a Linux-only binary, something that needs the Linux kernel, an OCI image with no darwin variant. The two lists are exported as well, for code that keys a value by system instead of iterating one, such as a per-system asset map or a CI matrix.

Both helpers merge a system's outputs the way flake-utils does (`packages.<system>.<attr>`) and need no flake input of their own, so a producer that carried flake-utils only to enumerate systems can drop that input. `mkLeafFlake` iterates the same three, so a leaf producer needs no flake-utils at all. This library carries no flake-utils input itself; a consumer that still forwards one to it (`inputs.flake-utils.follows = "flake-utils"` on the `flake-lib` input) earns `input 'flake-lib' has an override for a non-existent input 'flake-utils'`, so that line goes with the rest.

They differ from flake-utils in one case: under `--impure`, flake-utils adds `builtins.currentSystem` to the set when the evaluating host is not already in it, while these helpers iterate exactly the hosts they name.

### Python wheel closures

`mkPythonWheelhouse` is an `artifactHook` that pins a consumer's complete python
dependency closure as hash-pinned wheels instead of per-package flakes or
floating nixpkgs pythonPackages. It returns `{ hook; fingerprint; }`: pass
`hook` through `mkComposedHook` (or directly) as the `artifactHook`, and
`fingerprint` to `mkUpdateVersion`'s generic `artifactFingerprint` so the hook
re-runs when its complete generation contract moves, even at an unchanged
version and rev. `mkUpdateVersion` adds the `artifactFingerprint` pin field
automatically and rejects a hook result that does not emit the declared value.

flake-lib pre-prepares wheel sets for these environments:

```nix
flake-lib.lib.pythonEnvironments
# {
#   pythonVersions = [ "3.13" "3.14" ];
#   systems = defaultSystems;  # the standard three
#   targets = {
#     x86_64-linux = { uvPlatform = "x86_64-manylinux_2_28"; };
#     aarch64-linux = { uvPlatform = "aarch64-manylinux_2_28"; };
#     x86_64-darwin = { uvPlatform = "x86_64-apple-darwin"; };
#     aarch64-darwin = { uvPlatform = "aarch64-apple-darwin"; };
#   };
# }
```

The Python-version list and system-to-platform mapping form the prepared compatibility menu: every pair is claimed support, so every environment resolves before mutation. If replacement or pruning raises `OSError`, the hook attempts to restore every pre-publication path and then fails, blocking upstream branch publication. Persistent filesystem failures during restoration or abrupt process termination can leave the worktree partial. Removed pairs, legacy unqualified artifacts, and the obsolete `python-readiness.json` are pruned after a successful resolution. A consumer may narrow `pythonVersions` or `systems` only for a demonstrated incompatibility. `requirementsHash` and `wheelManifestHash` are deterministic aggregates over the complete ordered `(python, system)` environment set.

The client declares only its requirements source:

```nix
wheelhouse = flake-lib.lib.mkPythonWheelhouse {
  inherit pkgs;
  sources = [
    { kind = "source-pyproject"; groups = [ "studio" ]; buildSystem = false; }
    { kind = "source-file"; path = "backend/requirements/studio.txt"; }
    { kind = "repo-file"; path = "requirements.in"; }
  ];
};
# mkUpdateVersion { ...; artifactHook = lib.getExe wheelhouse.hook; artifactFingerprint = wheelhouse.fingerprint; extraHashes = [ "requirementsHash" "wheelManifestHash" ]; }
```

`source-pyproject` and `source-file` read the pinned upstream source (cloned at
`NEW_REV`; `buildSystem` appends the pyproject's build-system requires);
`repo-file` reads the consumer's own repository. Requirements are merged in
order, deduplicated, resolved per environment with `uv pip compile
--generate-hashes`, fetched with `pip download --require-hashes --only-binary
:all:` over the full ≤-target manylinux tag ladder (pip matches platform tags
exactly, unlike uv's resolver), and recorded per wheel as `name`, `version`,
`filename`, `url`, `sha256`, `size`.
Requirements-file directives such as `-r` and `-c` are rejected; flatten
included requirements and constraints into the declared source file before
using it as a wheelhouse source.

`noEmit` names packages that stay in the resolution graph but are omitted from
the emitted lock and wheelhouse (`uv pip compile --no-emit-package`): the
graph keeps honoring their metadata, and their own dependencies still resolve
and are emitted. This serves environments that layer wheels over a stack the
deployment provides separately — a consumer supplying CUDA-enabled `torch`
from its own package set still needs `torch`'s dependents resolved against
`torch`'s metadata, while a lock that carried `torch` itself would install a
second, mismatched copy beside the provided one.

`mkWheelhouse` takes the same `noEmit` for the other side of that boundary. A
committed manifest records what the resolution fetched, so exclusion at the generator alone still leaves every consumer of an already-committed manifest installing the provided package beside its own copy; `noEmit` at eval time keeps it out of the artifact whatever the lock says, and never fetches it. It accepts distribution names, matched case- and separator-insensitively, or a predicate over the name as the manifest records it, which covers a family of names a resolution may or may not emit (`nvidia-*`). A listed name matching no wheel is reported at eval time rather than ignored, so an exclusion that stops matching is visible instead of silently reinstating the duplicate.

At eval time `mkWheelhouse` turns a target-qualified manifest into a hash-pinned wheelhouse. `wheelhouseArtifactPaths` selects exactly one committed manifest from the composed interpreter version and Nix target system. `installWheelhouse` installs it into an application derivation:

```nix
python = pkgs.python3;
wheelArtifacts = flake-lib.lib.wheelhouseArtifactPaths {
  root = ./.;
  pythonVersion = python.pythonVersion;
  system = pkgs.system;
};
wheelManifest = wheelArtifacts.wheelManifest;
wheelhouse = flake-lib.lib.mkWheelhouse { inherit pkgs; wheels = wheelManifest; };
nativeBuildInputs = [ pkgs.uv pkgs.autoPatchelfHook ];
installPhase = ''
  mkdir -p "$out/lib/site-packages"
  ${flake-lib.lib.installWheelhouse { inherit python; target = "$out/lib/site-packages"; wheelhouse = wheelhouse.wheelhouse; }}
'';
```

Native manylinux wheels name a loader and shared libraries that exist on the machine that
built them and nowhere in the store, so an installed wheelhouse is only a valid store
artifact once its binaries are rewritten against nix's libraries. That rewrite is the
install, not an optional addition: `mkWheelhouseSiteTree` builds the derivation, installs
the wheelhouse into `$out/$sitePackages`, and takes the same attributes as
`stdenv.mkDerivation` plus `checkImports` — module names imported in an interpreter
started with no environment at all, so a site tree that loads only under an ambient
`LD_LIBRARY_PATH` fails its build instead of its first import in production. `buildInputs`
extends the libraries the rewrite may resolve against. `meta.sourceProvenance` defaults to
`binaryNativeCode`, since wheels arrive compiled; a caller's own `meta` overrides it.

```nix
python = pkgs.python3;
wheelhouse = flake-lib.lib.mkWheelhouse {
  inherit pkgs;
  wheels = flake-lib.lib.wheelhouseArtifactPaths {
    root = ./.;
    pythonVersion = python.pythonVersion;
    system = pkgs.system;
  }.wheelManifest;
};

comfyuiWheelhouse = flake-lib.lib.mkWheelhouseSiteTree {
  inherit pkgs python wheelhouse;
  pname = "comfyui-wheelhouse";
  version = "1.2.3";
  dontUnpack = true;
  checkImports = [ "numpy" "PIL.Image" ];
  buildInputs = [ pkgs.stdenv.cc.cc.lib ];
};
```

An application that installs its own source beside its wheels is the same builder: unpack
the source, overlay or patch it with `postPatch`, and add the project install to
`postInstall` targeting `$out/$sitePackages`. `installWheelhouse` remains the snippet for
a consumer whose layout differs from a site tree.

A library a program `dlopen`s by soname with no `DT_NEEDED` entry (a GPU driver, for
instance) is not something a rewrite can introduce; that belongs in the wrapper or image
environment that runs it.

`templates/workflows/` holds the workflow files a consuming repo installs under
`.github/workflows/` under the same names: `update-branches.yml` drives the
orchestrator for a source with named releases, `update-version.yml` moves one
current pin for a source tracked by commit, `build-and-check.yml` is the gate every
pull request passes -- build what the flake publishes, then check it -- and
`update-workflows.yml` keeps every installed copy following the templates, on a schedule of
its own half an hour ahead of the update workflows. A producer
refreshes whichever it has installed by running
`nix run github:jgus-org/flake-lib/v1#update-workflows` -- flake-lib's own instance
of the tool, rather than a copy each producer republishes; see below.

Every template provides nix through `.github/actions/nix`, which installs nix where the runner has
none and leaves a runner that has nix alone, and caches through `.github/actions/fleet-nix-cache`,
a composite action that points Nix at the fleet Attic cache and pushes what a job builds to it
whenever the `ATTIC_TOKEN` secret resolves -- one organization secret covers every repository
-- and falls back to the repository's Actions cache when it does not, so repositories
and fork pull requests without a token behave as before.

### Publication builds the tracked package

`packages.default` is the tracked package, by standard rather than by convention: it is
the only attr flake-lib's publication machinery builds, evaluates, or repairs hashes
against, and a producer's own package attr name is an alias with no publication meaning.
The pull-request gate deliberately covers more than the tracked attr, because everything a
producer publishes is what its consumers build. On the publication path the publisher is
the only thing that builds, because it is the thing that cannot be trusted to have
checked -- and the publisher differs by model, so there are two call sites and one
definition. The version model publishes from its workflow, and `update-version.yml`
builds `.#default` between the updater and its commit. A refresh publishes from the
tool, because one run resolves and pushes many version branches: `refresh_version`
builds `packages.default` in the branch's own tree before it pushes anything, and no
workflow step could have reached that tree. A failed build leaves the branch, its
aggregate, and the pin unpushed, and the next run retries the same version, so the
failure is visible and the published state stays consistent.

Aggregate publication builds nothing: it moves a ref to a commit an exact branch
already published, and that refresh built it.

`buildVerificationSkip` is the way out, and the reason belongs in a comment beside it:

```nix
flake-lib.lib.mkUpdateBranches {
  inherit pkgs source;
  pinSchema = "pypi";
  # packages.default builds a 20-minute CUDA wheelhouse; the pin's own hash check is the gate here.
  buildVerificationSkip = true;
}
```

false (the default) builds. true publishes without building and logs that verification
was skipped on every run, so the exception stays visible in the log. Use it only where
the build is genuinely prohibitive; it does not make the pin correct.

### Split update-branches jobs

`mkUpdateBranches` exposes a machine-readable interface for workflows that split
maintenance across jobs:

```console
update-branches list
update-branches refresh --base-sha SHA --version CANONICAL --upstream-version RAW
update-branches publish --base-sha SHA --versions-json JSON [--for-version CANONICAL]
```

`list` writes exactly one compact JSON object to stdout; progress goes to stderr:

```json
{
  "baseSha": "<full commit SHA>",
  "versions": [
    { "version": "1.2.3", "upstreamVersion": "1.2.3", "stable": true }
  ],
  "newestStable": {
    "version": "1.2.3",
    "upstreamVersion": "1.2.3",
    "stable": true
  }
}
```

`versions` is ordered newest first and `newestStable` is either the first stable
entry or `null`. Under Actions, where `GITHUB_OUTPUT` names a file, `list` also
appends that manifest as `base_sha`, `versions`, `newest_stable`, and
`maintenance` outputs, so the workflow that fans out over it carries no version
logic of its own. `maintenance` is `versions` without `newestStable`, which is
refreshed as its own fast path rather than twice.

A refresh invocation does not query upstream: it creates or
merges exactly one `v<version>` branch from `baseSha`, then updates and pushes
that branch. Publication consumes the unchanged `versions` array, considers only
exact refs containing `baseSha`, and updates aggregates independently. When the
highest candidate is a prerelease but an aggregate is stable, the aggregate
advances to the highest successful stable candidate. `--for-version` narrows a
publication pass to the aggregates that version carries: it selects which
aggregates the pass may move, never which version one moves to, so a publisher
that runs before the maintenance fan-out has refreshed the other lines reports
nothing about them. Invoking `update-branches` without arguments retains the
compatible all-in-one behavior.

The workflow template uses the newest stable entry as a fast path, publishing
the aggregates that entry carries before the matrix starts, refreshes all
remaining exact versions in a parallel matrix, and runs a final publisher even
when a maintenance job fails. Both publishers and every exact job reuse the
discovery SHA and version manifest. Every job restores Nix from the shared
GitHub Actions cache, so a bump reuses the dependency closure an earlier run
built, and the maintenance matrix bounds its fan-out so a growing release list
cannot spawn unbounded parallel refreshes. Ref publication uses bounded retries and
re-reads the remote after every failed push: an already-applied desired SHA is
accepted, an unchanged ref is retried, and a different concurrent update is
never overwritten. Branch update commands receive one additional attempt only
when their output identifies a transient network failure.

### Where an update runs

Every update template -- the publication workflows and the workflow that refreshes the
installed copies -- runs on `ubuntu-latest` unless the repository sets its `RUNNER` variable
to a label one of its own runners carries; the gate routes by the same
variable. Set it only once a runner answers the label, because GitHub queues a job whose
labels nothing answers until the job times out.

### Refresh installed workflows (`update-workflows`)

Workflow files are copies of flake-lib's templates, so on their own they cannot
follow the templates: flake-lib moves and the installed copy does not. The
`update-workflows` package closes that gap, and `templates/workflows/update-workflows.yml`
is the workflow that runs it, on a schedule half an hour ahead of the update workflows:

```console
nix run github:jgus-org/flake-lib/v1#update-workflows
```

Producers invoke flake-lib's own instance rather than republishing one through their
own `packages`. Nothing about the calling flake is baked into the tool -- it reads the
lock and the installed workflows -- so a re-export is boilerplate, and a re-export is
also self-defeating: `nix run .#update-workflows` evaluates the _program_ at the
revision the flake currently locks, which leaves the tool doing the adopting one
revision behind the templates it installs.

The tool reads the `flake-lib` input out of `flake.lock`, advances it, and
overwrites each workflow in `.github/workflows` whose name a template of that
revision ships. It picks no names of its own: which workflows a repo has beyond
`update-workflows.yml` — the schedule that runs the tool, which every run installs or
refreshes — is the author's decision, and a workflow flake-lib has no template for is left
alone. Installing the schedule everywhere is what carries a template to a repository that has
no updater at all: the pull-request gate is a copy of a template like any other, and without
this it is frozen the day it is installed.
What is compared is the installed file against the template at the revision _now
locked_, not the revision the run started from — the pin path advances
`flake-lib` as it commits pins, so a lock can reach a revision without that
revision's templates having been installed, and a refresh that asked only whether
the input had moved would leave a repository running old workflow files against
new scripts indefinitely. Anything a template does not carry is a constructor
argument in `flake.nix`, baked into the package the workflow invokes, which is why
a template can replace its workflow file wholesale. The advanced input and the
refreshed workflows are committed together,
because a workflow that tracks flake-lib N would otherwise be refreshing the
scripts it invokes from revision N too.

A refreshed workflow takes effect for the next run of the workflow it rewrote, and the
schedule half an hour ahead of the update workflows means that is the same day.

A repository with no workflow named like a template joins that set by naming one:

```console
nix run github:jgus-org/flake-lib/v1#update-workflows -- adopt update-version.yml
```

This installs exactly the named template — creating it, or replacing a hand-written file
of the same name — and advances the
input even when it is already current, since joining does not depend on the revision
moving. It is the upgrade path for a producer that exists only on GitHub and so has no
local source to promote from. `update-workflows.yml` joins by that same command, and is
installed with any update workflow that needs it.
The tool never picks the publication model, and retiring a
workflow flake-lib has no template for stays the author's `git rm`; what is still in the
way is named in the output, the refresher's own workflow excepted.

The commit goes to the branch the run started on. Nothing reports a commit SHA for a later
job to check out, because the run that writes a workflow file is never the run that executes
it. When the input did not move and every installed workflow already matches the template at
the revision locked, nothing is committed and the run says so.

### Order a producer after its dependencies (`wait-for-deps`)

A producer whose flake takes inputs from other producers must not pin them before their
own update has published: the sibling resolver derives a ref from the upstream's declared
requirements and assumes the sibling already published it, so a dependency that has not run
yet yields either a silently unpinned input or a red run.

Spacing the schedules apart approximates that ordering, and cannot hold: scheduled runs are
delayed by queue pressure, a dependency's build can overrun the gap, and the gap has to be
maintained by hand as the graph changes. `wait-for-deps` observes the ordering instead:

```console
nix run github:jgus-org/flake-lib/v1#wait-for-deps
```

The edges are the inputs the repository already declares — every github input in
`flake.lock` owned by this repository's own owner, excluding `flake-lib` itself. They are
never declared a second time, and the graph cannot cycle, because a flake's inputs are
acyclic by construction. A leaf producer takes no such input and reports nothing to wait
for.

For each dependency, in this order: a completed update run within the freshness window
means it is done; a recent run that ended badly is reported and skipped; a queued or
running update is waited for; anything else is started with `workflow_dispatch` and then
waited for. Dependencies are waited for concurrently, so the wait is the slowest
dependency rather than their sum, and a chain of them resolves in real dependency depth
rather than in fixed slots.

The wait reports as it goes rather than only at the end: it names the dependencies it
intends to order and the budget each one has before it reads anything, and it reports each
dependency the moment it settles with how many are still outstanding, because a consumer's
run is read in a log where a silent wait is indistinguishable from a hung one.

Every failure to establish ordering other than a refused credential ends in continuing
without waiting, and the exit status is success: a dependency that cannot be observed, that
fails, or that never finishes must not stop the fleet. The report says which of those
happened, and says so when the dependency's update was started by this run, since that run is
not otherwise attributable to the consumer that began it.

A credential the API refuses is the exception, because it is the one failure that says the
wait was never going to observe anything: through it no run can be read and none can be
started. The gate names the dependencies it could not order, and exits with status 1 when
that is every one of them, so the run that asked to be ordered ends red rather than updating
with its dependencies unpublished.

Reading another repository's runs needs Actions read, and starting its update needs
Actions write — the first repository role that grants "create, edit, run, re-run, and
cancel GitHub Actions workflows" is Write. The templates pass one organization secret,
`ORG_UPDATE_TOKEN`, so every producer is covered at once and none of them declares
anything, in the same shape as `ATTIC_TOKEN`. With no such secret the gate observes
nothing and proceeds, in the same shape as the Attic cache action's fallback.

### Gate a pull request (`build-packages`)

A flake's packages are the surface its consumers build, and nothing in a producer's CI built
them: `nix flake check` builds `checks` and only looks at the shape of `packages`, and the
updater's own build runs after the change is already merged.
`templates/workflows/build-and-check.yml` is the gate that builds them, running flake-lib's
own instance of the tool:

```console
nix run github:jgus-org/flake-lib/v1#build-packages
```

It builds every package the flake publishes for the system the runner is on, reading the
calling tree rather than anything baked into the workflow, so a package a producer adds
later is gated by the next pull request without a workflow change. `--dry-run` prints the
installables it would build, which is how a repository is audited before adopting;
`--system` selects another system's family and `--flake` reads another tree.

Adopting it names the template the way every other flake-lib workflow is adopted, and it
then refreshes with the rest:

```console
nix run github:jgus-org/flake-lib/v1#update-workflows -- adopt build-and-check.yml
```

A flake that locks a private repository needs one secret, because nix fetches a github input
anonymously: `BUILD_TOKEN`, a credential that can read the contents of every private repository
the flake locks. It is inert where the secret does not resolve, so a repository of public inputs
declares nothing, and a run without it fetches the public inputs alone. Set it on the
repositories that need it rather than organization-wide: a secret an organization grants every
repository is readable by the pull requests of every public one, which is a wider circle than a
contents credential justifies. GitHub gives a fork pull request no secrets at all, so a flake
with a private input is gated by pull requests from inside the organization.

A package the runner cannot build excuses itself, with the reason in the comment beside
the marker:

```nix
packages.${system}.vm-test =
  (pkgs.callPackage ./test/vm.nix { }).overrideAttrs (_final: previous: {
    # This package is the VM run derivation: building it boots two VMs, and a hosted runner
    # has no nested virtualization.
    passthru = (previous.passthru or { }) // { ciBuildSkip = true; };
  });
```

A VM suite usually does not need the marker. `nixosTest` publishes its driver beside its run
derivation, and building the driver type-checks the test script and builds every guest system
while booting nothing, so the package that earns a gate is the driver and the part that needs
`kvm` stays unpublished.

The run names every package it excused, so an exemption cannot go unnoticed, and a marker
that is not a boolean fails the run. It is the per-package sibling of the publication path's
`buildVerificationSkip`; the two gate different builds.

One system per run, which is a scope decision rather than a limit: hosted arm64 runners
exist and a second job could gate `aarch64-linux`. Apps and devShells are not built -- an
app names a program to run, and a `mkShell` derivation has no build phase to fail. A flake
that publishes nothing buildable for the runner's system reports that and passes, which is
why every published flake installs the gate whatever it publishes.

The gate triggers on a pull request and a dispatch, not a push: an updater's commit is
pushed with the run's `GITHUB_TOKEN`, which starts no workflow, and it is built by the
publication path that made it. A push trigger would build the whole family to verify a
workflows refresh, which is what most of a producer's machine-made commits are.

### Org-standard formatting (`mkFormatting`)

Every repo in the org formats with the same program set and the same config files, so a
repo opts in instead of configuring:

```nix
outputs = { self, flake-lib, nixpkgs, ... }:
  flake-lib.lib.eachDefaultSystem (system:
    let
      formatting = flake-lib.lib.mkFormatting { inherit self system; };
    in
    {
      formatter = formatting.formatter;
      checks.formatting = formatting.check;
    });
```

`self` is the tree to format, so a flake-parts module and a plain flake both pass what they
already have in scope. `excludes` adds the paths only the repo knows about — generated files,
vendored trees, secrets — on top of the excludes treefmt applies by default.

The program set is a union across the org, and a repo that does not write a language
simply has no files the matching formatter picks up:

| Formatter      | Files                             | Settings                                                                                                              |
| -------------- | --------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `nixfmt`       | `*.nix`                           | the command is `pedantix` (attrs grouped and sorted over nixfmt's RFC style), configured by `formatter/pedantix.toml` |
| `clang-format` | C, C++, GLSL                      | `formatter/.clang-format` (Google base, 120 columns, no bin packing)                                                  |
| `ruff-format`  | `*.py`, `*.pyi`                   | `--line-length 79`                                                                                                    |
| `shfmt`        | `*.sh`, `*.bash`, `.envrc`        | indent 2, no `-s` simplification                                                                                      |
| `prettier`     | js, ts, json, md, yaml, css, html | prettier's own defaults                                                                                               |
| `gofmt`        | `*.go`                            | not `gofumpt`: two formatters cannot both claim `*.go`                                                                |

Two formatters must not match the same file, because treefmt lets the higher-priority one
win in silence: `nixfmt` rather than `deadnix`/`statix`/`alejandra`/`nixpkgs-fmt` for Nix,
`ruff-format` rather than `black`/`yapf`/`isort` for Python, `shfmt` rather than `beautysh`,
`prettier` rather than `yamlfmt`/`taplo`/`biome`/`dprint`/`oxfmt`.

Tools resolve from **this flake's own** pinned nixpkgs and from nothing else: the function
takes no `pkgs`, so a repo cannot resolve the tools elsewhere. Every repo formats identically
and a repo upgrades its formatter by bumping its flake-lib pin. The same
drift returns through a `follows` edge on `flake-lib.inputs.nixpkgs`, which is why a consumer
leaves that edge off: every other flake-lib function takes the caller's `pkgs` as an argument,
so a consumer that drops the edge changes nothing but its formatter. The two config files reach
their tools by absolute store path, which means a repo that still carries its own
`.clang-format` or `pedantix.toml` would keep two copies of one standard: those files are
removed in consuming repos, not overridden.

A dev shell that wants the formatters on its `PATH` adds `formatter`, and the tools a specific
editor drives, from its own `pkgs`; flake-lib does not build a shell for a repo.

## Versioning

Hand-versioned via git tags (`vX.Y.Z`) with a moving `v1` aggregate branch. Breaking
changes bump to `v2`; consumers migrate deliberately, so one push can't break every
repo at once.

See [LICENSE.md](LICENSE.md) for licensing and copyright.
