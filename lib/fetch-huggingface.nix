{
  pkgs,
  name,
  manifest,
  outputHash,
  downloader ? null,
}:
let
  inherit (pkgs) lib;
  client = import ./huggingface-client.nix { inherit pkgs; };
  inherit (builtins.fromJSON (builtins.readFile manifest)) files;

  # The declared tree is fetched with the same downloader the runtime model manager
  # uses, into a scratch directory, then only the manifest files are promoted into
  # `$out`. The downloader's cache and lock sidecar live in the scratch directory, so
  # they are never hashed into the store path and the recursive output hash stays stable.
  downloadCommand =
    if downloader != null then
      downloader
    else
      ''${client.python}/bin/python ${client.script} ${manifest} fetch-stamp download staging'';
in
pkgs.runCommand name {
  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  inherit outputHash;
  nativeBuildInputs = lib.optionals (downloader == null) [ client.python ];
  impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [ "HF_TOKEN" ];
} ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME" staging
  ${downloadCommand}
  runHook preInstall
  ${lib.concatMapStringsSep "\n" (file: ''install -Dm0644 "staging/${file.path}" "$out/${file.path}"'') files}
  runHook postInstall
''
