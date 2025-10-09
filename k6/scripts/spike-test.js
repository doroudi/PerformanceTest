/*
 * SPIKE TEST - a sudden, extreme jump in load over a very short window.
 *
 * Question it answers : can the system absorb a flash crowd, and how long does
 *                       it take to come back to normal afterwards?
 * Profile             : baseline -> sharp spike -> back to baseline -> baseline
 *                       hold -> down. Unlike a stress test there is no gradual
 *                       ramp, so autoscaling and caches get no time to warm up.
 * Where it belongs    : staging, typically before a known high-traffic event
 *                       (campaign, batch cut-over, marketing launch).
 *
 * WHAT THE SUMMARY CANNOT TELL YOU
 * --------------------------------
 * The number that matters here is RECOVERY TIME: how long after the spike ends
 * does p95 return to its baseline? That is a property of the time series, not of
 * any single aggregate, so read it from the Grafana dashboard's over-time panel.
 * A run can pass every threshold in this file and still have taken 20 minutes to
 * recover, which is the actual incident.
 *
 * The spike hold is deliberately longer than the spike ramp: the interesting
 * failure mode is not the moment of impact but the queue that keeps growing
 * afterwards.
 *
 * Knobs:
 *   TARGET_URL          required, no default
 *   BASELINE_VUS        default 10
 *   SPIKE_VUS           default 100
 *   BASELINE_DURATION   default 30s
 *   SPIKE_DURATION      default 1m
 *   REQUEST_PAUSE       default 0.2 seconds
 */

import http from "k6/http";
import { check, sleep } from "k6";

import { USER_AGENT, TREND_STATS, buildRequestHeaders, envNumber, envString, requireTargetUrl } from "./lib/env.js";
import { makeHandleSummary } from "./lib/summary.js";

const testType = "spike";
const targetUrl = requireTargetUrl();

const baselineVus = envNumber("BASELINE_VUS", 10);
const spikeVus = Math.max(baselineVus, envNumber("SPIKE_VUS", 100));
const baselineDuration = envString("BASELINE_DURATION", "30s");
const spikeDuration = envString("SPIKE_DURATION", "1m");
const requestPause = envNumber("REQUEST_PAUSE", 0.2);

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: TREND_STATS,
  userAgent: USER_AGENT,
  tags: { test_type: testType },

  stages: [
    { duration: "10s", target: baselineVus },
    { duration: baselineDuration, target: baselineVus },
    { duration: "10s", target: spikeVus },
    { duration: spikeDuration, target: spikeVus },
    { duration: "10s", target: baselineVus },
    // The second baseline hold is the recovery measurement window - do not
    // shorten it to save time, or you lose the only answer this test gives.
    { duration: baselineDuration, target: baselineVus },
    { duration: "10s", target: 0 },
  ],

  // Loose on purpose. Some errors during a spike test are expected and are part
  // of the finding; a spike test that must pass 99.9% is not a spike test.
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
