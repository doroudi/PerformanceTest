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
| `scripts/rate-test.js` | a FIXED offered rate (open model): the only profile that can compare 1 pod vs 3 |
| `scripts/journey-test.js` | a multi-step user flow: log in, then several endpoints, each measured separately |
| `scripts/lib/auth.js` | token fetch/cache/refresh for authenticated targets |
| `scripts/lib/users.js` | a pool of accounts, one per virtual user (round robin, stable per VU) |
| `scripts/lib/profiles.js` | the load shapes (steady, load, stress, spike) the journey can run under |
| `scripts/lib/env.js` | env parsing; `TARGET_URL` is required and has no default |
| `scripts/lib/summary.js` | the machine-readable summary the runners parse |
| `tests/summary.test.mjs` | `node k6/tests/summary.test.mjs` - checks the summary library |
| `tests/users.test.mjs` | `node k6/tests/users.test.mjs` - checks pool parsing and assignment |
| `tests/profiles.test.mjs` | `node k6/tests/profiles.test.mjs` - checks the load shapes |
| `tests/journey-pool.test.mjs` | `node k6/tests/journey-pool.test.mjs` - runs the journey with k6 stubbed, asserting each VU logs in as its own account |
| `users.example.json` | copy to `users.json` (gitignored) for a pool of accounts |
| `Dockerfile` | the generator image used by cluster runs, k6 tag pinned |
| `docker-compose.yml` | k6 + Prometheus + Grafana + a demo target |
| `prometheus-config.yml` | Prometheus config; the remote-write receiver is what matters |
| `grafana/provisioning/` | datasource + dashboard provider, mounted into Grafana |
| `grafana/dashboards/` | **k6 load test** (the report) and **k6 ingestion check** (the diagnostic) |
| `run-test.ps1` / `run-test.sh` | run a scenario against the compose stack |
| `run-journey.ps1` | the multi-step journey: prompts for the password, always skips the preflight |
| `run-auth-test.ps1` | any single-endpoint type against an authenticated target; refuses to run if auth is unconfigured |
| `.env.example` | copy to `k6\.env` for the login URL, account and token settings |

The cluster equivalents live one directory up and are listed here only so the two paths
are not confused: `../scripts/run-cluster-test.ps1` (interactive: build, deploy,
preflight, run, Grafana link) and `../scripts/deploy-and-test.ps1` (the non-interactive
runner both it and CI use).

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

### The same scenarios, in the cluster

Everything in `scripts/` also runs as a Kubernetes Job, and the cluster path has its
own front door:

```powershell
pwsh -File scripts/run-cluster-test.ps1 -TestType load -TargetPath /api/new-core/wallets -DryRun
pwsh -File scripts/run-cluster-test.ps1 -TestType load -TargetPath /api/new-core/wallets
```

The scenarios are baked into the `k6` image from `k6/Dockerfile` (which copies
`k6/scripts` to `/scripts`), so it is the *same files* on both paths - there is no
second copy of a scenario to keep in step. What differs is where the generator runs,
and that the API then sits under the CPU and memory limits you asked for, which is the
only way a pod's capacity can be measured. `scripts/run-cluster-test.ps1` reads
`k6\.env` for the login details, puts the credential-shaped values into a Kubernetes
Secret, and prints the in-cluster Grafana link for the run.

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

Every scenario gets authentication without changing the scenario file:
`buildRequestHeaders()` in `scripts/lib/env.js` merges a token from `scripts/lib/auth.js`
into the request headers, once per iteration. Leave all of it unconfigured and nothing
changes, so unauthenticated targets keep working exactly as before.

Three ways, in ascending order of how much they buy you:

| Mode | Configure | Renews? |
|---|---|---|
| Static header | `REQUEST_HEADERS=Authorization: Bearer eyJ...` | no |
| OAuth2 | `AUTH_MODE=oauth2` + `AUTH_TOKEN_URL` + client credentials | yes |
| Bespoke JSON login | `AUTH_MODE=json-login` + `LOGIN_URL` + account | yes |

**A static token expires mid-run**, and every request after that is a 401 - which reads as
the service collapsing rather than the test having lost its credentials. Both fetching modes
renew before expiry, which is what makes an authenticated **soak** possible.

### `AUTH_MODE=json-login`, for first-party identity APIs

Plenty of in-house identity APIs are not OAuth2 at all: they take `application/json`, have
no grant types, and answer with the token nested somewhere in the body. The OAuth2 path
cannot talk to them - wrong content type, wrong grant types, wrong response shape - so this
mode does:

```ini
AUTH_MODE=json-login
LOGIN_URL=https://idp.example.com/accounts/login
JOURNEY_USERNAME=someone@example.com
JOURNEY_PASSWORD=...
```

| Variable | Default | Purpose |
|---|---|---|
| `AUTH_MODE` | `oauth2` | `oauth2`, `json-login`, or `off` |
| `AUTH_TOKEN_URL` | | OAuth2 token endpoint |
| `AUTH_CLIENT_ID` / `AUTH_CLIENT_SECRET` | | OAuth2 client credentials |
| `AUTH_GRANT_TYPE` | `client_credentials` | or `password` |
| `AUTH_USERNAME` / `AUTH_PASSWORD` | fall back to `JOURNEY_*` | password grant, or json-login |
| `AUTH_LOGIN_URL` | falls back to `LOGIN_URL` | json-login endpoint |
| `AUTH_TOKEN_PATH` | `data.accessToken` | where the token sits in the JSON response |
| `AUTH_LOGIN_BODY` | see below | JSON body template, with `{{username}}`/`{{password}}` substituted |
| `AUTH_EXPIRES_IN` | `300` | lifetime for an **opaque** token; a JWT's own `exp` always wins |
| `AUTH_SCOPE` / `AUTH_AUDIENCE` | | OAuth2 only |
| `AUTH_TOKEN_HEADER` | `Authorization` | for APIs that use a custom header |
| `AUTH_TOKEN_PREFIX` | `Bearer ` | set empty for a bare token |
| `AUTH_EXPIRY_SKEW` | `30` | seconds of safety margin before real expiry |

The default login body is `{"Email":"{{username}}","Password":"{{password}}","RememberMe":true}`.
Set `AUTH_LOGIN_BODY` for an endpoint that wants different field names or extra fields. For a
JWT the token's own `exp` is decoded and used, so renewal follows the real lifetime rather
than a guess.

**`AUTH_MODE=off`** disables the mechanism whatever else is set. `run-journey.ps1` uses it:
the journey logs in once in `setup()`, so leaving this on would add a redundant login per VU
on top of that.

### Credentials come from `k6/.env`

Both runners read `k6/.env`, then `<repo>/.env`; `-EnvFile` names one explicitly. `-EnvVars`
overrides the file, so one run can change a single knob without editing it. Copy
`k6/.env.example` to start - and keep `k6/.env` gitignored, because it holds a password.
Credential-shaped values are redacted from `meta.json`, so the file remains the only place a
secret is written down.

### The runner that refuses to run blind

```powershell
pwsh -File k6/run-auth-test.ps1 -TestType load `
  -TargetUrl https://api.example.com/api/new-core/wallets -Vus 20 -Duration 2m
```

A protected endpoint answers **401 to every request**, which k6 records as a *fast* run at a
100% failure rate with no error anywhere - the request succeeded, it just said no. So this
wrapper checks that it can see how authentication is configured and **refuses to start**
otherwise, then passes `-SkipPreflight`, which is mandatory for every authenticated type
except `smoke`: the preflight sends an unauthenticated request and stops the run with exit
code 2. It also warns when the only configured mechanism is a static header that cannot be
renewed.

`REQUEST_HEADERS` wins on a name collision, so an explicitly supplied header always beats an
inferred one.

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

One more thing that only bites a **cluster** run: the identity provider's hostname may not
be resolvable from inside the cluster at all (measured here: CoreDNS timing out against
Docker Desktop's resolver for `tc-idp-api.nt-development.dev`, while the host resolved it
fine). The login then fails with `lookup <host> on <ip>:53: server misbehaving` and every
request is a 401 before one is even sent. Pass `-ResolveHost <host>` to
`scripts/deploy-and-test.ps1` - it resolves the name on your machine and pins it into the
Job's `/etc/hosts` - or let `scripts/run-cluster-test.ps1` do it, which pins the target and
`LOGIN_URL` for you. See the main README, "Testing an endpoint that needs authorization".

## A multi-step user journey

`journey-test.js` measures a real flow rather than one endpoint: it logs in, then
requests several URLs in sequence, and reports **each step separately**.

```powershell
# Recommended. Prompts for the password (never echoed, never in shell history), always
# skips the preflight, and refuses a production-looking host by default.
pwsh -File k6/run-journey.ps1 `
  -TargetUrl https://api.example.com `
  -LoginUrl  https://idp.example.com/accounts/login `
  -Username  someone@example.com `
  -Vus 5 -Duration 1m

# Equivalent, if you would rather drive the generic runner directly.
pwsh -File k6/run-test.ps1 -TestType journey `
  -TargetUrl https://api.example.com -SkipPreflight `
  -EnvVars 'LOGIN_URL=https://idp.example.com/accounts/login,JOURNEY_USERNAME=someone@example.com,JOURNEY_PASSWORD=***,TARGET_VUS=5,TEST_DURATION=1m'
```

**`-SkipPreflight` is required here, and that is not optional.** The preflight sends an
unauthenticated smoke request to `-TargetUrl`; an API that needs a token answers 401, so
the preflight concludes "not one request succeeded" and stops the run with exit code 2
before the journey ever starts. The preflight is genuinely useful for an anonymous
target and actively wrong for an authenticated one.

`-TargetUrl` is the API base: `API_BASE_URL` falls back to it, so the host the runner
validates, preflights and records in `meta.json` is the host the journey actually talks
to. Set `API_BASE_URL` only when the API base and the recorded target must differ.

| Variable | Default | Purpose |
|---|---|---|
| `JOURNEY_USERNAME` / `JOURNEY_PASSWORD` | **required, no default** | the account the journey logs in as |
| `LOGIN_URL` | **required, no default** | JSON login endpoint returning `data.accessToken` |
| `API_BASE_URL` | falls back to `TARGET_URL` | base for the step URLs |
| `KYC_STEP_PATH` / `WALLETS_PATH` / `REQUESTS_ACTIVE_PATH` | `/api/new-core/...` | the steps |
| `STEP_PAUSE` | `0` | think time between steps |
| `TARGET_VUS` / `TEST_DURATION` / `REQUEST_PAUSE` | `5` / `1m` / `0.5` | load profile |

There are deliberately **no fallbacks for the login URL or the account**. A built-in
login URL lets a run appear to work against an environment nobody chose, and a password
written into a scenario file is a password in git.

**Credentials are redacted from the artefacts.** `meta.json` records the run's environment
so a result can be reproduced, but any variable whose *name* looks like a credential - or
whose *value* does (`REQUEST_HEADERS=Authorization: Bearer ...`, a JSON login body) - is
stored as `***REDACTED***`. The key is kept, so you can still see that a password was
supplied; only the value is replaced. This applies to both runners. The one place a
credential still appears verbatim is `results/<run>/k6-job.yaml` for a **cluster** run,
because that file is the exact manifest that was applied - which is why cluster credentials
belong in a Kubernetes Secret (`envFrom`/`secretKeyRef`) rather than in `-EnvVars`.

### What load shape it applies

`steady` by default: `setup()` logs in once, then every VU repeats the steps for
`TEST_DURATION` at a constant VU count. It is a **closed, VU-based** model in every profile —
not a ramp, and not a fixed rate.

```powershell
pwsh -File k6/run-journey.ps1 -Profile stress -EnvVars STEP_VUS=10,STRESS_STEPS=4,STEP_DURATION=1m
pwsh -File k6/run-journey.ps1 -Profile load   -Vus 30 -EnvVars RAMP_DURATION=1m,HOLD_DURATION=5m
```

| `JOURNEY_PROFILE` | shape | knobs |
|---|---|---|
| `steady` | constant | `TARGET_VUS`, `TEST_DURATION` |
| `load` | ramp, hold, ramp down | `TARGET_VUS`, `RAMP_DURATION`, `HOLD_DURATION` |
| `stress` | stepped plateaus, then 0 | `STEP_VUS`, `STRESS_STEPS`, `STEP_DURATION` |
| `spike` | baseline, spike, recovery | `BASELINE_VUS`, `SPIKE_VUS`, `BASELINE_DURATION`, `SPIKE_DURATION` |
| `rate` | a FIXED offered rate (open model) | `TARGET_RPS`, `TEST_DURATION`, `PREALLOCATED_VUS`, `MAX_VUS` |
| `rate-ramp` | a FIXED offered rate rising in steps, then 0 | the above + `RATE_STEPS`, `STEP_DURATION` |

The first four are **closed**: offered load **falls** when the target slows down, because each
VU waits for its own response before sending the next request. So they cannot answer "does one
pod beat three" (that needs a fixed offered rate), and they cannot push a server that is
already struggling. `rate` and `rate-ramp` offer a fixed number of iterations per second
whatever the target does, which is the shape to use to load a server - and the one where
`dropped_iterations` matters, since a dropped iteration is load that was never offered.

In `stress` and `spike` the per-step thresholds are *meant* to be crossed, so the failure gate
is loosened and does not abort. In `steady` it aborts on the first failed requests, so a
broken login costs seconds instead of the whole profile.

### Adding a step

One line in the `STEPS` table near the top of the file:

```js
{ name: "statements", path: envString("STATEMENTS_PATH", "/statements"), p95: 2500 },
```

The request, its per-step metric, its threshold and its console row are generated from that
entry — nothing else to edit, and no step can be added without being named and measured.
Paths are relative to the base URL you configure, so a base of `https://host/api/new-core`
makes `/kyc/step` resolve to `…/api/new-core/kyc/step`, and each step's `<STEP>_PATH` variable
can still override it on its own.

### Running it as many users instead of one

```powershell
# k6/users.json (gitignored; k6/users.example.json is the template):
#   [{"username":"a@example.com","password":"..."}, {"username":"b@example.com","password":"..."}]
pwsh -File k6/run-journey.ps1 -Vus 30 -Duration 5m
```

With a pool, each VU authenticates as its own account - no `JOURNEY_USERNAME`, no password
prompt - and each request is tagged `account=user-01`, `user-02`, ... so a slow outlier
account is visible rather than averaged away. The pool is passed to k6 as
`JOURNEY_USERS_JSON` and never through `-EnvVars` (which splits on commas and would take the
JSON apart). `-UsersFile` names a file explicitly; otherwise `k6\users.json` is used when it
exists, and `JOURNEY_USERS_FILE` in the `.env` file also works.

**Each step is tagged**, which is the whole point. The console summary and
`summary.json` both break latency down per step, and each step has its own threshold,
so a journey can fail because `/wallets` is slow while the other steps pass:

```
  per step (ms, slowest first):
    login                  avg 591   p95 591   p99 591   max 591
    kyc-step               avg 283   p95 391   p99 410   max 415
    wallets                avg 275   p95 311   p99 318   max 320
    requests-active        avg 249   p95 261   p99 262   max 262
```

Three things worth knowing:

- **The login runs once, in `setup()`.** The load you generate is the steps you meant
  to measure, not four VUs' worth of authentication. That is safe only because the
  token outlives the run - the scenario decodes the JWT and logs its expiry at
  start-up, and warns if it is under five minutes. For a run longer than the token's
  life, move `login()` into the default function (it is exported for exactly that).
- **`discardResponseBodies: true` would eat the token.** The login sets
  `responseType: "text"` for that one request. Without it the POST returns 200 and
  looks healthy while every iteration fails to parse an empty body.
- **Credentials come from the environment, never from the file.** Locally pass them
  with `-EnvVars`; in Kubernetes inject them from a Secret into the k6 Job.

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
