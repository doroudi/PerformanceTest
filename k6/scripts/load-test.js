/*
 * LOAD TEST - expected peak, sustained long enough to be a baseline.
 *
 * Question it answers : do we still meet the SLOs at the traffic we actually
 *                       expect? This is the number you carry into a release.
 * Profile             : ramp up, hold at expected peak, ramp down.
 * Where it belongs    : a prod-shaped staging environment. Never on a laptop.
 *
 * READ THIS BEFORE TRUSTING THE NUMBER
 * ------------------------------------
 * The VU-based stages below are a *closed* model: offered load falls when the
 * API slows down, because each VU waits for its own response. That politely
 * backs off exactly when you want to see the system buckle. An open model
 * (`constant-arrival-rate` / `ramping-arrival-rate` executors) sends a fixed
 * request rate regardless of latency and is the correct model for a load test.
 * Switching to it is the next step for this kit; until then, treat absolute RPS
 * figures as indicative and read latency as the primary signal.
 *
 * Size the load from production data (RPS percentiles from access logs/APM),
 * not from a guess. Sanity-check with Little's Law: VUs ~= RPS x latency.
 *
 * Knobs:
 *   TARGET_URL      required, no default
 *   TARGET_VUS      default 50
 *   RAMP_DURATION   default 1m
 *   HOLD_DURATION   default 10m  (a baseline needs a real plateau, not 1m)
 *   REQUEST_PAUSE   default 0.3 seconds
 */

import http from "k6/http";
import { check, sleep } from "k6";

import { USER_AGENT, TREND_STATS, envNumber, envString, requireTargetUrl } from "./lib/env.js";
import { makeHandleSummary } from "./lib/summary.js";

const testType = "load";
const targetUrl = requireTargetUrl();

const targetVus = envNumber("TARGET_VUS", 50);
const rampDuration = envString("RAMP_DURATION", "1m");
const holdDuration = envString("HOLD_DURATION", "10m");
const requestPause = envNumber("REQUEST_PAUSE", 0.3);

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

  thresholds: {
    // abortOnFail: if the target is down or unreachable, stop after 30s with a
    // summary instead of hammering a closed socket for the full duration and
    // leaving nothing behind. The delay matters - it skips the ramp-up, where a
    // cold start can legitimately produce a few errors.
    http_req_failed: [{ threshold: "rate<0.01", abortOnFail: true, delayAbortEval: "30s" }],
    http_req_duration: ["p(95)<1000", "p(99)<2000"],
    checks: ["rate>0.99"],
  },
};

export default function () {
  const response = http.get(targetUrl, {
    headers: { Accept: "application/json" },
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
