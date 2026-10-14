{ pkgs, mkWheelhouse }:
let
  inherit (pkgs) lib;
  manifest = builtins.fromJSON (builtins.readFile ./fixtures/mini-wheels.json);
  selection = noEmit: (mkWheelhouse { inherit pkgs noEmit; wheels = ./fixtures/mini-wheels.json; }).files;
  kept = predicate: map (wheel: pkgs.fetchurl { inherit (wheel) url sha256; name = wheel.filename; }) (lib.filter predicate manifest);
  notNamed = names: wheel: !lib.elem wheel.name names;
in
{
  testOmitsNamedWheel = {
    expr = selection [ "attrs" ];
    expected = kept (notNamed [ "attrs" ]);
  };
  testOmitsEveryName = {
    expr = selection [ "attrs" "iniconfig" "msgpack" ];
    expected = [ ];
  };
  testCanonicalizesSpelling = {
    expr = map (spelling: selection [ spelling ]) [ "Attrs" "attrs" "ATTRS" ];
    expected = [
      (kept (notNamed [ "attrs" ]))
      (kept (notNamed [ "attrs" ]))
      (kept (notNamed [ "attrs" ]))
    ];
  };
  testPredicateOverName = {
    expr = selection (name: lib.hasPrefix "i" name);
    expected = kept (wheel: !lib.hasPrefix "i" wheel.name);
  };
  testEmptySelectionKeepsManifest = {
    expr = selection [ ];
    expected = kept (_: true);
  };
}
