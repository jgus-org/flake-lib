let
  inherit (import ./default-systems.nix) defaultSystems;

  pythonEnvironments = {
    pythonVersions = [
      "3.13"
      "3.14"
    ];
    systems = defaultSystems;
    targets = {
      aarch64-darwin.uvPlatform = "aarch64-apple-darwin";
      aarch64-linux.uvPlatform = "aarch64-manylinux_2_28";
      # Not a build host any more, but an Intel macOS wheel remains a target a producer can ask for.
      x86_64-darwin.uvPlatform = "x86_64-apple-darwin";
      x86_64-linux.uvPlatform = "x86_64-manylinux_2_28";
    };
  };

  platformTags =
    {
      platform,
      pythonVersion,
    }:
    let
      pythonParts = builtins.match "([0-9]+)\\.([0-9]+)" pythonVersion;
      platformParts = builtins.match "([A-Za-z0-9_]+)-(.+)" platform;
    in
    if pythonParts == null then
      throw "python-wheelhouse: pythonVersion must be <major>.<minor>, got \"${pythonVersion}\""
    else if platformParts == null then
      throw "python-wheelhouse: platform must be <arch>-<vendor>, got \"${platform}\""
    else if
      !(
        builtins.elemAt platformParts 1 == "linux"
        || builtins.match "manylinux_2_[0-9]+" (builtins.elemAt platformParts 1) != null
        || builtins.elemAt platformParts 1 == "apple-darwin"
      )
    then
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
        inherit markerEnvironment;
        pipAbi = "cp" + pythonMajor + pythonMinor;
        pipPlatforms =
          if isDarwin then
            [ "macosx_14_0_${if platformArch == "aarch64" then "arm64" else platformArch}" ]
          else
            pipPlatformLadder platformArch platformVendor;
        pipPythonVersion = pythonMajor + pythonMinor;
        python = pythonVersion;
        uvEnvironment = if isDarwin then { MACOSX_DEPLOYMENT_TARGET = "14.0"; } else { };
        uvPythonPlatform = platform;
        uvPythonVersion = pythonVersion;
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
      aliasNames =
        if arch == "x86_64" then
          [
            "manylinux2014"
            "manylinux2010"
            "manylinux1"
          ]
        else
          [ "manylinux2014" ];
      glibcFloor = 5;
    in
    if vendor == "linux" then
      [ "linux_${arch}" ]
    else if numeric != null then
      let
        minor = builtins.fromJSON (builtins.elemAt numeric 0);
        descending = map (step: "manylinux_2_${toString (minor - step)}_${arch}") (
          builtins.genList (step: step) (minor - glibcFloor + 1)
        );
        usableAliases = map (name: "${name}_${arch}") (
          builtins.filter (name: aliases.${name} <= minor) aliasNames
        );
      in
      descending ++ usableAliases ++ [ "linux_${arch}" ]
    else
      throw "python-wheelhouse: unsupported pip platform vendor \"${vendor}\" (expected manylinux_<glibc> or linux)";

  mkPythonWheelhouse =
    {
      depsCore ? ../scripts/deps_core.py,
      extraRequirements ? [ ],
      index ? "https://pypi.org/simple",
      noEmit ? [ ],
      pkgs,
      pythonVersions ? pythonEnvironments.pythonVersions,
      sources,
      systems ? pythonEnvironments.systems,
    }:
    let
      lib = pkgs.lib;
      validKinds = [
        "repo-file"
        "source-file"
        "source-pyproject"
      ];
      invalidSources = lib.filter (source: !(lib.elem source.kind validKinds)) sources;
      artifactPython = pkgs.python3.withPackages (pythonPackages: [
        pythonPackages.packaging
        pythonPackages.pip
      ]);
      environmentFor =
        {
          pythonVersion,
          system,
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
          // {
            inherit system;
          };
      environments = lib.concatMap (
        pythonVersion: map (system: environmentFor { inherit pythonVersion system; }) systems
      ) pythonVersions;
      generationSpec = {
        inherit
          environments
          extraRequirements
          noEmit
          sources
          ;
        generator = {
          depsCore = builtins.hashFile "sha256" depsCore;
          packaging = pkgs.python3Packages.packaging.version;
          pip = pkgs.python3Packages.pip.version;
          python = pkgs.python3.version;
          script = builtins.hashFile "sha256" ../scripts/python-wheelhouse.py;
          uv = pkgs.uv.version;
        };
        indexUrl = index;
      };
      fingerprint = builtins.hashString "sha256" (builtins.toJSON generationSpec);
    in
    if invalidSources != [ ] then
      throw "python-wheelhouse: unknown source kinds [${
        lib.concatStringsSep ", " (map (source: source.kind) invalidSources)
      }], expected one of [${lib.concatStringsSep ", " validKinds}]"
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
        inherit fingerprint;
        hook = pkgs.writeShellApplication {
          excludeShellChecks = [
            "SC2089"
            "SC2090"
          ];
          name = "python-wheelhouse";
          runtimeEnv = {
            DEPS_CORE = "${pkgs.copyPathToStore depsCore}";
            WHEELHOUSE_SPEC = builtins.toJSON (generationSpec // { inherit fingerprint; });
          };
          runtimeInputs = with pkgs; [
            cacert
            coreutils
            git
            uv
            artifactPython
          ];
          text = "exec ${artifactPython}/bin/python ${../scripts/python-wheelhouse.py}";
        };
      };

  manifestFromWheels =
    wheels: if builtins.isList wheels then wheels else builtins.fromJSON (builtins.readFile wheels);

  wheelhouseArtifactPaths =
    {
      pythonVersion,
      pythonVersions ? pythonEnvironments.pythonVersions,
      root,
      system,
    }:
    if !(builtins.elem pythonVersion pythonVersions) then
      throw "python-wheelhouse: unsupported pythonVersion \"${pythonVersion}\""
    else if
      !(builtins.elem system pythonEnvironments.systems)
      || !(builtins.hasAttr system pythonEnvironments.targets)
    then
      throw "python-wheelhouse: unsupported system \"${system}\""
    else
      {
        requirementsLock = root + "/requirements-${pythonVersion}-${system}.lock";
        wheelManifest = root + "/wheels-${pythonVersion}-${system}.json";
      };

  # A wheelhouse is the whole environment only when nothing else populates the
  # interpreter. `noEmit` names what the consumer's own package set provides instead, so
  # the artifact this builds carries neither a duplicate of it nor a version that would
  # shadow it. Either a list of distribution names or a predicate on a name as the
  # manifest records it; a listed name that matches nothing is reported, not ignored.
  mkWheelhouse =
    {
      noEmit ? [ ],
      pkgs,
      wheels,
    }:
    let
      lib = pkgs.lib;
      # The manifest carries PEP 503 names; a consumer may spell a name any other way.
      canonical = name: builtins.replaceStrings [ "_" "." ] [ "-" "-" ] (lib.toLower name);
      listed = builtins.isList noEmit;
      wanted = lib.unique (map canonical (if listed then noEmit else [ ]));
      manifest = manifestFromWheels wheels;
      unmatched = lib.unique (lib.subtractLists (map (wheel: canonical wheel.name) manifest) wanted);
      excluded = wheel: if listed then lib.elem (canonical wheel.name) wanted else noEmit wheel.name;
      selected = lib.filter (wheel: !excluded wheel) manifest;
      files = map (
        wheel:
        pkgs.fetchurl {
          inherit (wheel) sha256 url;
          name = wheel.filename;
        }
      ) selected;
      wheelhouse = pkgs.linkFarm "python-wheelhouse" (
        lib.zipListsWith (wheel: path: {
          inherit path;
          name = wheel.filename;
        }) selected files
      );
    in
    lib.warnIf (listed && unmatched != [ ])
      "mkWheelhouse: noEmit names [${lib.concatStringsSep ", " unmatched}] match no wheel in the manifest; the exclusion had no effect."
      { inherit files wheelhouse; };

  installWheelhouse =
    {
      python,
      target,
      wheelhouse,
    }:
    ''uv pip install --python ${python}/bin/python --target ${target} --no-index --no-deps "${wheelhouse}"/*.whl'';

  # Manylinux wheels name a loader and shared libraries that exist on the machine that built
  # them and nowhere in the store, so an installed wheelhouse is only a valid store artifact
  # once its binaries are rewritten. The rewrite is part of the install rather than a hook a
  # consumer remembers to add, and `checkImports` runs each name in an interpreter with no
  # environment at all: a tree that imports only under an ambient `LD_LIBRARY_PATH` fails
  # here instead of at the first import in production.
  mkWheelhouseSiteTree =
    {
      buildInputs ? [ ],
      checkImports ? [ ],
      nativeBuildInputs ? [ ],
      pkgs,
      python,
      wheelhouse,
      ...
    }@args:
    let
      lib = pkgs.lib;
      inherited = builtins.removeAttrs args [
        "pkgs"
        "python"
        "wheelhouse"
        "checkImports"
        "nativeBuildInputs"
        "buildInputs"
      ];
    in
    pkgs.stdenv.mkDerivation (
      inherited
      // {
        buildInputs = [
          pkgs.stdenv.cc.cc.lib
          pkgs.zlib
        ]
        ++ buildInputs;
        doInstallCheck = checkImports != [ ];
        installCheckPhase = ''
          runHook preInstallCheck
          env -i PYTHONPATH="$out/$sitePackages" ${python}/bin/${python.executable} \
            -c '${lib.concatStringsSep "; " (map (module: "import ${module}") checkImports)}'
          runHook postInstallCheck
        '';
        installPhase = ''
          runHook preInstall
          export HOME="$TMPDIR"
          mkdir -p "$out/$sitePackages"
          ${installWheelhouse {
            inherit python wheelhouse;
            target = "$out/$sitePackages";
          }}
          runHook postInstall
        '';
        nativeBuildInputs = [
          pkgs.uv
          pkgs.autoPatchelfHook
          python
        ]
        ++ nativeBuildInputs;
        sitePackages = python.sitePackages;
      }
    );
in
{
  inherit
    installWheelhouse
    mkPythonWheelhouse
    mkWheelhouse
    mkWheelhouseSiteTree
    platformTags
    pythonEnvironments
    wheelhouseArtifactPaths
    ;
}
