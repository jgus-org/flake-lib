# flake-lib

Shared library for the `jgus-org/*-flake` family of pinned-dependency sub-flakes. It generates the boilerplate those repos would otherwise hand-copy: the per-version-branch orchestrator, the `update-version` machinery, and PyPI package builders all come from a small declarative spec.

Consumers pin it as an input (`github:jgus-org/flake-lib/v1`) and pull improvements by
bumping that pin — the same `nix flake update` the orchestrator already runs per
branch. There is no copy-and-merge of scripts between repos.

## API (`flake-lib.lib`)

```nix
# High-level: a simple PyPI leaf collapses to one call.
flake-lib.lib.mkLeafFlake {
  inherit nixpkgs flake-utils;
  source  = { type = "pypi"; pname = "iso639_lang"; format = "sdist"; };  # pname = PyPI dist (underscore form)
  package = { attr = "iso639-lang"; description = "..."; };               # attr = nix attr (dash form)
  pin     = import ./pin.nix;
}
# => packages.<system> = { <attr>; update-version; update-branches; default; }

# Low-level: bespoke flakes supply their own package derivation.
flake-lib.lib.mkUpdateVersion  { pkgs; source; buildAttr; siblings ? []; siblingRefsInPin ? false; hashMode ? "prefetch"; extraHashes ? []; buildFailureHash ? null; artifactHook ? null; verification ? if buildFailureHash == null then "evaluate" else "build"; markerEnvironment ? {}; artifactFingerprint ? ""; }
flake-lib.lib.mkUpdateBranches { pkgs; source; pinSchema; branchOwnedFiles ? [ "pin.nix" "flake.lock" "requirements.in" "requirements-*.lock" "wheels-*.json" "python-readiness.json" ]; extraBranchOwnedFiles ? []; extraHashes ? []; versionOverrides ? {}; versionCanon ? []; minVersionComponents ? 3; }
flake-lib.lib.mkPypiPackage    { pkgs; source; package; pin; }
flake-lib.lib.mkRevalidateHash { pkgs; buildAttr; hashField ? "hash"; }
flake-lib.lib.mkJsDepsHook     { pkgs; manager; source ? "shipped"; field ? null; fetcherVersion ? null; }
flake-lib.lib.mkComposedHook   { pkgs; hooks; }
flake-lib.lib.mkHuggingFaceModelManager { pkgs; name; manifest; model; stampName ? ".${name}-verified.json"; }
flake-lib.lib.mkOciImage       { pkgs; source; pin; }
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
hashes the source *tree* at a release tag (`{ version, sourceRev, sourceHash }`);
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
update-version = flake-lib.lib.mkUpdateVersion { inherit pkgs source; buildAttr = "image"; };
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
update-version = flake-lib.lib.mkUpdateVersion { inherit pkgs source; buildAttr = "image"; };
update-branches = flake-lib.lib.mkUpdateBranches { inherit pkgs source; pinSchema = "oci"; };
```

A versioned producer pins no `tag`: it publishes its image under its version, so the registry reference is the release version with any GitHub version prefix removed, which is also the version recorded in the pin. Invoking its `update-version` with no arguments resolves the newest upstream release through GitHub's `releases/latest` endpoint, which excludes drafts and prereleases; publish the whole tree with `update-branches`, whose `pinSchema = "oci"` seeds a new exact branch from the base pin's `imageDigest` and `imageHash` alone. A seed claims no version, because `mkOciImage` asserts the digest's shape at evaluation and the branch must not name a release before its image has been resolved. The updater then writes that branch's own version, and reuses the already-pinned content when the resolved image is the one the branch was seeded with. Several releases sharing one image digest is a correct pairing rather than a stale pin, and a version branch counts as unchanged only once its pin names the version it is being resolved for.

`versions` therefore requires the registry to publish the bare release version as a tag. `versionOverrides` and `versionCanon` rename the canonical version — the branch and the pin's `version` — but the updater pulls the tag named by the upstream release version, so neither redirects the image reference. An upstream whose registry tag is spelled differently has no mechanism here and remains a single-branch producer until a version source that reads registry tags exists. The loaded image's local name and tag follow `finalImageName`/`finalImageTag` as usual; with neither set, a versioned pin tags the image with its own version, and a branch seeded before its image resolved falls back to the digest.

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

`mkHuggingFaceModelManager` builds the matching runtime downloader from one manifest file path. It exposes the supplied `model` value as `passthru.model`; `stampName` defaults to `.${name}-verified.json`. Its executable accepts `download DIRECTORY`, `verify DIRECTORY`, and `check DIRECTORY`. `download` fetches the manifest files and verifies them, `verify` hashes them, and `check` validates the current manifest stamp plus file sizes without rehashing. `download` authenticates against Hugging Face only when the caller's environment exports `HF_TOKEN`; the local HF token store is never picked up implicitly.

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

Update verification evaluates the target package's derivation on every run. Set `verification = "build"` only when the producer must realize the package before publishing its pin. A non-null `buildFailureHash` selects build verification by default; set `verification = "evaluate"` when hash discovery is sufficient and realizing the full package is prohibitively expensive for the updater.

`buildFailureHash` names one additional pin field whose value is populated from
the package build's fixed-output hash mismatch. This supports dependency fetchers
such as `fetchPnpmDeps` while the source tree continues to use normal prefetching.
For PyPI sources, pass the same field through `mkUpdateBranches.extraHashes` so
new version branches include it in their placeholder pins.
Use `pinSchema = "github-pnpm"` for the corresponding `{ version, sourceRev,
sourceHash, pnpmDepsHash }` branch placeholders.

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
#   systems = flake-utils.lib.defaultSystems;
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
extends the libraries the rewrite may resolve against.

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
current pin for a source tracked by commit. A producer refreshes whichever it has
installed by running `nix run github:jgus-org/flake-lib/v1#update-workflows` --
flake-lib's own instance of the tool, rather than a copy each producer republishes;
see below.

Both templates cache through `.github/actions/fleet-nix-cache`, a composite action
that points Nix at the fleet Attic cache and pushes what a job builds to it whenever
the `ATTIC_TOKEN` secret resolves -- one organization secret covers every repository
-- and falls back to the repository's Actions cache when it does not, so repositories
and fork pull requests without a token behave as before.


### Split update-branches jobs

`mkUpdateBranches` exposes a machine-readable interface for workflows that split
maintenance across jobs:

```console
update-branches list
update-branches refresh --base-sha SHA --version CANONICAL --upstream-version RAW
update-branches publish --base-sha SHA --versions-json JSON
```

`list` writes exactly one compact JSON object to stdout; progress goes to stderr:

```json
{"baseSha":"<full commit SHA>","versions":[{"version":"1.2.3","upstreamVersion":"1.2.3","stable":true}],"newestStable":{"version":"1.2.3","upstreamVersion":"1.2.3","stable":true}}
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
advances to the highest successful stable candidate. Invoking `update-branches`
without arguments retains the compatible all-in-one behavior.

The workflow template uses the newest stable entry as a fast path, refreshes all
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

### Refresh installed workflows (`update-workflows`)

Workflow files are copies of flake-lib's templates, so on their own they cannot
follow the templates: flake-lib moves and the installed copy does not. The
`update-workflows` package closes that gap, and is the first job of every workflow
flake-lib ships:

```console
nix run github:jgus-org/flake-lib/v1#update-workflows
```

Producers invoke flake-lib's own instance rather than republishing one through their
own `packages`. Nothing about the calling flake is baked into the tool -- it reads the
lock and the installed workflows -- so a re-export is boilerplate, and a re-export is
also self-defeating: `nix run .#update-workflows` evaluates the *program* at the
revision the flake currently locks, which leaves the tool doing the adopting one
revision behind the templates it installs.

The tool reads the `flake-lib` input out of `flake.lock`, advances it, and
overwrites each workflow in `.github/workflows` whose name a template of that
revision ships. It does not add or rename a workflow: which workflows a repo has
is the author's decision, and one flake-lib has no template for is left alone.
What is compared is the installed file against the template at the revision *now
locked*, not the revision the run started from — the pin path advances
`flake-lib` as it commits pins, so a lock can reach a revision without that
revision's templates having been installed, and a refresh that asked only whether
the input had moved would leave a repository running old workflow files against
new scripts indefinitely. Anything a template does not carry is a constructor
argument in `flake.nix`, baked into the package the workflow invokes, which is why
a template can replace its workflow file wholesale. The advanced input and the
refreshed workflows are committed together,
because a workflow that tracks flake-lib N would otherwise be refreshing the
scripts it invokes from revision N too.

A repository with no workflow named like a template joins that set by naming one:

```console
nix run github:jgus-org/flake-lib/v1#update-workflows -- adopt update-version.yml
```

This installs exactly the named template — creating it, or replacing a hand-written file
of the same name — and advances the
input even when it is already current, since joining does not depend on the revision
moving. It is the upgrade path for a producer that exists only on GitHub and so has no
local source to promote from. The tool never picks the publication model, and retiring a
workflow flake-lib has no template for stays the author's `git rm`; what is still in the
way is named in the output, because two workflows committing to one branch fight over it.

The commit is pushed and reported as the `sha` output, which the run's remaining
jobs check out. Without that handoff the update would only pay off a day later —
a workflow is read when its run starts, and a push made with `GITHUB_TOKEN`
triggers nothing — so the run that moves a workflow builds from the workflow it
just wrote. When the input did not move and every installed workflow already matches
the template at the revision locked, nothing is pushed and no `sha` is reported, which
leaves the run on the revision it started from.

## Versioning

Hand-versioned via git tags (`vX.Y.Z`) with a moving `v1` aggregate branch. Breaking
changes bump to `v2`; consumers migrate deliberately, so one push can't break every
repo at once.
