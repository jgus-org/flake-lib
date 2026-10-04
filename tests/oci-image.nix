{ pkgs, lib }:
let
  source = {
    type = "oci";
    imageName = "registry.example/image";
    tag = "latest";
    os = "linux";
    arch = "amd64";
    finalImageName = "example/image";
    finalImageTag = "latest";
  };
  digest = "sha256:${builtins.concatStringsSep "" (builtins.genList (_: "a") 64)}";
  skopeo =
    (pkgs.writeShellApplication {
      name = "skopeo";
      runtimeInputs = [
        pkgs.jq
        pkgs.gnugrep
      ];
      text = ''
        OCI_OS=""
        OCI_ARCH=""
        OCI_VARIANT=""
        OCI_REGISTRIES=""
        while (( ''${#} > 0 )); do
          case "''${1}" in
            --registries-conf) OCI_REGISTRIES="''${2}"; shift 2 ;;
            --override-os) OCI_OS="''${2}"; shift 2 ;;
            --override-arch) OCI_ARCH="''${2}"; shift 2 ;;
            --override-variant) OCI_VARIANT="''${2}"; shift 2 ;;
            --tmpdir) shift 2 ;;
            --tmpdir=*) shift ;;
            --insecure-policy) shift ;;
            inspect | copy) OCI_OPERATION="''${1}"; shift; break ;;
            *) exit 41 ;;
          esac
        done
        grep -Fxq 'unqualified-search-registries = []' "''${OCI_REGISTRIES}"
        jq -e 'keys == ["auths"] and .auths == {}' "''${REGISTRY_AUTH_FILE}" >/dev/null
        if [[ "''${1}" == --no-tags || "''${1}" == --src-tls-verify=true ]]; then
          shift
        fi
        OCI_URL="''${1}"
        if [[ -n "''${TEST_OCI_LOG:-}" ]]; then
          printf '%s\n' "''${OCI_OPERATION} os=''${OCI_OS} arch=''${OCI_ARCH} variant=''${OCI_VARIANT} source=''${OCI_URL}" >> "''${TEST_OCI_LOG}"
        fi
        if [[ "''${TEST_OCI_FAIL:-}" == "''${OCI_OPERATION}" ]]; then
          exit 42
        fi
        if [[ "''${OCI_OPERATION}" == inspect ]]; then
          printf '%s\n' "''${TEST_OCI_METADATA}"
        else
          OCI_ARCHIVE="''${2#docker-archive://}"
          OCI_ARCHIVE="''${OCI_ARCHIVE%%:*}"
          OCI_REFERENCE="''${2#docker-archive://"''${OCI_ARCHIVE}":}"
          printf '%s\n' \
            "source=''${OCI_URL}" \
            "os=''${OCI_OS}" \
            "arch=''${OCI_ARCH}" \
            "variant=''${OCI_VARIANT}" \
            "reference=''${OCI_REFERENCE}" > "''${OCI_ARCHIVE}"
        fi
      '';
    }).overrideAttrs
      (_: {
        version = "fixture";
      });
  fixturePkgs = pkgs // {
    inherit skopeo;
  };
  contract = import ../lib/oci-image.nix {
    pkgs = fixturePkgs;
    inherit source;
  };
  armContract = import ../lib/oci-image.nix {
    pkgs = fixturePkgs;
    source = source // {
      arch = "arm64";
      variant = "v8";
    };
  };
  archive = ''
    source=docker://registry.example/image@${digest}
    os=linux
    arch=amd64
    variant=
    reference=example/image:latest
  '';
  imageHash = builtins.convertHash {
    hash = builtins.hashString "sha256" archive;
    hashAlgo = "sha256";
    toHashFormat = "sri";
  };
  image = lib.mkOciImage {
    pkgs = fixturePkgs;
    inherit source;
    pin = {
      imageDigest = digest;
      inherit imageHash;
      archiveFingerprint = contract.fingerprint;
    };
  };
  changed =
    field: value:
    (import ../lib/oci-image.nix {
      pkgs = fixturePkgs;
      source = source // {
        ${field} = value;
      };
    }).fingerprint;
  patchedContract = import ../lib/oci-image.nix {
    pkgs = fixturePkgs // {
      skopeo = skopeo.overrideAttrs (_: {
        postInstall = "true";
      });
    };
    inherit source;
  };
  stalePin =
    builtins.tryEval
      (lib.mkOciImage {
        pkgs = fixturePkgs;
        inherit source;
        pin = {
          imageDigest = digest;
          inherit imageHash;
          archiveFingerprint = "stale";
        };
      }).drvPath;
in
assert builtins.all (fingerprint: fingerprint != contract.fingerprint) [
  (changed "imageName" "registry.example/other")
  (changed "tag" "other")
  (changed "os" "windows")
  (changed "arch" "arm64")
  (changed "variant" "v8")
  (changed "finalImageName" "example/other")
  (changed "finalImageTag" "other")
];
assert
  image.baseImage == contract.pullArgs
  // {
    imageDigest = digest;
    hash = imageHash;
  };
assert image.archiveFingerprint == contract.fingerprint;
assert patchedContract.fingerprint != contract.fingerprint;
assert !stalePin.success;
{
  inherit image imageHash;
  settings = builtins.toJSON contract.settings;
  fingerprint = contract.fingerprint;
  skopeo = pkgs.lib.getExe contract.skopeo;
  armSkopeo = pkgs.lib.getExe armContract.skopeo;
}
