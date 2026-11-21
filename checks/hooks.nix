# Each check builds a generated hook and asserts the result is executable.
{ lib, pkgs }:
let
  npm-generated-hook = lib.mkJsDepsHook {
    inherit pkgs;
    manager = "npm";
    source = "generated";
  };

  yarn-hook = lib.mkJsDepsHook {
    inherit pkgs;
    manager = "yarn";
  };

  hookCheck = name: exe: pkgs.runCommand name { } "test -x ${exe} && touch $out";
in
{
  composed-hook = hookCheck "composed-hook" (
    lib.mkComposedHook {
      inherit pkgs;
      hooks = [
        npm-generated-hook
        yarn-hook
      ];
    }
  );

  npm-generated-hook = hookCheck "npm-generated-hook" npm-generated-hook;

  npm-shipped-hook = hookCheck "npm-shipped-hook" (
    lib.mkJsDepsHook {
      inherit pkgs;
      fetcherVersion = 2;
      manager = "npm";
    }
  );

  yarn-hook = hookCheck "yarn-hook" yarn-hook;
}
