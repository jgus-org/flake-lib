{ pythonPolicy }:
let
  platformTags =
    { pythonVersion
    , platform
    }:
    let
      pythonParts = builtins.match "([0-9]+)\\.([0-9]+)" pythonVersion;
      platformParts = builtins.match "([A-Za-z0-9_]+)-([A-Za-z0-9_]+)" platform;
    in
    if pythonParts == null then
      throw "python-wheelhouse: pythonVersion must be <major>.<minor>, got \"${pythonVersion}\""
    else if platformParts == null then
      throw "python-wheelhouse: platform must be <arch>-<vendor>, got \"${platform}\""
    else
      let
        pythonMajor = builtins.head pythonParts;
        pythonMinor = builtins.elemAt pythonParts 1;
        platformArch = builtins.head platformParts;
        platformVendor = builtins.elemAt platformParts 1;
      in
      {
        python = pythonVersion;
        uvPythonVersion = pythonVersion;
        uvPythonPlatform = platform;
        pipPythonVersion = pythonMajor + pythonMinor;
        pipPlatforms = pipPlatformLadder platformArch platformVendor;
        pipAbi = "cp" + pythonMajor + pythonMinor;
      };

  pipPlatformLadder =
    arch: vendor:
    let
      numeric = builtins.match "manylinux_2_([0-9]+)" vendor;
      aliases = {
        manylinux1 = 5;
        manylinux2010 = 12;
        manylinux2014 = 17;
      };
      aliasNames = if arch == "x86_64" then [ "manylinux2014" "manylinux2010" "manylinux1" ] else [ "manylinux2014" ];
      glibcFloor = 5;
    in
    if vendor == "linux" then
      [ "linux_${arch}" ]
    else if numeric != null then
      let
        minor = builtins.fromJSON (builtins.elemAt numeric 0);
        descending = map (step: "manylinux_2_${toString (minor - step)}_${arch}") (builtins.genList (step: step + 1) (minor - glibcFloor + 1));
        usableAliases = map (name: "${name}_${arch}") (builtins.filter (name: aliases.${name} <= minor) aliasNames);
      in
      descending ++ usableAliases ++ [ "linux_${arch}" ]
    else
      throw "python-wheelhouse: unsupported pip platform vendor \"${vendor}\" (expected manylinux_<glibc> or linux)";

  mkPythonWheelhouse =
    { pkgs
    , sources
    , extraRequirements ? [ ]
    , pythonVersions ? pythonPolicy.pythonVersions
    , platform ? pythonPolicy.platform
    , index ? "https://pypi.org/simple"
    , depsCore ? ../scripts/deps_core.py
    }:
    let
      lib = pkgs.lib;
      validKinds = [ "repo-file" "source-file" "source-pyproject" ];
      invalidSources = lib.filter (source: !(lib.elem source.kind validKinds)) sources;
      artifactPython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging pythonPackages.pip ]);
      environments = lib.imap0
        (index: env: env // { readiness = index != 0; })
        (map (pythonVersion: platformTags { inherit pythonVersion platform; }) pythonVersions);
      current = builtins.head environments;
    in
    if invalidSources != [ ] then
      throw "python-wheelhouse: unknown source kinds [${lib.concatStringsSep ", " (map (source: source.kind) invalidSources)}], expected one of [${lib.concatStringsSep ", " validKinds}]"
    else if environments == [ ] then
      throw "python-wheelhouse: pythonVersions must name at least the current environment"
    else
      {
        hook = pkgs.writeShellApplication {
          name = "python-wheelhouse";
          runtimeInputs = with pkgs; [ cacert coreutils git uv artifactPython ];
          runtimeEnv = {
            WHEELHOUSE_SPEC = builtins.toJSON {
              inherit sources extraRequirements environments;
            };
            DEPS_CORE = "${depsCore}";
            INDEX_URL = index;
          };
          text = ''exec ${artifactPython}/bin/python ${../scripts/python-wheelhouse.py}'';
        };
        currentEnvironment = {
          python = current.python;
          inherit platform;
          fingerprint = "${current.python}-${platform}";
        };
      };

  manifestFromWheels = wheels:
    if builtins.isList wheels then wheels
    else builtins.fromJSON (builtins.readFile wheels);

  mkWheelhouse = { pkgs, wheels }:
    let
      lib = pkgs.lib;
      manifest = manifestFromWheels wheels;
      files = map
        (wheel: pkgs.fetchurl { inherit (wheel) url sha256; name = wheel.filename; })
        manifest;
      wheelhouse = pkgs.linkFarm "python-wheelhouse" (lib.zipListsWith
        (wheel: path: { name = wheel.filename; inherit path; })
        manifest
        files);
    in
    { inherit files wheelhouse; };

  installWheelhouse = { python, target, wheelhouse }:
    ''uv pip install --python ${python}/bin/python --target ${target} --no-index --no-deps "${wheelhouse}"/*.whl'';
in
{
  inherit pythonPolicy platformTags mkPythonWheelhouse mkWheelhouse installWheelhouse;
}
