{
  nixpkgs,
  treefmt-nix,
}:
let
  formatterConfig = ../formatter;
in
{
  mkFormatting =
    {
      self,
      excludes ? [ ],
      system,
    }:
    let
      pkgs = nixpkgs.legacyPackages.${system};
      treefmtEval = treefmt-nix.lib.evalModule pkgs {
        programs = {
          clang-format.enable = true;
          gofmt.enable = true;
          nixfmt.enable = true;
          prettier.enable = true;
          ruff-format = {
            enable = true;
            lineLength = 79;
          };
          shfmt = {
            enable = true;
            simplify = false;
          };
        };
        projectRootFile = "flake.nix";
        settings = {
          inherit excludes;
          formatter = {
            clang-format.options = [ "--style=file:${formatterConfig}/.clang-format" ];
            nixfmt = {
              command = pkgs.writeShellApplication {
                name = "nix-format";
                runtimeInputs = [
                  pkgs.nixfmt
                  pkgs.pedantix
                ];
                text = ''exec pedantix "$@"'';
              };
              options = [
                "--config"
                "${formatterConfig}/pedantix.toml"
              ];
              stdin-options = [
                "--config"
                "${formatterConfig}/pedantix.toml"
              ];
            };
          };
        };
      };
    in
    {
      check = treefmtEval.config.build.check self;
      formatter = treefmtEval.config.build.wrapper;
    };
}
