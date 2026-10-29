#!/usr/bin/env ucode

const SB_DNS_SERVER_TAG = getenv("SB_DNS_SERVER_TAG") || "dns-server";
const SB_FAKEIP_DNS_SERVER_TAG = getenv("SB_FAKEIP_DNS_SERVER_TAG") || "fakeip-server";
const SB_BOOTSTRAP_SERVER_TAG = getenv("SB_BOOTSTRAP_SERVER_TAG") || "bootstrap-dns-server";
const SB_FAKEIP_DNS_RULE_TAG = getenv("SB_FAKEIP_DNS_RULE_TAG") || "fakeip-dns-rule-tag";
const SB_FAKEIP_RULESET_DNS_RULE_TAG = getenv("SB_FAKEIP_RULESET_DNS_RULE_TAG") || "fakeip-ruleset-dns-rule-tag";
const SB_SERVICE_FAKEIP_DNS_RULE_TAG = getenv("SB_SERVICE_FAKEIP_DNS_RULE_TAG") || "service-fakeip-dns-rule-tag";
const SB_TPROXY_INBOUND_TAG = getenv("SB_TPROXY_INBOUND_TAG") || "tproxy-in";
const SB_TPROXY_INBOUND6_TAG = getenv("SB_TPROXY_INBOUND6_TAG") || "tproxy6-in";
const SB_DNS_INBOUND_TAG = getenv("SB_DNS_INBOUND_TAG") || "dns-in";
const SB_SERVICE_MIXED_INBOUND_TAG = getenv("SB_SERVICE_MIXED_INBOUND_TAG") || "service-mixed-in";
const SB_DIRECT_OUTBOUND_TAG = getenv("SB_DIRECT_OUTBOUND_TAG") || "direct-out";
const SB_BYPASS_OUTBOUND_TAG = getenv("SB_BYPASS_OUTBOUND_TAG") || "bypass-out";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function digit_char(value) {
    return match(as_string(value), /^[0-9]$/) != null;
}

function strip_leading_zeroes(value) {
    value = as_string(value);
    let i = 0;
    while (i < length(value) - 1 && substr(value, i, 1) == "0")
        i++;
    return substr(value, i);
}

function version_compare(lhs, rhs) {
    lhs = as_string(lhs);
    rhs = as_string(rhs);

    let li = 0, ri = 0;
    while (li < length(lhs) || ri < length(rhs)) {
        if (li >= length(lhs))
            return substr(rhs, ri, 1) == "~" ? 1 : -1;
        if (ri >= length(rhs))
            return substr(lhs, li, 1) == "~" ? -1 : 1;

        let lc = substr(lhs, li, 1);
        let rc = substr(rhs, ri, 1);
        if (lc == rc) {
            li++;
            ri++;
            continue;
        }

        if (lc == "~" || rc == "~")
            return lc == "~" ? -1 : 1;

        if (digit_char(lc) && digit_char(rc)) {
            let ls = li, rs = ri;
            while (li < length(lhs) && digit_char(substr(lhs, li, 1)))
                li++;
            while (ri < length(rhs) && digit_char(substr(rhs, ri, 1)))
                ri++;

            let lnum = strip_leading_zeroes(substr(lhs, ls, li - ls));
            let rnum = strip_leading_zeroes(substr(rhs, rs, ri - rs));
            if (length(lnum) != length(rnum))
                return length(lnum) < length(rnum) ? -1 : 1;
            if (lnum != rnum)
                return lnum < rnum ? -1 : 1;
            continue;
        }

        return lc < rc ? -1 : 1;
    }

    return 0;
}

function version_at_least(current, required) {
    return version_compare(current, required) >= 0;
}

function first_index_any(value, needles, start) {
    value = as_string(value);
    start = int(start || 0);

    for (let i = start; i < length(value); i++) {
        let c = substr(value, i, 1);
        for (let needle in needles)
            if (c == needle)
                return i;
    }

    return -1;
}

function strip_first_scheme_marker(value) {
    value = as_string(value);
    let marker = index(value, "://");
    return marker >= 0 ? substr(value, marker + 3) : value;
}

function url_authority(value) {
    value = strip_first_scheme_marker(value);
    let at = index(value, "@");
    if (at >= 0)
        value = substr(value, at + 1);

    let end = first_index_any(value, ["/", "?", "#"], 0);
    return end >= 0 ? substr(value, 0, end) : value;
}

function url_get_host(value) {
    let authority = url_authority(value);
    let colon = index(authority, ":");
    print(colon >= 0 ? substr(authority, 0, colon) : authority, "\n");
}

function download_via_proxy_option_for_purpose(purpose) {
    purpose = as_string(purpose || "lists");

    if (purpose == "lists")
        print("download_lists_via_proxy\n");
    else if (purpose == "components")
        print("download_components_via_proxy\n");
    else
        exit(1);
}

function tag_is_reserved(tag, reserved) {
    tag = as_string(tag);
    for (let value in reserved)
        if (tag == as_string(value))
            return true;
    return false;
}

function allocate_runtime_tag_value(base, postfix, reserved) {
    base = as_string(base);
    postfix = as_string(postfix);
    reserved = type(reserved) == "array" ? reserved : [];
    let candidate = base + "-" + postfix;
    let suffix = 1;

    while (tag_is_reserved(candidate, reserved)) {
        candidate = base + "-" + postfix + "-" + suffix;
        suffix++;
    }

    return candidate;
}

function default_reserved_runtime_tags() {
    return [
        SB_DNS_SERVER_TAG,
        SB_FAKEIP_DNS_SERVER_TAG,
        SB_BOOTSTRAP_SERVER_TAG,
        SB_FAKEIP_DNS_RULE_TAG,
        SB_FAKEIP_RULESET_DNS_RULE_TAG,
        SB_SERVICE_FAKEIP_DNS_RULE_TAG,
        SB_TPROXY_INBOUND_TAG,
        SB_TPROXY_INBOUND6_TAG,
        SB_DNS_INBOUND_TAG,
        SB_SERVICE_MIXED_INBOUND_TAG,
        SB_DIRECT_OUTBOUND_TAG,
        SB_BYPASS_OUTBOUND_TAG
    ];
}

function print_runtime_tag(base, postfix, reserved) {
    print(allocate_runtime_tag_value(base, postfix, reserved), "\n");
}

let mode = ARGV[0] || "";

if (mode == "version-at-least")
    exit(version_at_least(ARGV[1], ARGV[2]) ? 0 : 1);
else if (mode == "download-via-proxy-option-for-purpose")
    download_via_proxy_option_for_purpose(ARGV[1]);
else if (mode == "inbound-tag")
    print_runtime_tag(ARGV[1], "in", default_reserved_runtime_tags());
else if (mode == "server-inbound-tag")
    print_runtime_tag("server-" + as_string(ARGV[1]), "in", default_reserved_runtime_tags());
else if (mode == "tailscale-dns-tag")
    print_runtime_tag("server-" + as_string(ARGV[1]), "tailscale-dns", default_reserved_runtime_tags());
else if (mode == "outbound-tag")
    print_runtime_tag(ARGV[1], "out", default_reserved_runtime_tags());
else if (mode == "url-get-host")
    url_get_host(ARGV[1]);
else {
    warn("Usage: core/helpers.uc <operation> ...\n");
    exit(1);
}
