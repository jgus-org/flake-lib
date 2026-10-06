{ pkgs }:
{
  python = pkgs.python3.withPackages (
    pythonPackages: [
      pythonPackages.hf-xet
      pythonPackages.huggingface-hub
    ]
  );
  script = ../scripts/huggingface-model-manager.py;
}
