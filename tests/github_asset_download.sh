#!/usr/bin/env bash
# Release packages must download through the GitHub API asset URL, which
# redirects straight to the release CDN, so installs work on networks where
# github.com itself is unreachable but api.github.com and the CDN are not.
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT_DIR/install.sh"
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

assert_eq() {
  [ "$2" = "$1" ] || fail "$3: expected '$1', got '$2'"
}

fake_bin="$WORK_DIR/bin"
mkdir -p "$fake_bin"
export FAKE_FETCH_LOG="$WORK_DIR/fetch.log"

# Fake fetchers: github.com download links time out, the API serves release
# JSON and, with the octet-stream Accept header, the asset itself.
cat >"$fake_bin/fake-fetch" <<'SH'
#!/usr/bin/env sh
accept=""
output=""
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H|--header) accept="$2"; shift ;;
    --header=*) accept="${1#--header=}" ;;
    -o|-O) output="$2"; shift ;;
    -T|-m|--connect-timeout|--max-time|-x) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
printf '%s|%s\n' "$url" "$accept" >>"${FAKE_FETCH_LOG:?}"
release='{"tag_name":"9.9.9","html_url":"https://github.com/o/r/releases/tag/9.9.9","assets":[
{"name":"forkop_9.9.9.ipk","url":"https://api.github.com/repos/o/r/releases/assets/1","browser_download_url":"https://github.com/o/r/releases/download/9.9.9/forkop_9.9.9.ipk"},
{"name":"luci-app-forkop_9.9.9.ipk","url":"https://api.github.com/repos/o/r/releases/assets/2","browser_download_url":"https://github.com/o/r/releases/download/9.9.9/luci-app-forkop_9.9.9.ipk"},
{"name":"luci-i18n-forkop-ru_9.9.9.ipk","url":"https://api.github.com/repos/o/r/releases/assets/3","browser_download_url":"https://github.com/o/r/releases/download/9.9.9/luci-i18n-forkop-ru_9.9.9.ipk"}]}'
write_out() {
  if [ -z "$output" ] || [ "$output" = "-" ]; then printf '%s' "$1"; else printf '%s' "$1" >"$output"; fi
}
case "$url" in
  https://github.com/*) exit 28 ;;
  https://api.github.com/repos/o/r/releases/latest|https://api.github.com/repos/o/r/releases/tags/9.9.9)
    write_out "$release" ;;
  https://api.github.com/repos/o/r/releases/assets/*)
    [ "$accept" = "Accept: application/octet-stream" ] || exit 22
    write_out "package ${url##*/}" ;;
  *) exit 6 ;;
esac
SH
chmod +x "$fake_bin/fake-fetch"
ln -s fake-fetch "$fake_bin/curl"
ln -s fake-fetch "$fake_bin/wget"

# --- install.sh ---
installer_funcs="$WORK_DIR/installer-funcs.sh"
awk '
  /^download_file_once\(\)|^download_with_retry\(\)/ { capture = 1 }
  capture { print }
  capture && /^}/ { capture = 0 }
' "$INSTALLER" >"$installer_funcs"
grep -q '^download_with_retry()' "$installer_funcs" || fail "failed to extract installer download helpers"

for fetcher in curl wget; do
  : >"$FAKE_FETCH_LOG"
  out="$WORK_DIR/installer-$fetcher.ipk"
  PATH="$fake_bin:$PATH" FETCHER="$fetcher" sh -c '
    msg() { :; }
    warn() { :; }
    run_with_deadline() { shift; "$@"; }
    CONNECT_TIMEOUT_SECONDS=1 DOWNLOAD_TIMEOUT_SECONDS=5
    . "$1"
    download_with_retry "https://github.com/o/r/releases/download/9.9.9/forkop_9.9.9.ipk" "$2" forkop_9.9.9.ipk \
      "https://api.github.com/repos/o/r/releases/assets/1"
  ' sh "$installer_funcs" "$out" || fail "installer ($fetcher) must download through the GitHub API asset URL"
  assert_eq "package 1" "$(cat "$out")" "installer ($fetcher) asset content"
  grep -q '^https://github.com/' "$FAKE_FETCH_LOG" &&
    fail "installer ($fetcher) must not hit github.com when the API download works"

  # Without an API URL the installer still falls back to the direct link.
  : >"$FAKE_FETCH_LOG"
  if PATH="$fake_bin:$PATH" FETCHER="$fetcher" sh -c '
    msg() { :; }
    warn() { :; }
    run_with_deadline() { shift; "$@"; }
    . "$1"
    download_with_retry "https://github.com/o/r/releases/download/9.9.9/forkop_9.9.9.ipk" "$2" forkop_9.9.9.ipk
  ' sh "$installer_funcs" "$out.direct"; then
    fail "installer ($fetcher) direct download must fail when github.com is unreachable"
  fi
  assert_eq 3 "$(grep -c '^https://github.com/' "$FAKE_FETCH_LOG")" "installer ($fetcher) direct attempts"
done

# --- components/action.uc (Forkop self-update) ---
: >"$FAKE_FETCH_LOG"
cat >"$fake_bin/opkg" <<'SH'
#!/usr/bin/env sh
case "$1" in
  install) for f in "$@"; do case "$f" in *.ipk) cat "$f" >>"${FAKE_FETCH_LOG:?}.installed"; echo >>"${FAKE_FETCH_LOG:?}.installed" ;; esac; done ;;
esac
grep -Fxq 'package 3' "$FAKE_FETCH_LOG.installed" &&
  fail "the i18n package must not be installed when it was not installed before"

exit 0
SH
printf '#!/usr/bin/env sh\nexit 0\n' >"$fake_bin/logger"
chmod +x "$fake_bin/opkg" "$fake_bin/logger"
rm -f "$fake_bin/wget"

state_dir="$WORK_DIR/state"
mkdir -p "$state_dir"
set +e
output="$(PATH="$fake_bin:$PATH" \
  FORKOP_LIB="$FORKOP_LIB" \
  FORKOP_VERSION=1.0.0 \
  FORKOP_RELEASE_REPO=o/r \
  FORKOP_RUNTIME_STATE_DIR="$state_dir" \
  UPDATES_LOCK_DIR="$state_dir/lock" \
  FORKOP_BIN="$WORK_DIR/missing-forkop" \
  FORKOP_SERVICE_INIT="$WORK_DIR/missing-init" \
  ucode -L "$FORKOP_LIB" "$ACTION_UC" component-action forkop install 2>&1)"
set -e
grep -Eq '"success": ?true' <<<"$output" ||
  fail "forkop install must succeed through the GitHub API asset URL: $output"
grep -Fxq 'https://api.github.com/repos/o/r/releases/assets/1|Accept: application/octet-stream' "$FAKE_FETCH_LOG" ||
  fail "backend package must be requested from the API with the octet-stream Accept header"
grep -Fxq 'https://api.github.com/repos/o/r/releases/assets/2|Accept: application/octet-stream' "$FAKE_FETCH_LOG" ||
  fail "LuCI package must be requested from the API with the octet-stream Accept header"
grep -q '^https://github.com/' "$FAKE_FETCH_LOG" &&
  fail "forkop install must not hit github.com when the API download works"
grep -Fxq 'package 1' "$FAKE_FETCH_LOG.installed" || fail "downloaded backend package must be installed"

grep -Fxq 'package 3' "$FAKE_FETCH_LOG.installed" &&
  fail "the i18n package must not be installed when it was not installed before"

exit 0
