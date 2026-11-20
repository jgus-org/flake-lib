# Each check builds a generated hook and asserts the result is executable.
{ lib, pkgs }:
let
  npm-generated-hook = lib.mkJsDepsHook {
    inherit pkgs;
    manager = "npm";
    source = "generated";
  };

  pnpm-declaration-hook = lib.mkPnpmDeclarationHook {
    inherit pkgs;
  };

  yarn-hook = lib.mkJsDepsHook {
    inherit pkgs;
    manager = "yarn";
  };

  hookCheck = name: exe: pkgs.runCommand name { } "test -x ${exe} && touch $out";

  # The Contents API answers with the manifest bytes, so the fetch is the only part a check has to supply.
  declares =
    manifest:
    lib.mkPnpmDeclarationHook {
      pkgs = pkgs // {
        gh = pkgs.writeShellApplication {
          name = "gh";
          text = "cat ${pkgs.writeText "manifest" manifest}";
        };
      };
    };

  emitsCheck =
    name: manifest: emitted:
    pkgs.runCommand name { } ''
      GH_OWNER=kdlbs GH_REPO=kandev NEW_REV=0123456789012345678901234567890123456789 \
        ${declares manifest} > actual
      printf '%s\n' ${pkgs.lib.escapeShellArg emitted} > expected
      cmp actual expected
      touch $out
    '';
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
  pnpm-declaration-hook = hookCheck "pnpm-declaration-hook" pnpm-declaration-hook;
  # A major read wrong degrades to a different toolchain rather than an error, so the emitted line is what a downstream build cannot check for itself.
  pnpm-declaration-hook-major = emitsCheck "pnpm-declaration-hook-major" ''
    { "packageManager": "pnpm@9.15.9+sha512.15d5f4deaafb62492fdecebdc0c8344d15c519bce550523f9d41d8f8cae2e0901479947ab73e8747577a241239cd7219f2fe3d837ceb868e8084427110d415a6" }
  '' "pnpmMajor=9";
  yarn-hook = hookCheck "yarn-hook" yarn-hook;
}
