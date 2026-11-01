#!/usr/bin/env ucode

let common = require("core.common");
let core_ip = require("core.ip");
let runtime_constants = require("singbox.constants");
let runtime_url = require("core.url");

let as_string = common.as_string;
let bool_option = common.bool_option;
let list_option = common.list_option;
let option = common.option;

const DEFAULT_QUERY_TIMEOUT = "500ms";
// Filtering resolvers answer a blocked or unknown name with these addresses.
const BLOCKED_ADDRESSES = [ "0.0.0.0/32", "::/128" ];
// Rule fields that say what to do rather than which queries match.
const ACTION_FIELDS = [
    "action", "server", "rewrite_ttl", "disable_cache", "disable_optimistic_cache",
    "client_subnet", "timeout"
];

function server_list(settings, key, fallback) {
    let result = [];
    for (let value in list_option(settings, key)) {
        value = trim(as_string(value));
        if (value != "")
            push(result, value);
    }
    if (length(result) == 0)
        push(result, fallback);
    return result;
}

function detour_tag(settings) {
    if (!bool_option(settings, "dns_detour_enabled", false))
        return "";
    let section_name = option(settings, "dns_detour_section", "");
    return section_name == "" ? "" : runtime_constants.outbound_tag(section_name);
}

function duration_milliseconds(value) {
    let rest = as_string(value);
    let total = 0.0;
    let units = { ns: 0.000001, us: 0.001, ms: 1, s: 1000, m: 60000, h: 3600000, d: 86400000 };
    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return 0;
        total += (matched[1] * 1) * units[matched[3]];
        rest = substr(rest, length(matched[0]));
    }
    return int(total + 0.5);
}

// How long one server may take before the query moves on to the next one.
function query_timeout(settings) {
    let value = option(settings, "dns_query_timeout", DEFAULT_QUERY_TIMEOUT);
    return duration_milliseconds(value) > 0 ? value : DEFAULT_QUERY_TIMEOUT;
}

function server_from_options(tag_name, dns_type, dns_server, detour) {
    let server = runtime_url.host(dns_server);
    let port = runtime_url.port(dns_server);
    let result = {
        type: "udp",
        tag: tag_name,
        server,
        server_port: 53
    };

    if (dns_type == "udp") {
        if (port != "")
            result.server_port = int(port, 10);
    }
    else if (dns_type == "dot") {
        result.type = "tls";
        result.server_port = port != "" ? int(port, 10) : 853;
    }
    else if (dns_type == "doh") {
        result.type = "https";
        result.server_port = port != "" ? int(port, 10) : 443;
        let path = runtime_url.path(dns_server);
        if (path != "")
            result.path = path;
    }
    else {
        return { unsupported: "unsupported dns_type " + dns_type };
    }

    if (!core_ip.valid_ip(server))
        result.domain_resolver = runtime_constants.BOOTSTRAP_DNS_SERVER_TAG;
    if (as_string(detour) != "")
        result.detour = as_string(detour);

    return result;
}

function bootstrap_server(tag_name, value) {
    let server = runtime_url.host(value);
    let port = runtime_url.port(value);
    return {
        type: "udp",
        tag: tag_name,
        server: server != "" ? server : value,
        server_port: port != "" ? int(port, 10) : 53
    };
}

function item_tag(base_tag, index_value) {
    return base_tag + "-" + as_string(index_value + 1);
}

// sing-box-extended's fallback server tries its servers in order and moves on
// after a timeout or an error reply; it serves lookups that bypass DNS rules.
function fallback_server(tag_name, tags, timeout) {
    return {
        type: "fallback",
        tag: tag_name,
        servers: tags,
        strategy: "sequential",
        timeout: as_string(duration_milliseconds(timeout) * length(tags)) + "ms"
    };
}

// features.fallback_server: the core has sing-box-extended's fallback server.
// Returns the DNS servers and the main-server chain that client queries walk.
function config(settings, features) {
    features = features || {};
    let dns_type = option(settings, "dns_type", "udp");
    let detour = detour_tag(settings);
    let timeout = query_timeout(settings);
    let main_servers = server_list(settings, "dns_server", "77.88.8.8");
    let bootstrap_servers = server_list(settings, "bootstrap_dns_server", "77.88.8.8");
    let servers = [];
    let chain = [];

    if (length(bootstrap_servers) > 1 && features.fallback_server) {
        let tags = [];
        for (let i = 0; i < length(bootstrap_servers); i++) {
            push(tags, item_tag(runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, i));
            push(servers, bootstrap_server(tags[i], bootstrap_servers[i]));
        }
        push(servers, fallback_server(runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, tags, timeout));
    }
    else {
        push(servers, bootstrap_server(runtime_constants.BOOTSTRAP_DNS_SERVER_TAG, bootstrap_servers[0]));
    }

    if (length(main_servers) > 1) {
        for (let i = 0; i < length(main_servers); i++) {
            let server = server_from_options(item_tag(runtime_constants.DNS_SERVER_TAG, i), dns_type, main_servers[i], detour);
            if (server.unsupported)
                return { unsupported: server.unsupported };
            push(servers, server);
            push(chain, server.tag);
        }
    }

    // Lookups that skip DNS rules, like proxy addresses, use the main tag
    // directly; without the fallback server it is the first server alone.
    let main = length(chain) > 1 && features.fallback_server
        ? fallback_server(runtime_constants.DNS_SERVER_TAG, chain, timeout)
        : server_from_options(runtime_constants.DNS_SERVER_TAG, dns_type, main_servers[0], detour);
    if (main.unsupported)
        return { unsupported: main.unsupported };
    push(servers, main);

    return { servers, chain, timeout };
}

// A reply is kept when the server answered NOERROR without a blocking address;
// an A query also needs an address. Anything else, NXDOMAIN included, moves on.
function good_response_rule() {
    return {
        type: "logical",
        mode: "and",
        rules: [
            { match_response: true, response_rcode: "NOERROR" },
            { match_response: true, ip_cidr: BLOCKED_ADDRESSES, invert: true },
            {
                type: "logical",
                mode: "or",
                rules: [
                    { query_type: "A", invert: true },
                    { match_response: true, ip_accept_any: true }
                ]
            }
        ]
    };
}

function rule_parts(rule) {
    let matchers = {};
    let options = {};
    for (let key, value in rule) {
        if (index(ACTION_FIELDS, key) >= 0) {
            if (key != "action" && key != "server")
                options[key] = value;
        }
        else {
            matchers[key] = value;
        }
    }
    return { matchers, options };
}

function with_fields(target, fields) {
    for (let key, value in fields)
        target[key] = value;
    return target;
}

// One rule that routes to the main server becomes: ask each server in turn,
// keep a good reply, and let the last server answer whatever it says.
function chain_rules(rule, chain, timeout) {
    let parts = rule_parts(rule);
    let has_matchers = length(keys(parts.matchers)) > 0;
    let result = [];

    for (let i = 0; i < length(chain) - 1; i++) {
        push(result, with_fields(with_fields({}, parts.matchers), with_fields(with_fields({}, parts.options), {
            action: "evaluate",
            server: chain[i],
            timeout
        })));

        let respond = good_response_rule();
        if (has_matchers)
            respond.rules = [ with_fields({}, parts.matchers), ...respond.rules ];
        respond.action = "respond";
        push(result, respond);
    }

    push(result, with_fields(with_fields(with_fields({}, parts.matchers), parts.options), {
        action: "route",
        server: chain[length(chain) - 1]
    }));
    return result;
}

// Expands every route to the main server, and the final fallback, into the chain.
function expand_chain(dns, chain, timeout) {
    if (length(chain) < 2)
        return;

    let rules = [];
    for (let rule in dns.rules) {
        if (rule.action == "route" && rule.server == runtime_constants.DNS_SERVER_TAG)
            push(rules, ...chain_rules(rule, chain, timeout));
        else
            push(rules, rule);
    }
    if (dns.final == runtime_constants.DNS_SERVER_TAG)
        push(rules, ...chain_rules({ action: "route", server: runtime_constants.DNS_SERVER_TAG }, chain, timeout));
    dns.rules = rules;
}

function default_domain_resolver(settings) {
    return bool_option(settings, "dns_detour_enabled", false)
        ? runtime_constants.BOOTSTRAP_DNS_SERVER_TAG
        : runtime_constants.DNS_SERVER_TAG;
}

return {
    DEFAULT_QUERY_TIMEOUT,
    config,
    default_domain_resolver,
    detour_tag,
    duration_milliseconds,
    expand_chain,
    query_timeout,
    server_from_options,
    server_list
};
