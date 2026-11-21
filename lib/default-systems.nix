# Build hosts a sub-flake produces for, stated once for the flake family, and the per-system output iteration built on them. Nixpkgs 26.11 dropped x86_64-darwin, so importing it there fails: a throw on current nixpkgs-unstable, a warning where an abort-on-warn verification build already refuses it. A flake naming that host evaluates fine until something forces its attributes, so a per-flake list drifts silently. Intel macOS remains reachable as a cross-compile or an upstream prebuilt.
with builtins;
let
  defaultSystems = [
    "aarch64-darwin"
    "aarch64-linux"
    "x86_64-linux"
  ];

  defaultLinuxSystems = [
    "aarch64-linux"
    "x86_64-linux"
  ];

  eachSystem =
    systems: f:
    let
      addSystem =
        acc: system:
        let
          outputs = f system;
          merge =
            attrs: attr:
            attrs
            // {
              ${attr} = (attrs.${attr} or { }) // {
                ${system} = outputs.${attr};
              };
            };
        in
        foldl' merge acc (attrNames outputs);
    in
    foldl' addSystem { } systems;
in
{
  inherit defaultLinuxSystems defaultSystems eachSystem;
  eachDefaultLinuxSystem = eachSystem defaultLinuxSystems;
  eachDefaultSystem = eachSystem defaultSystems;
}
