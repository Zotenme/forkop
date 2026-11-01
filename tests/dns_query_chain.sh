#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORKOP_LIB="$ROOT_DIR/forkop/files/usr/lib"
GENERATOR="$FORKOP_LIB/singbox/generator.uc"
WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# The fifth argument tells the generator whether the core is sing-box-extended.
generate() {
  FORKOP_LIB="$FORKOP_LIB" \
    ucode -L "$FORKOP_LIB" "$GENERATOR" generate-config-fixture "$1" "$2" 192.168.1.1 0 "$3" "" 1.14.3
}

cat >"$WORK_DIR/single.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "udp",
    "dns_server": "77.88.8.8",
    "bootstrap_dns_server": "77.88.8.8"
  },
  "section": [
    { ".name": "direct", ".type": "section", "enabled": "1", "action": "bypass", "domain_suffix": [ "example.org" ] }
  ]
}
JSON

cat >"$WORK_DIR/multi.json" <<'JSON'
{
  "settings": {
    ".name": "settings",
    ".type": "settings",
    "dns_type": "doh",
    "dns_server": [ "77.88.8.8", "dns.google/dns-query", "1.1.1.1" ],
    "bootstrap_dns_server": [ "1.1.1.1", "8.8.8.8" ],
    "dns_query_timeout": "700ms"
  },
  "section": [
    { ".name": "direct", ".type": "section", "enabled": "1", "action": "bypass", "domain_suffix": [ "example.org" ] },
    {
      ".name": "proxy",
      ".type": "section",
      "enabled": "1",
      "action": "outbound",
      "outbound_json": "{\"type\":\"direct\",\"tag\":\"fixture\"}",
      "domain_suffix": [ "example.net" ]
    }
  ]
}
JSON

generate "$WORK_DIR/single.json" "$WORK_DIR/single-out.json" 1
generate "$WORK_DIR/multi.json" "$WORK_DIR/extended-out.json" 1
generate "$WORK_DIR/multi.json" "$WORK_DIR/stock-out.json" 0

node - "$WORK_DIR" <<'NODE'
const fs = require("fs");
const dir = process.argv[2];
const load = (name) => JSON.parse(fs.readFileSync(`${dir}/${name}`, "utf8"));

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}
function assertEqual(actual, expected, message) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    fail(`${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
const server = (config, tag) => config.dns.servers.find((item) => item.tag === tag);

// One server: no chain, the main tag is the server itself.
const single = load("single-out.json");
assertEqual(server(single, "dns-server").type, "udp", "single main server");
assertEqual(server(single, "dns-server-1"), undefined, "single server has no chain items");
if (single.dns.rules.some((rule) => rule.action === "evaluate" && /^dns-server-/.test(rule.server))) {
  fail("single server must not build a chain");
}

for (const name of ["extended-out.json", "stock-out.json"]) {
  const config = load(name);
  const rules = config.dns.rules;

  if (rules.some((rule) => rule.server === "dns-server")) {
    fail(`${name}: no rule may route to the main tag once it is a chain`);
  }
  if (config.inbounds.some((inbound) => /dns-health/.test(inbound.tag))) {
    fail(`${name}: background health inbounds must be gone`);
  }

  // The last rules answer queries that matched nothing else: each server in turn.
  const tail = rules.slice(-5);
  assertEqual(
    tail.map((rule) => [rule.action, rule.server || ""]),
    [
      ["evaluate", "dns-server-1"],
      ["respond", ""],
      ["evaluate", "dns-server-2"],
      ["respond", ""],
      ["route", "dns-server-3"],
    ],
    `${name}: final chain order`,
  );
  assertEqual(tail[0].timeout, "700ms", `${name}: per-server timeout`);
  const good = JSON.stringify(tail[1]);
  for (const part of ['"response_rcode":"NOERROR"', '"0.0.0.0/32"', '"ip_accept_any":true', '"query_type":"A"']) {
    if (!good.includes(part)) fail(`${name}: good response check misses ${part}`);
  }

  // A bypass section keeps its matchers on every step of the chain.
  const bypass = rules.filter((rule) => JSON.stringify(rule).includes("example.org"));
  assertEqual(
    bypass.map((rule) => rule.action),
    ["evaluate", "respond", "evaluate", "respond", "route"],
    `${name}: bypass section chain`,
  );
  if (!bypass.every((rule) => rule.domain_suffix || rule.rules?.[0]?.domain_suffix)) {
    fail(`${name}: bypass chain must keep the section matchers`);
  }

  // A named server is found through the bootstrap tag.
  assertEqual(server(config, "dns-server-2").domain_resolver, "bootstrap-dns-server", `${name}: named server resolver`);
}

// sing-box-extended: lookups outside the rules fall back through the same servers.
const extended = load("extended-out.json");
assertEqual(server(extended, "dns-server"), {
  type: "fallback",
  tag: "dns-server",
  servers: ["dns-server-1", "dns-server-2", "dns-server-3"],
  strategy: "sequential",
  timeout: "2100ms",
}, "extended main fallback server");
assertEqual(server(extended, "bootstrap-dns-server").servers, ["bootstrap-dns-server-1", "bootstrap-dns-server-2"], "extended bootstrap fallback");

// Without it, those lookups use the first server.
const stock = load("stock-out.json");
assertEqual(server(stock, "dns-server").server, "77.88.8.8", "stock main tag is the first server");
assertEqual(server(stock, "bootstrap-dns-server").server, "1.1.1.1", "stock bootstrap is the first server");
assertEqual(server(stock, "bootstrap-dns-server-1"), undefined, "stock has no bootstrap items");
NODE

printf 'DNS query chain tests passed\n'
