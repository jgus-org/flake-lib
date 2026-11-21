# The tree's own formatting check, and the test of the exclusion behavior behind it.
{
  self,
  lib,
  orgFormatting,
  pkgs,
  system,
}:
{
  formatting = orgFormatting.check;

  formatting-tests =
    pkgs.runCommand "formatting-tests"
      {
        EXCLUDING_FORMATTER =
          (lib.mkFormatting {
            inherit self system;
            excludes = [ "skipped/**" ];
          }).formatter;
        FORMATTER = orgFormatting.formatter;
      }
      ''
        bash ${./test_formatting.sh}
        touch $out
      '';
}
