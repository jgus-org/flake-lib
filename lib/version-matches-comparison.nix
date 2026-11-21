with builtins;
actual:
{ operator, version, ... }:
let
  numericPart = part: match "[0-9]+" part != null;
  reverse = list: genList (index: elemAt list (length list - 1 - index)) (length list);
  dropLeadingZeros =
    list: if list != [ ] && head list == "0" then dropLeadingZeros (tail list) else list;
  normalizePart = part: head (match "0*([0-9]+)" part);
  stripTrailingZeros =
    value:
    let
      parts = filter isString (split "\\." value);
    in
    if parts == [ ] || !(all numericPart parts) then
      value
    else
      let
        numeric = map normalizePart parts;
        stripped = reverse (dropLeadingZeros (reverse numeric));
      in
      if stripped == [ ] then "0" else concatStringsSep "." stripped;
  comparison = compareVersions (stripTrailingZeros actual) (stripTrailingZeros version);
  matches = {
    "!=" = comparison != 0;
    "<" = comparison == -1;
    "<=" = comparison != 1;
    "==" = comparison == 0;
    "===" = actual == version;
    ">" = comparison == 1;
    ">=" = comparison != -1;
  };
in
matches.${operator} or (throw "versionMatchesComparison: unsupported operator ${operator}")
