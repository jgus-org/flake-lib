{ versionMatchesComparison }:
{
  testDifferent = {
    expected = true;
    expr = versionMatchesComparison "1.0" {
      operator = "!=";
      version = "2.0";
    };
  };
  testEquivalentMatch = {
    expected = true;
    expr = versionMatchesComparison "1.0" {
      operator = "==";
      version = "1.00";
    };
  };
  testExactMatch = {
    expected = true;
    expr = versionMatchesComparison "1.0" {
      operator = "===";
      version = "1.0";
    };
  };
  testExactMismatch = {
    expected = false;
    expr = versionMatchesComparison "1.0" {
      operator = "===";
      version = "1.00";
    };
  };
  testGreaterThan = {
    expected = true;
    expr = versionMatchesComparison "2.0" {
      operator = ">";
      version = "1.0";
    };
  };
  testGreaterThanOrEqual = {
    expected = true;
    expr = versionMatchesComparison "1.0" {
      operator = ">=";
      version = "1.0";
    };
  };
  testLessThan = {
    expected = true;
    expr = versionMatchesComparison "1.0" {
      operator = "<";
      version = "2.0";
    };
  };
  testLessThanOrEqual = {
    expected = true;
    expr = versionMatchesComparison "1.0" {
      operator = "<=";
      version = "1.0";
    };
  };
  testNonZeroSuffixPreserved = {
    expected = false;
    expr = versionMatchesComparison "3.13.50" {
      operator = "==";
      version = "3.13.5";
    };
  };
  testTrailingZeroEquality = {
    expected = true;
    expr = versionMatchesComparison "3.13.5" {
      operator = "==";
      version = "3.13.5.0";
    };
  };
  testTrailingZeroGreaterEqual = {
    expected = true;
    expr = versionMatchesComparison "3.13.5" {
      operator = ">=";
      version = "3.13.5.0";
    };
  };
  testTrailingZeroInequality = {
    expected = false;
    expr = versionMatchesComparison "3.13.5.0" {
      operator = "!=";
      version = "3.13.5";
    };
  };
  testUnsupportedOperator = {
    expected = false;
    expr =
      (builtins.tryEval (
        versionMatchesComparison "1.0" {
          operator = "~=";
          version = "1.0";
        }
      )).success;
  };
}
