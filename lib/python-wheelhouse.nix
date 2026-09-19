let
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
        uvPythonVersion = pythonVersion;
        uvPythonPlatform = platform;
        pipPythonVersion = pythonMajor + pythonMinor;
        pipPlatforms = pipPlatformLadder platformArch platformVendor;
        pipAbi = "cp" + pythonMajor + pythonMinor;
      };

  mkPythonWheelhouse =
    { pkgs
    , pythonVersion
    , platform
    , sources
    , extraRequirements ? [ ]
    , index ? "https://pypi.org/simple"
    , depsCore ? ../scripts/deps_core.py
    }:
    let
      lib = pkgs.lib;
      validKinds = [ "repo-file" "source-file" "source-pyproject" ];
      invalidSources = lib.filter (source: !(lib.elem source.kind validKinds)) sources;
      artifactPython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging pythonPackages.pip ]);
    in
    if invalidSources != [ ] then
      throw "python-wheelhouse: unknown source kinds [${lib.concatStringsSep ", " (map (source: source.kind) invalidSources)}], expected one of [${lib.concatStringsSep ", " validKinds}]"
    else
      pkgs.writeShellApplication {
        name = "python-wheelhouse";
        runtimeInputs = with pkgs; [ cacert coreutils git uv artifactPython ];
        runtimeEnv = {
          WHEELHOUSE_SPEC = builtins.toJSON ({
            inherit sources extraRequirements;
          } // (platformTags { inherit pythonVersion platform; }));
          DEPS_CORE = "${depsCore}";
          INDEX_URL = index;
        };
        text = ''exec ${artifactPython}/bin/python ${../scripts/python-wheelhouse.py}'';
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
  inherit platformTags mkPythonWheelhouse mkWheelhouse installWheelhouse;
}
