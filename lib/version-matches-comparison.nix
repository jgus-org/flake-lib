actual:
{ operator, version, ... }:
let
  numericPart = part: builtins.match "[0-9]+" part != null;
  reverse = list:
    builtins.genList (index: builtins.elemAt list (builtins.length list - 1 - index)) (builtins.length list);
  dropLeadingZeros = list:
    if list != [ ] && builtins.head list == "0" then dropLeadingZeros (builtins.tail list) else list;
  normalizePart = part: builtins.head (builtins.match "0*([0-9]+)" part);
  stripTrailingZeros = value:
    let
      parts = builtins.filter builtins.isString (builtins.split "\\." value);
    in
    if parts == [ ] || !(builtins.all numericPart parts) then value
    else
      let
        numeric = map normalizePart parts;
        stripped = reverse (dropLeadingZeros (reverse numeric));
      in
      if stripped == [ ] then "0" else builtins.concatStringsSep "." stripped;
  comparison = builtins.compareVersions (stripTrailingZeros actual) (stripTrailingZeros version);
  matches = {
    "===" = actual == version;
    "==" = comparison == 0;
    "!=" = comparison != 0;
    "<=" = comparison != 1;
    ">=" = comparison != -1;
    "<" = comparison == -1;
    ">" = comparison == 1;
  };
in
matches.${operator} or (throw "versionMatchesComparison: unsupported operator ${operator}")
