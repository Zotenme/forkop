#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
VALIDATOR="$FORKOP_LIB/config/validator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

export MWAN3_INIT="$WORK_DIR/mwan3.init"
export MWAN3_CONFIG="$WORK_DIR/mwan3.config"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci.state"

cat >"$MWAN3_INIT" <<'INIT'
#!/usr/bin/env bash
case "$1" in
  status) exit "${MWAN3_FAKE_STATUS:-0}" ;;
  enabled) exit "${MWAN3_FAKE_ENABLED:-0}" ;;
esac
exit 2
INIT
chmod 0755 "$MWAN3_INIT"

write_mwan3_state() {
  printf 'config interface wan\n' >"$MWAN3_CONFIG"
  printf 'mwan3.wan=interface\nmwan3.wan.enabled=%s\n' "$1" >"$FORKOP_UCI_STATE_FILE"
}

mwan3_is_active_status() {
  local status=0
  FORKOP_LIB="$FORKOP_LIB" ucode -L "$FORKOP_LIB" "$VALIDATOR" mwan3-is-active >"$WORK_DIR/out" 2>&1 || status=$?
  printf '%s\n' "$status"
}

write_mwan3_state 1
assert_eq 0 "$(mwan3_is_active_status)" "running mwan3 with an enabled interface"
[ ! -s "$WORK_DIR/out" ] || fail "mwan3 detection must not print errors: $(cat "$WORK_DIR/out")"

assert_eq 0 "$(MWAN3_FAKE_STATUS=1 mwan3_is_active_status)" "enabled but stopped mwan3"
assert_eq 1 "$(MWAN3_FAKE_STATUS=1 MWAN3_FAKE_ENABLED=1 mwan3_is_active_status)" "stopped and disabled mwan3"

write_mwan3_state 0
assert_eq 1 "$(mwan3_is_active_status)" "mwan3 without enabled interfaces"

write_mwan3_state 1
: >"$MWAN3_CONFIG"
assert_eq 1 "$(mwan3_is_active_status)" "empty mwan3 config"

write_mwan3_state 1
rm -f "$MWAN3_INIT"
assert_eq 1 "$(mwan3_is_active_status)" "missing mwan3 init script"

printf 'mwan3 detection checks passed\n'
