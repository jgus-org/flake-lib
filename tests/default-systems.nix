{
  defaultSystems,
  defaultLinuxSystems,
  eachDefaultSystem,
  eachDefaultLinuxSystem,
  flake-utils,
}:
let
  standardThree = [
    "aarch64-darwin"
    "aarch64-linux"
    "x86_64-linux"
  ];
  standardTwo = [
    "aarch64-linux"
    "x86_64-linux"
  ];
  sample = system: {
    packages = {
      default = system;
      tool = "${system}-tool";
    };
    checks.smoke = { inherit system; };
  };
in
{
  testDefaultSystemsAreTheStandardThree = {
    expr = defaultSystems;
    expected = standardThree;
  };
  testDefaultLinuxSystemsAreTheStandardTwo = {
    expr = defaultLinuxSystems;
    expected = standardTwo;
  };
  testIterationMatchesFlakeUtils = {
    expr = eachDefaultSystem sample == flake-utils.lib.eachSystem standardThree sample;
    expected = true;
  };
  testLinuxIterationMatchesFlakeUtils = {
    expr = eachDefaultLinuxSystem sample == flake-utils.lib.eachSystem standardTwo sample;
    expected = true;
  };
}
