# Real-core ARM64 experiment

Opt-in comparison of `sing-box-extended 1.14.3-extended-2.7.3` (ordinary and
UPX compressed) and `sing-box-forkop 1.14.4-r1 tiny`. This does not change
Forkop's installed-core detection, installer, updater or router configuration.
It is a compatibility experiment, not an assertion that tiny is supported.

The release downloads are pinned by SHA256. Only the executable is extracted;
OpenWrt package installation hooks are never executed. Runs need Internet for
the downloads, but the VLESS traffic test is entirely on loopback.

From the repository root on a Docker host with native ARM64 Linux containers:

```sh
docker build --load -t forkop-ci tests/docker
docker build --load -t forkop-core-benchmark tests/benchmarks
mkdir -p .build/core-benchmark
docker run --rm --platform linux/arm64 --cap-add NET_ADMIN \
  --memory 256m --memory-swap 256m \
  -v "$PWD":/repo:ro -v "$PWD/.build/core-benchmark":/results \
  forkop-core-benchmark --variant tiny
docker run --rm --platform linux/arm64 --cap-add NET_ADMIN \
  --memory 256m --memory-swap 256m \
  -v "$PWD":/repo:ro -v "$PWD/.build/core-benchmark":/results \
  forkop-core-benchmark --variant extended
docker run --rm --platform linux/arm64 --cap-add NET_ADMIN \
  --memory 256m --memory-swap 256m \
  -v "$PWD":/repo:ro -v "$PWD/.build/core-benchmark":/results \
  forkop-core-benchmark --variant compressed
```

With OrbStack and a selected `docker-container` buildx builder, use
`docker build --builder orbstack --load ...` for both image builds so the second
build can resolve the local `forkop-ci` image instead of trying Docker Hub.
Use `--name forkop-bench-<variant>` instead of `--rm` to retain completed
containers and their logs. Inspect them with `docker ps -a --filter name=forkop-bench`.

The capability is required for the generated TPROXY listeners and socket marks.
Ports are not published to the host. No host networking or privileged container
is needed. Repeat with `--memory 128m --memory-swap 128m` to investigate pressure;
this is the entire container budget, including the Python controller, not the
RAM available to sing-box on a 128/256 MB router. A killed container can leave
an incomplete report; preserve its output/exit code, do not interpret that as
a passing measurement. Emulated ARM64 on x86 cannot give reliable native timing
or memory comparisons.

Each variant writes `report.json`, generated configs, command logs, downloaded
archive and extracted binary to its own directory under `.build/core-benchmark`.
A rejected config or failed round trip causes a nonzero exit. Results include:

- Package/archive size and extracted executable size, separately. Neither is
  the actual compressed flash allocation on a router's filesystem.
- `version`, rule-set compilation and `check` peak RSS / elapsed time from GNU
  time, including short-lived process peaks that polling can miss.
- Checks against the current Forkop generator, both its present stock-core
  detection mode and an explicit extended-capabilities mode. The latter tests
  config compatibility; it does not implement automatic detection in Forkop.
- An XHTTP config check. This checks parsing only, not an XHTTP handshake.
  By default the runtime smoke test uses unencrypted VLESS/TCP on loopback.
  Append `--reality` for actual local Reality/Vision/uTLS handshakes against a
  test VLESS peer and an OpenSSL TLS 1.3 camouflage server. All keys and the
  self-signed certificate are generated for this test, not production use.
- Clash API readiness, idle and post-traffic `/proc` memory, 20 HTTP requests
  through the generated mixed inbound and VLESS outbound to a local VLESS peer.
- Additional `version` and `.srs` decompilation processes while the main core
  remains running, and whether the daemon survives.

`sampled_daemon_plus_child_rss_kib` is a sampled sum of RSS, which can count
shared pages twice and miss brief peaks. It is not PSS or a container memory
peak. `max_rss_kib` is the helper's own kernel-recorded peak. These measurements
do not cover nftables list import, DNS load, production connections, a long-term
memory leak, OpenWrt/procd lifecycle or update/rollback behavior. Different core
versions also mean the comparison cannot isolate UPX as the sole variable
between extended and tiny.

By default the decompilation test uses a deterministic synthetic list of 16,384
IPv4 subnets. To reproduce the router's input, place the actual `geoip-ru.srs`
in `.build/core-benchmark/geoip-ru.srs` and append:

```sh
--ruleset /results/geoip-ru.srs
```

The input checksum is recorded. The actual OOM involved Forkop extracting
subnets into nftables, so decompilation alone cannot reproduce all its costs.

An anonymized router config can be checked by placing it at
`.build/core-benchmark/router.json` and appending:

```sh
--config /results/router.json
```

It is passed only to `sing-box check`, never `run`. Referenced files must also
exist at the paths visible inside the container. Logs/config artifacts may still
contain values from this file, so use an anonymized copy.

## Representative router profile

Append `--router-profile /results/rulesets --reality` to model the configuration
supplied in the discussion: five VLESS outbounds, two selectors, Reality/Vision,
source-aware DNS, two main and two bootstrap DNS servers, and six binary rule
sets. Put these actual files in `.build/core-benchmark/rulesets` first:

- `geosite-category-ru.srs`
- `youtube.srs`
- `telegram.srs`
- `geosite-apple.srs`
- `geosite-google.srs`
- `geoip-ru.srs`

The harness records their SHA256 values and serves them over local HTTP. Names,
addresses and keys replace the masked user values. All VLESS outbounds target
the local test peer; the test is not a literal replay of the user's config.
DNS rule acceptance is checked, but live public DoH/DNS fallback is not tested.
Use `--output /results/router-profile` to keep this separate from the simple run.

## Execution status

Executed on 2026-11-17 in native ARM64 OrbStack containers. See [RESULTS.md](RESULTS.md)
for measured values, OOM evidence, scope and saved report locations. Tiny and full
extended passed the router profile at 256 MiB; compressed hit OOM. Tiny also
passed at 128 MiB. The experiment itself does not install anything on a router. Core selection is now implemented separately in the application.
