# Accepted baselines

One JSON file per test type (`smoke.json`, `load.json`, `soak.json`, ...), recorded
from a run whose thresholds passed:

```powershell
pwsh -File scripts/compare-summary.ps1 -Current results/latest.txt -Baseline baselines/load.json -Update
```

`-Update` copies `summary.json` here and refuses to do so if the run's thresholds
failed. The `meta.json` of that run is copied next to it as `meta.json`, so the
baseline can be traced back to the image and git revision that produced it - a
baseline with no provenance is barely better than no baseline.

These files are meant to be committed. Compare a new run against one with:

```powershell
pwsh -File scripts/compare-summary.ps1 -Current results/latest.txt -Baseline baselines/load.json
```

It exits non-zero when latency, TTFB, error rate or throughput regressed beyond
`-TolerancePercent` (default 10%), or when thresholds that used to pass now fail.

A baseline is only meaningful for the configuration it was recorded under. If you
change the CPU limits, the replica count, the data volume or the endpoint, record a
new baseline rather than comparing across the change.
