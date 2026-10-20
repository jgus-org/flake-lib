{
  defaultSystems,
  defaultLinuxSystems,
  eachDefaultSystem,
  eachDefaultLinuxSystem,
}:
let
  sample = system: {
    packages.default = system;
    devShells.default = [ system ];
  };
in
{
  testDefaultSystemsAreTheStandardThree = {
    expr = defaultSystems;
    expected = [
      "aarch64-darwin"
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
  testDefaultLinuxSystemsAreTheStandardTwo = {
    expr = defaultLinuxSystems;
    expected = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
  testEveryOutputIsKeyedByHost = {
    expr = eachDefaultSystem sample;
    expected = {
      packages = {
        aarch64-darwin = {
          default = "aarch64-darwin";
        };
        aarch64-linux = {
          default = "aarch64-linux";
        };
        x86_64-linux = {
          default = "x86_64-linux";
        };
      };
      devShells = {
        aarch64-darwin = {
          default = [ "aarch64-darwin" ];
        };
        aarch64-linux = {
          default = [ "aarch64-linux" ];
        };
        x86_64-linux = {
          default = [ "x86_64-linux" ];
        };
      };
    };
  };
  testLinuxIteratesOnlyTheLinuxHosts = {
    expr = builtins.attrNames (eachDefaultLinuxSystem sample).packages;
    expected = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
