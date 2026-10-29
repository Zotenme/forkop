#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/chains"
cat >"$WORK_DIR/bin/nft" <<'SH'
#!/usr/bin/env sh
case "$*" in
  'list table inet ForkopTable') exit 0 ;;
  'list tables') printf '%s\n' 'table inet ForkopTable' ;;
  'list chain inet ForkopTable '*) cat "$NFT_FIXTURES/$5" ;;
  *) exit 1 ;;
esac
SH
for command in curl sleep; do
  printf '#!/usr/bin/env sh\nexit 0\n' >"$WORK_DIR/bin/$command"
done
chmod +x "$WORK_DIR/bin/"*

write_base_chains() {
  printf '%s\n' 'jump priority_rules' 'meta mark set 0x04000000 counter packets 0 bytes 0' >"$WORK_DIR/chains/mangle"
  printf '%s\n' 'jump priority_output_rules' 'meta mark set 0x04000000 counter packets 0 bytes 0' >"$WORK_DIR/chains/mangle_output"
  printf '%s\n' 'meta mark 0x04000000 tproxy ip to :1602 counter packets 9144 bytes 2777459' >"$WORK_DIR/chains/proxy"
}

assert_nft_status() {
  local expected="$1"
  local result
  result="$(PATH="$WORK_DIR/bin:$PATH" NFT_FIXTURES="$WORK_DIR/chains" FORKOP_LIB="$FORKOP_LIB" \
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/diagnostics/runtime.uc" check-nft-rules)" ||
    fail "nft diagnostics command failed"
  JSON_VALUE="$result" node - "$expected" <<'NODE'
const value = JSON.parse(process.env.JSON_VALUE);
const expected = JSON.parse(process.argv[2]);
for (const [key, wanted] of Object.entries(expected)) {
  if (value[key] !== wanted) {
    console.error(`FAIL: ${key}: expected ${wanted}, got ${value[key]}`);
    process.exit(1);
  }
}
NODE
}

# Fully routed clients are accepted in priority_rules; base counters stay zero.
write_base_chains
printf '%s\n' 'meta mark set 0x04000000 counter packets 9405 bytes 2792819 accept' >"$WORK_DIR/chains/priority_rules"
printf '%s\n' 'meta mark set 0x04000000 counter packets 29 bytes 39362 accept' >"$WORK_DIR/chains/priority_output_rules"
assert_nft_status '{"table_exist":1,"rules_mangle_exist":1,"rules_mangle_counters":1,"rules_mangle_output_exist":1,"rules_mangle_output_counters":1,"rules_proxy_exist":1,"rules_proxy_counters":1,"rules_other_mark_exist":0}'

# Activity in one path must not hide idle counters in the other path.
printf '%s\n' 'counter packets 0 bytes 0 accept' >"$WORK_DIR/chains/priority_output_rules"
assert_nft_status '{"rules_mangle_counters":1,"rules_mangle_output_counters":0}'
printf '%s\n' 'counter packets 0 bytes 0 accept' >"$WORK_DIR/chains/priority_rules"
assert_nft_status '{"rules_mangle_counters":0,"rules_mangle_output_counters":0}'

# Ordinary base-chain activity still works without priority chains.
rm "$WORK_DIR/chains/priority_rules" "$WORK_DIR/chains/priority_output_rules"
printf '%s\n' 'counter packets 2 bytes 100' >>"$WORK_DIR/chains/mangle"
printf '%s\n' 'counter packets 3 bytes 150' >>"$WORK_DIR/chains/mangle_output"
assert_nft_status '{"rules_mangle_counters":1,"rules_mangle_output_counters":1}'
write_base_chains
assert_nft_status '{"rules_mangle_exist":1,"rules_mangle_counters":0,"rules_mangle_output_exist":1,"rules_mangle_output_counters":0}'

# An unrelated priority chain must not make a broken base chain look healthy.
printf '%s\n' 'counter packets 5 bytes 250 accept' >"$WORK_DIR/chains/priority_rules"
printf '%s\n' 'counter packets 0 bytes 0' >"$WORK_DIR/chains/mangle"
assert_nft_status '{"rules_mangle_counters":0}'
printf '%s\n' 'jump priority_rules' >"$WORK_DIR/chains/mangle"
assert_nft_status '{"rules_mangle_exist":0,"rules_mangle_counters":1}'
rm "$WORK_DIR/chains/mangle"
assert_nft_status '{"rules_mangle_exist":0,"rules_mangle_counters":0}'

printf 'diagnostics nft checks passed\n'
