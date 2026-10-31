def candidates:
  if $format == "sdist" then map(select(.packagetype == "sdist"))
  elif $format == "wheel" then
    map(select(.packagetype == "bdist_wheel"))
    | if $tag == "" then . else map(select(.filename | endswith("-" + $tag + ".whl"))) end
  else error("unsupported PyPI artifact format: " + $format)
  end;

def unique_selected:
  if length == 1 then .[0]
  elif length == 0 then error("no matching PyPI artifact")
  else error("multiple matching PyPI artifacts")
  end;

if $mode == "artifact" then
  .urls | candidates
  | if $format == "wheel" and $tag == "" then
      (map(select(.filename | endswith("-py3-none-any.whl")))[0] // .[0])
    elif $tag != "" then unique_selected
    else .[0]
    end
  | if .url == null then error("no matching PyPI artifact") else .url end
elif $mode == "versions" then
  .releases | to_entries[]
  | .value |= candidates
  | if $format == "wheel" and $tag == "" then
      select(.value | any(.filename | endswith("-py3-none-any.whl")))
    elif $tag != "" then
      if (.value | length) > 1 then error("multiple matching PyPI artifacts for " + .key)
      else select(.value | length == 1)
      end
    else select(.value | length > 0)
    end
  | .key
else error("unsupported PyPI selection mode: " + $mode)
end
