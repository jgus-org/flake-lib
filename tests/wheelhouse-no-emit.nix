{ mkWheelhouse, pkgs }:
let
  inherit (pkgs) lib;
  manifest = builtins.fromJSON (builtins.readFile ./fixtures/mini-wheels.json);
  selection =
    noEmit:
    (mkWheelhouse {
      inherit noEmit pkgs;
      wheels = ./fixtures/mini-wheels.json;
    }).files;
  kept =
    predicate:
    map (
      wheel:
      pkgs.fetchurl {
        inherit (wheel) sha256 url;
        name = wheel.filename;
      }
    ) (lib.filter predicate manifest);
  notNamed = names: wheel: !lib.elem wheel.name names;
in
{
  testCanonicalizesSpelling = {
    expected = [
      (kept (notNamed [ "attrs" ]))
      (kept (notNamed [ "attrs" ]))
      (kept (notNamed [ "attrs" ]))
    ];
    expr = map (spelling: selection [ spelling ]) [
      "Attrs"
      "attrs"
      "ATTRS"
    ];
  };
  testEmptySelectionKeepsManifest = {
    expected = kept (_: true);
    expr = selection [ ];
  };
  testOmitsEveryName = {
    expected = [ ];
    expr = selection [
      "attrs"
      "iniconfig"
      "msgpack"
    ];
  };
  testOmitsNamedWheel = {
    expected = kept (notNamed [ "attrs" ]);
    expr = selection [ "attrs" ];
  };
  testPredicateOverName = {
    expected = kept (wheel: !lib.hasPrefix "i" wheel.name);
    expr = selection (name: lib.hasPrefix "i" name);
  };
}
