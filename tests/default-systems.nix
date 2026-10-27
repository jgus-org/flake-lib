{
  defaultLinuxSystems,
  defaultSystems,
  eachDefaultLinuxSystem,
  eachDefaultSystem,
  eachSystem,
}:
let
  sample = system: {
    devShells.default = [ system ];
    packages.default = system;
  };
in
{
  testDefaultLinuxSystemsAreTheStandardTwo = {
    expected = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    expr = defaultLinuxSystems;
  };
  testDefaultSystemsAreTheStandardThree = {
    expected = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];
    expr = defaultSystems;
  };
  testEachSystemIteratesOnlyTheHostsItIsGiven = {
    expected = {
      devShells.x86_64-linux.default = [ "x86_64-linux" ];
      packages.x86_64-linux.default = "x86_64-linux";
    };
    expr = eachSystem [ "x86_64-linux" ] sample;
  };
  testEachSystemOnNoHostsProducesNoOutputs = {
    expected = { };
    expr = eachSystem [ ] sample;
  };
  testEveryOutputIsKeyedByHost = {
    expected = {
      devShells = {
        aarch64-darwin.default = [ "aarch64-darwin" ];
        aarch64-linux.default = [ "aarch64-linux" ];
        x86_64-linux.default = [ "x86_64-linux" ];
      };
      packages = {
        aarch64-darwin.default = "aarch64-darwin";
        aarch64-linux.default = "aarch64-linux";
        x86_64-linux.default = "x86_64-linux";
      };
    };
    expr = eachDefaultSystem sample;
  };
  testLinuxIteratesOnlyTheLinuxHosts = {
    expected = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    expr = builtins.attrNames (eachDefaultLinuxSystem sample).packages;
  };
}
