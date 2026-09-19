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
flake-lib.lib.mkUpdateVersion  { pkgs; source; buildAttr; siblings ? []; siblingRefsInPin ? false; hashMode ? "prefetch"; extraHashes ? []; buildFailureHash ? null; artifactHook ? null; verification ? if buildFailureHash == null then "evaluate" else "build"; }
flake-lib.lib.mkUpdateBranches { pkgs; source; pinSchema; branchOwnedFiles ? [ "pin.nix" "flake.lock" ]; extraHashes ? []; versionOverrides ? {}; versionCanon ? []; minVersionComponents ? 3; }
flake-lib.lib.mkPypiPackage    { pkgs; source; package; pin; }
flake-lib.lib.mkRevalidateHash { pkgs; buildAttr; hashField ? "hash"; }
flake-lib.lib.mkJsDepsHook     { pkgs; manager; source ? "shipped"; field ? null; fetcherVersion ? null; }
flake-lib.lib.mkComposedHook   { pkgs; hooks; }
flake-lib.lib.versionMatchesComparison actual { operator; version; }
flake-lib.lib.depsCore                                                   # store path of the shared python dep-resolution module; load via the DEPS_CORE env var
flake-lib.lib.pythonPolicy                                               # fleet wheelhouse policy: pythonVersions (first = current, rest = readiness) + platform
flake-lib.lib.platformTags     { pythonVersion; platform; }              # "3.13" + "x86_64-manylinux_2_28" -> uv/pip tag attrs
flake-lib.lib.mkPythonWheelhouse { pkgs; sources; extraRequirements ? []; pythonVersions ? pythonPolicy.pythonVersions; platform ? pythonPolicy.platform; index ? "https://pypi.org/simple"; depsCore ? flake-lib.lib.depsCore; }  # -> { hook; currentEnvironment; }
flake-lib.lib.mkWheelhouse     { pkgs; wheels; }                         # wheels-<py>.json path or list -> { files; wheelhouse; }
flake-lib.lib.installWheelhouse { python; target; wheelhouse; }          # bash snippet installing a wheelhouse into a target dir

# Returns pkgs.${name}, emitting an eval warning when a version-numbered nixpkgs
# package (postgresql_18, php83, jdk21_headless, …) has a higher major available.
flake-lib.lib.warnIfNewerMajor { pkgs; name; lib ? pkgs.lib; }
```

`source.type` is `pypi`, `github`, `github-release-asset`, `huggingface`, or `gitlab`. `github`
hashes the source *tree* at a release tag (`{ version, sourceRev, sourceHash }`);
GitHub sources whose release tags have an additional prefix set `tagPrefix`, such as `source = { type = "github"; owner = "openai"; repo = "codex"; tagPrefix = "rust-v"; };`. Pins and version branches use the version without that prefix.
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

The update machinery and the orchestrator's per-flake bits
(`list_upstream_versions`, `prepare_new_branch_pin`, and sibling cascades) are all driven from that spec. `version-only` preserves the current complete pin while creating a branch so a bespoke updater can evaluate and atomically replace it with the target version's complete pin.

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
floating nixpkgs pythonPackages. It returns `{ hook; currentEnvironment; }`:
pass `hook` through `mkComposedHook` (or directly) as the `artifactHook`, and
`currentEnvironment.fingerprint` to `mkUpdateVersion`'s `environmentFingerprint`
so a policy promotion re-runs the hook even at an unchanged version.

Environments come from fleet policy, declared in flake-lib's `flake.nix`:

```nix
flake-lib.lib.pythonPolicy
# { pythonVersions = [ "3.13" "3.14" "3.15" ]; platform = "x86_64-manylinux_2_28"; }
```

The first `pythonVersions` entry is **current** — the environment the pin
records (`pythonEnvironment`/`requirementsHash`/`wheelManifestHash` pin
fields hash its artifacts). Every environment — current and readiness
alike — commits `requirements-<py>.lock` + `wheels-<py>.json`, and the shared
env-independent manifest lands in `requirements.in`. Readiness environments
resolve best-effort on every run, committed as `requirements-<py>.lock` + `wheels-<py>.json` for every environment when they
resolve and their wheels exist, and recorded — with the blocking error, when
they don't — in `python-readiness.json`. Readiness failures never block the
current environment's update; the committed file's red→green transition is the
signal that the fleet can promote (promote by advancing the policy list).
Override per flake by passing `pythonVersions` (e.g. `[ "3.12" "3.13" ]`).

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
# mkUpdateVersion { ...; artifactHook = lib.getExe wheelhouse.hook; environmentFingerprint = wheelhouse.currentEnvironment.fingerprint; extraHashes = [ "pythonEnvironment" "requirementsHash" "wheelManifestHash" ]; }
```

`source-pyproject` and `source-file` read the pinned upstream source (cloned at
`NEW_REV`; `buildSystem` appends the pyproject's build-system requires);
`repo-file` reads the consumer's own repository. Requirements are merged in
order, deduplicated, resolved per environment with `uv pip compile
--generate-hashes`, fetched with `pip download --require-hashes --only-binary
:all:` over the full ≤-target manylinux tag ladder (pip matches platform tags
exactly, unlike uv's resolver), and recorded per wheel as `name`, `version`,
`filename`, `url`, `sha256`, `size`.

At eval time `mkWheelhouse` turns a `wheels.json` into a hash-pinned wheelhouse,
and `installWheelhouse` installs it into an application derivation:

```nix
nativeBuildInputs = [ pkgs.uv pkgs.autoPatchelfHook ];
installPhase = ''
  mkdir -p "$out/lib/site-packages"
  ${flake-lib.lib.installWheelhouse { inherit python; target = "$out/lib/site-packages"; wheelhouse = wheelhouse.wheelhouse; }}
'';
```

Native manylinux wheels need `autoPatchelfHook` (plus their native library
dependencies in `buildInputs`) so the installed site-packages links against
nix's libraries instead of runtime `LD_LIBRARY_PATH` assembly. Application
flakes that vendor opaque wheelhouses (freetoken-style) skip autoPatchelf and
resolve native libraries from the wrapper environment instead.

`templates/` holds `gitattributes` and `workflow.yml`, which a consuming repo installs as `.gitattributes` and `.github/workflows/update.yml`.


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
entry or `null`. A refresh invocation does not query upstream: it creates or
merges exactly one `v<version>` branch from `baseSha`, then updates and pushes
that branch. Publication consumes the unchanged `versions` array, considers only
exact refs containing `baseSha`, and updates aggregates independently. When the
highest candidate is a prerelease but an aggregate is stable, the aggregate
advances to the highest successful stable candidate. Invoking `update-branches`
without arguments retains the compatible all-in-one behavior.

The workflow template uses the newest stable entry as a fast path, refreshes all
remaining exact versions in a parallel matrix, and runs a final publisher even
when a maintenance job fails. Both publishers and every exact job reuse the
discovery SHA and version manifest. Ref publication uses bounded retries and
re-reads the remote after every failed push: an already-applied desired SHA is
accepted, an unchanged ref is retried, and a different concurrent update is
never overwritten. Branch update commands receive one additional attempt only
when their output identifies a transient network failure.

## Versioning

Hand-versioned via git tags (`vX.Y.Z`) with a moving `v1` aggregate branch. Breaking
changes bump to `v2`; consumers migrate deliberately, so one push can't break every
repo at once.
