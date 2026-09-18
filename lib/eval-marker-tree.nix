{ versionMatchesComparison }:
let
  versionVariables = [
    "python_version"
    "python_full_version"
    "implementation_version"
  ];
in
bindings:
let
  evaluateComparison =
    { variable, operator, literal }:
    let
      observed = bindings.${variable} or (throw "evalMarkerTree: no binding for marker variable ${variable}");
    in
    if builtins.elem variable versionVariables then
      versionMatchesComparison observed { inherit operator; version = literal; }
    else if operator == "==" || operator == "===" then
      observed == literal
    else if operator == "!=" then
      observed != literal
    else
      throw "evalMarkerTree: unsupported operator ${operator} for non-version marker variable ${variable}";
  evaluate =
    tree:
    if tree == null then
      true
    else if tree == false then
      false
    else if tree.kind == "cmp" then
      evaluateComparison (removeAttrs tree [ "kind" ])
    else if tree.kind == "all" then
      builtins.foldl' (acc: condition: acc && evaluate condition) true tree.conditions
    else if tree.kind == "any" then
      builtins.foldl' (acc: condition: acc || evaluate condition) false tree.conditions
    else
      throw "evalMarkerTree: unsupported marker tree kind ${tree.kind}";
in
evaluate
