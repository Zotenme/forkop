"""Opt-in ARM64 real-core comparison; never installs anything on a router."""

import argparse
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import tarfile
import threading
import time
import urllib.request


# Published release-asset SHA256 values, not hashes of the extracted binaries.
ASSETS = {
    "tiny": (
        "ushan0v/sing-box-forkop", "v1.14.4-r1",
        "sing-box-forkop_1.14.4-r1_tiny_aarch64_cortex-a53.ipk",
        "d8ee6e2a4dae8c3e9b65d879f23b16b0d5b2cbd043f806b071577dcbb1245f9f",
    ),
    "extended": (
        "shtorm-7/sing-box-extended", "v1.14.3-extended-2.7.3",
        "sing-box-1.14.3-extended-2.7.3-linux-arm64.tar.gz",
        "da50f003ee172ba048068145c6d07db5cc6f1202831a358be549a5f2bb1975a6",
    ),
    "compressed": (
        "shtorm-7/sing-box-extended", "v1.14.3-extended-2.7.3",
        "sing-box-1.14.3-extended-2.7.3-linux-arm64-compressed.tar.gz",
        "21d90e197a2523b74016fda0f770ae874eeb4e1aca99d3956b160f41380306eb",
    ),
}
UUID = "00000000-0000-4000-8000-000000000001"
LIB = Path("/repo/forkop/files/usr/lib")


def download(repo, tag, name, target, expected):
    if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != expected:
        url = f"https://github.com/{repo}/releases/download/{tag}/{name}"
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "forkop-core-benchmark"})
            with urllib.request.urlopen(request, timeout=90) as response:
                data = response.read()
        except OSError:
            api = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
            request = urllib.request.Request(api, headers={"User-Agent": "forkop-core-benchmark"})
            with urllib.request.urlopen(request, timeout=60) as response:
                release = json.load(response)
            asset = next(a for a in release["assets"] if a["name"] == name)
            request = urllib.request.Request(asset["url"], headers={
                "User-Agent": "forkop-core-benchmark", "Accept": "application/octet-stream",
            })
            with urllib.request.urlopen(request, timeout=90) as response:
                data = response.read()
        if hashlib.sha256(data).hexdigest() != expected:
            raise RuntimeError(f"SHA256 mismatch: {name}")
        target.write_bytes(data)
    return target.read_bytes()


def extract_binary(data, packaged=False):
    # Read only the required regular member; never extract archive paths.
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        if packaged:
            member = next(m for m in archive if m.isfile() and Path(m.name).name == "data.tar.gz")
            return extract_binary(archive.extractfile(member).read())
        for member in archive:
            if member.isfile() and Path(member.name).name == "sing-box":
                stream = archive.extractfile(member)
                magic = stream.read(4)
                if magic == b"\x7fELF":
                    return magic + stream.read()
        raise RuntimeError("archive contains no sing-box ELF executable")


def status(pid):
    try:
        lines = Path(f"/proc/{pid}/status").read_text().splitlines()
        return {k: int(v.split()[0]) for line in lines if ":" in line
                for k, v in [line.split(":", 1)]
                if k in ("VmRSS", "VmHWM", "RssAnon", "RssFile", "RssShmem")}
    except (FileNotFoundError, ProcessLookupError):
        return {}


def memory_events():
    path = Path("/sys/fs/cgroup/memory.events")
    return dict(line.split() for line in path.read_text().splitlines()) if path.exists() else {}


def measured(command, directory, name, daemon=None, timeout=60):
    metrics = directory / f"{name}.time"
    log = directory / f"{name}.log"
    # GNU time obtains the short-lived child's peak RSS via wait4, without
    # missing decompression peaks between /proc samples.
    peak_sum = 0
    with log.open("w") as output:
        process = subprocess.Popen([
            "/usr/bin/time", "-f", "%M %e", "-o", str(metrics), "--", *map(str, command),
        ], stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                if daemon is not None:
                    children_file = Path(f"/proc/{process.pid}/task/{process.pid}/children")
                    try:
                        children = [int(pid) for pid in children_file.read_text().split()]
                    except FileNotFoundError:
                        children = []
                    peak_sum = max(peak_sum, sum(status(pid).get("VmRSS", 0)
                                                for pid in [daemon.pid, *children]))
                if time.monotonic() > deadline:
                    raise TimeoutError(f"{name} exceeded {timeout}s")
                time.sleep(0.005)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, 9)
                process.wait()
    fields = metrics.read_text().splitlines()[-1].split()
    return {"exit_code": process.returncode, "max_rss_kib": int(fields[0]),
            "elapsed_seconds": float(fields[1]),
            "sampled_daemon_plus_child_rss_kib": peak_sum if daemon else None}


def fixture(directory, xhttp=False):
    transport = "&security=tls&type=xhttp&sni=example.org" if xhttp else "&security=none&type=tcp"
    return {
        "settings": {
            ".name": "settings", ".type": "settings", "dns_type": "udp",
            "dns_server": ["1.1.1.1", "8.8.8.8"],
            "bootstrap_dns_server": ["1.1.1.1", "8.8.8.8"],
            "cache_path": str(directory / "cache.db"),
        },
        "section": [{
            ".name": "proxy", ".type": "section", "enabled": "1", "action": "connection",
            "selector_proxy_links": [f"vless://{UUID}@127.0.0.1:18443?encryption=none{transport}#Local"],
            "domain_suffix": ["example.org"],
            "mixed_proxy_enabled": "1", "mixed_proxy_port": "18080",
        }],
    }


def router_fixture(directory):
    """Representative user profile; masked values replaced with local test data."""
    value = fixture(directory)
    value["settings"].update(dns_type="doh", dns_strategy="ipv4_only", dns_query_timeout="1s")
    value["section"][0]["source_ip_cidr"] = ["192.168.1.2/32"]
    value["section"][0]["domain_suffix"] = []
    public_key = "YXpxegYjFaofqWRKziq7cVqtSDxr2CQkhQLbz8OV2yE"
    link = (f"vless://{UUID}@127.0.0.1:18443?encryption=none&security=reality"
            f"&sni=example.org&fp=chrome&pbk={public_key}&sid=aabbccdd&flow=xtls-rprx-vision&type=tcp")
    value["section"][0]["selector_proxy_links"] = []
    nodes = []
    for name in ("SE-01", "SE-02", "SE-03", "US-01"):
        nodes.append(json.dumps({"type": "vless", "tag": name, "server": "127.0.0.1", "server_port": 18443,
                                "uuid": UUID, "flow": "xtls-rprx-vision", "tls": {
                                    "enabled": True, "server_name": "example.org",
                                    "utls": {"enabled": True, "fingerprint": "chrome"},
                                    "reality": {"enabled": True, "public_key": public_key, "short_id": "aabbccdd"}}}))
    value["section"][0]["outbound_jsons"] = nodes
    def url(name):
        return "http://127.0.0.1:18081/" + name + ".srs"
    value["section"] = [
        {".name": "dns", ".type": "section", "enabled": "1", "action": "dns",
         "dns_type": "doh", "dns_server": "dns.example.org/dns-query",
         "domain_suffix": ["dns.example.org"], "rule_set": [url("geosite-category-ru")]},
        {".name": "youtube", ".type": "section", "enabled": "1", "action": "connection",
         "selector_proxy_links": [link + "#YouTube"], "rule_set": [url("youtube"), url("telegram")]},
        {".name": "bypass", ".type": "section", "enabled": "1", "action": "bypass",
         "domain_suffix": ["example.org"], "ip_cidr": ["192.0.2.0/24"],
         "source_ip_cidr": ["192.168.1.3/32"],
         "rule_set": [url(n) for n in ("geosite-category-ru", "geosite-apple", "geosite-google")],
         "rule_set_with_subnets": [url("geoip-ru")]},
        *value["section"],
    ]
    return value


def generate(directory, name, features, xhttp=False, router_profile=False):
    source = directory / f"{name}.fixture.json"
    output = directory / f"{name}.json"
    source.write_text(json.dumps(router_fixture(directory) if router_profile and not xhttp else fixture(directory, xhttp)))
    env = dict(os.environ, FORKOP_LIB=str(LIB))
    subprocess.run([
        "ucode", "-L", str(LIB), str(LIB / "singbox/generator.uc"),
        "generate-config-fixture", str(source), str(output), "127.0.0.1", "0",
        str(features), "", "1.14.4",
    ], env=env, check=True, timeout=60, stdout=subprocess.DEVNULL)
    return output


class Handler(http.server.BaseHTTPRequestHandler):
    ruleset_dir = None

    def do_GET(self):
        body = b"forkop-vless-benchmark\n"
        if self.ruleset_dir and self.path.endswith(".srs"):
            path = self.ruleset_dir / Path(self.path).name
            if not path.is_file():
                self.send_error(404)
                return
            body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def runtime(binary, config, ruleset, directory, idle_seconds, reality=False):
    # Add a local VLESS peer to the generated config. Its connections go
    # direct; the section's mixed inbound routes through the VLESS outbound.
    data = json.loads(config.read_text())
    data["inbounds"].append({"type": "vless", "tag": "benchmark-peer", "listen": "127.0.0.1",
                             "listen_port": 18443, "users": [{"uuid": UUID}]})
    data["route"]["rules"].insert(0, {"inbound": "benchmark-peer", "action": "route", "outbound": "direct-out"})
    tls_peer = None
    tls_log = None
    if reality:
        pair = subprocess.check_output([str(binary), "generate", "reality-keypair"], text=True, timeout=30)
        keys = dict(line.split(": ", 1) for line in pair.strip().splitlines())
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
            "-nodes", "-keyout", str(directory / "test.key"), "-out", str(directory / "test.crt"),
            "-days", "1", "-subj", "/CN=example.org",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        tls_log = (directory / "tls-peer.log").open("w")
        tls_peer = subprocess.Popen([
            "openssl", "s_server", "-accept", "127.0.0.1:18444", "-cert", str(directory / "test.crt"),
            "-key", str(directory / "test.key"), "-tls1_3", "-quiet", "-www",
        ], stdout=tls_log, stderr=tls_log)
        for _ in range(50):
            try:
                with socket.create_connection(("127.0.0.1", 18444), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.1)
        peer = data["inbounds"][-1]
        peer["users"][0]["flow"] = "xtls-rprx-vision"
        peer["tls"] = {"enabled": True, "server_name": "example.org", "reality": {
            "enabled": True, "handshake": {"server": "127.0.0.1", "server_port": 18444},
            "private_key": keys["PrivateKey"], "short_id": ["aabbccdd"],
        }}
        for outbound in data["outbounds"]:
            if outbound["type"] == "vless":
                outbound["server"] = "127.0.0.1"
                outbound["server_port"] = 18443
                outbound["flow"] = "xtls-rprx-vision"
                outbound["tls"] = {"enabled": True, "server_name": "example.org",
                                   "utls": {"enabled": True, "fingerprint": "chrome"},
                                   "reality": {"enabled": True, "public_key": keys["PublicKey"], "short_id": "aabbccdd"}}
    path = directory / "runtime.json"
    path.write_text(json.dumps(data))
    result = {}
    with (directory / "daemon.log").open("w") as log:
        started = time.monotonic()
        daemon = subprocess.Popen([str(binary), "run", "-c", str(path)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 30
            while True:
                if daemon.poll() is not None:
                    raise RuntimeError("daemon exited before readiness; see daemon.log")
                try:
                    with urllib.request.urlopen("http://127.0.0.1:9090/version", timeout=0.2) as response:
                        result["clash_version"] = json.load(response)
                    result["ready_seconds"] = round(time.monotonic() - started, 3)
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        raise TimeoutError("Clash API readiness timed out")
                    time.sleep(0.1)
            time.sleep(idle_seconds)
            result["idle_status_kib"] = status(daemon.pid)
            for _ in range(20):
                response = subprocess.check_output([
                    "curl", "--silent", "--show-error", "--fail", "--max-time", "5",
                    "--noproxy", "", "--proxy", "http://127.0.0.1:18080", "http://127.0.0.1:18081/",
                ], timeout=10)
                if response != b"forkop-vless-benchmark\n":
                    raise RuntimeError("VLESS round-trip response mismatch")
            result["vless_reality_vision_round_trips" if reality else "vless_tcp_round_trips"] = 20
            result["after_traffic_status_kib"] = status(daemon.pid)
            for command in ("version", "decompile"):
                args = [binary, "version"] if command == "version" else [
                    binary, "rule-set", "decompile", ruleset, "-o", directory / "decompiled.json",
                ]
                result[f"concurrent_{command}"] = measured(args, directory, f"concurrent-{command}", daemon)
            result["daemon_survived"] = daemon.poll() is None
            result["final_status_kib"] = status(daemon.pid)
        finally:
            if daemon.poll() is None:
                daemon.terminate()
                try:
                    daemon.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait()
            result["daemon_exit_code"] = daemon.returncode
            if tls_peer is not None:
                tls_peer.terminate()
                tls_peer.wait(timeout=10)
                tls_log.close()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=ASSETS, required=True)
    parser.add_argument("--output", type=Path, default=Path("/results"))
    parser.add_argument("--config", type=Path, help="check an additional config; never run it")
    parser.add_argument("--ruleset", type=Path, help="use a real SRS instead of synthetic subnets")
    parser.add_argument("--idle-seconds", type=float, default=5)
    parser.add_argument("--reality", action="store_true", help="test local Reality + Vision + uTLS handshake")
    parser.add_argument("--router-profile", type=Path, help="model the user profile with six real SRS files served from this directory")
    options = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() not in ("aarch64", "arm64"):
        parser.error("run in a native linux/arm64 Docker container")
    directory = options.output.resolve() / options.variant
    directory.mkdir(parents=True, exist_ok=True)
    report = {"variant": options.variant, "platform": platform.platform(), "checks": {}}
    report["cgroup_memory_events_before"] = memory_events()
    server = None
    try:
        repo, tag, name, sha = ASSETS[options.variant]
        archive = directory / name
        data = download(repo, tag, name, archive, sha)
        binary = directory / "sing-box"
        binary.write_bytes(extract_binary(data, packaged=name.endswith(".ipk")))
        binary.chmod(0o755)
        report.update(archive_bytes=len(data), binary_bytes=binary.stat().st_size,
                      asset_sha256=sha, release=tag)
        del data
        report["checks"]["version"] = measured([binary, "version"], directory, "version")
        ruleset = options.ruleset.resolve() if options.ruleset else directory / "subnets.srs"
        if not options.ruleset:
            source = directory / "subnets.json"
            source.write_text(json.dumps({"version": 3, "rules": [{"ip_cidr": [
                f"10.{n // 256}.{n % 256}.1/32" for n in range(16384)
            ]}]}))
            report["checks"]["compile"] = measured([
                binary, "rule-set", "compile", source, "-o", ruleset,
            ], directory, "compile")
        report["ruleset_sha256"] = hashlib.sha256(ruleset.read_bytes()).hexdigest()
        report["ruleset_source"] = "user-supplied" if options.ruleset else "synthetic-16384-ipv4-subnets"
        if options.router_profile:
            Handler.ruleset_dir = options.router_profile.resolve()
            files = ["geosite-category-ru.srs", "youtube.srs", "telegram.srs", "geosite-apple.srs", "geosite-google.srs", "geoip-ru.srs"]
            report["profile_rulesets_sha256"] = {
                name: hashlib.sha256((Handler.ruleset_dir / name).read_bytes()).hexdigest() for name in files
            }
        # features=0 models current stock-core detection; features=1 models
        # recognizing the candidate core's extended DNS/XHTTP capabilities.
        for label, features, xhttp in [("current-detection", 0, False), ("candidate", 1, False), ("xhttp", 1, True)]:
            config = generate(directory, label, features, xhttp, bool(options.router_profile))
            report["checks"][label] = measured([binary, "check", "-c", config], directory, label)
        if options.config:
            report["checks"]["user-config"] = measured([
                binary, "check", "-c", options.config.resolve(),
            ], directory, "user-config")
        if report["checks"]["candidate"]["exit_code"] == 0:
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 18081), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            report["runtime"] = runtime(binary, directory / "candidate.json", ruleset, directory, options.idle_seconds, options.reality)
        else:
            raise RuntimeError("generated config rejected; see candidate.log")
        report["passed"] = all(check["exit_code"] == 0 for check in report["checks"].values())
        report["passed"] &= report["runtime"]["daemon_survived"] and all(
            report["runtime"][f"concurrent_{name}"]["exit_code"] == 0 for name in ("version", "decompile")
        )
    except Exception as error:
        report.update(passed=False, error=str(error))
    finally:
        if server:
            server.shutdown()
            server.server_close()
        report["cgroup_memory_events_after"] = memory_events()
        (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2), flush=True)
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
