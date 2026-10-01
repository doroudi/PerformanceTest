/*
 * STRESS TEST - find the knee, and watch how the system degrades and recovers.
 *
 * Question it answers : at what load does the system stop behaving linearly,
 *                       and does it fail gracefully or fall over?
 * Profile             : stepped ramps. Each plateau is a stable load level, so
 *                       you can see exactly where latency stops being flat and
 *                       starts being non-linear. A single continuous ramp
 *                       hides that point.
 * Where it belongs    : a prod-shaped staging environment, never production.
 *
 * THE EXIT CODE IS INFORMATIONAL, NOT A GATE
 * ------------------------------------------
 * A stress test is *supposed* to cross the thresholds - that is the finding.
 * k6 exits 99 when thresholds fail, so treat a non-zero exit here as "we found
 * the limit", not "the build is broken". This is why stress tests are run
 * manually against staging instead of on every pull request.
 *
 * Knobs:
 *   TARGET_URL      required, no default
 *   STEP_VUS        default 50   (VUs added per plateau)
 *   STRESS_STEPS    default 4    (number of plateaus -> peak = STEP_VUS x steps)
 *   STEP_DURATION   default 2m   (long enough for the system to settle)
 *   REQUEST_PAUSE   default 0.3 seconds
 */

import http from "k6/http";
import { check, sleep } from "k6";

import { USER_AGENT, TREND_STATS, buildRequestHeaders, envNumber, envString, requireTargetUrl } from "./lib/env.js";
import { makeHandleSummary } from "./lib/summary.js";

const testType = "stress";
const targetUrl = requireTargetUrl();

const stepVus = envNumber("STEP_VUS", 50);
// A stress test with fewer than two plateaus cannot show a knee.
const stepCount = Math.max(2, Math.round(envNumber("STRESS_STEPS", 4)));
const stepDuration = envString("STEP_DURATION", "2m");
const requestPause = envNumber("REQUEST_PAUSE", 0.3);

const stages = [];
for (let step = 1; step <= stepCount; step += 1) {
  stages.push({ duration: stepDuration, target: stepVus * step });
}
stages.push({ duration: stepDuration, target: 0 });

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: TREND_STATS,
  userAgent: USER_AGENT,
  tags: { test_type: testType },

  stages: stages,

  // Loosened on purpose: these mark "still acceptable while being pushed past
  // the expected peak", not the SLO. Cross them and the interesting question is
  // how far past, and whether throughput recovered when the load dropped.
  thresholds: {
    http_req_failed: ["rate<0.05"],
    http_req_duration: ["p(95)<2000", "p(99)<5000"],
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
