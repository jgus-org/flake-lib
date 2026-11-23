# Runs the workspace adaptation over trees that differ only in what their manifest names, and asserts what each one comes back saying. Which release a tree names is known only from the tree, so the decision to adapt is behavior rather than evaluation, and the build failures it prevents happen inside `pnpmConfigHook`, where no producer can reach them.
{ pkgs }:
let
  targetVersion = "10.34.7";

  tree =
    name: fixture: directory:
    pkgs.runCommand "adaptation-${name}-src" { } ''
      mkdir -p "''${out}${directory}"
      cp ${fixture} "''${out}${directory}/package.json"
    '';

  # The script reads `targetVersion` and `workspaceDir` from its environment, which is how the toolchain hands them to it.
  adapt =
    name: src: directory:
    pkgs.runCommand "adaptation-${name}"
      {
        inherit targetVersion;
        nativeBuildInputs = [ pkgs.jq ];
        workspaceDir = if directory == null then "" else directory;
      }
      ''
        cp -r ${src} "''${out}"
        chmod -R u+w "''${out}"
        cd "''${out}"
        bash ${../lib/pnpm-toolchain/adapt-workspace.sh}
      '';

  fixture = file: ./fixtures/pnpm-adaptation + "/${file}";

  patchDriftManifest = fixture "patch-drift.json";

  # Same major, different release: the release the tree names is unreachable from a build sandbox.
  patchDrift = adapt "patch-drift" (tree "patch-drift" patchDriftManifest "") null;

  # The release the tree names is the one it is handed.
  alreadyNamed = adapt "already-named" (tree "already-named" (fixture "already-named.json") "") null;

  # Another major: the named release and the settings' location both have to move.
  crossMajor = adapt "cross-major" (tree "cross-major" (fixture "cross-major.json") "") null;

  # A manifest naming another manager is upstream's own choice, and rewriting it would state a toolchain that is not the one running.
  foreignManager = adapt "foreign-manager" (tree "foreign-manager" (fixture "foreign-manager.json")
    ""
  ) null;

  # A producer whose workspace lives in a subdirectory names it, and the manifest has to be reached there.
  nested = adapt "nested" (tree "nested" patchDriftManifest "/apps") "apps";
in
pkgs.runCommand "pnpm-adaptation-tests" { nativeBuildInputs = [ pkgs.jq ]; } ''
  test "$(jq -r .packageManager ${patchDrift}/package.json)" = "pnpm@${targetVersion}"

  # Relocating the settings while the major matches would drop settings the tool in the build still reads.
  jq -e '.pnpm.overrides | has("foo")' ${patchDrift}/package.json >/dev/null
  jq -e '.pnpm.onlyBuiltDependencies | index("bar") != null' ${patchDrift}/package.json >/dev/null
  test ! -e ${patchDrift}/pnpm-workspace.yaml

  # A tree that already names the release it is handed comes back byte for byte, so adapting every tree is not also a source change.
  cmp ${alreadyNamed}/package.json ${fixture "already-named.json"}
  test ! -e ${alreadyNamed}/pnpm-workspace.yaml

  cmp ${foreignManager}/package.json ${fixture "foreign-manager.json"}

  jq -e '.packageManager == "pnpm@${targetVersion}" and (has("pnpm") | not)' ${crossMajor}/package.json >/dev/null
  grep -q '^overrides:' ${crossMajor}/pnpm-workspace.yaml
  grep -q '^onlyBuiltDependencies:' ${crossMajor}/pnpm-workspace.yaml

  test "$(jq -r .packageManager ${nested}/apps/package.json)" = "pnpm@${targetVersion}"
  test ! -e ${nested}/package.json

  touch "''${out}"
''
