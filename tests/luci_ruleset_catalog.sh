#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECTION_JS="$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/section.js"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

create_section="$(sed -n '/^function createSectionContent(/,/^function loadSectionTableOptions(/p' "$SECTION_JS")"
add_entries="$(sed -n '/^function addRulesetCatalogEntries(/,/^function showRulesetCatalogModal(/p' "$SECTION_JS")"

grep -Fq 'attachRulesetCatalogButton(ruleSetOption, { allowSubnets: true });' <<<"$create_section" ||
  fail "routing rule sets must offer the catalog with geoip lists"
grep -Fq 'attachRulesetCatalogButton(dnsRuleSetOption, { allowSubnets: false });' <<<"$create_section" ||
  fail "DNS rule sets must offer the catalog without geoip lists"
grep -Fq 'writeListOption(section_id, "rule_set_with_subnets", [...subnets]);' <<<"$add_entries" ||
  fail "catalog geoip lists must be added with subnets enabled"
grep -Fq 'widget.setValue(refs);' <<<"$add_entries" ||
  fail "catalog selection must update the visible rule set list"

# Run the pure catalog helpers outside LuCI to check URL building and search.
node - "$SECTION_JS" <<'NODE'
const fs = require("fs");
const vm = require("vm");
const source = fs.readFileSync(process.argv[2], "utf8");

function fail(message) {
  console.error(`FAIL: ${message}`);
  process.exit(1);
}

function extract(pattern, name) {
  const match = source.match(pattern);
  if (!match) {
    fail(`${name} not found in section.js`);
  }
  return match[0];
}

const code = [
  extract(/^const RULESET_CATALOG_SOURCES = \[[\s\S]*?^\];$/m, "RULESET_CATALOG_SOURCES"),
  ...[
    "rulesetCatalogEntryName",
    "parseRulesetCatalogIndex",
    "rulesetCatalogEntry",
    "filterRulesetCatalogNames",
  ].map((name) =>
    extract(new RegExp(`^function ${name}\\([\\s\\S]*?^}$`, "m"), name),
  ),
  "this.result = { RULESET_CATALOG_SOURCES, parseRulesetCatalogIndex, rulesetCatalogEntry, filterRulesetCatalogNames };",
].join("\n");
const context = {};
vm.runInNewContext(code, context);
const api = context.result;
const geosite = api.RULESET_CATALOG_SOURCES.find((item) => item.id === "geosite");
const geoip = api.RULESET_CATALOG_SOURCES.find((item) => item.id === "geoip");

if (!geosite || geosite.subnets || !geoip || !geoip.subnets) {
  fail("catalog must provide domain-only geosite and subnet geoip sources");
}

const names = api.parseRulesetCatalogIndex(geosite, {
  files: [
    { name: "/geosite-youtube.srs" },
    { name: "/geosite-apple.srs" },
    { name: "/geosite-apple@cn.srs" },
    { name: "/geosite-apple-dev.srs" },
    { name: "/geosite-pineapple.srs" },
    { name: "/geosite-apple.srs" },
    { name: "/geoip-ru.srs" },
    { name: "/README.md" },
    { name: "/nested/geosite-skip.srs" },
  ],
});
if (JSON.stringify(names) !== JSON.stringify(["apple", "apple-dev", "apple@cn", "pineapple", "youtube"])) {
  fail(`unexpected parsed catalog names: ${JSON.stringify(names)}`);
}

const entry = api.rulesetCatalogEntry(geosite, "apple");
if (entry.url !== "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-apple.srs") {
  fail(`unexpected geosite URL: ${entry.url}`);
}
const ipEntry = api.rulesetCatalogEntry(geoip, "ru");
if (ipEntry.url !== "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs" || !ipEntry.subnets) {
  fail(`unexpected geoip entry: ${JSON.stringify(ipEntry)}`);
}

const search = api.filterRulesetCatalogNames(names, " Apple ", false);
if (JSON.stringify(search) !== JSON.stringify(["apple", "apple-dev", "pineapple"])) {
  fail(`search must rank exact and prefix matches first and hide variants: ${JSON.stringify(search)}`);
}
const withVariants = api.filterRulesetCatalogNames(names, "apple", true);
if (!withVariants.includes("apple@cn")) {
  fail("variant lists must appear when enabled");
}
if (api.filterRulesetCatalogNames(names, "", false).length !== 4) {
  fail("empty search must list every non-variant rule set");
}
NODE

printf 'LuCI rule set catalog checks passed\n'
