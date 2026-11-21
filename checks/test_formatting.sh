#!/usr/bin/env -S nix shell nixpkgs#bash nixpkgs#coreutils nixpkgs#gnugrep --command bash

set -euo pipefail

ORG_FORMATTER="${FORMATTER:?formatting-tests needs FORMATTER}"
EXCLUDING_FORMATTER="${EXCLUDING_FORMATTER:?formatting-tests needs EXCLUDING_FORMATTER}"

ORG_COLUMN_LIMIT=120
LLVM_COLUMN_LIMIT=80
ORG_RUFF_WIDTH=79
SIGNATURE_HEADER='def signature(alpha_value, beta_value, gamma_value, delta_value, epsilon_value):'

fail() {
  printf 'test_formatting: %s\n' "${1}" >&2
  exit 1
}

treefmt_of() {
  local WRAPPER
  WRAPPER="${1}/bin/treefmt"
  [[ -x "${WRAPPER}" ]] || fail "the formatter output carries no treefmt: ${1}"
  printf '%s' "${WRAPPER}"
}

new_tree() {
  local TREE
  TREE=$(mktemp -d)
  printf '{}\n' >"${TREE}/flake.nix"
  printf '%s' "${TREE}"
}

run_formatter() {
  local TREE="${1}" TREEFMT="${2}"
  (cd "${TREE}" && "${TREEFMT}" --no-cache >/dev/null)
}

unformatted_signature() {
  printf '\n%s\n    pass\n' "${SIGNATURE_HEADER}"
}

signature_on_one_line() {
  grep -q "^def signature(.*epsilon_value):$" "${1}"
}

discriminating() {
  local NAME="${1}" WIDTH="${2}" OVER="${3}" UNDER="${4:-}"
  ((WIDTH > OVER)) || fail "${NAME} no longer discriminates: ${WIDTH} columns, needs to exceed ${OVER}"
  if [[ -n "${UNDER}" ]]; then
    ((WIDTH <= UNDER)) ||
      fail "${NAME} no longer discriminates: ${WIDTH} columns, needs to stay within ${UNDER}"
  fi
}

TREE=$(new_tree)
printf '{\n  b = 1;\n  a = 2;\n}\n' >"${TREE}/attrs.nix"
unformatted_signature >"${TREE}/signature.py"
printf 'int main(void) {\nint x = 1;\nreturn x;\n}\n' >"${TREE}/body.c"
printf '{"a":1,"b":[1,2]}\n' >"${TREE}/values.json"
printf 'package main\n\nfunc main(){\nprintln("hi")\n}\n' >"${TREE}/main.go"

C_DECLARATION='static int compute_a_value(int alpha, int beta, int gamma, int delta, int epsilon, int zeta) { return 0; }'
discriminating "the C case" "${#C_DECLARATION}" "${LLVM_COLUMN_LIMIT}" "${ORG_COLUMN_LIMIT}"
printf '%s\n' "${C_DECLARATION}" >"${TREE}/style.c"

discriminating "the python case" "${#SIGNATURE_HEADER}" "${ORG_RUFF_WIDTH}"

run_formatter "${TREE}" "$(treefmt_of "${ORG_FORMATTER}")"

NIX_A=$(grep -n 'a = 2' "${TREE}/attrs.nix" | cut -d: -f1)
NIX_B=$(grep -n 'b = 1' "${TREE}/attrs.nix" | cut -d: -f1)
((NIX_A < NIX_B)) ||
  fail "attrs.nix is not sorted, so the nix formatter is not the configured one: $(tr -d '\n' <"${TREE}/attrs.nix")"

if signature_on_one_line "${TREE}/signature.py"; then
  fail "signature.py stayed on one line, so python is not formatted at the org width"
fi

grep -q '^  *int x = 1;$' "${TREE}/body.c" || fail "body.c is not indented, so clang-format did not run"
grep -qF 'zeta) { return 0; }' "${TREE}/style.c" ||
  fail "style.c came back wrapped, so clang-format did not get the org style file"
[[ "$(cat "${TREE}/values.json")" == '{ "a": 1, "b": [1, 2] }' ]] ||
  fail "values.json was not reformatted, so prettier did not run: $(cat "${TREE}/values.json")"
grep -q '^func main() {$' "${TREE}/main.go" || fail "main.go was not reformatted, so gofmt did not run"

(cd "${TREE}" && "$(treefmt_of "${ORG_FORMATTER}")" --no-cache --fail-on-change >/dev/null) ||
  fail "a freshly formatted tree does not pass --fail-on-change"

TREE=$(new_tree)
mkdir -p "${TREE}/skipped"
unformatted_signature >"${TREE}/skipped/signature.py"
unformatted_signature >"${TREE}/signature.py"
run_formatter "${TREE}" "$(treefmt_of "${EXCLUDING_FORMATTER}")"
signature_on_one_line "${TREE}/skipped/signature.py" ||
  fail "skipped/signature.py was formatted despite the caller excluding skipped/**"
if signature_on_one_line "${TREE}/signature.py"; then
  fail "signature.py was not formatted, so the caller's excludes hid more than it named"
fi

printf 'ok\n'
