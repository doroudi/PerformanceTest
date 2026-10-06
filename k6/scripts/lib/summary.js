/*
 * Machine-readable end-of-test summary.
 *
 * Why this exists: k6's console summary is for humans, and the in-cluster run
 * only leaves `kubectl logs` behind, so without this there is nothing to store,
 * diff, or gate on.
 *
 * How it travels: the JSON is printed to stdout between two markers. The
 * runners (scripts/deploy-and-test.ps1, k6/run-test.ps1) cut it out of the log
 * and write it to results/<run>/summary.json. That works identically for
 * `docker compose run` and for a Kubernetes Job, needs no shared volume, no
 * sidecar and no object storage.
 *
 * Deliberately NOT using `k6 run --summary-export`: the file would live inside a
 * container that has already exited, so it cannot be collected without extra
 * machinery, and the flag has known regressions on current k6 builds.
 *
 * This module must stay free of k6 globals (no __ENV, no http) so it can be
 * unit-tested outside k6 - see the sanity check in the README.
 */

export const SUMMARY_SCHEMA = "perftest.summary/v1";

// Keep these two in sync with Get-K6SummaryFromText in
// scripts/lib/PerfTest.psm1 - the runners look for these exact lines.
export const SUMMARY_BEGIN = "===K6_SUMMARY_JSON_BEGIN===";
export const SUMMARY_END = "===K6_SUMMARY_JSON_END===";

// Rendered in this order, most useful first; any other metric is appended.
const METRIC_ORDER = [
  "http_req_duration",
  "http_req_waiting",
  "http_req_connecting",
  "http_req_blocked",
  "http_reqs",
  "http_req_failed",
  "checks",
  "iterations",
  "iteration_duration",
  // An arrival-rate scenario drops iterations when it runs out of VUs, and a dropped iteration
  // was never sent - so the run then looks like a target that coped perfectly. It has to be
  // visible in the human summary, next to the throughput it quietly reduces.
  "dropped_iterations",
  "vus_max",
  "data_received",
  "data_sent",
];

function round(value, digits) {
  if (typeof value !== "number" || !isFinite(value)) {
    return value === undefined ? null : value;
  }
  const factor = Math.pow(10, digits);
  return Math.round(value * factor) / factor;
}

function firstDefined() {
  for (let index = 0; index < arguments.length; index += 1) {
    if (arguments[index] !== undefined && arguments[index] !== null) {
      return arguments[index];
    }
  }
  return undefined;
}

/*
 * k6 hands each metric a `values` object: counters give {count, rate}, rates
 * give {rate, passes, fails}, gauges give {value, min, max} and trends give one
 * entry per requested summaryTrendStats name. Older k6 builds reported trend
 * stats as a positional array, so tolerate that too rather than throwing away
 * the whole summary.
 */
function readValues(metric) {
  if (!metric || metric.values === undefined || metric.values === null) {
    return null;
  }
  const values = metric.values;
  if (typeof values === "number") {
    return { value: values };
  }
  if (Array.isArray(values)) {
    const legacyOrder = ["avg", "min", "med", "max", "p(90)", "p(95)"];
    const mapped = {};
    for (let index = 0; index < values.length; index += 1) {
      const key = legacyOrder[index] || "stat_" + index;
      mapped[key] = values[index];
    }
    return mapped;
  }
  const copy = {};
  Object.keys(values).forEach(function (key) {
    copy[key] = values[key];
  });
  return copy;
}

function collectThresholds(metrics) {
  const detail = {};
  const failed = [];
  Object.keys(metrics).forEach(function (name) {
    const thresholds = metrics[name] && metrics[name].thresholds;
    if (!thresholds) {
      return;
    }
    Object.keys(thresholds).forEach(function (expression) {
      const ok = thresholds[expression] && thresholds[expression].ok === true;
      detail[name + ": " + expression] = ok;
      if (!ok) {
        failed.push(name + ": " + expression);
      }
    });
  });
  return { detail: detail, failed: failed, allOk: failed.length === 0 };
}

/*
 * k6 reports how long the test actually ran in the summary payload's `state`
 * block. Spellings have varied, so accept the known ones and treat anything
 * non-positive as "not reported" rather than pretending the run took 0 seconds.
 */
function readTestRunDurationMs(data) {
  const state = data && data.state;
  if (!state) {
    return null;
  }
  const candidates = [state.testRunDurationMs, state.testRunDurationMS];
  for (let index = 0; index < candidates.length; index += 1) {
    const value = candidates[index];
    if (typeof value === "number" && isFinite(value) && value > 0) {
      return value;
    }
  }
  return null;
}

function collectChecks(group, accumulator) {
  if (!group) {
    return accumulator;
  }
  if (Array.isArray(group.checks)) {
    group.checks.forEach(function (entry) {
      accumulator.push({
        name: entry.name,
        passes: entry.passes || 0,
        fails: entry.fails || 0,
      });
    });
  }
  if (Array.isArray(group.groups)) {
    group.groups.forEach(function (child) {
      collectChecks(child, accumulator);
    });
  }
  return accumulator;
}

export function buildSummary(data, meta) {
  const metrics = (data && data.metrics) || {};
  const available = Object.keys(metrics);

  const ordered = METRIC_ORDER.filter(function (name) {
    return available.indexOf(name) !== -1;
  }).concat(
    available
      .filter(function (name) {
        return METRIC_ORDER.indexOf(name) === -1;
      })
      .sort()
  );

  const normalized = {};
  ordered.forEach(function (name) {
    normalized[name] = readValues(metrics[name]);
  });

  const thresholdInfo = collectThresholds(metrics);
  const checkEntries = collectChecks(data && data.root_group, []);
  const checkPasses = checkEntries.reduce(function (total, entry) {
    return total + entry.passes;
  }, 0);
  const checkFails = checkEntries.reduce(function (total, entry) {
    return total + entry.fails;
  }, 0);

  // Timing comes from k6's own measurement, NOT from a `new Date()` captured in the
  // init context. Measured on a real 32-second run, an init-context Date and the
  // summary-time Date both read as the summary moment, so deriving the window from
  // them produced started_at == ended_at and a duration of 0. k6 re-evaluates the
  // script for the summary, so init-context wall-clock values cannot describe the
  // run. `state.testRunDurationMs` is reported by k6 itself and is correct.
  const endedAt = new Date().toISOString();
  const runDurationMs = readTestRunDurationMs(data);
  let durationSeconds = null;
  let startedAt = null;
  if (runDurationMs !== null) {
    durationSeconds = round(runDurationMs / 1000, 3);
    startedAt = new Date(Date.parse(endedAt) - runDurationMs).toISOString();
  }

  const summary = {
    schema: SUMMARY_SCHEMA,
    test_type: meta && meta.test_type ? meta.test_type : null,
    target_url: meta && meta.target_url ? meta.target_url : null,
    started_at: startedAt,
    ended_at: endedAt,
    duration_seconds: durationSeconds,
    thresholds_all_ok: thresholdInfo.allOk,
    threshold_count: Object.keys(thresholdInfo.detail).length,
    failed_thresholds: thresholdInfo.failed,
    thresholds: thresholdInfo.detail,
    checks: {
      total: checkEntries.length,
      passes: checkPasses,
      fails: checkFails,
      rate: checkPasses + checkFails > 0 ? round(checkPasses / (checkPasses + checkFails), 6) : null,
      detail: checkEntries,
    },
    metrics: normalized,
  };

  if (meta && meta.notes) {
    summary.notes = meta.notes;
  }

  return summary;
}

function formatNumber(value, digits, suffix) {
  if (value === null || value === undefined) {
    return "n/a";
  }
  if (typeof value !== "number") {
    return String(value) + (suffix || "");
  }
  const rendered = digits === 0 ? String(Math.round(value)) : value.toFixed(digits);
  return rendered + (suffix || "");
}

function printStats(lines, label, values, stats) {
  if (!values) {
    return;
  }
  stats.forEach(function (stat) {
    const raw = values[stat];
    if (raw === undefined || raw === null) {
      return;
    }
    const padded = stat.length < 6 ? stat + " ".repeat(6 - stat.length) : stat;
    lines.push("  " + label + " " + padded + ": " + formatNumber(raw, 2));
  });
}

/*
 * Per-step latency for a multi-step journey.
 *
 * A journey tags each request with `name`, which k6 keeps as a separate
 * http_req_duration{name:...} sub-metric. Without printing those here, the console
 * shows one blended average for the whole flow - and "which step got slower" is the
 * only question a journey exists to answer. The JSON always had this; the human
 * summary did not.
 *
 * Only `name:` tags are listed. k6 also emits http_req_duration{expected_response:...},
 * which is a correctness split rather than a step, and listing it here would just be
 * noise on every single-endpoint run.
 */
function printTaggedSteps(lines, metrics) {
  const pattern = /^http_req_duration\{name:(.+)\}$/;
  const steps = [];

  Object.keys(metrics).forEach(function (name) {
    const match = pattern.exec(name);
    if (match && metrics[name]) {
      steps.push({ name: match[1], values: metrics[name] });
    }
  });

  if (steps.length === 0) {
    return;
  }

  // Slowest first, so the step that needs attention is not hunted for.
  steps.sort(function (left, right) {
    const leftP95 = firstDefined(left.values["p(95)"], left.values.avg, 0);
    const rightP95 = firstDefined(right.values["p(95)"], right.values.avg, 0);
    return rightP95 - leftP95;
  });

  lines.push("");
  lines.push("  per step (ms, slowest first):");
  steps.forEach(function (step) {
    const padded = step.name.length < 22 ? step.name + " ".repeat(22 - step.name.length) : step.name;
    lines.push(
      "    " +
        padded +
        " avg " +
        formatNumber(step.values.avg, 0) +
        "   p95 " +
        formatNumber(step.values["p(95)"], 0) +
        "   p99 " +
        formatNumber(step.values["p(99)"], 0) +
        "   max " +
        formatNumber(step.values.max, 0)
    );
  });
}

export function renderText(summary) {
  const metrics = summary.metrics || {};
  const duration = metrics.http_req_duration;
  const waiting = metrics.http_req_waiting;
  const iterationDuration = metrics.iteration_duration;
  const requests = metrics.http_reqs;
  const failures = metrics.http_req_failed;
  const checks = summary.checks || {};
  const vusMax = metrics.vus_max;

  const lines = [];
  lines.push("");
  lines.push("perf-test-kit / " + (summary.test_type || "unknown") + " test");
  lines.push("  target          : " + (summary.target_url || "unknown"));
  if (summary.started_at) {
    lines.push(
      "  window          : " +
        summary.started_at +
        " -> " +
        (summary.ended_at || "?") +
        " (" +
        formatNumber(summary.duration_seconds, 1, "s") +
        ")"
    );
  }
  else {
    lines.push("  window          : ended " + (summary.ended_at || "?") + " (k6 did not report a run duration)");
  }

  if (requests) {
    lines.push(
      "  http_reqs       : " +
        formatNumber(requests.count, 0) +
        "  (" +
        formatNumber(requests.rate, 2, "/s") +
        ")"
    );
  }
  if (failures) {
    // Compute the failing count from the rate against the total request count.
    // k6's own passes/fails fields for this rate metric are inverted and confusing
    // (`passes` counts the samples that WERE failures), which used to print
    // "100.00% (0 failed)" - a self-contradicting line.
    const total = requests && typeof requests.count === "number" ? requests.count : null;
    const detail = total !== null
      ? "  (" + formatNumber(Math.round(total * (failures.rate || 0)), 0) + " of " + formatNumber(total, 0) + " requests)"
      : "";
    lines.push("  http_req_failed : " + formatNumber((failures.rate || 0) * 100, 2, "%") + detail);
  }
  if (checks.total > 0) {
    lines.push(
      "  checks          : " +
        formatNumber((checks.rate || 0) * 100, 2, "%") +
        "  (" +
        formatNumber(checks.passes, 0) +
        " passed / " +
        formatNumber(checks.fails, 0) +
        " failed)"
    );
  }
  if (vusMax) {
    lines.push("  vus_max         : " + formatNumber(firstDefined(vusMax.value, vusMax.max), 0));
  }

  /*
   * A dropped iteration is load the generator did not offer. k6 only reports it for
   * arrival-rate executors, and it is the difference between "the server coped" and "we never
   * asked the server" - so it is printed as a warning rather than a statistic, and only when
   * it happened.
   */
  const dropped = metrics.dropped_iterations;
  if (dropped && typeof dropped.count === "number" && dropped.count > 0) {
    lines.push(
      "  dropped_iters   : " +
        formatNumber(dropped.count, 0) +
        "  <- iterations the generator could NOT send (raise MAX_VUS, or lower the offered rate)"
    );
  }

  lines.push("");
  printStats(lines, "http_req_duration", duration, ["avg", "med", "p(90)", "p(95)", "p(99)", "max"]);
  printStats(lines, "http_req_waiting ", waiting, ["avg", "p(95)", "p(99)"]);

  /*
   * Iteration duration is the end-to-end time for ONE iteration of the scenario, and
   * for a multi-step journey that is the flow time the user actually experiences.
   * None of the per-request numbers above can answer it: a journey whose third step
   * got slower has a flow time that grew while every individual request still looks
   * acceptable, and a per-request p95 cannot show a step that was ADDED to the flow.
   *
   * It includes any think time the scenario sleeps (REQUEST_PAUSE/STEP_PAUSE), which
   * is deliberate: a closed-model flow is bounded by its own sleeps as much as by the
   * server, and seeing both numbers is how you tell which one bounds it.
   */
  printStats(lines, "iteration_duration", iterationDuration, ["avg", "med", "p(90)", "p(95)", "p(99)", "max"]);

  printTaggedSteps(lines, metrics);

  const thresholdNames = Object.keys(summary.thresholds || {});
  if (thresholdNames.length > 0) {
    lines.push("");
    lines.push(
      "  thresholds      : " +
        (summary.thresholds_all_ok ? "all passed" : "FAILED") +
        " (" +
        formatNumber(summary.threshold_count - summary.failed_thresholds.length, 0) +
        " passed / " +
        formatNumber(summary.failed_thresholds.length, 0) +
        " failed)"
    );
    thresholdNames.forEach(function (name) {
      lines.push("    " + (summary.thresholds[name] ? "PASS" : "FAIL") + "  " + name);
    });
  }

  const failedChecks = (checks.detail || []).filter(function (entry) {
    return entry.fails > 0;
  });
  if (failedChecks.length > 0) {
    lines.push("");
    lines.push("  failing checks:");
    failedChecks.forEach(function (entry) {
      lines.push(
        "    FAIL  " + entry.name + " (" + formatNumber(entry.fails, 0) + " failed)"
      );
    });
  }

  lines.push("");
  return lines.join("\n");
}

/*
 * Usage, at the bottom of a scenario file:
 *
 *   export const handleSummary = makeHandleSummary({
 *     test_type: "smoke",
 *     target_url: targetUrl,
 *   });
 *
 * Do not add a start timestamp captured in the init context: k6 re-evaluates the
 * script for the summary, so such a value describes the summary moment, not the
 * start of the run.
 */
export function makeHandleSummary(meta) {
  return function handleSummary(data) {
    const summary = buildSummary(data, meta);
    return {
      stdout: [
        renderText(summary),
        SUMMARY_BEGIN,
        JSON.stringify(summary),
        SUMMARY_END,
        "",
      ].join("\n"),
    };
  };
}
