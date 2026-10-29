#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/tests/helpers/function_order.js"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

cat >"$WORK_DIR/forward.uc" <<'UC'
function early(later_value) {
    let shadowed = 1;
    let note = { later: "later()" };
    return later("x") + later_value + shadowed + note.later;
}

function later(value) {
    return value;
}

function shadowed() {
    return 0;
}
UC

if output="$(node "$CHECK" "$WORK_DIR/forward.uc")"; then
  fail "a call to a function declared later must be reported"
fi
[ "$output" = "$WORK_DIR/forward.uc:4: 'later' is used before its declaration at line 7" ] ||
  fail "unexpected forward reference report: $output"

ucode -S -c -o /dev/null "$WORK_DIR/forward.uc" ||
  fail "the forward reference fixture must compile, which is why this check exists"
{ cat "$WORK_DIR/forward.uc"; printf 'early(1);\n'; } >"$WORK_DIR/forward-run.uc"
if ucode "$WORK_DIR/forward-run.uc" >/dev/null 2>&1; then
  fail "ucode is expected to reject calls to functions declared later"
fi

files=()
while IFS= read -r -d '' file; do
  files+=("$file")
done < <(find "$ROOT_DIR/forkop/files/usr/lib" -name '*.uc' -print0 | sort -z)
files+=("$ROOT_DIR/forkop/files/usr/bin/forkop")

if ! output="$(node "$CHECK" "${files[@]}")"; then
  fail "functions must be declared before they are used:
$output"
fi

printf 'function order checks passed\n'
