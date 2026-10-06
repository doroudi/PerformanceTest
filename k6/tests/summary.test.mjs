/*
 * Sanity checks for k6/scripts/lib/summary.js, runnable without k6:
 *
 *   node k6/tests/summary.test.mjs
 *
 * The summary module is what the runners parse results out of, so a shape change
 * there silently breaks every recorded baseline. It deliberately has no k6
 * globals, which is what makes this possible.
 *
 * Two of these cases encode bugs found in a real run rather than invented ones:
 * a duration of 0 for a 32-second test (init-context clocks do not describe the
 * run), and a summary line reading "100.00% (0 failed)".
 */

import assert from "node:assert/strict";

import {
  SUMMARY_BEGIN,
  SUMMARY_END,
  SUMMARY_SCHEMA,
  buildSummary,
  makeHandleSummary,
  renderText,
} from "../scripts/lib/summary.js";

// Shape of the `data` argument k6 passes to handleSummary.
function sampleData(overrides = {}) {
  return {
    metrics: {
      http_req_duration: {
        type: "trend",
        contains: "time",
        values: { avg: 12.4, min: 3.1, med: 11, max: 55.2, "p(90)": 19, "p(95)": 21, "p(99)": 30.1 },
        thresholds: { "p(95)<1000": { ok: true }, "p(99)<1500": { ok: true } },
      },
      http_req_waiting: {
        type: "trend",
        contains: "time",
        values: { avg: 11.9, "p(95)": 20.1, "p(99)": 29 },
      },
      http_reqs: { type: "counter", contains: "default", values: { count: 1180, rate: 19.62 } },
      http_req_failed: {
        type: "rate",
        contains: "default",
        values: { rate: 0, passes: 1180, fails: 0 },
        thresholds: { "rate<0.01": { ok: true } },
      },
      checks: {
        type: "rate",
        contains: "default",
        values: { rate: 1, passes: 1180, fails: 0 },
        thresholds: { "rate>0.99": { ok: true } },
      },
      vus_max: { type: "gauge", contains: "default", values: { value: 1, min: 1, max: 1 } },
      iterations: { type: "counter", contains: "default", values: { count: 1180, rate: 19.62 } },
      iteration_duration: {
        type: "trend",
        contains: "time",
        values: { avg: 62.4, min: 40.1, med: 60, max: 130.2, "p(90)": 80, "p(95)": 95, "p(99)": 120 },
      },
      data_received: { type: "counter", contains: "data", values: { count: 812345, rate: 13539 } },
    },
    root_group: {
      name: "",
      path: "",
      checks: [{ name: "response is successful", path: "::response is successful", passes: 1180, fails: 0 }],
      groups: [],
    },
    state: { isStdOut: true, isStdErr: false, testRunDurationMs: 60000 },
    ...overrides,
  };
}

const meta = {
  test_type: "smoke",
  target_url: "http://api-service:8080/api/health",
};

// 1. Healthy run: metrics normalized, thresholds aggregate, and the window comes
//    from k6's own duration rather than from a wall clock captured at init.
const healthy = buildSummary(sampleData(), meta);
assert.equal(healthy.schema, SUMMARY_SCHEMA);
assert.equal(healthy.test_type, "smoke");
assert.equal(healthy.target_url, "http://api-service:8080/api/health");
assert.equal(healthy.metrics.http_req_duration["p(95)"], 21);
assert.equal(healthy.metrics.http_req_duration["p(99)"], 30.1);
assert.equal(healthy.metrics.http_reqs.rate, 19.62);
assert.equal(healthy.metrics.http_req_failed.rate, 0);
assert.equal(healthy.thresholds_all_ok, true);
assert.equal(healthy.threshold_count, 4);
assert.deepEqual(healthy.failed_thresholds, []);
assert.equal(healthy.checks.passes, 1180);
assert.equal(healthy.checks.fails, 0);
assert.equal(healthy.checks.rate, 1);
assert.equal(healthy.duration_seconds, 60, "duration must come from state.testRunDurationMs");
assert.equal(
  Date.parse(healthy.ended_at) - Date.parse(healthy.started_at),
  60000,
  "started_at must be derived as ended_at minus the run duration"
);

const text = renderText(healthy);
assert.ok(text.includes("http://api-service:8080/api/health"), "text summary names the target");
assert.ok(text.includes("PASS  http_req_duration: p(95)<1000"), "text summary lists threshold results");
assert.ok(text.includes("all passed"), "text summary reports passing thresholds");
assert.ok(text.includes("0 of 1180 requests"), "error line states the failing count out of the total");
// For a multi-step journey this is the flow time a user experiences. It is not
// derivable from the per-request percentiles above, so it must be printed.
assert.ok(
  text.includes("iteration_duration"),
  "text summary prints the end-to-end iteration time, not only per-request latency"
);
assert.ok(text.includes("62.40"), "iteration_duration stats come from the metric, not a placeholder");

// 2. A crossed threshold must be visible and machine-detectable.
const failing = buildSummary(
  sampleData({
    metrics: {
      ...sampleData().metrics,
      http_req_duration: {
        type: "trend",
        values: { avg: 400, min: 10, med: 300, max: 5000, "p(90)": 800, "p(95)": 1900, "p(99)": 4000 },
        thresholds: { "p(95)<1000": { ok: false }, "p(99)<1500": { ok: false } },
      },
      http_req_failed: {
        type: "rate",
        values: { rate: 0.02, passes: 1180, fails: 0 },
        thresholds: { "rate<0.01": { ok: false } },
      },
      checks: {
        type: "rate",
        values: { rate: 0.5, passes: 590, fails: 590 },
        thresholds: { "rate>0.99": { ok: false } },
      },
    },
    root_group: {
      name: "",
      checks: [{ name: "response is successful", path: "::response is successful", passes: 590, fails: 590 }],
      groups: [],
    },
  }),
  meta
);
assert.equal(failing.thresholds_all_ok, false);
assert.ok(failing.failed_thresholds.includes("http_req_duration: p(95)<1000"));
assert.ok(failing.failed_thresholds.includes("http_req_failed: rate<0.01"));
const failingText = renderText(failing);
assert.ok(failingText.includes("FAILED"), "text summary flags failed thresholds");
assert.ok(failingText.includes("failing checks:"), "text summary lists failing checks");
// k6 reports http_req_failed as passes=1180/fails=0 even when every request
// failed, so the human count must be derived from the rate instead.
assert.ok(failingText.includes("2.00%"), "error rate shown");
assert.ok(failingText.includes("24 of 1180 requests"), "failing count derived from the rate");
assert.ok(!failingText.includes("(0 failed)"), "no self-contradicting '0 failed' line");

// 3. Older k6 builds report trend stats positionally; that must not throw or
//    silently produce an empty summary.
const legacy = buildSummary(
  sampleData({
    metrics: {
      http_req_duration: { type: "trend", values: [12.4, 3.1, 11, 55.2, 19, 21] },
    },
  }),
  meta
);
assert.equal(legacy.metrics.http_req_duration.avg, 12.4);
assert.equal(legacy.metrics.http_req_duration["p(95)"], 21);

// 4. A run with nothing but errors still produces a summary instead of throwing.
const empty = buildSummary({}, meta);
assert.deepEqual(empty.metrics, {});
assert.equal(empty.thresholds_all_ok, true);
assert.equal(empty.checks.total, 0);
assert.ok(renderText(empty).includes("perf-test-kit"));

// 5. Without k6's state block there is no trustworthy duration: say so, rather
//    than falling back to a clock that would claim the run took 0 seconds.
const noState = buildSummary(sampleData({ state: undefined }), meta);
assert.equal(noState.duration_seconds, null);
assert.equal(noState.started_at, null);
assert.notEqual(noState.ended_at, null);
assert.ok(
  renderText(noState).includes("did not report a run duration"),
  "absence of a duration is stated explicitly"
);

// 6. The transported form: markers wrap parseable JSON, and the human summary
//    survives alongside it (the runners rely on both).
const handleSummary = makeHandleSummary(meta);
const output = handleSummary(sampleData());
assert.equal(typeof output.stdout, "string");
const beginIndex = output.stdout.indexOf(SUMMARY_BEGIN);
const endIndex = output.stdout.indexOf(SUMMARY_END);
assert.ok(beginIndex > 0, "begin marker present");
assert.ok(endIndex > beginIndex, "end marker after begin marker");
const transported = JSON.parse(output.stdout.slice(beginIndex + SUMMARY_BEGIN.length, endIndex).trim());
assert.equal(transported.schema, SUMMARY_SCHEMA);
assert.equal(transported.metrics.http_req_duration["p(95)"], 21);
assert.equal(transported.duration_seconds, 60);
assert.ok(output.stdout.slice(0, beginIndex).includes("thresholds"), "human text precedes the JSON");

// 7. An arrival-rate run that could not send everything it offered must SAY so: a dropped
//    iteration is load the server never saw, and without this line the run reads as a target
//    that coped perfectly.
const withDrops = buildSummary(
  sampleData({
    metrics: {
      ...sampleData().metrics,
      dropped_iterations: { type: "counter", contains: "default", values: { count: 412, rate: 6.8 } },
    },
  }),
  meta
);
const dropsText = renderText(withDrops);
assert.ok(dropsText.includes("dropped_iters"), "dropped iterations must be printed when they happen");
assert.ok(dropsText.includes("412"), "and the count must be the real one");
assert.ok(dropsText.includes("could NOT send"), "and it must read as a warning, not a statistic");

// ...and NOT printed when there were none, so a healthy run does not carry a scary line.
assert.ok(!text.includes("dropped_iters"), "a run with no dropped iterations must not print the line");

console.log("summary.test.mjs: all assertions passed");
