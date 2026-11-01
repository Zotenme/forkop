#!/usr/bin/env ucode

// Checks a DNS server from the router before it is saved, for the DNS tab.

let fs = require("fs");
let common = require("core.common");
let core_ip = require("core.ip");
let url = require("core.url");

let as_string = common.as_string;
let write_json = common.write_json;

const CHECK_DOMAIN = getenv("FORKOP_DNS_CHECK_DOMAIN") || "example.com";
const CHECK_TIMEOUT = getenv("FORKOP_DNS_CHECK_TIMEOUT") || "3";
const PROTOCOLS = [ "udp", "dot", "doh" ];

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_output(args) {
    let pipe = fs.popen(command_from_args(args) + " 2>&1", "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    pipe.close();
    return data == null ? "" : as_string(data);
}

// The host ends up in a dig argument, so only plain names and addresses pass.
function valid_host(host) {
    return core_ip.valid_ip(host) ||
        match(host, /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/) != null;
}

function valid_port(port) {
    return port == "" || (match(port, /^[0-9]{1,5}$/) != null && int(port, 10) >= 1 && int(port, 10) <= 65535);
}

function requested_protocols(value) {
    let result = [];
    for (let protocol in split(as_string(value), ","))
        if (index(PROTOCOLS, protocol) >= 0 && index(result, protocol) < 0)
            push(result, protocol);
    return length(result) ? result : PROTOCOLS;
}

function resolve_with_bootstrap(host, bootstrap) {
    let output = command_output([
        "dig", "+short", "+time=" + CHECK_TIMEOUT, "+tries=1", "@" + bootstrap, host, "A"
    ]);
    for (let line in split(output, "\n")) {
        line = trim(line);
        if (core_ip.valid_ipv4(line))
            return line;
    }
    return "";
}

function dig_args(protocol, host, port, path) {
    let args = [ "dig", "+noall", "+comments", "+answer", "+stats", "+time=" + CHECK_TIMEOUT, "+tries=1" ];
    // +tls-ca verifies the certificate the way sing-box does.
    if (protocol == "dot")
        push(args, "+tls", "+tls-ca");
    else if (protocol == "doh")
        push(args, path != "" ? "+https=" + path : "+https", "+tls-ca");
    if (port != "")
        push(args, "-p", port);
    push(args, "@" + host, CHECK_DOMAIN, "A");
    return args;
}

// dig prints nothing at all when a TLS handshake fails, so only a header counts as a reply.
function parse_reply(output) {
    let status = match(output, /status: ([A-Z]+)/);
    if (status == null) {
        if (match(output, /timed out/) != null)
            return { ok: false, error: "timeout" };
        if (match(output, /couldn't get address/) != null)
            return { ok: false, error: "host_not_found" };
        return { ok: false, error: "no_response" };
    }
    if (status[1] != "NOERROR")
        return { ok: false, error: lc(status[1]) };

    let address = "";
    for (let line in split(output, "\n")) {
        let record = match(line, /\sIN\s+A\s+([0-9.]+)\s*$/);
        if (record != null) {
            address = record[1];
            break;
        }
    }
    if (address == "")
        return { ok: false, error: "empty_answer" };

    let time = match(output, /Query time: ([0-9]+) msec/);
    return { ok: true, ms: time != null ? int(time[1], 10) : null, address };
}

function check_server(server, protocols, bootstrap) {
    server = trim(as_string(server));
    bootstrap = trim(as_string(bootstrap));

    let host = url.host(server);
    let port = url.port(server);
    if (host == "" || !valid_host(host) || !valid_port(port)) {
        write_json({ success: false, server, error: "invalid_server" });
        return 1;
    }
    if (bootstrap != "" && !core_ip.valid_ip(bootstrap)) {
        write_json({ success: false, server, error: "invalid_bootstrap" });
        return 1;
    }

    let result = { success: true, server, host, results: {} };

    // sing-box finds a server given by name through the bootstrap servers.
    if (!core_ip.valid_ip(host) && bootstrap != "") {
        result.resolved = resolve_with_bootstrap(host, bootstrap);
        result.bootstrap_ok = result.resolved != "";
    }

    let path = url.path(server);
    for (let protocol in requested_protocols(protocols))
        result.results[protocol] = parse_reply(command_output(dig_args(protocol, host, port, path)));

    write_json(result);
    return 0;
}

let mode = ARGV[0] || "";
if (mode == "check")
    exit(check_server(ARGV[1], ARGV[2], ARGV[3]));

warn("Usage: dns/check.uc check <server> [protocols] [bootstrap]\n");
exit(1);
