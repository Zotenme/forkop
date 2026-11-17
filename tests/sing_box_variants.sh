#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$WORK_DIR/bin" "$WORK_DIR/target" "$WORK_DIR/data/usr/bin" "$WORK_DIR/overlay"
export SB_BINARY_PATH="$WORK_DIR/target/sing-box" SB_SERVICE_INIT="$WORK_DIR/sing-box-init"
export SB_VARIANT_STATE_FILE="$WORK_DIR/variant" SB_VERSION_STATE_FILE="$WORK_DIR/version"
export SB_FORKOP_VARIANT_FILE="$WORK_DIR/package-variant"
export FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/state" UPDATES_LOCK_DIR="$WORK_DIR/state/lock"
export FORKOP_OPENWRT_RELEASE_FILE="$WORK_DIR/openwrt_release" FORKOP_OVERLAY_DIR="$WORK_DIR/overlay"
export FORKOP_UCI_STATE_FILE="$WORK_DIR/uci-state" FORKOP_LIB
export FORKOP_BIN="$WORK_DIR/forkop" FORKOP_SERVICE_INIT="$WORK_DIR/forkop-init"
export TEST_ASSET="$WORK_DIR/core.ipk" TEST_RELEASE="$WORK_DIR/release.json" TEST_LOG="$WORK_DIR/calls"
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$FORKOP_OPENWRT_RELEASE_FILE"
printf 'forkop.settings.config_path=%s\n' "$WORK_DIR/config.json" > "$FORKOP_UCI_STATE_FILE"
printf '{}\n' > "$WORK_DIR/config.json"

cat > "$WORK_DIR/data/usr/bin/sing-box" <<'SH'
#!/bin/sh
if [ "$1" = version ] && [ "${TEST_FORBID_LIVE_VERSION:-0}" = 1 ] && [ "$0" = "$SB_BINARY_PATH" ]; then exit 99; fi
case "$1" in
  version) printf 'sing-box version 1.14.4-r1\nTags: with_utls,with_clash_api,with_quic\n' ;;
  check) [ "${TEST_REJECT_CONFIG:-0}" != 1 ] || exit 1 ;;
esac
exit 0
SH
chmod +x "$WORK_DIR/data/usr/bin/sing-box"
truncate -s 2097152 "$WORK_DIR/data/usr/bin/sing-box"
tar -czf "$WORK_DIR/data.tar.gz" -C "$WORK_DIR/data" ./usr
tar -czf "$TEST_ASSET" -C "$WORK_DIR" ./data.tar.gz
digest="$(sha256sum "$TEST_ASSET" | awk '{print $1}')"
cat > "$TEST_RELEASE" <<JSON
{"tag_name":"v1.14.4-r1","html_url":"https://example.org/release","assets":[{
 "name":"sing-box-forkop_1.14.4-r1_tiny_aarch64_cortex-a53.ipk",
 "digest":"sha256:$digest","browser_download_url":"https://example.org/core.ipk"}]}
JSON
cat > "$WORK_DIR/bin/curl" <<'SH'
#!/bin/sh
out=''; url=''
while [ "$#" -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; -H|-m|--connect-timeout|-x) shift ;; -*) ;; *) url="$1" ;; esac
  shift
done
printf 'curl %s\n' "$url" >> "$TEST_LOG"
case "$url" in
  */releases/latest) cp "$TEST_RELEASE" "$out" ;;
  https://example.org/core.ipk) cp "$TEST_ASSET" "$out" ;;
  *) exit 7 ;;
esac
SH
cat > "$WORK_DIR/bin/df" <<'SH'
#!/bin/sh
printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
if [ "${TEST_NO_SPACE:-0}" = 1 ]; then space=0
elif [ -f "$SB_BINARY_PATH" ]; then space=1300
else space=16000; fi
printf 'overlay 44000 10000 %s 10%% /overlay\n' "$space"
SH
cat > "$WORK_DIR/bin/opkg" <<'SH'
#!/bin/sh
printf 'opkg %s\n' "$*" >> "$TEST_LOG"
exit 0
SH
cat > "$WORK_DIR/bin/sleep" <<'SH'
#!/bin/sh
case "$1" in 6) /bin/sleep 0.1 ;; esac
exit 0
SH
cat > "$WORK_DIR/bin/gzip" <<'SH'
#!/bin/sh
if [ "$1" = -dc ] && [ "${TEST_REQUIRE_FREED_TARGET:-0}" = 1 ] && [ -f "$SB_BINARY_PATH" ]; then exit 1; fi
exec /bin/gzip "$@"
SH
printf '#!/bin/sh\nexit 0\n' > "$WORK_DIR/bin/logger"
cat > "$FORKOP_BIN" <<'SH'
#!/bin/sh
if [ "$1" = get_status ]; then
  if [ "${TEST_FAIL_START:-0}" = 1 ] && [ "$(cat "$SB_VARIANT_STATE_FILE")" = forkop-tiny ]; then
    printf '{"running":0}\n'
  else printf '{"running":1}\n'; fi
fi
SH
printf '#!/bin/sh\nexit 0\n' > "$FORKOP_SERVICE_INIT"
chmod +x "$WORK_DIR/bin/"* "$FORKOP_BIN" "$FORKOP_SERVICE_INIT"
export PATH="$WORK_DIR/target:$WORK_DIR/bin:$PATH"

reset_old_core() {
  printf '#!/bin/sh\nprintf "sing-box version 1.14.3-extended-2.7.3\\n"\nexit 0\n' > "$SB_BINARY_PATH"
  chmod +x "$SB_BINARY_PATH"
  truncate -s 3145728 "$SB_BINARY_PATH"
  printf '#!/bin/sh\n# original service\nexit 0\n' > "$SB_SERVICE_INIT"
  chmod +x "$SB_SERVICE_INIT"
  printf 'extended\n' > "$SB_VARIANT_STATE_FILE"
  printf '1.14.3-extended-2.7.3\n' > "$SB_VERSION_STATE_FILE"
  : > "$TEST_LOG"
}
action() {
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/components/action.uc" component-action sing_box "$1" > "$WORK_DIR/result.json"
}

reset_old_core
action install_forkop_tiny || fail "tiny installation failed: $(cat "$WORK_DIR/result.json")"
[ "$(cat "$SB_VARIANT_STATE_FILE")" = forkop-tiny ] || fail "tiny marker missing"
[ "$(stat -c %s "$SB_BINARY_PATH")" = 2097152 ] || fail "wrong archive member installed"
[ "$(ucode -L "$FORKOP_LIB" "$FORKOP_LIB/singbox/runtime.uc" variant)" = forkop-tiny ] || fail "tiny core not detected"
capabilities="$(FORKOP_UI_SING_BOX_BIN_PATH="$SB_BINARY_PATH" \
  ucode -L "$FORKOP_LIB" "$FORKOP_LIB/service/ui.uc" get-ui-capabilities)"
printf '%s' "$capabilities" | node -e '
let input=""; process.stdin.on("data",v=>input+=v); process.stdin.on("end",()=>{
 const v=JSON.parse(input);
 if(v.sing_box_forkop!==1 || v.sing_box_tiny!==1 || v.sing_box_extended!==0 || v.sing_box_tailscale!==0) process.exit(1);
});' || fail "tiny capabilities incorrectly advertise full-core features"
: > "$TEST_LOG"
TEST_FORBID_LIVE_VERSION=1 action check_update || fail "tiny update check must use cached version state"
grep -q 'repos/ushan0v/sing-box-forkop/releases/latest' "$TEST_LOG" || fail "tiny updates must use its own repository"
if grep -q shtorm-7 "$TEST_LOG"; then fail "tiny check switched repositories"; fi
action install || fail "tiny update must retain tiny"
[ "$(cat "$SB_VARIANT_STATE_FILE")" = forkop-tiny ] || fail "update changed the core variant"

reset_old_core
old_hash="$(sha256sum "$SB_BINARY_PATH" | awk '{print $1}')"
if TEST_REJECT_CONFIG=1 action install_forkop_tiny; then fail "unsupported configuration was accepted"; fi
[ "$(sha256sum "$SB_BINARY_PATH" | awk '{print $1}')" = "$old_hash" ] || fail "config rejection changed the old core"

reset_old_core
if TEST_FAIL_START=1 TEST_REQUIRE_FREED_TARGET=1 action install_forkop_tiny; then fail "failed restart must roll back"; fi
[ "$(sha256sum "$SB_BINARY_PATH" | awk '{print $1}')" = "$old_hash" ] || fail "rollback did not restore the old executable"
grep -q 'original service' "$SB_SERVICE_INIT" || fail "rollback did not restore the service script"
[ "$(cat "$SB_VARIANT_STATE_FILE")" = extended ] || fail "rollback did not restore the variant"

reset_old_core
if TEST_NO_SPACE=1 action install_forkop_tiny; then fail "out-of-space installation must fail"; fi
[ "$(sha256sum "$SB_BINARY_PATH" | awk '{print $1}')" = "$old_hash" ] || fail "out-of-space rollback lost the old core"

# A corrupt package is rejected before changing files or stopping the service.
printf 'corruption' >> "$TEST_ASSET"
reset_old_core
if action install_forkop_tiny; then fail "corrupt package was accepted"; fi
grep -q checksum "$WORK_DIR/result.json" || fail "checksum failure was not explained"
[ "$(sha256sum "$SB_BINARY_PATH" | awk '{print $1}')" = "$old_hash" ] || fail "checksum failure changed the old core"

eval "$(sed -n '/^core_recommendation()/,/^}/p' "$ROOT_DIR/install.sh")"
[ "$(core_recommendation 120000)" = extended ] || fail "large flash recommendation"
[ "$(core_recommendation 44000)" = tiny ] || fail "small flash recommendation"
[ "$(core_recommendation 30000)" = extended-compressed ] || fail "very small flash recommendation"
[ "$(core_recommendation 10000)" = none ] || fail "insufficient space recommendation"
[ "$(core_recommendation unknown)" = tiny ] || fail "unknown flash recommendation"
eval "$(sed -n '/^parse_args()/,/^}/p' "$ROOT_DIR/install.sh")"
SING_BOX_REQUESTED_VARIANT=""
parse_args --variant tiny
[ "$SING_BOX_REQUESTED_VARIANT" = tiny ] || fail "installer explicit tiny option"
if (parse_args --variant invalid) >/dev/null 2>&1; then fail "invalid installer variant was accepted"; fi
if (parse_args --variant) >/dev/null 2>&1; then fail "installer accepted a missing variant"; fi
printf 'Core variant installation, update and rollback checks passed\n'
