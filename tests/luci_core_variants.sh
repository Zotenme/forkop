#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node - "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/server.js" "$ROOT_DIR/luci-app-forkop/htdocs/luci-static/resources/view/forkop/forkop.js" <<'NODE'
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');
const start = source.indexOf('function normalizeServerCapabilities(');
const end = source.indexOf('function getServerName(', start);
const context = {
  BASE_PROTOCOL_LABELS: { vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan' },
  EXTENDED_PROTOCOL_LABELS: { mtproto: 'MTProto' },
  TAILSCALE_PROTOCOL_LABELS: { tailscale: 'Tailscale' },
  CUSTOM_PROTOCOL_LABELS: { json_inbound: 'JSON' },
  DEFAULT_SERVER_PROTOCOL: 'tailscale', FALLBACK_SERVER_PROTOCOL: 'vless',
  resetOptionValues: option => { option.values = []; },
  addOptionValue: (option, value) => option.values.push(value),
};
if (start < 0 || end < 0) throw new Error('FAIL: server capability helpers missing');
vm.createContext(context);
vm.runInContext(source.slice(start, end), context);
const section = { serverCapabilityOptions: { protocol: {}, transport: {} } };
context.applyServerCapabilities(section, { singBoxForkop: true, singBoxExtended: false, singBoxTailscale: false });
const protocols = section.serverCapabilityOptions.protocol.values;
const transports = section.serverCapabilityOptions.transport.values;
if (!protocols.includes('vless') || protocols.some(p => ['vmess', 'tailscale', 'mtproto'].includes(p)))
  throw new Error('FAIL: tiny must expose its supported protocols without full-core features');
if (!transports.includes('xhttp')) throw new Error('FAIL: forkop tiny supports XHTTP');
if (section.serverCapabilityOptions.protocol.default !== 'vless') throw new Error('FAIL: tiny server must default to VLESS');
context.applyServerCapabilities(section, { singBoxExtended: true, singBoxTailscale: true });
if (!section.serverCapabilityOptions.protocol.values.includes('mtproto'))
  throw new Error('FAIL: switching back to extended must restore full-core protocol choices');
// A background core switch updates server choices without a page reload.
const view = fs.readFileSync(process.argv[3], 'utf8');
const subscriptionStart = view.indexOf('    // Core changes also arrive');
const subscriptionEnd = view.indexOf('    const applyUiState =', subscriptionStart);
let subscriber;
context.main = { store: { subscribe: cb => { subscriber = cb; return () => {}; } } };
context.uiCapabilities = { singBoxExtended: true, singBoxForkop: false, singBoxTiny: false, singBoxTailscale: true };
context.serverSectionRef = section;
context.server = { applyServerCapabilities: context.applyServerCapabilities };
context.window = { addEventListener() {} };
section.unsavedValue = 'keep this edit';
if (subscriptionStart < 0 || subscriptionEnd < 0) throw new Error('FAIL: live core capability subscription missing');
vm.runInContext(view.slice(subscriptionStart, subscriptionEnd), context);
subscriber({ diagnosticsSystemInfo: { sing_box_extended: 0, sing_box_forkop: 1, sing_box_tiny: 1, sing_box_tailscale: 0 } }, {}, { diagnosticsSystemInfo: true });
if (section.serverCapabilityOptions.protocol.values.includes('tailscale') ||
    !section.serverCapabilityOptions.transport.values.includes('xhttp') || section.unsavedValue !== 'keep this edit')
  throw new Error('FAIL: live switch must update capabilities without replacing form state');
NODE
printf 'LuCI core variant capabilities checks passed\n'
