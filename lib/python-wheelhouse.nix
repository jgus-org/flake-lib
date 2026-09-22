{ pythonEnvironments }:
let
  platformTags =
    { pythonVersion
    , platform
    }:
    let
      pythonParts = builtins.match "([0-9]+)\\.([0-9]+)" pythonVersion;
      platformParts = builtins.match "([A-Za-z0-9_]+)-(.+)" platform;
    in
    if pythonParts == null then
      throw "python-wheelhouse: pythonVersion must be <major>.<minor>, got \"${pythonVersion}\""
    else if platformParts == null then
      throw "python-wheelhouse: platform must be <arch>-<vendor>, got \"${platform}\""
    else if !(builtins.elemAt platformParts 1 == "linux" || builtins.match "manylinux_2_[0-9]+" (builtins.elemAt platformParts 1) != null || builtins.elemAt platformParts 1 == "apple-darwin") then
      throw "python-wheelhouse: unsupported platform vendor \"${builtins.elemAt platformParts 1}\""
    else
      let
        pythonMajor = builtins.head pythonParts;
        pythonMinor = builtins.elemAt pythonParts 1;
        platformArch = builtins.head platformParts;
        platformVendor = builtins.elemAt platformParts 1;
        isDarwin = platformVendor == "apple-darwin";
        markerEnvironment = {
          implementation_name = "cpython";
          implementation_version = "${pythonVersion}.0";
          os_name = "posix";
          platform_machine = if isDarwin && platformArch == "aarch64" then "arm64" else platformArch;
          platform_python_implementation = "CPython";
          platform_release = "";
          platform_system = if isDarwin then "Darwin" else "Linux";
          platform_version = "";
          python_full_version = "${pythonVersion}.0";
          python_version = pythonVersion;
          sys_platform = if isDarwin then "darwin" else "linux";
        };
      in
      {
        python = pythonVersion;
        uvPythonVersion = pythonVersion;
        uvPythonPlatform = platform;
        pipPythonVersion = pythonMajor + pythonMinor;
        pipPlatforms = if isDarwin then [ "macosx_14_0_${if platformArch == "aarch64" then "arm64" else platformArch}" ] else pipPlatformLadder platformArch platformVendor;
        pipAbi = "cp" + pythonMajor + pythonMinor;
        uvEnvironment = if isDarwin then { MACOSX_DEPLOYMENT_TARGET = "14.0"; } else { };
        inherit markerEnvironment;
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
        descending = map (step: "manylinux_2_${toString (minor - step)}_${arch}") (builtins.genList (step: step) (minor - glibcFloor + 1));
        usableAliases = map (name: "${name}_${arch}") (builtins.filter (name: aliases.${name} <= minor) aliasNames);
      in
      descending ++ usableAliases ++ [ "linux_${arch}" ]
    else
      throw "python-wheelhouse: unsupported pip platform vendor \"${vendor}\" (expected manylinux_<glibc> or linux)";

  mkPythonWheelhouse =
    { pkgs
    , sources
    , extraRequirements ? [ ]
    , pythonVersions ? pythonEnvironments.pythonVersions
    , systems ? pythonEnvironments.systems
    , index ? "https://pypi.org/simple"
    , depsCore ? ../scripts/deps_core.py
    }:
    let
      lib = pkgs.lib;
      validKinds = [ "repo-file" "source-file" "source-pyproject" ];
      invalidSources = lib.filter (source: !(lib.elem source.kind validKinds)) sources;
      artifactPython = pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging pythonPackages.pip ]);
      environmentFor =
        { pythonVersion
        , system
        }:
        if !(builtins.hasAttr system pythonEnvironments.targets) then
          throw "python-wheelhouse: unsupported system \"${system}\""
        else if !(builtins.hasAttr "uvPlatform" pythonEnvironments.targets.${system}) then
          throw "python-wheelhouse: system \"${system}\" has no uvPlatform target"
        else
          (platformTags {
            inherit pythonVersion;
            platform = pythonEnvironments.targets.${system}.uvPlatform;
          })
          // { inherit system; };
      environments = lib.concatMap (pythonVersion: map (system: environmentFor { inherit pythonVersion system; }) systems) pythonVersions;
      generationSpec = {
        inherit sources extraRequirements environments;
        generator = {
          script = builtins.hashFile "sha256" ../scripts/python-wheelhouse.py;
          depsCore = builtins.hashFile "sha256" depsCore;
          uv = pkgs.uv.version;
          python = pkgs.python3.version;
          pip = pkgs.python3Packages.pip.version;
          packaging = pkgs.python3Packages.packaging.version;
        };
        indexUrl = index;
      };
      fingerprint = builtins.hashString "sha256" (builtins.toJSON generationSpec);
    in
    if invalidSources != [ ] then
      throw "python-wheelhouse: unknown source kinds [${lib.concatStringsSep ", " (map (source: source.kind) invalidSources)}], expected one of [${lib.concatStringsSep ", " validKinds}]"
    else if environments == [ ] then
      throw "python-wheelhouse: pythonVersions and systems must name at least one prepared environment"
    else if lib.length (lib.unique pythonVersions) != lib.length pythonVersions then
      throw "python-wheelhouse: pythonVersions must not contain duplicates"
    else if lib.any (system: !(builtins.hasAttr system pythonEnvironments.targets)) systems then
      throw "python-wheelhouse: systems must have configured targets"
    else if lib.length (lib.unique systems) != lib.length systems then
      throw "python-wheelhouse: systems must not contain duplicates"
    else
      {
        hook = pkgs.writeShellApplication {
          name = "python-wheelhouse";
          excludeShellChecks = [ "SC2089" "SC2090" ];
          runtimeInputs = with pkgs; [ cacert coreutils git uv artifactPython ];
          runtimeEnv = {
            WHEELHOUSE_SPEC = builtins.toJSON (generationSpec // { inherit fingerprint; });
            DEPS_CORE = "${depsCore}";
          };
          text = ''exec ${artifactPython}/bin/python ${../scripts/python-wheelhouse.py}'';
        };
        inherit fingerprint;
      };

  manifestFromWheels = wheels:
    if builtins.isList wheels then wheels
    else builtins.fromJSON (builtins.readFile wheels);

  wheelhouseArtifactPaths =
    { root
    , pythonVersion
    , system
    , pythonVersions ? pythonEnvironments.pythonVersions
    }:
    if !(builtins.elem pythonVersion pythonVersions) then
      throw "python-wheelhouse: unsupported pythonVersion \"${pythonVersion}\""
    else if !(builtins.elem system pythonEnvironments.systems) || !(builtins.hasAttr system pythonEnvironments.targets) then
      throw "python-wheelhouse: unsupported system \"${system}\""
    else
      {
        requirementsLock = root + "/requirements-${pythonVersion}-${system}.lock";
        wheelManifest = root + "/wheels-${pythonVersion}-${system}.json";
      };

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
  inherit pythonEnvironments platformTags mkPythonWheelhouse wheelhouseArtifactPaths mkWheelhouse installWheelhouse;
}
