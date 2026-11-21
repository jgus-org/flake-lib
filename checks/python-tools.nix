# Suites for the python the tools run: the dependency core, the ordering gate, and the model manager.
{ lib, pkgs }:
let
  huggingface-model-manager = lib.mkHuggingFaceModelManager {
    inherit pkgs;
    manifest = pkgs.writeText "huggingface-model-manager-manifest.json" ''
      {
        "repo": "example/model",
        "revision": "revision-one",
        "total_bytes": 32,
        "files": [
          { "path": "sha256.txt", "bytes": 15, "sha256": "85ad1c506a0c0e1eb1b7d36d4a5128b90d2e411863baf1f275279aec8b3e458a" },
          { "path": "git-blob.txt", "bytes": 17, "sha256": null, "git_blob": "9a5c9c50f67f7be093ed07dc3bc185066b5c9067" }
        ]
      }
    '';
    model = { };
    name = "huggingface-model-manager";
  };
in
{
  cascade-tests =
    pkgs.runCommand "cascade-tests"
      {
        CASCADE_PY = ../scripts/cascade.py;
        DEPS_CORE = ../scripts/deps_core.py;
        nativeBuildInputs = [ (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ])) ];
      }
      ''
        python3 ${./test_cascade.py}
        touch $out
      '';

  deps-core-tests =
    pkgs.runCommand "deps-core-tests"
      {
        DEPS_CORE = ../scripts/deps_core.py;
        nativeBuildInputs = [ (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.packaging ])) ];
      }
      ''
        python3 ${./test_deps_core.py}
        touch $out
      '';

  huggingface-model-manager-tests =
    pkgs.runCommand "huggingface-model-manager-tests"
      {
        MODEL_MANAGER = "${huggingface-model-manager}/bin/huggingface-model-manager";
        nativeBuildInputs = [
          pkgs.python3
          huggingface-model-manager
        ];
      }
      ''
        python3 ${./test_huggingface_model_manager.py}
        touch "$out"
      '';

  wait-for-deps-tests =
    pkgs.runCommand "wait-for-deps-tests"
      {
        WAIT_FOR_DEPS = ../scripts/wait_for_deps.py;
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        python3 ${./test_wait_for_deps.py}
        touch $out
      '';
}
