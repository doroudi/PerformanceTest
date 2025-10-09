/*
 * SOAK TEST - sustained load for hours, to catch what only time reveals.
 *
 * Question it answers : does anything leak, fill up, or drift?
 * Profile             : ramp to a moderate level (60-80% of peak, NOT peak),
 *                       hold for hours, ramp down.
 * Where it belongs    : a dedicated staging environment that nobody else is
 *                       using, ideally overnight. Never production.
 *
 * WHAT TO WATCH WHILE IT RUNS (none of this is visible from k6 alone)
 * ------------------------------------------------------------------
 *   - process RSS / container memory: a slow climb is a leak
 *   - GC generation-2 frequency and pause time
 *   - thread pool / DB connection pool counts: exhaustion shows as rising
 *     latency long before errors appear
 *   - disk: logs, temp files, and database growth
 *   - latency drift: compare the p95 of the first 10 minutes with the last 10.
 *     A flat average can still hide a steadily worsening tail.
 *
 * A 30-minute "soak" is just a longer load test. Leaks and pool exhaustion need
 * hours, and a soak should span at least one full GC cycle, one backup/batch
 * job and one token or certificate renewal. Default here is 2h; 4-24h is the
 * real target. Read the results in the time-series dashboard, not the summary.
 *
 * Knobs:
 *   TARGET_URL      required, no default
 *   TARGET_VUS      default 20   (60-80% of your peak load level)
 *   RAMP_DURATION   default 2m
 *   HOLD_DURATION   default 2h
 *   REQUEST_PAUSE   default 0.5 seconds
 */

import http from "k6/http";
import { check, sleep } from "k6";

import { USER_AGENT, TREND_STATS, buildRequestHeaders, envNumber, envString, requireTargetUrl } from "./lib/env.js";
import { makeHandleSummary } from "./lib/summary.js";

const testType = "soak";
const targetUrl = requireTargetUrl();

const targetVus = envNumber("TARGET_VUS", 20);
const rampDuration = envString("RAMP_DURATION", "2m");
const holdDuration = envString("HOLD_DURATION", "2h");
const requestPause = envNumber("REQUEST_PAUSE", 0.5);

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: TREND_STATS,
  userAgent: USER_AGENT,
  tags: { test_type: testType },

  stages: [
    { duration: rampDuration, target: targetVus },
    { duration: holdDuration, target: targetVus },
    { duration: rampDuration, target: 0 },
  ],

  // Held to the SLO, unlike the stress test: a soak that already exceeds the
  // SLO proves nothing about leaks, because the system was never healthy.
  thresholds: {
    http_req_failed: [{ threshold: "rate<0.01", abortOnFail: true, delayAbortEval: "30s" }],
    http_req_duration: ["p(95)<1500", "p(99)<3000"],
    checks: ["rate>0.99"],
  },
};

export default function () {
  const response = http.get(targetUrl, {
    // Built per iteration rather than once per VU. With AUTH_TOKEN_URL configured
    // that is what lets a long run pick up a RENEWED token instead of sending an
    // expired one for the rest of the test. It is cheap: the static headers are
    // parsed once at module load, and the token is read from a cache until it needs
    // renewing.
    headers: buildRequestHeaders(),
  });

  check(response, {
    "response is successful": (result) => result.status >= 200 && result.status < 400,
  });

  sleep(requestPause);
}

export const handleSummary = makeHandleSummary({
  test_type: testType,
  target_url: targetUrl,
});
