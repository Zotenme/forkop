#!/usr/bin/env bash
# The sing-box-extended package needs about 100 MB of flash. When it does not
# fit, the component action must install the compressed binary instead of
# letting opkg fail with "No space left on device".
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
ACTION_UC="$FORKOP_LIB/components/action.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

tag="v1.14.3-extended-2.7.3"
ipk_name="sing-box-extended_1.14.3-extended-2.7.3_openwrt_aarch64_cortex-a53.ipk"
tgz_name="sing-box-1.14.3-extended-2.7.3-linux-arm64-compressed.tar.gz"

# A minimal IPK whose control file declares the real Installed-Size.
pkg_dir="$WORK_DIR/pkg"
mkdir -p "$pkg_dir/control" "$pkg_dir/data/usr/bin" "$pkg_dir/assets"
printf 'Package: sing-box-extended\nInstalled-Size: 97722\n' >"$pkg_dir/control/control"
printf '#!/bin/sh\nexit 1\n' >"$pkg_dir/data/usr/bin/sing-box"
tar -czf "$pkg_dir/control.tar.gz" -C "$pkg_dir/control" ./control
tar -czf "$pkg_dir/data.tar.gz" -C "$pkg_dir/data" ./usr
printf '2.0\n' >"$pkg_dir/debian-binary"
tar -czf "$pkg_dir/assets/$ipk_name" -C "$pkg_dir" ./debian-binary ./data.tar.gz ./control.tar.gz
# The compressed binary fails validation, so the action stops before touching
# the system; the test only checks which variant was chosen.
mkdir -p "$pkg_dir/tgz/sing-box-compressed"
printf '#!/bin/sh\nexit 1\n' >"$pkg_dir/tgz/sing-box-compressed/sing-box"
chmod +x "$pkg_dir/tgz/sing-box-compressed/sing-box"
tar -czf "$pkg_dir/assets/$tgz_name" -C "$pkg_dir/tgz" sing-box-compressed

fake_bin="$WORK_DIR/bin"
mkdir -p "$fake_bin"
export FAKE_LOG="$WORK_DIR/calls.log" FAKE_ASSETS="$pkg_dir/assets" FAKE_TAG="$tag" \
  FAKE_IPK="$ipk_name" FAKE_TGZ="$tgz_name"

cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env sh
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="$2"; shift ;;
    -H|-m|--connect-timeout|-x) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
printf 'curl %s\n' "$url" >>"$FAKE_LOG"
base="https://github.com/shtorm-7/sing-box-extended/releases/download/$FAKE_TAG"
case "$url" in
  https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest|https://api.github.com/repos/shtorm-7/sing-box-extended/releases/tags/*)
    printf '{"tag_name":"%s","html_url":"https://example.com/release","assets":[{"name":"%s","url":"https://api.github.com/assets/ipk","browser_download_url":"%s/%s"},{"name":"%s","url":"https://api.github.com/assets/tgz","browser_download_url":"%s/%s"}]}' \
      "$FAKE_TAG" "$FAKE_IPK" "$base" "$FAKE_IPK" "$FAKE_TGZ" "$base" "$FAKE_TGZ" >"$output" ;;
  https://api.github.com/assets/ipk) cp "$FAKE_ASSETS/$FAKE_IPK" "$output" ;;
  https://api.github.com/assets/tgz) cp "$FAKE_ASSETS/$FAKE_TGZ" "$output" ;;
  *) exit 7 ;;
esac
SH
cat >"$fake_bin/opkg" <<'SH'
#!/usr/bin/env sh
printf 'opkg %s\n' "$*" >>"$FAKE_LOG"
exit 0
SH
cat >"$fake_bin/df" <<'SH'
#!/usr/bin/env sh
printf 'Filesystem 1K-blocks Used Available Use%% Mounted on\n'
printf '/dev/ubi0_2 45772 8294 %s 19%% /overlay\n' "${FAKE_DF_FREE_KB:?}"
SH
cat >"$fake_bin/uname" <<'SH'
#!/usr/bin/env sh
echo aarch64
SH
printf '#!/usr/bin/env sh\nexit 0\n' >"$fake_bin/logger"
chmod +x "$fake_bin"/*

printf "DISTRIB_ARCH='aarch64_cortex-a53'\nDISTRIB_RELEASE='24.10.8'\n" >"$WORK_DIR/openwrt_release"
mkdir -p "$WORK_DIR/overlay"

run_install() {
  : >"$FAKE_LOG"
  rm -rf "$WORK_DIR/state"
  mkdir -p "$WORK_DIR/state"
  set +e
  PATH="$fake_bin:$PATH" \
    FAKE_DF_FREE_KB="$1" \
    FORKOP_LIB="$FORKOP_LIB" \
    FORKOP_RUNTIME_STATE_DIR="$WORK_DIR/state" \
    UPDATES_LOCK_DIR="$WORK_DIR/state/lock" \
    FORKOP_BIN="$WORK_DIR/missing-forkop" \
    FORKOP_SERVICE_INIT="$WORK_DIR/missing-init" \
    FORKOP_OPENWRT_RELEASE_FILE="$WORK_DIR/openwrt_release" \
    FORKOP_OVERLAY_DIR="$WORK_DIR/overlay" \
    ucode -L "$FORKOP_LIB" "$ACTION_UC" component-action sing_box install_extended >"$WORK_DIR/out.json" 2>&1
  set -e
}

# 34 MB free: the package (about 95 MB) does not fit.
run_install 35020
grep -Fq 'curl https://api.github.com/assets/tgz' "$FAKE_LOG" ||
  fail "low flash space must switch to the compressed sing-box-extended binary: $(cat "$WORK_DIR/out.json")"
grep -q '^opkg install' "$FAKE_LOG" &&
  fail "low flash space must not run opkg install for the sing-box-extended package"

# 200 MB free: the package fits and is installed with opkg.
run_install 204800
grep -q "^opkg install .*$ipk_name" "$FAKE_LOG" ||
  fail "enough flash space must install the sing-box-extended package: $(cat "$WORK_DIR/out.json")"
grep -Fq 'curl https://api.github.com/assets/tgz' "$FAKE_LOG" &&
  fail "enough flash space must not download the compressed binary"

exit 0
