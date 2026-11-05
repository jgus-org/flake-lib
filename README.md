# flake-lib

Shared library for the `jgus-org/*-flake` family of pinned-dependency sub-flakes. It generates the boilerplate those repos would otherwise hand-copy: the per-version-branch orchestrator, the `update-version` machinery, and PyPI package builders all come from a small declarative spec.

Consumers pin it as an input (`github:jgus-org/flake-lib/v1`) and pull improvements by
bumping that pin — the same `nix flake update` the orchestrator already runs per
branch. There is no copy-and-merge of scripts between repos.

## API (`flake-lib.lib`)

Every entry states what a call is for and what it publishes. The arguments are the
implementation's: each entry names the file that owns them, and `tests/python-flake.nix`
and `flake.nix` are executable uses.

`mkPythonFlake` (`lib/mk-python-flake.nix`) -- one call is a whole producer flake: the upstream
it tracks, the payload it publishes, and the org formatter. It publishes `overlays.default`, and
per supported system `packages` (the `payload.packages` half, the update tools, and `default` when
that half has exactly one package), `checks` (the `payload.overlays` members built in the tree
`gate.config` names, the `payload.checks` half, and `formatting`) and `formatter`. Neither family
mirrors the other: a published artifact is not also a check, because what a host needs is that
payload resolved in the host's own set, which the producer cannot see, and building the host is
what verifies it. The update tools appear only when the flake names an upstream to track. The tree
it formats is the tree the caller hands it, so a flake-parts module and a plain flake both pass
what they already have in scope. A producer built from the upstream source tree rather than a
published distribution reads source files from an eval-time fetch, never from a derivation's
output. The fetch a pin names is `lib/pinned-source.nix`; the recipe defaults, including the rule
that a wheel is installed rather than built, are `lib/python-builders.nix`.

`mkFormatting` (`lib/mk-formatting.nix`) -- the org-standard formatter, so a repo carries no
treefmt config, no treefmt-nix input, and no formatter config files of its own. It publishes a
`formatter` and a `check` over the tree the caller hands it, with the repo's own paths excluded on
top of treefmt's defaults. The tools resolve from the nixpkgs the caller's flake-lib input
resolves to, and the function takes no package set, so a caller's only lever on their version is
its `follows` edge. See [Org-standard formatting](#org-standard-formatting-mkformatting).

`eachDefaultSystem`, `eachDefaultLinuxSystem`, `eachSystem`, `defaultSystems`,
`defaultLinuxSystems` (`lib/default-systems.nix`) -- per-system outputs over the hosts this fleet
builds for, replacing the flake-utils equivalents and iterating exactly the hosts they name; see
[Supported systems](#supported-systems).

`mkUpdateVersion` (`lib/mk-update-version.nix`, runtime in `scripts/update-version.sh`) -- the
updater for one pinned source: it resolves the upstream's newest release, populates every hash the
pin declares, cascades to siblings, and runs the pull-request gate over the result before anything
is committed. It evaluates everything the flake publishes and starts no package build of its own
except hash discovery.

`mkUpdateBranches` (`lib/mk-update-branches.nix`, runtime in `scripts/update-branches-core.sh`) --
the per-version-branch orchestrator: it enumerates the upstream's versions, maintains one branch
per version plus the aggregates, and publishes only refs a run has built. Its discovery, refresh,
and publication phases split across jobs; see [Split update-branches jobs](#split-update-branches-jobs).

`mkRevalidateHash` (`lib/mk-revalidate-hash.nix`) -- a recovery tool that rewrites one
fixed-output hash pin from a build's hash mismatch, for a hash nothing can prefetch.

`mkJsDepsHook` (`lib/mk-js-deps-hook.nix`) -- an artifact hook that computes a JS package-manager
offline-dependency hash at the pinned revision and prints it for the updater to capture into the
pin.

`mkComposedHook` (`lib/mk-composed-hook.nix`) -- several artifact hooks composed into the one
executable a single hook slot takes.

`mkHuggingFaceModelManager` (`lib/mk-huggingface-model-manager.nix`, runtime in
`scripts/huggingface-model-manager.py`) -- the runtime downloader for a manifest-pinned model
repository, carrying the manifest's identity on the derivation.

`mkOciImage` (`lib/mk-oci-image.nix`, shared shape in `lib/oci-image.nix`) -- the image a registry
digest pin names: a fixed-output directory holding the upstream manifest, config and compressed
layers, copied unchanged, with the loading helpers a consumer needs beside it.

`versionMatchesComparison` (`lib/version-matches-comparison.nix`) -- a version against one
comparison operator, with numeric versions normalized so leading and trailing zero components do
not decide, and an exact operator that compares the strings as written.

`evalMarkerTree` (`lib/eval-marker-tree.nix`) -- a PEP 508 marker tree decided against a stated
environment, so an incompatible requirement is dropped rather than pinned.

`readPythonRequirements` (`lib/read-python-requirements.nix`) -- the distribution names a
requirements file asks for, in the shape a python package set names its members: lowercased, `.`
and `_` folded to `-`, with specifiers, extras, markers, comments, and indented lines dropped. A
producer's payload reads them from the pinned source rather than a checked-out tree, because
evaluation may read source files from an eval-time fetch and never from a derivation's output.

`mkPythonApplication` (`lib/mk-python-application.nix`) -- an executable that runs one python
source file against an environment carrying named dependencies, with the launcher conventions a
service would otherwise hand-roll on makeWrapper: a working directory, extra programs on PATH,
prepended PYTHONPATH entries, and environment exported unconditionally or only where the name is
unset. The environment is published beside the executable, so an image build can peel the
dependency layer away from the script it runs.

`pythonDualStackIPv6` (`lib/python-dual-stack-ipv6.nix`) -- the one dual-stack IPv6 interposer: an
`IPV6_V6ONLY=True` setsockopt becomes a no-op, so a `[::]` listener serves both families (asyncio
and waitress set the flag before any bind). Two shapes, for whether the consumer controls the
interpreter environment: a directory holding a `sitecustomize.py` for a PYTHONPATH it owns, or the
same interposer appended to a package file the entrypoint transitively imports.

`warnIfNewerMajor` (`lib/default.nix`) -- a version-numbered nixpkgs package (`postgresql_18`,
`php83`, `jdk21_headless`, …), returned with an eval warning when a higher major is available.

`depsCore` (`scripts/deps_core.py`) -- the shared python dependency-resolution module, loaded by
the updater scripts from the environment they are built with.

`source.type` is `pypi`, `github`, `github-release-asset`, `huggingface`, `gitlab`, `mutable-url`, or `oci`. `github`
hashes the source _tree_ at a release tag (`{ version, sourceRev, sourceHash }`);
GitHub sources whose release tags have an additional prefix set `tagPrefix`. Pins and version branches use the version without that prefix.
A `github` source names its versions in exactly one of two places, and `track` says which: `release` (the default) reads the GitHub Releases API, and `tag` reads the repository's git tags. An upstream that ships tags without opening GitHub Releases for them has an empty releases list, so a producer for one tracks `tag` — otherwise its versions are invisible to both the updater and the orchestrator.
A `gitlab` source names its versions as the project's git tags, which is also where its updater resolves a release from, so there is no endpoint for `track` to choose between; `mkUpdateBranches` enumerates those tags and refuses a gitlab source that asks for `tag`.
`github-release-asset` instead prefetches a single prebuilt release asset into a
`{ version, hash }` pin (`pinSchema = "github-asset"`), for upstreams shipped as a
ready-to-run binary/jar rather than built from source; `lib/mk-update-version.nix` names the
fields the asset and tag templates take.

`mutable-url` tracks a small artifact whose URL remains stable while its contents change. It is single-branch and has no meaningful upstream version. The updater compares the final response's `Last-Modified` header with the `{ lastModified, hash }` pin and downloads the artifact only when that header changes. `lib/mk-update-version.nix` owns its source fields.

`oci` tracks a public registry tag and pins `{ imageDigest, imageHash }`. `imageName` must include the registry hostname. The updater accepts an optional tag or `sha256:...` digest in the configured repository, resolves an image index to one platform manifest, checks its platform, and copies that immutable manifest with its config and layers unchanged. `imageHash` is the recursive Nix hash of the resulting Skopeo directory. `lib/mk-oci-image.nix` and `lib/oci-image.nix` own the source and pin fields.

`tag`, `os`, and `arch` default to `latest`, `linux`, and `amd64`; `variant` is optional. The returned package is the image directory, with `imageName`, `imageTag`, `imageDigest`, `copyTo`, and `copyToPodman` attributes for loading it. Its local name defaults to `imageName`, and its local tag defaults to the manifest digest without `sha256:`; `finalImageName` and `finalImageTag` can override them. `copyTo` accepts a Skopeo destination and additional copy arguments. Public fetches use isolated registry configuration and an empty authentication file. Pulling and loading preserve the original image manifest, config, and compressed layers rather than rebuilding a base image. OCI updates skip downloads for a matching platform manifest digest and populated hash, preserve dependency locks, and restore the original pin and lock if updating or verification fails. A versioned producer skips only once its pin also names the version being resolved. A legacy `archiveFingerprint` triggers one fetch to migrate the hash to the directory format and remove that field. OCI source updates do not support sibling cascades, artifact hooks, or extra hash fields.

An `oci` producer opts into the version tree by adding `versions` to the same spec, whose `type` selects the discovery path already implemented for that vocabulary (`github` reads the endpoint that source's `track` names; a registry-tag source would be a new arm, not a producer-shape change). Its pin is `{ version, imageDigest, imageHash }`; a producer without `versions` keeps pinning exactly `{ imageDigest, imageHash }`. Absence of `versions` is the single-branch signal, so an existing producer is untouched by construction, still rejects a second positional argument, and still pins no version. `lib/oci-image.nix` owns that spec's fields.

A versioned producer pins no `tag`: it publishes its image under its version, so the registry reference is the release version with any GitHub version prefix removed, which is also the version recorded in the pin. Invoking its `update-version` with no arguments resolves the newest upstream release through GitHub's `releases/latest` endpoint, which excludes drafts and prereleases; publish the whole tree with `update-branches`, whose `pinSchema = "oci"` seeds a new exact branch from the base pin's `imageDigest` and `imageHash` alone. A seed claims no version, because `mkOciImage` asserts the digest's shape at evaluation and the branch must not name a release before its image has been resolved. The updater then writes that branch's own version, and reuses the already-pinned content when the resolved image is the one the branch was seeded with. Several releases sharing one image digest is a correct pairing rather than a stale pin, and a version branch counts as unchanged only once its pin names the version it is being resolved for.

`versions` therefore requires the registry to publish the bare release version as a tag. `versionOverrides` and `versionCanon` rename the canonical version — the branch and the pin's `version` — but the updater pulls the tag named by the upstream release version, so neither redirects the image reference. An upstream whose registry tag is spelled differently has no mechanism here and remains a single-branch producer until a version source that reads registry tags exists. The loaded image's local name and tag follow `finalImageName`/`finalImageTag` as usual; with neither set, a versioned pin tags the image with its own version, and a branch seeded before its image resolved falls back to the digest.

`meta.sourceProvenance` on the image defaults to `binaryNativeCode`: the layers arrive as upstream's binaries and nothing in the build reads them. A caller's own `meta` overrides it. No license is defaulted, because the content is upstream's and neither `pin` nor `source` names its terms — writing one into the image's config would also change the config digest the pin pins, so image metadata belongs on the derivation.

`huggingface` tracks a model repository revision and writes a `{ version,
sourceRev }` pin. An optional `files` list adds a `hashes` attribute containing
the Nix content hash of each selected repository file; `lib/mk-update-version.nix` owns the source's fields.

For checkpoints too large to import into the Nix store, `manifest` writes immutable blob metadata without downloading the artifacts. `include` and `exclude` contain jq regular expressions matched against repository-relative paths. An empty `include` selects every file. The generated pin records the manifest's SHA256 in `manifestHash` by default; set `hashField` to choose another field name. `lib/mk-update-version.nix` owns the manifest's fields.

`mkHuggingFaceModelManager` builds the matching runtime downloader from one manifest file path. It exposes the supplied `model` value as `passthru.model`; `stampName` defaults to `.${name}-verified.json`. `meta` defaults to the MIT license, because the downloader is flake-lib's own script, and a caller's `meta` is merged key-wise over it. Its executable accepts `download DIRECTORY`, `verify DIRECTORY`, and `check DIRECTORY`. `download` fetches the manifest files and verifies them, `verify` hashes them, and `check` validates the current manifest stamp plus file sizes without rehashing. `download` authenticates against Hugging Face only when the caller's environment exports `HF_TOKEN`; the local HF token store is never picked up implicitly. `lib/mk-huggingface-model-manager.nix` owns its arguments.

The update machinery and the orchestrator's per-flake bits
(`list_upstream_versions`, `prepare_new_branch_pin`, and sibling cascades) are all driven from that spec. `version-only` preserves the current complete pin while creating a branch so a bespoke updater can evaluate and atomically replace it with the target version's complete pin. `oci` seeds a content-only placeholder pin, and an `oci` producer discovers its versions from `source.versions` rather than from `source.type`.

PyPI producers resolve sibling requirements from their release metadata. Exact pins select exact branches, unbounded minimums select `main`, and bounded ranges select a compatible aggregate. Prerelease exact branches are always maintained. A prerelease advances each aggregate independently only when that aggregate is absent or already tracks a prerelease; stable aggregates remain stable until a newer stable release replaces them.

GitHub producers read sibling requirements from `reqFile = "requirements.txt"` by default. Set `reqFormat = "pyproject"`, `reqFile = "pyproject.toml"`, and `reqGroups = [ "extra-name" ]` to combine `[project].dependencies` with selected optional-dependency groups. Environment markers are evaluated before the compatible branch is selected.

Set `siblingRefsInPin = true` to write the resolved refs under `pin.nix.dependencies` instead of rewriting `flake.nix`. The updater applies those refs while regenerating `flake.lock`, so each historical branch owns its complete source and dependency selection through `pin.nix` and `flake.lock` while `flake.nix` retains generic input URLs.

The updater evaluates every package the flake publishes on every run; it starts no package build of
its own, since the publication path runs the pull-request gate's command instead, see
[Publication builds what the flake publishes](#publication-builds-what-the-flake-publishes). The
one build the updater does start is hash discovery: a fixed-output hash that cannot be prefetched
is recovered from a package build's hash-mismatch error, which is what
`hashMode = "build-failure"` and `buildFailureHash`/`buildFailureHashes` select. That discovery
runs the same build a pull request is gated by, over the same published family, and asks for a
build rather than a clean report over nothing to build: a flake that publishes no package this
runner builds fails there rather than finishing a pin whose hashes were never resolved.

`buildFailureHash` names one additional pin field whose value is populated from
the package build's fixed-output hash mismatch. This supports dependency fetchers
such as `fetchPnpmDeps` while the source tree continues to use normal prefetching.
For PyPI sources, pass the same field through `mkUpdateBranches.extraHashes` so
new version branches include it in their placeholder pins.
Use `pinSchema = "github-pnpm"` for the corresponding `{ version, sourceRev,
sourceHash, pnpmDepsHash }` branch placeholders.

`buildFailureHashes` declares the set of pin fields the build's hash mismatch may name, for a package whose build fails on whichever of its unprefetchable dependencies is stale first: declaring one field per fetcher covers a `fetchPnpmDeps` tree and a `buildGoModule` vendor tree in one bump. A mismatch is attributed to the declared field already holding the hash the build reported as specified, and while no declared field is resolved yet, to the first declared field. `buildFailureHash` and `buildFailureHashes` combine, and each declared field is resolved at most once, so the build runs at most one more time than there are declared fields. A build that still reports a hash mismatch once every declared field is resolved ends the run, as does a mismatch belonging to a pin field no declaration covers.

Both recovery tools take `buildTarget`, the published package the hash is recovered from: `mkRevalidateHash { buildTarget = "caddy"; }`, or the same name on `mkUpdateVersion`. The question a recovery build answers is what a hash fetches, and that is usually one package's build, so a flake whose family publishes more than the package carrying its hash need not build the rest to recover one value. The family stays the default because nothing about a producer has to be correct for the default to work, and naming a target narrows only the recovery build: the rewritten tree is still built whole before it is committed or reported, so the finished pin is proven by the build a pull request is gated by. A name outside the published family is an error rather than a fallback, so a package renamed away leaves a recovery that says so instead of quietly rebuilding what the caller asked to avoid.

### Supported systems

`eachDefaultSystem` and `eachDefaultLinuxSystem` replace `flake-utils.lib.eachDefaultSystem`. They differ from flake-utils in one case: under `--impure`, flake-utils adds `builtins.currentSystem` to the set when the evaluating host is not already in it, while these helpers iterate exactly the hosts they name.

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

A repository whose builds need a nix setting the runner does not default to publishes that setting
in `.github/nix.conf`, a nix.conf fragment in git, and `.github/actions/nix` hands it to every later
step through the job's `NIX_CONFIG`.

### Publication builds what the flake publishes

The publication path runs the pull-request gate's own command, `nix run
github:jgus-org/flake-lib/v1#build-and-check`, so the tree a producer pushes is the tree a pull
request would have gated and no publication site names the attribute it builds. What that builds is
every package in the published `packages.<system>` family for the runner's system, flake-lib's own
tooling entries included. A producer whose deliverable is an overlay publishes no materialized
payload of its own; what is left in `packages` is its tooling, and that is what gets built.

Two call sites, one definition. The version model publishes from its workflow:
`update-version.yml` runs the gate between the updater and its commit. A refresh publishes from the
tool, because one run resolves and pushes many version branches: `refresh_version` runs the same
build in the branch's own tree before it pushes anything, and no workflow step could have reached
that tree. A failed build leaves the branch, its aggregate, and the pin unpushed, and the next run
retries the same version, so the failure is visible and the published state stays consistent.

Aggregate publication builds nothing: it moves a ref to a commit an exact branch
already published, and that refresh built it.

Hash discovery builds the family the gate builds, so it names no attribute of its own: a producer
whose deliverable is an overlay publishes no package it deploys, and the hash it pins is recovered
from the family it does publish. What it requires instead is that the build be a build: a producer
publishing no package this runner builds is told so there rather than finishing a pin whose hashes
were never resolved.

`buildVerificationSkip` is the way out, and the reason belongs in a comment beside it;
`lib/mk-update-branches.nix` owns the option.

false (the default) runs the gate. true publishes without running it and logs that verification
was skipped on every run, so the exception stays visible in the log. Use it only where the gate is
genuinely prohibitive; it does not make the pin correct.

### Split update-branches jobs

`mkUpdateBranches` exposes a machine-readable interface for workflows that split
maintenance across jobs; `scripts/update-branches-core.sh` owns the three invocations and
the arguments each takes.

`list` writes exactly one compact JSON object to stdout; progress goes to stderr:

```json
{
  "baseSha": "<full commit SHA>",
  "versions": [
    { "version": "1.2.3", "upstreamVersion": "1.2.3", "stable": true }
  ]
}
```

`versions` is ordered newest first. Under Actions, where `GITHUB_OUTPUT` names a
file, `list` also appends that manifest as `base_sha` and `versions` outputs, so
the workflow that fans out over it carries no version logic of its own.

A refresh invocation does not query upstream: it brings exactly one
`v<version>` branch up to `baseSha`, then updates and pushes that branch. The
refreshed tree is `baseSha` with the branch's own `branchOwnedFiles` on top, so
a path outside those patterns keeps nothing of the branch's: the base's content
wins, and where the base has none the branch's copy is dropped and named in a
workflow warning. Publication consumes the unchanged `versions` array, considers
only exact refs containing `baseSha`, and updates aggregates independently. When
the highest candidate is a prerelease but an aggregate is stable, the aggregate
advances to the highest successful stable candidate. Invoking `update-branches`
without arguments retains the compatible all-in-one behavior.

The workflow template refreshes every tracked exact version in a parallel matrix
and runs the publisher after it, even when a maintenance job fails. The
publisher and every exact job reuse the discovery SHA and version manifest.
Every job restores Nix from the shared
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
waited for. A repository shipping none of the update workflow names is reported and skipped,
and so is one whose update workflow is still on its default branch but no longer runs —
GitHub disables a workflow that has not run in sixty days, which leaves a producer tracking
a quiet upstream holding a workflow that never runs again, and left its consumer waiting its
whole budget on a dispatch that is refused every time.

The wait reports as it goes rather than only at the end: it names the dependencies it
intends to order and the budget each one has before it reads anything, and it reports each
dependency the moment it settles with how many are still outstanding, because a consumer's
run is read in a log where a silent wait is indistinguishable from a hung one.

Every failure to establish ordering other than a refused credential ends in continuing
without waiting, and the exit status is success: a dependency that cannot be observed, that
fails, or that never finishes must not stop the fleet. A dispatch the API rejects for a
reason no retry clears — a workflow that is disabled, a ref that does not exist — ends that
dependency's wait at once instead of at the budget, while a dispatch that fails for a reason
that might clear is followed by waiting anyway. The report says which of those happened, and
says so when the dependency's update was started by this run, since that run is not
otherwise attributable to the consumer that began it.

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

### Gate a pull request (`build-and-check`)

A flake's packages are the surface its consumers build, and neither of the older commands covers
them on its own: `nix flake check` builds `checks` and only looks at the shape of `packages`, and
the updater's own build runs after the change is already merged.
`templates/workflows/build-and-check.yml` is the gate that does, running flake-lib's own instance
of the tool:

```console
nix run github:jgus-org/flake-lib/v1#build-and-check
```

It builds every package the flake publishes for the system the runner is on, then runs
`nix flake check`. Both halves run even when the first fails, so one run names every problem in
a tree rather than the first one nix reached. The publication path runs the same command, so the
tree an updater pushes is the tree a pull request would have gated. The build half reads the
calling tree rather than anything baked into the workflow, so a package a producer adds later is
gated by the next pull request without a workflow change.

`build-packages` is the build half on its own -- `nix run
github:jgus-org/flake-lib/v1#build-packages` -- and does the things the gate asks it to do, each
of which a caller may ask for directly: it prints the installables it would build instead of
building them, which is how a repository is audited before adopting; it builds another system's
family, or another tree; it builds one published package instead of the family, for a caller that
needs a build from that package and no other -- that package is built even where
`passthru.ciBuildSkip` excuses it from the gate, since the name says what to build rather than
what to gate, and a name outside the family fails instead of quietly building the family; and a
family with nothing to build is a failure rather than a clean exit, for a caller that reads a
clean exit as something having been built -- hash discovery does, and a hash never built is not a
hash validated. `scripts/build-packages.sh` owns the spellings.

Adopting it names the template the way every other flake-lib workflow is adopted, and it
then refreshes with the rest:

```console
nix run github:jgus-org/flake-lib/v1#update-workflows -- adopt build-and-check.yml
```

A flake that locks a private repository needs one secret: `BUILD_TOKEN`, a credential that can
read the contents of every private repository the flake locks. A repository whose inputs are all
public declares nothing. Set it on the repositories that need it rather than organization-wide: a
secret an organization grants every repository is readable by the pull requests of every public
one, which is a wider circle than a contents credential justifies. GitHub gives a fork pull
request no secrets at all, so a flake with a private input is gated by pull requests from inside
the organization. The credential comes with being given nix: every job that uses
`jgus-org/flake-lib/.github/actions/nix` passes `BUILD_TOKEN`.

A package the runner cannot build excuses itself, with the reason in a comment beside
the marker -- a boolean on the package's `passthru`, spelled by `scripts/build-packages.sh`.

A VM suite usually does not need the marker. `nixosTest` publishes its driver beside its run
derivation, and building the driver type-checks the test script and builds every guest system
while booting nothing, so the package that earns a gate is the driver and the part that needs
`kvm` stays unpublished.

The run names every package it excused, so an exemption cannot go unnoticed, and a marker
that is not a boolean fails the run. It is the per-package sibling of the publication path's
`buildVerificationSkip`, which skips the whole gate rather than one package in its build half.

One system per run, which is a scope decision rather than a limit: hosted arm64 runners
exist and a second job could gate `aarch64-linux`. Apps and devShells are not built -- an
app names a program to run, and a `mkShell` derivation has no build phase to fail. A flake
that publishes nothing buildable for the runner's system reports that and passes, which is
why every published flake installs the gate whatever it publishes.

The gate triggers on a pull request and a dispatch, not a push: an updater's commit is
pushed with the run's `GITHUB_TOKEN`, which starts no workflow, and it is built by the
publication path that made it. A push trigger would build the whole family to verify a
workflows refresh, which is what most of a producer's machine-made commits are.

### Build what an overlay produces

A producer whose deliverable is an overlay publishes no payload of its own: what the consumer gets
is built in the consumer's tree, from an overlay that has to be applied first. Neither gate half
touches it -- the published family holds the flake's build surface, and `nix flake check` never
instantiates an unfree payload, which is the point of unfree packaging -- so patches that stopped
applying, or an upstream that moved an assumption the overlay depends on, would reach the fleet
through the overlay untested.

The build belongs in the flake's own `checks`, which is the family the gate's second half builds,
and a check instantiates the package set it needs. The check is the overlaid package itself, named
as the consumer names it, taken from a throwaway set built with the overlay applied -- that set is
where the payload's licence is accepted and where CUDA is selected, and neither election reaches a
consumer's package set. `scripts/build-and-check.sh` is the gate half that builds the check family:

```nix
checks.${system} = { inherit (checkPkgs) es-de; formatting = orgFormatting.check; };
```

No machinery is involved -- the check is an ordinary package in the family `nix flake check`
builds -- and the grant is inside the check, so the flake still accepts no licence on a consumer's
behalf: the same overlay applied to a set that permits nothing unfree is refused as it was before.
A check reaches a payload nested in another scope (`checkPkgs.cudaPackages.libcufile`, a
`pythonPackagesExtensions` member) as easily as a top-level one, because it is Nix and not a name
lookup.

What it costs is that a check is a published output: a consumer who runs `nix flake check` on the
flake builds the payload too, and the store paths land wherever the gate ran.

Choose a target that can build. A payload nixpkgs itself blocks -- a package removed for known
vulnerabilities -- cannot be proved this way, and naming it leaves the gate permanently red.

### Org-standard formatting (`mkFormatting`)

Every repo in the org formats with the same program set and the same config files, so a
repo opts in instead of configuring. The call publishes a `formatter` and a `check`, which a
repo wires to its own `formatter` and `checks.formatting`; `lib/mk-formatting.nix` owns the
arguments.

The tree formatted is the tree the caller hands it, so a flake-parts module and a plain flake both
pass what they already have in scope. The paths only the repo knows about — generated files,
vendored trees, secrets — are excluded on top of the excludes treefmt applies by default.

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

Tools resolve from the `nixpkgs` that the caller's flake-lib input resolves to and from nothing
else: the function takes no `pkgs`, so a repo's only lever on their version is the `follows` edge
on `flake-lib.inputs.nixpkgs`, and [AGENTS.md](AGENTS.md) owns that edge. One tree therefore has
exactly one formatter version -- the one its own root and lock resolve -- which is the only
context a flake's formatter ever runs in. Which formatter claims a file and the style it applies
are the same in every repo, because the two config files reach their tools by absolute store
path: a repo that still carries its own `.clang-format` or `pedantix.toml` would keep two copies
of one standard, and those files are removed in consuming repos, not overridden.

A dev shell that wants the formatters on its `PATH` adds `formatter`, and the tools a specific
editor drives, from its own `pkgs`; flake-lib does not build a shell for a repo.

## Versioning

Hand-versioned via git tags (`vX.Y.Z`) with a moving `v1` aggregate branch. Breaking
changes bump to `v2`; consumers migrate deliberately, so one push can't break every
repo at once.

See [LICENSE.md](LICENSE.md) for licensing and copyright.
