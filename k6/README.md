# k6 scenarios and the local stack

The main guide is in the [repository README](../README.md) - read that first. This
file only covers what lives in this directory.

## What is here

| Path | Purpose |
|---|---|
| `scripts/smoke-test.js` | 1-2 VUs, <1 min: proves the script and target work |
| `scripts/load-test.js` | ramp to expected peak and hold: the release baseline |
| `scripts/stress-test.js` | stepped plateaus to and past failure: find the knee |
| `scripts/spike-test.js` | baseline -> sharp spike -> baseline: absorb and recover |
| `scripts/soak-test.js` | hours at 60-80% of peak: leaks, pools, drift |
| `scripts/lib/env.js` | env parsing; `TARGET_URL` is required and has no default |
| `scripts/lib/summary.js` | the machine-readable summary the runners parse |
| `tests/summary.test.mjs` | `node k6/tests/summary.test.mjs` - checks the summary library |
| `Dockerfile` | the generator image used by cluster runs, k6 tag pinned |
| `docker-compose.yml` | k6 + Prometheus + Grafana + a demo target |
| `prometheus-config.yml` | Prometheus config; the remote-write receiver is what matters |
| `grafana/provisioning/` | datasource + dashboard provider, mounted into Grafana |
| `grafana/dashboards/` | **k6 load test** (the report) and **k6 ingestion check** (the diagnostic) |
| `run-test.ps1` / `run-test.sh` | run a scenario against the compose stack |

## Quick start

```powershell
# 1. Bring the stack up and generate load against the built-in demo target.
pwsh -File k6/run-test.ps1 -TargetUrl http://demo-target:80/ -TestType smoke `
  -EnvVars TARGET_VUS=4,TEST_DURATION=30s

# 2. Now point the same thing at your own API. It must be reachable FROM a
#    container, so host.docker.internal rather than localhost.
pwsh -File k6/run-test.ps1 -TargetUrl http://host.docker.internal:5180/healthz -TestType load `
  -EnvVars TARGET_VUS=50,RAMP_DURATION=1m,HOLD_DURATION=5m
```

At the end of every run the runner prints a **Grafana link already zoomed to that
run's window**. Use it - it is the difference between "Grafana is broken" and "I was
looking at the wrong time range" (see below).

### The demo target

`demo-target` is a `traefik/whoami` container that is always up, so you can answer
"is the kit broken, or is my API broken?" in one command:

```powershell
pwsh -File k6/run-test.ps1 -TargetUrl http://demo-target:80/ -TestType smoke
```

It answers any path with a small JSON document, which makes it a realistic JSON
endpoint. It is reachable from the host at <http://127.0.0.1:8081/> and from k6 at
`http://demo-target:80/`.

**It is not a performance model of anything.** A green run against it proves the
generator, the metrics pipeline and the dashboards work, and nothing about your
system's capacity. (On this machine it happens to show ~200ms p95 at 8 VUs, which
is Docker Desktop's networking, not a measurement of anything.)

## Testing an API that runs on your machine (not in Docker)

This is the normal case and it needs no changes to your application.

**k6 runs in a container; the API it tests does not have to.** Your API can be any
process on your machine - `dotnet run`, node, IIS Express, a Windows service. The
only thing that differs is the host name: use `host.docker.internal`, not `localhost`.

```powershell
# you would browse to http://localhost:5180/healthz
# k6 must use:
pwsh -File k6/run-test.ps1 -TargetUrl http://host.docker.internal:5180/healthz -TestType smoke
```

The runner refuses a `localhost`/`127.0.0.1` target and prints that exact corrected
URL, because the failure it prevents is silent: inside the k6 container `localhost`
is the k6 container, so every request is rejected in ~2ms and a full load test can
"pass" while measuring nothing at all.

### Two different "do not use localhost" rules

They are easy to conflate, so:

| What | Use | Not |
|---|---|---|
| **The target** (`-TargetUrl`) | `http://host.docker.internal:<port>/path` | `localhost` / `127.0.0.1` - that is the k6 container |
| **Viewing Grafana / Prometheus** | `http://127.0.0.1:3000`, `http://127.0.0.1:9090` | `localhost` - Docker Desktop's IPv6 proxy hangs |

### Does my API need to bind 0.0.0.0?

On Docker Desktop, **no** - even a service bound only to `127.0.0.1` is reachable,
because Docker Desktop proxies `host.docker.internal` into the host's loopback.
Verified on this machine with a server bound to `127.0.0.1` only (`netstat`
confirmed no `0.0.0.0` listener):

| From | URL | Result |
|---|---|---|
| host | `http://127.0.0.1:<port>/` | works |
| k6 container | `http://host.docker.internal:<port>/` | **works** |
| k6 container | `http://127.0.0.1:<port>/` | fails - that is the container itself |

A service started by `dotnet run` normally listens on `127.0.0.1` and `[::1]` only.
That is fine here. On **native Linux Docker** it is not: `host.docker.internal`
resolves to the bridge gateway, where a loopback-bound socket is invisible, so the
app must also bind `0.0.0.0` (`ASPNETCORE_URLS=http://+:5180`). The runner detects
which host you are on and says so in its error message.

### One thing that will still fail

A local API on **HTTPS with a self-signed certificate**. k6 rejects untrusted
certificates and the runner has no switch for it yet - ask and it can be added.

## How metrics reach Grafana

```
k6 --(Prometheus remote write)--> Prometheus --(query)--> Grafana
```

Four things have to be true, and when Grafana is empty it is almost always one of
the last two:

1. **k6 must have an output enabled.** `K6_PROMETHEUS_RW_SERVER_URL` only says *where*
   to send. On its own it does nothing at all: the run succeeds and writes no
   metrics, with no error to explain the empty dashboards. The output is enabled once,
   as `K6_OUT=experimental-prometheus-rw` in `docker-compose.yml`, so every
   `docker compose run` gets it - including a manual one. Do not also pass `--out` on
   the command line: k6 appends outputs, so you would push every sample twice.
2. **Prometheus must accept remote writes.** It needs
   `--web.enable-remote-write-receiver`, and, because k6 pushes trends as native
   histograms, `--enable-feature=native-histograms` as well. Both are set in the
   compose command.
3. **Grafana must have exactly one datasource.** Nothing is provisioned implicitly:
   an empty `grafana/provisioning/` means Grafana starts with **no datasource**, and
   every panel renders empty even when Prometheus is full of data. A *second*,
   hand-added Prometheus datasource with an empty URL is just as bad - check
   <http://127.0.0.1:3000/connections/datasources> and delete any extra.
4. **The time range must cover the run.** This is the one that catches people.
   k6 writes samples *only while the test runs*. Once it stops, an instant query at
   "now" matches nothing, so a finished run looks exactly like a broken pipeline.
   The dashboard's default range is deliberately wide (`now-3h`) and the runner
   prints a link pinned to the exact run window.

## Reading the dashboard

Two dashboards are provisioned into the `perf-test-kit` folder:

| Dashboard | Use |
|---|---|
| **k6 load test** (`k6-load-test`) | The report: load profile, RPS, latency percentiles, failures, checks, throughput, where the request time went |
| **k6 ingestion check** (`perf-kit-ingest-check`) | The diagnostic: is *any* k6 data arriving at all |

Filters at the top: `run (testid)` (one entry per run, `All` overlays runs) and
`test type`. Every run is tagged `testid=<utc timestamp>-<type>` and
`test_type=<type>`.

### Latency: two modes, and why it matters

The latency panels prefer native histograms:

```promql
histogram_quantile(0.95, sum(rate(k6_http_req_duration_seconds{...}[$__rate_interval]))) * 1000
```

If native histograms are off, each panel falls back with PromQL `or` to k6's gauge
statistics (`k6_http_req_duration_p95`). **Those two are not equivalent, and the
gauges are the worse one.** Measured on a real 40-second run:

| Mode | `http_req_duration` p95 across 67 samples | What it means |
|---|---|---|
| Gauges | `0.0243` flat, for every sample | **Cumulative** over the run. It converges in seconds and then never moves again. |
| Native histograms | `52.56, 131.79, 198.43, 202.95, 204.09, ...` | A true **per-interval** percentile. |

A flat latency line in gauge mode is **not** evidence that latency was flat. In
particular, a spike five minutes into a two-hour soak is invisible in gauge mode -
and that drift is the entire point of a soak. That is why native histograms are the
default here.

To change modes, set `K6_PROMETHEUS_RW_TREND_AS_NATIVE_HISTOGRAM` in
`docker-compose.yml`; the matching `TREND_STATS` value takes over when it is `false`.

## Load testing an authenticated target

Every scenario gets authentication without changing the scenario file: `buildRequestHeaders()`
in `scripts/lib/env.js` merges a token from `scripts/lib/auth.js` into the request headers.
Leave it unconfigured and nothing changes, so unauthenticated targets keep working as before.

**Static token** - fine for a short run:

```powershell
-EnvVars 'REQUEST_HEADERS=Authorization: Bearer eyJhbGciOi...'
```

**Fetched and refreshed token** - OAuth2 client credentials, or password grant for a
dedicated test user:

```powershell
-EnvVars 'AUTH_TOKEN_URL=https://idp.example.com/connect/token,AUTH_CLIENT_ID=my-client,AUTH_CLIENT_SECRET=***,AUTH_SCOPE=api'
```

| Variable | Default | Purpose |
|---|---|---|
| `AUTH_TOKEN_URL` | *(unset = auth off)* | token endpoint |
| `AUTH_CLIENT_ID` / `AUTH_CLIENT_SECRET` | | client credentials |
| `AUTH_GRANT_TYPE` | `client_credentials` | or `password` |
| `AUTH_USERNAME` / `AUTH_PASSWORD` | | password grant only |
| `AUTH_SCOPE` | | space separated |
| `AUTH_AUDIENCE` | | sent as `audience` |
| `AUTH_TOKEN_HEADER` | `Authorization` | for APIs that use a custom header |
| `AUTH_TOKEN_PREFIX` | `Bearer ` | set empty for a bare token |
| `AUTH_EXPIRY_SKEW` | `30` | seconds of safety margin before real expiry |

**Why the second mode exists.** A static token expires mid-run, and every request after
that is a 401 - which reads as the service collapsing rather than the test having lost its
credentials. The fetched-token mode renews before expiry, so a run of any length keeps
working. That is what makes an authenticated **soak** possible.

`REQUEST_HEADERS` wins on a name collision, so an explicitly supplied header always beats
an inferred one. Scenarios call `buildRequestHeaders()` per iteration precisely so a
renewed token is picked up; it is cheap, because the static headers are parsed once at
module load and the token comes from a cache.

### Two things that will bite you

- **The token cache is per-VU.** k6 gives every VU its own JavaScript runtime, so 50 VUs
  make 50 token requests, all at roughly the same instant when the run starts. Normally
  harmless, but if your identity provider rate-limits its token endpoint you will notice
  here first. Mitigations, best first: ramp fewer VUs simultaneously, raise
  `AUTH_EXPIRY_SKEW` so tokens live longer, or fetch once in `setup()` via
  `fetchTokenForSetup()` and hand the token to the VUs with `authHeadersFromToken()`.
- **`discardResponseBodies: true` discards the token response too.** The scenarios set
  that option so the generator's memory is not what is under test. The token request
  overrides it with `responseType: "text"` - if you write your own token call, do the
  same, or `JSON.parse` receives an empty body and every iteration fails with a
  misleading "could not be parsed as JSON" while the token POST looks perfectly healthy
  in the metrics. This caught the module during development; the symptom to recognise is
  `checks: total: 0` in `summary.json`.

Never commit a token or a client secret. Pass them as environment variables locally, and
in Kubernetes inject them into the k6 Job from a Secret rather than into the manifest.

## Running locally

```powershell
pwsh -File k6/run-test.ps1 -TargetUrl http://host.docker.internal:5000/api/health -TestType smoke
```

Add scenario knobs with `-EnvVars TARGET_VUS=20,TEST_DURATION=2m`.

`-EnvVars` accepts the comma-separated form under **both** invocation styles. That is
worth stating because it used to be false: `pwsh -File` does not split on commas the
way an in-process call does, so the README's own example delivered
`TARGET_VUS=20,HOLD_DURATION=5m` as a *single* value and k6 failed with
`TARGET_VUS must be a non-negative number, but got "20,HOLD_DURATION=5m"`. Both
runners now parse it through `ConvertTo-PerfTestEnvTable`.

| What | Where |
|---|---|
| The report | <http://127.0.0.1:3000/d/k6-load-test> |
| Is data arriving at all? | <http://127.0.0.1:3000/d/perf-kit-ingest-check> |
| Raw k6 metrics | <http://127.0.0.1:9090/graph> - `count by (__name__) ({__name__=~"k6_.*"})` |
| The demo target | <http://127.0.0.1:8081/> |

Single runs can be isolated in PromQL:

```promql
sum(rate(k6_http_reqs_total{testid="20261001-084131-load"}[1m]))
```

### Use `127.0.0.1`, never `localhost`

Docker Desktop publishes these ports on IPv6 as well, and its IPv6 proxy does not
answer on at least this machine. Measured:

| URL | Result |
|---|---|
| `http://127.0.0.1:9090` | answers immediately |
| `http://localhost:9090` | **times out** |
| `http://[::1]:9090` | **times out** |

A browser eventually falls back to IPv4 and appears to work, which is why this hid
for so long; PowerShell, curl and health checks just hang. All published ports are
now bound to `127.0.0.1` and every documented URL uses it. That also keeps Grafana -
which runs with anonymous admin - off every network interface.

`localhost` inside the k6 **container** is the container itself. To reach a service on
your machine from compose, use `http://host.docker.internal:<port>`. The runner
**refuses** a `localhost`/`127.0.0.1` target outright (`-AllowLocalhostTarget` is the
escape hatch): the failure it causes is silent, because every request is rejected in
about 2ms and a whole load test can pass with nothing but "connection refused" in it.

## First local run

Start with `smoke`, which is over in under a minute. The longer profiles use their
scenario defaults, which are sized for real environments, not a laptop:

| Test | Default duration | Quick local override |
|---|---|---|
| `smoke` | 1m | *(already short)* |
| `load` | 12m (1m ramp + 10m hold + 1m down) | `-EnvVars RAMP_DURATION=10s,HOLD_DURATION=30s` |
| `stress` | 4 plateaus x 2m | `-EnvVars STEP_DURATION=15s,STRESS_STEPS=2,STEP_VUS=5` |
| `spike` | ~2m | `-EnvVars BASELINE_DURATION=10s,SPIKE_DURATION=20s,SPIKE_VUS=50` |
| `soak` | 2h+ | `-EnvVars RAMP_DURATION=10s,HOLD_DURATION=60s` |

Interrupting a run (Ctrl+C) means no `summary.json` and no `meta.json` - only the
partial `k6.log`. Long tests get their artefacts when they finish or abort.

`smoke`, `load` and `soak` also abort early on their own: if more than 1% of requests
have failed 10-30 seconds in, k6 stops the run and reports it, instead of hammering an
unreachable target for twelve minutes. That is `abortOnFail` in the scenario
thresholds. `stress` and `spike` deliberately do not have it, because failures there
are the finding.

Local runs are for making a scenario work. They are not capacity measurements: the
generator and the target share one machine. Use
`scripts/deploy-and-test.ps1` for numbers you intend to act on.

## Gotchas in this stack

- **`restart` does not re-read `docker-compose.yml`.** A container created from an
  older version of the file keeps its old mounts and flags forever. Only
  `up -d --force-recreate` rebuilds a container from the current file. Confirm what
  the running container actually has mounted:

  ```powershell
  docker inspect (docker compose -f k6/docker-compose.yml ps -q grafana) `
    --format '{{range .Mounts}}{{.Source}} => {{.Destination}}{{"\n"}}{{end}}'
  ```

  It must show `...\k6\grafana\provisioning => /etc/grafana/provisioning`.
- **A provisioned dashboard lands in the `perf-test-kit` folder**, not in the root
  dashboard list. Provisioning failures are reported in Grafana's own log:

  ```powershell
  docker compose -f k6/docker-compose.yml logs --tail 60 grafana
  Invoke-RestMethod 'http://127.0.0.1:3000/api/search?type=dash-db' | Select-Object title, folderTitle, uid
  ```

  (Grafana also logs two harmless startup errors about `provisioning/plugins` and
  `provisioning/alerting` not existing. Those directories are optional; ignore them.)
- **The generator version is pinned in two places and they must match.**
  `docker-compose.yml` and `k6/Dockerfile` are both on **k6 1.3.0**. A different
  generator version is a different experiment, so bump them together.
- **The output name is the same on both lines.** `experimental-prometheus-rw` is
  accepted by k6 0.54.0 *and* 1.3.0 - verified by asking both images to list their
  output types. An earlier version of this file claimed 1.x had renamed it; it had
  not, and moving the pin needed no output-name change.
- **A tag set in a scenario's `options.tags` does not reach Prometheus.** Measured:
  a run whose scenario sets `tags: { test_type: "smoke" }` produced k6 series with a
  `testid` label and **no** `test_type` label, while the same tag passed as a CLI
  `--tag test_type=probe` arrived as `test_type="probe"`. Both runners therefore pass
  `test_type` on the command line. If you add a tag that dashboards depend on, add it
  to the runner, not to `options.tags`.
- **`k6.log` contains k6's errors too.** The runner merges stderr into the log
  (`2>&1`), because k6 writes `level=error` lines - including remote-write push
  failures - to stderr while the summary goes to stdout. If a run looks clean but
  Grafana is empty, read the log before assuming anything about the network.
- **`gracefulStop` must not be set in `options`.** It is a CLI flag
  (`--graceful-stop`), and its default of 30s is what the scenarios want anyway.
- **Storage is local to the volumes.** Prometheus keeps 7 days
  (`--storage.tsdb.retention.time=7d`); `docker compose down -v` discards it, and with
  it every comparison to a past run.
- **Grafana runs with anonymous admin.** Fine because the port is now bound to
  loopback only, not something to expose by re-publishing it on `0.0.0.0`.
