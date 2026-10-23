{ select }:
let
  published = name: {
    drvPath = "/nix/store/${name}.drv";
    system = "x86_64-linux";
  };
  excused = name: (published name) // { passthru.ciBuildSkip = true; };
in
{
  testEmptyFamilySelectsNothing = {
    expected = {
      build = [ ];
      skip = [ ];
    };
    expr = select { };
  };
  testEveryPackageIsBuiltWhenNoneIsExcused = {
    expected = {
      build = [
        "a"
        "b"
      ];
      skip = [ ];
    };
    expr = select {
      a = published "a";
      b = published "b";
    };
  };
  testExcusedPackageLeavesItsSiblingsBuilt = {
    expected = {
      build = [
        "a"
        "z"
      ];
      skip = [ "model" ];
    };
    expr = select {
      a = published "a";
      model = excused "model";
      z = published "z";
    };
  };
  testFamilyWithoutPassthruIsBuilt = {
    expected = {
      build = [ "only" ];
      skip = [ ];
    };
    expr = select { only = published "only"; };
  };
  testOtherPassthruIsNotTheMarker = {
    expected = {
      build = [ "only" ];
      skip = [ ];
    };
    expr = select {
      only = published "only" // {
        passthru.tests = [ ];
      };
    };
  };
  testSelectionDoesNotForceTheRestOfPassthru = {
    expected = {
      build = [ ];
      skip = [ "model" ];
    };
    expr = select {
      model = (published "model") // {
        passthru = {
          ciBuildSkip = true;
          tests = throw "a package's other passthru members are not the gate's business";
        };
      };
    };
  };
  # The gate consumes this as JSON, so its keys and shapes are the contract between this
  # expression and the shell that reads it.
  testSelectionSerializesToTheNamesTheGateReads = {
    expected = {
      build = [ "a" ];
      skip = [ "model" ];
    };
    expr = builtins.fromJSON (
      builtins.toJSON (select {
        a = published "a";
        model = excused "model";
      })
    );
  };
}
