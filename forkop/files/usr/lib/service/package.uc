#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function env(name, fallback) {
    let value = getenv(name);
    return value == null ? as_string(fallback) : as_string(value);
}

const CONFIG_NAME = env("FORKOP_CONFIG_NAME", "forkop");
const RT_TABLES_PATH = env("FORKOP_RT_TABLES", "/etc/iproute2/rt_tables");
const BIN_PATH = env("FORKOP_BIN", "/usr/bin/forkop");
const INIT_PATH = env("FORKOP_INIT", "/etc/init.d/forkop");
const DNS_APPLY_UC = env("FORKOP_DNS_APPLY_UC", "/usr/lib/forkop/dns/apply.uc");
const SING_BOX_INIT = env("FORKOP_SING_BOX_INIT", "/etc/init.d/sing-box");
const SING_BOX_BIN = env("FORKOP_SING_BOX_BIN", "/usr/bin/sing-box");
const SING_BOX_CRONET = env("FORKOP_SING_BOX_CRONET", "/usr/lib/libcronet.so");
const SING_BOX_MANAGED_MARKER = env("SB_MANAGED_SERVICE_MARKER", "Forkop managed sing-box service for binary variants");
const SING_BOX_VARIANT_STATE_FILE = env("SB_VARIANT_STATE_FILE", "/etc/forkop/sing-box-variant");
const PACKAGE_UPGRADE_STATE = env("FORKOP_PACKAGE_UPGRADE_STATE", "/tmp/forkop-package-was-running");
const PACKAGE_RECOVERY_LOCK_DIR = env("FORKOP_PACKAGE_RECOVERY_LOCK_DIR", "/tmp/forkop-package-recovery.lock");
const PACKAGE_TEST_MODE = env("FORKOP_PACKAGE_TEST_MODE", "") != "";
const PACKAGE_START_TIMEOUT = env("FORKOP_PACKAGE_START_TIMEOUT", "180");

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function normalize_status(status) {
    status = int(status);
    return status > 255 ? int(status / 256) : status;
}

function command_success_from_args(args) {
    return normalize_status(system(command_from_args(args) + " >/dev/null 2>&1")) == 0;
}

function log_package(message, level) {
    command_success_from_args([ "logger", "-t", "forkop", "[" + as_string(level || "info") + "] " + as_string(message) ]);
}

function command_success_with_timeout(args, timeout_seconds) {
    timeout_seconds = as_string(timeout_seconds);
    if (match(timeout_seconds, /^[1-9][0-9]*$/) == null)
        timeout_seconds = "180";

    // A hung command must never block opkg/apk: the package manager waits
    // for postinst, and the Forkop updater waits for the package manager.
    let command = command_from_args(args) + " >/dev/null 2>&1 </dev/null & pid=$!; " +
        "( sleep " + timeout_seconds + "; kill $pid 2>/dev/null && echo timeout >&2 ) 2>/dev/null & watcher=$!; " +
        "wait $pid 2>/dev/null; rc=$?; kill $watcher 2>/dev/null || true; wait $watcher 2>/dev/null || true; exit $rc";
    return normalize_status(system(command_from_args([ "sh", "-c", command ]) + " >/dev/null 2>&1")) == 0;
}

function path_exists(path) {
    return fs.stat(as_string(path)) != null;
}

function unlink_if_exists(path) {
    if (path_exists(path))
        fs.unlink(as_string(path));
}

function remove_rt_tables_entry() {
    let data = fs.readfile(RT_TABLES_PATH);
    if (data == null)
        return true;

    let changed = false;
    let lines = [];
    for (let line in split(data, "\n")) {
        if (index(line, "105 forkop") >= 0) {
            changed = true;
            continue;
        }
        push(lines, line);
    }

    return !changed || fs.writefile(RT_TABLES_PATH, join("\n", lines)) != null;
}

function ascii_lower(value) {
    let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    let lower = "abcdefghijklmnopqrstuvwxyz";
    return replace(as_string(value), /[A-Z]/g, function(ch) {
        return substr(lower, index(upper, ch), 1);
    });
}

function truthy(value) {
    value = ascii_lower(trim(as_string(value)));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function dont_touch_dhcp_enabled() {
    return truthy(uci_core.get(CONFIG_NAME + ".settings.dont_touch_dhcp"));
}

function restore_dnsmasq_if_needed() {
    if (dont_touch_dhcp_enabled())
        return;

    command_success_from_args([ BIN_PATH, "restore_dnsmasq" ]);
    if (path_exists(DNS_APPLY_UC))
        command_success_from_args([ "ucode", DNS_APPLY_UC, "failsafe-restore" ]);
}

function remove_managed_sing_box() {
    let data = fs.readfile(SING_BOX_INIT);
    if (data == null || index(data, SING_BOX_MANAGED_MARKER) < 0)
        return;

    command_success_from_args([ SING_BOX_INIT, "stop" ]);
    command_success_from_args([ SING_BOX_INIT, "disable" ]);
    unlink_if_exists(SING_BOX_INIT);
    unlink_if_exists(SING_BOX_BIN);
    unlink_if_exists(SING_BOX_CRONET);
}

function managed_sing_box_variant() {
    let marker = trim(as_string(fs.readfile(SING_BOX_VARIANT_STATE_FILE) || ""));
    if (marker == "forkop-tiny")
        return "forkop-tiny";
    if (marker == "extended-compressed")
        return "extended-compressed";
    return "";
}

function recover_managed_sing_box_binary() {
    let variant = managed_sing_box_variant();
    if (variant == "" || path_exists(SING_BOX_BIN))
        return true;

    let action = variant == "forkop-tiny" ? "install_forkop_tiny" : "install_extended_compressed";
    log_package("Restoring the managed sing-box binary after the Forkop package upgrade", "info");
    command_success_from_args([
        "env",
        "UPDATES_LOCK_DIR=" + PACKAGE_RECOVERY_LOCK_DIR,
        BIN_PATH,
        "component_action",
        "sing_box",
        action
    ]);
    if (path_exists(SING_BOX_BIN))
        return true;

    log_package("Failed to restore the managed sing-box binary (" + variant + "). Reinstall the sing-box core on the Components tab", "error");
    return false;
}

function remember_upgrade_state(action) {
    if (as_string(action) != "upgrade") {
        unlink_if_exists(PACKAGE_UPGRADE_STATE);
        return;
    }

    if (command_success_from_args([ INIT_PATH, "status" ]))
        fs.writefile(PACKAGE_UPGRADE_STATE, "1\n");
}

function prerm_cleanup(action) {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    remember_upgrade_state(action);
    if (!PACKAGE_TEST_MODE) {
        command_success_from_args([ INIT_PATH, "stop" ]);
        restore_dnsmasq_if_needed();
        if (as_string(action) != "upgrade")
            remove_managed_sing_box();
    }
    return remove_rt_tables_entry();
}

// postinst never fails because of the runtime: the package files are already
// in place, and a failed postinst only leaves opkg/apk in a half-configured
// state and makes the updater report a broken install.
function postinst_restore() {
    if (env("IPKG_INSTROOT", "") != "")
        return true;

    let core_ready = recover_managed_sing_box_binary();
    if (!path_exists(PACKAGE_UPGRADE_STATE))
        return true;
    unlink_if_exists(PACKAGE_UPGRADE_STATE);

    if (!core_ready) {
        log_package("Forkop was not started after the package upgrade because the sing-box core is missing", "warn");
        return true;
    }

    if (!command_success_with_timeout([ INIT_PATH, "start" ], PACKAGE_START_TIMEOUT))
        log_package("Forkop did not start after the package upgrade; check the log above", "warn");
    return true;
}

function luci_cache_globs() {
    let configured = env("FORKOP_LUCI_CACHE_GLOBS", "");
    if (configured != "")
        return split(configured, /[ \t\r\n]+/);

    return [ "/var/luci-indexcache*", "/tmp/luci-indexcache*" ];
}

function remove_luci_index_cache() {
    for (let pattern in luci_cache_globs()) {
        pattern = as_string(pattern);
        if (pattern == "")
            continue;

        for (let path in fs.glob(pattern))
            unlink_if_exists(path);
    }
}

function luci_postinst() {
    remove_luci_index_cache();
    if (!PACKAGE_TEST_MODE) {
        if (path_exists("/etc/init.d/rpcd"))
            command_success_from_args([ "/etc/init.d/rpcd", "reload" ]);
        command_success_from_args([ "logger", "-t", "forkop", "[info] Package defaults applied" ]);
    }
    return true;
}

let mode = ARGV[0] || "";

if (mode == "prerm")
    exit(prerm_cleanup(ARGV[1]) ? 0 : 1);
else if (mode == "postinst")
    exit(postinst_restore() ? 0 : 1);
else if (mode == "remove-rt-tables-entry")
    exit(remove_rt_tables_entry() ? 0 : 1);
else if (mode == "luci-postinst")
    exit(luci_postinst() ? 0 : 1);
else {
    warn("Usage: service/package.uc <prerm|postinst|remove-rt-tables-entry|luci-postinst>\n");
    exit(1);
}
