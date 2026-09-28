/*
 * SMOKE TEST - minimal load, short duration.
 *
 * Question it answers : does the script, the target URL and the plumbing work?
 * Profile             : 1-2 VUs, under a minute, no ramping.
 * Where it belongs    : your laptop, a pull-request pipeline, and (at a very
 *                       low constant rate) production monitoring.
 * Where it does NOT   : it is not a capacity measurement and says nothing about
 *                       how the system behaves under load.
 *
 * Run it after every change to a scenario file, and before every other test
 * type: a smoke test that fails makes every number that follows meaningless.
 *
 * Knobs (all optional except TARGET_URL):
 *   TARGET_URL      required, no default
 *   TARGET_VUS      default 1
 *   TEST_DURATION   default 1m
 *   REQUEST_PAUSE   default 0.5 seconds
 */

import http from "k6/http";
import { check, sleep } from "k6";

import { USER_AGENT, TREND_STATS, envNumber, envString, requireTargetUrl } from "./lib/env.js";
import { makeHandleSummary } from "./lib/summary.js";

const testType = "smoke";
const targetUrl = requireTargetUrl();
const requestPause = envNumber("REQUEST_PAUSE", 0.5);

export const options = {
  // Do not buffer response bodies: the generator's memory must not become the
  // thing under test.
  discardResponseBodies: true,
  summaryTrendStats: TREND_STATS,
  userAgent: USER_AGENT,
  tags: { test_type: testType },

  vus: envNumber("TARGET_VUS", 1),
  duration: envString("TEST_DURATION", "1m"),

  thresholds: {
    // abortOnFail: a smoke test exists to answer "does the target work?", so it
    // should answer that in seconds rather than run to completion against a host
    // that refuses every connection.
    http_req_failed: [{ threshold: "rate<0.01", abortOnFail: true, delayAbortEval: "10s" }],
    http_req_duration: ["p(95)<1000", "p(99)<1500"],
    // Without a `checks` threshold a failing check() only prints a warning and
    // the run still exits 0 - i.e. the test would pass while asserting nothing.
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
