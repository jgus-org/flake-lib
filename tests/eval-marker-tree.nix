{ evalMarkerTree }:
let
  bindings = {
    platform_machine = "x86_64";
    python_full_version = "3.13.5";
    python_version = "3.13";
    sys_platform = "linux";
  };
  bound = evalMarkerTree bindings;
in
{
  testAllConditionFails = {
    expected = false;
    expr = bound {
      conditions = [
        {
          kind = "cmp";
          literal = "3.10";
          operator = ">=";
          variable = "python_version";
        }
        {
          kind = "cmp";
          literal = "ARM64";
          operator = "==";
          variable = "platform_machine";
        }
      ];
      kind = "all";
    };
  };
  testAllConditions = {
    expected = true;
    expr = bound {
      conditions = [
        {
          kind = "cmp";
          literal = "3.10";
          operator = ">=";
          variable = "python_version";
        }
        {
          kind = "cmp";
          literal = "ARM64";
          operator = "!=";
          variable = "platform_machine";
        }
      ];
      kind = "all";
    };
  };
  testAnyCondition = {
    expected = true;
    expr = bound {
      conditions = [
        {
          kind = "cmp";
          literal = "3.10";
          operator = "<";
          variable = "python_version";
        }
        {
          kind = "cmp";
          literal = "ARM64";
          operator = "!=";
          variable = "platform_machine";
        }
      ];
      kind = "any";
    };
  };
  testAnyConditionFails = {
    expected = false;
    expr = bound {
      conditions = [
        {
          kind = "cmp";
          literal = "3.10";
          operator = "<";
          variable = "python_version";
        }
        {
          kind = "cmp";
          literal = "3.0";
          operator = "<";
          variable = "python_full_version";
        }
      ];
      kind = "any";
    };
  };
  testExactOperatorMatches = {
    expected = true;
    expr = bound {
      kind = "cmp";
      literal = "3.13";
      operator = "===";
      variable = "python_version";
    };
  };
  testFalseMarkerIsNotApplicable = {
    expected = false;
    expr = bound false;
  };
  testNestedGroups = {
    expected = true;
    expr = bound {
      conditions = [
        {
          conditions = [
            {
              kind = "cmp";
              literal = "3.12";
              operator = ">=";
              variable = "python_version";
            }
            {
              kind = "cmp";
              literal = "ARM64";
              operator = "==";
              variable = "platform_machine";
            }
          ];
          kind = "all";
        }
        {
          kind = "cmp";
          literal = "linux";
          operator = "==";
          variable = "sys_platform";
        }
      ];
      kind = "any";
    };
  };
  testNullMarkerIsApplicable = {
    expected = true;
    expr = bound null;
  };
  testOrderedNonVersionVariableThrows = {
    expected = {
      success = false;
      value = false;
    };
    expr = builtins.tryEval (bound {
      kind = "cmp";
      literal = "win32";
      operator = "<";
      variable = "sys_platform";
    });
  };
  testPlatformMachineEquality = {
    expected = true;
    expr = bound {
      kind = "cmp";
      literal = "x86_64";
      operator = "==";
      variable = "platform_machine";
    };
  };
  testPlatformMachineInequality = {
    expected = true;
    expr = bound {
      kind = "cmp";
      literal = "ARM64";
      operator = "!=";
      variable = "platform_machine";
    };
  };
  testPythonVersionBelowFails = {
    expected = false;
    expr = bound {
      kind = "cmp";
      literal = "3.10";
      operator = "<";
      variable = "python_version";
    };
  };
  testPythonVersionComparison = {
    expected = true;
    expr = bound {
      kind = "cmp";
      literal = "3.10";
      operator = ">=";
      variable = "python_version";
    };
  };
  testPythonVersionTrailingZeroEquivalence = {
    expected = true;
    expr = bound {
      kind = "cmp";
      literal = "3.13.5.0";
      operator = "==";
      variable = "python_full_version";
    };
  };
  testUnknownKindThrows = {
    expected = {
      success = false;
      value = false;
    };
    expr = builtins.tryEval (bound {
      kind = "bogus";
    });
  };
  testUnknownVariableThrows = {
    expected = {
      success = false;
      value = false;
    };
    expr = builtins.tryEval (bound {
      kind = "cmp";
      literal = "";
      operator = "==";
      variable = "platform_release";
    });
  };
}
