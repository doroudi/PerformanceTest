# k6 scenarios and the local authoring stack

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
| `docker-compose.yml` | local k6 + Prometheus + Grafana (authoring only) |
| `prometheus-config.yml` | Prometheus config; the remote-write receiver is what matters |
| `grafana/provisioning/` | datasource + dashboard provider, mounted into Grafana |
| `grafana/dashboards/` | dashboards loaded from file (currently the ingestion check) |
| `run-test.ps1` / `run-test.sh` | run a scenario against the compose stack |

## How metrics reach Grafana

```
k6 --(Prometheus remote write)--> Prometheus --(query)--> Grafana
```

Three things have to be true, and when Grafana is empty it is almost always the
first one:

1. **k6 must have an output enabled.** `K6_PROMETHEUS_RW_SERVER_URL` only says *where*
   to send. On its own it does nothing at all: the run succeeds and writes no
   metrics, with no error to explain the empty dashboards. The output is enabled once,
   as `K6_OUT=experimental-prometheus-rw` in `docker-compose.yml`, so every
   `docker compose run` gets it - including a manual one. Do not also pass `--out` on
   the command line: k6 appends outputs, so you would push every sample twice.
2. **Prometheus must accept remote writes.** It needs
   `--web.enable-remote-write-receiver` (already set in the compose command).
3. **Grafana must have a datasource.** Nothing is provisioned implicitly: an empty
   `grafana/provisioning/` means Grafana starts with **no datasource**, and every
   panel renders empty even when Prometheus is full of data.
   `grafana/provisioning/datasources/prometheus.yml` fixes that, and
   `grafana/provisioning/dashboards/dashboards.yml` loads JSON dashboards from
   `grafana/dashboards/`.

Datasource provisioning is read when Grafana starts, so after changing it:

```powershell
docker compose -f k6/docker-compose.yml up -d --force-recreate grafana
```

## Running locally

```powershell
pwsh -File k6/run-test.ps1 -TargetUrl http://host.docker.internal:5000/api/health -TestType smoke
```

Add scenario knobs with `-EnvVars TARGET_VUS=20,TEST_DURATION=2m`.

| What | Where |
|---|---|
| Is data arriving at all? | <http://localhost:3000/d/perf-kit-ingest-check> |
| Raw k6 metrics | <http://localhost:9090/graph> - `count by (__name__) ({__name__=~"k6_.*"})` |
| Full k6 panels | Import Grafana.com dashboard **19665**, pick the `prometheus` datasource |

The runner tags every run with `testid=<utc timestamp>-<type>`, so a single run can be
isolated in Grafana or PromQL:

```promql
sum(rate({__name__=~"k6_http_reqs.*", testid="20250101-120000-smoke"}[1m]))
```

`localhost` inside the k6 container is the container itself - to reach a service on
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
  older version of the file keeps its old mounts and flags forever, so Grafana can
  be running with no datasource provisioning and Prometheus without
  `--web.enable-remote-write-receiver`, with nothing erroring to say so. Only
  `up -d --force-recreate` rebuilds a container from the current file. Confirm what
  the running container actually has mounted:

  ```powershell
  docker inspect (docker compose -f k6/docker-compose.yml ps -q grafana) `
    --format '{{range .Mounts}}{{.Source}} => {{.Destination}}{{"\n"}}{{end}}'
  ```

  It must show `...\k6\grafana\provisioning => /etc/grafana/provisioning`. If it shows
  `k6\grafana-datasource.yaml` or `k6\grafana-dashboard.yaml` instead, the container
  predates the Prometheus migration - and because those two files have since been
  deleted, a plain `restart` of it now fails outright with a missing bind source.
  Recreate it.
- **A provisioned dashboard lands in the `perf-test-kit` folder**, not in the root
  dashboard list. Provisioning failures are reported in Grafana's own log:

  ```powershell
  docker compose -f k6/docker-compose.yml logs --tail 60 grafana
  Invoke-RestMethod 'http://localhost:3000/api/search?type=dash-db' | Select-Object title, folderTitle, uid
  ```
- **`k6.log` contains k6's errors too.** The runner merges stderr into the log
  (`2>&1`), because k6 writes `level=error` lines - including remote-write push
  failures - to stderr while the summary goes to stdout. If a run looks clean but
  Grafana is empty, read the log before assuming anything about the network.
- **`gracefulStop` must not be set in `options`.** On the pinned k6 0.54 it is an
  unknown option field and k6 warns and ignores it:
  `unknown fields in the options exported in the script ... unknown field "gracefulStop"`.
  It is a CLI flag (`--graceful-stop`), and its default of 30s is what the scenarios
  want anyway, so they do not set it. The warning only became visible once the
  runner started merging stderr into `k6.log`.
- **The k6 image tag and the output name are coupled.** `experimental-prometheus-rw`
  is correct for the k6 0.x line pinned in `docker-compose.yml`; k6 1.x renamed the
  output. Bump the tag and the output name in the same commit - a wrong name makes k6
  exit immediately rather than fail quietly. Note that `k6/Dockerfile` pins **1.3.0**
  for cluster runs: align local and cluster before comparing numbers, because a
  different generator version is a different experiment.
- **Storage is local to the volumes.** Prometheus keeps 7 days
  (`--storage.tsdb.retention.time=7d`); `docker compose down -v` discards it, and with
  it every comparison to a past run.
- **Grafana runs with anonymous admin enabled** on a published port. Fine on a laptop
  behind a firewall, not something to expose.
- **The two JSON dashboards in `k6/dashboards/` are InfluxDB-era** (InfluxQL queries
  and a `k6influxdb` datasource). They are no longer mounted, and cannot work against
  Prometheus. Kept only until you confirm you do not want them.
