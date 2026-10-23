{
  defaultLinuxSystems,
  defaultSystems,
  eachDefaultLinuxSystem,
  eachDefaultSystem,
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
