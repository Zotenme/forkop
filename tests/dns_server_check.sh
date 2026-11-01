#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
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
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

mkdir -p "$WORK_DIR/bin"

# Records every call and answers like dig 9.20 does on OpenWrt.
cat >"$WORK_DIR/bin/dig" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" >>"$DIG_LOG"
case " $* " in
  *' +short '*'@9.9.9.9 dns.example A '*) printf '203.0.113.7\n' ;;
  *' +short '*) ;;
  *' +tls '*'@dns.example '*)
    # A failed TLS handshake prints nothing.
    ;;
  *' @dns.example '*|*' @192.0.2.1 '*)
    cat <<'OUT'
;; Got answer:
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
;; ANSWER SECTION:
example.com.		300	IN	A	192.0.2.10

;; Query time: 23 msec
OUT
    ;;
  *' @192.0.2.2 '*)
    printf ';; Got answer:\n;; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1\n'
    ;;
  *)
    printf ';; communications error to %s: timed out\n' "$*"
    ;;
esac
SH
chmod +x "$WORK_DIR/bin/dig"

# POSIXLY_CORRECT keeps glibc ucode from taking "-f..." server values as its
# own options, as musl ucode on the router does not either.
run_check() {
  POSIXLY_CORRECT=1 PATH="$WORK_DIR/bin:$PATH" DIG_LOG="$WORK_DIR/dig.log" \
    ucode -L "$FORKOP_LIB" "$FORKOP_LIB/dns/check.uc" check "$@"
}

field() {
  JSON="$1" node -e "const v = JSON.parse(process.env.JSON); console.log(String($2))"
}

# A server by name: resolved through bootstrap, then checked over each protocol.
: >"$WORK_DIR/dig.log"
out="$(run_check 'dns.example/custom-path' '' '9.9.9.9')"
assert_eq "$(field "$out" 'v.success')" "true" "named server check succeeds"
assert_eq "$(field "$out" 'v.resolved')" "203.0.113.7" "bootstrap resolves the name"
assert_eq "$(field "$out" 'v.bootstrap_ok')" "true" "bootstrap status"
assert_eq "$(field "$out" 'v.results.udp.ok')" "true" "udp reply"
assert_eq "$(field "$out" 'v.results.udp.ms')" "23" "udp query time"
assert_eq "$(field "$out" 'v.results.udp.address')" "192.0.2.10" "udp answer"
assert_eq "$(field "$out" 'v.results.dot.ok')" "false" "silent TLS failure"
assert_eq "$(field "$out" 'v.results.dot.error')" "no_response" "silent TLS failure error"
assert_eq "$(field "$out" 'v.results.doh.ok')" "true" "doh reply"
grep -Fq '+https=/custom-path +tls-ca' "$WORK_DIR/dig.log" ||
  fail "DoH must use the server path and verify the certificate"
grep -Fq '+tls +tls-ca' "$WORK_DIR/dig.log" ||
  fail "DoT must verify the certificate"

# A port applies to every protocol; only the requested protocols run.
: >"$WORK_DIR/dig.log"
out="$(run_check '192.0.2.1:5353' 'udp' '')"
assert_eq "$(field "$out" 'Object.keys(v.results).join(",")')" "udp" "requested protocols only"
assert_eq "$(field "$out" 'v.resolved')" "undefined" "an address needs no bootstrap"
grep -Fq -- '-p 5353 @192.0.2.1' "$WORK_DIR/dig.log" || fail "port must be passed to dig"

# Error replies and timeouts are reported per protocol.
out="$(run_check '192.0.2.2' 'udp' '')"
assert_eq "$(field "$out" 'v.results.udp.error')" "servfail" "error status"
out="$(run_check '192.0.2.3' 'udp' '')"
assert_eq "$(field "$out" 'v.results.udp.error')" "timeout" "timeout"

# Bootstrap that cannot resolve the name.
out="$(run_check 'dns.example' 'udp' '192.0.2.9')"
assert_eq "$(field "$out" 'v.bootstrap_ok')" "false" "bootstrap failure"

# Anything that could become a dig option is rejected before dig runs.
: >"$WORK_DIR/dig.log"
for server in '-f/etc/passwd' '+tcp' 'bad..host' 'dns.example:99999' ''; do
  if out="$(run_check "$server" '' '')"; then
    fail "invalid server '$server' must fail"
  fi
  assert_eq "$(field "$out" 'v.error')" "invalid_server" "invalid server '$server'"
done
if out="$(run_check '192.0.2.1' '' '-f/etc/passwd')"; then
  fail "invalid bootstrap must fail"
fi
assert_eq "$(field "$out" 'v.error')" "invalid_bootstrap" "invalid bootstrap"
[ ! -s "$WORK_DIR/dig.log" ] || fail "dig must not run for invalid input"

printf 'DNS server check tests passed\n'
