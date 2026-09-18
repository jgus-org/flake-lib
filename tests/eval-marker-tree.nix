{ evalMarkerTree }:
let
  bindings = {
    python_version = "3.13";
    python_full_version = "3.13.5";
    sys_platform = "linux";
    platform_machine = "x86_64";
  };
  bound = evalMarkerTree bindings;
in
{
  nullMarkerIsApplicable = {
    expr = bound null;
    expected = true;
  };
  falseMarkerIsNotApplicable = {
    expr = bound false;
    expected = false;
  };
  pythonVersionComparison = {
    expr = bound { kind = "cmp"; variable = "python_version"; operator = ">="; literal = "3.10"; };
    expected = true;
  };
  pythonVersionBelowFails = {
    expr = bound { kind = "cmp"; variable = "python_version"; operator = "<"; literal = "3.10"; };
    expected = false;
  };
  pythonVersionTrailingZeroEquivalence = {
    expr = bound { kind = "cmp"; variable = "python_version"; operator = "=="; literal = "3.13"; };
    expected = true;
  };
  platformMachineEquality = {
    expr = bound { kind = "cmp"; variable = "platform_machine"; operator = "=="; literal = "x86_64"; };
    expected = true;
  };
  platformMachineInequality = {
    expr = bound { kind = "cmp"; variable = "platform_machine"; operator = "!="; literal = "ARM64"; };
    expected = true;
  };
  exactOperatorMatches = {
    expr = bound { kind = "cmp"; variable = "python_version"; operator = "==="; literal = "3.13"; };
    expected = true;
  };
  allConditions = {
    expr = bound {
      kind = "all";
      conditions = [
        { kind = "cmp"; variable = "python_version"; operator = ">="; literal = "3.10"; }
        { kind = "cmp"; variable = "platform_machine"; operator = "!="; literal = "ARM64"; }
      ];
    };
    expected = true;
  };
  allConditionFails = {
    expr = bound {
      kind = "all";
      conditions = [
        { kind = "cmp"; variable = "python_version"; operator = ">="; literal = "3.10"; }
        { kind = "cmp"; variable = "platform_machine"; operator = "=="; literal = "ARM64"; }
      ];
    };
    expected = false;
  };
  anyCondition = {
    expr = bound {
      kind = "any";
      conditions = [
        { kind = "cmp"; variable = "python_version"; operator = "<"; literal = "3.10"; }
        { kind = "cmp"; variable = "platform_machine"; operator = "!="; literal = "ARM64"; }
      ];
    };
    expected = true;
  };
  anyConditionFails = {
    expr = bound {
      kind = "any";
      conditions = [
        { kind = "cmp"; variable = "python_version"; operator = "<"; literal = "3.10"; }
        { kind = "cmp"; variable = "python_full_version"; operator = "<"; literal = "3.0"; }
      ];
    };
    expected = false;
  };
  nestedGroups = {
    expr = bound {
      kind = "any";
      conditions = [
        {
          kind = "all";
          conditions = [
            { kind = "cmp"; variable = "python_version"; operator = ">="; literal = "3.12"; }
            { kind = "cmp"; variable = "platform_machine"; operator = "=="; literal = "ARM64"; }
          ];
        }
        { kind = "cmp"; variable = "sys_platform"; operator = "=="; literal = "linux"; }
      ];
    };
    expected = true;
  };
  orderedNonVersionVariableThrows = {
    expr = builtins.tryEval (bound { kind = "cmp"; variable = "sys_platform"; operator = "<"; literal = "win32"; });
    expected = { success = false; value = false; };
  };
  unknownVariableThrows = {
    expr = builtins.tryEval (bound { kind = "cmp"; variable = "platform_release"; operator = "=="; literal = ""; });
    expected = { success = false; value = false; };
  };
  unknownKindThrows = {
    expr = builtins.tryEval (bound { kind = "bogus"; });
    expected = { success = false; value = false; };
  };
}
