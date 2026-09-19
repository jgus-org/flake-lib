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
  testNullMarkerIsApplicable = {
    expr = bound null;
    expected = true;
  };
  testFalseMarkerIsNotApplicable = {
    expr = bound false;
    expected = false;
  };
  testPythonVersionComparison = {
    expr = bound { kind = "cmp"; variable = "python_version"; operator = ">="; literal = "3.10"; };
    expected = true;
  };
  testPythonVersionBelowFails = {
    expr = bound { kind = "cmp"; variable = "python_version"; operator = "<"; literal = "3.10"; };
    expected = false;
  };
  testPythonVersionTrailingZeroEquivalence = {
    expr = bound { kind = "cmp"; variable = "python_full_version"; operator = "=="; literal = "3.13.5.0"; };
    expected = true;
  };
  testPlatformMachineEquality = {
    expr = bound { kind = "cmp"; variable = "platform_machine"; operator = "=="; literal = "x86_64"; };
    expected = true;
  };
  testPlatformMachineInequality = {
    expr = bound { kind = "cmp"; variable = "platform_machine"; operator = "!="; literal = "ARM64"; };
    expected = true;
  };
  testExactOperatorMatches = {
    expr = bound { kind = "cmp"; variable = "python_version"; operator = "==="; literal = "3.13"; };
    expected = true;
  };
  testAllConditions = {
    expr = bound {
      kind = "all";
      conditions = [
        { kind = "cmp"; variable = "python_version"; operator = ">="; literal = "3.10"; }
        { kind = "cmp"; variable = "platform_machine"; operator = "!="; literal = "ARM64"; }
      ];
    };
    expected = true;
  };
  testAllConditionFails = {
    expr = bound {
      kind = "all";
      conditions = [
        { kind = "cmp"; variable = "python_version"; operator = ">="; literal = "3.10"; }
        { kind = "cmp"; variable = "platform_machine"; operator = "=="; literal = "ARM64"; }
      ];
    };
    expected = false;
  };
  testAnyCondition = {
    expr = bound {
      kind = "any";
      conditions = [
        { kind = "cmp"; variable = "python_version"; operator = "<"; literal = "3.10"; }
        { kind = "cmp"; variable = "platform_machine"; operator = "!="; literal = "ARM64"; }
      ];
    };
    expected = true;
  };
  testAnyConditionFails = {
    expr = bound {
      kind = "any";
      conditions = [
        { kind = "cmp"; variable = "python_version"; operator = "<"; literal = "3.10"; }
        { kind = "cmp"; variable = "python_full_version"; operator = "<"; literal = "3.0"; }
      ];
    };
    expected = false;
  };
  testNestedGroups = {
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
  testOrderedNonVersionVariableThrows = {
    expr = builtins.tryEval (bound { kind = "cmp"; variable = "sys_platform"; operator = "<"; literal = "win32"; });
    expected = { success = false; value = false; };
  };
  testUnknownVariableThrows = {
    expr = builtins.tryEval (bound { kind = "cmp"; variable = "platform_release"; operator = "=="; literal = ""; });
    expected = { success = false; value = false; };
  };
  testUnknownKindThrows = {
    expr = builtins.tryEval (bound { kind = "bogus"; });
    expected = { success = false; value = false; };
  };
}
