{ mkWheelPackages, pkgs }:
let
  inherit (pkgs) lib;
  manifest = builtins.fromJSON (builtins.readFile ./fixtures/mini-wheels.json);
  selection = noEmit: mkWheelPackages { inherit manifest noEmit pkgs; };
  kept = names: lib.filter (wheel: !lib.elem wheel.name names) manifest;
  member = noEmit: name: (selection noEmit).${name};
in
{
  testCanonicalizesSpelling = {
    expected = [
      (lib.attrNames (selection [ "attrs" ]))
      (lib.attrNames (selection [ "attrs" ]))
      (lib.attrNames (selection [ "attrs" ]))
    ];
    expr = map (spelling: lib.attrNames (selection [ spelling ])) [
      "Attrs"
      "attrs"
      "ATTRS"
    ];
  };
  # A name the deployment's set already carries must not become a member, or the pinned
  # wheel shadows the built one and the interpreter decides which one imports.
  testDeploymentProvidedNameIsNotAMember = {
    expected = [
      "attrs"
      "iniconfig"
    ];
    expr = lib.attrNames (selection [ "msgpack" ]);
  };
  # The manifest is the pin: a platform-tagged wheel's URL path is a content hash, so
  # nothing but the resolved artifact identifies it.
  testMemberFetchesThePinnedArtifact = {
    expected = map (wheel: wheel.url) (kept [ ]);
    expr = map (wheel: (member [ ] wheel.name).src.url) (kept [ ]);
  };
  # A member is built for the deployment's interpreter, which is what a wheelhouse joined
  # by PYTHONPATH could not say: the tree it built was no set's member.
  testMemberIsBuiltForTheDeployedInterpreter = {
    expected = map (wheel: "python${pkgs.python3.pythonVersion}-${wheel.name}-${wheel.version}") (
      kept [ ]
    );
    expr = map (wheel: (member [ ] wheel.name).name) (kept [ ]);
  };
  testPredicateExcludesByName = {
    expected = [
      "iniconfig"
      "msgpack"
    ];
    expr = lib.attrNames (selection (name: lib.hasPrefix "a" name));
  };
}
