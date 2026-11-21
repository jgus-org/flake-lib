# Generates a flake-lib artifactHook that computes the JS package-manager offline-deps hash at the pinned revision. It prints one `name=value` line, which mkUpdateVersion captures into pin.nix.
#
#   source "shipped"   : upstream ships the lockfile, so fetch it from the repo at NEW_REV (buildNpmPackage/fetchYarnDeps consume upstream's directly)
#   source "generated" : upstream ships none, so regenerate it from package.json and vendor it into FLAKE_ROOT (the flake's build copies ./package-lock.json). npm only.
#   fetcherVersion     : npm only. The fetcher version changes the hash, so it must match the flake's npmDepsFetcherVersion.
{
  fetcherVersion ? null,
  field ? null,
  manager,
  pkgs,
  source ? "shipped",
}:
let
  fieldName =
    if field != null then
      field
    else if manager == "npm" then
      "npmDepsHash"
    else
      "yarnHash";
  npmFetcherEnv = pkgs.lib.optionalString (
    manager == "npm" && fetcherVersion != null
  ) "export NPM_FETCHER_VERSION=${toString fetcherVersion}";

  # Fetch the raw media type rather than the JSON `.content` field. `.content` is base64 and the Contents API caps it at 1 MB, so a large lockfile comes back empty. Raw media streams up to 100 MB.
  ghFetch =
    file:
    ''gh api "/repos/''${GH_OWNER}/''${GH_REPO}/contents/${file}?ref=''${NEW_REV}" -H "Accept: application/vnd.github.raw"'';

  body =
    if manager == "npm" && source == "shipped" then
      ''
        ${ghFetch "package-lock.json"} > "''${work}/package-lock.json"
        hash=$(prefetch-npm-deps "''${work}/package-lock.json")
      ''
    else if manager == "npm" && source == "generated" then
      ''
        ${ghFetch "package.json"} > "''${work}/package.json"
        ( cd "''${work}" && HOME="''${work}" npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 )
        cp "''${work}/package-lock.json" "''${FLAKE_ROOT}/package-lock.json"
        hash=$(prefetch-npm-deps "''${FLAKE_ROOT}/package-lock.json")
      ''
    else if manager == "yarn" && source == "shipped" then
      ''
        ${ghFetch "yarn.lock"} > "''${work}/yarn.lock"
        # prefetch-yarn-deps prints the hash then a trailing blank line. Take the last non-empty line and normalize it to SRI.
        hash=$(prefetch-yarn-deps "''${work}/yarn.lock" 2>/dev/null | awk 'NF{last=$0} END{print last}')
        if [[ "''${hash}" != sha256-* ]]; then
          hash=$(nix hash convert --hash-algo sha256 --to sri "''${hash}")
        fi
      ''
    else
      throw "mkJsDepsHook: unsupported (manager=${manager}, source=${source})";
in
pkgs.lib.getExe (
  pkgs.writeShellApplication {
    name = "js-deps-hook-${manager}-${source}";
    runtimeInputs = [
      pkgs.gh
      pkgs.coreutils
      (if manager == "npm" then pkgs.prefetch-npm-deps else pkgs.prefetch-yarn-deps)
      pkgs.nix
    ]
    ++ pkgs.lib.optionals (manager == "npm" && source == "generated") [ pkgs.nodejs ]
    ++ pkgs.lib.optionals (manager == "yarn") [ pkgs.gawk ];
    text = ''
      work="$(mktemp -d)"
      trap 'rm -rf "''${work}"' EXIT
      ${npmFetcherEnv}
      ${body}
      echo "${fieldName}=''${hash}"
    '';
  }
)
