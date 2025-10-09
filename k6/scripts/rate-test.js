/*
 * RATE TEST - a FIXED request rate, offered regardless of how slowly the target
 * answers. This is the open model.
 *
 * Question it answers : at <TARGET_RPS> requests per second, does the system keep
 *                       up, and what does latency do when it cannot? This is the
 *                       only profile in the kit that can compare "1 pod vs 3 pods",
 *                       because the offered load is the same in both runs.
 * Profile             : constant arrival rate for a fixed duration.
 * Where it belongs    : anywhere you are sizing replicas or CPU, and in staging
 *                       when you know the production request rate.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * Every other scenario here is VU-based, which is a CLOSED model: a fixed number
 * of virtual users, each waiting for its own response before sending the next
 * request. Offered load therefore falls automatically whenever the target slows
 * down - the test backs off exactly when you want to see the system buckle.
 *
 * That is not a theoretical objection; it silently invalidated a real comparison
 * on this kit. With 10 VUs, going from 1 pod to 3 moved throughput from 1685 to
 * 1794 rps (+6%), and the obvious reading - "adding pods does not help" - was
 * wrong. Ten VUs simply could not offer more work than that. Repeating it at 60
 * VUs gave +32%, still nowhere near the ~200% that three times the CPU should
 * yield, for the same reason: in a closed model, throughput is bounded by
 * VUs / latency, not by the server.
 *
 * With an arrival-rate executor the generator's job is to emit N requests per
 * second and nothing else. If the target cannot absorb them, requests queue and
 * latency rises - which is the measurement you actually wanted.
 *
 * READ `dropped_iterations` BEFORE TRUSTING ANY NUMBER HERE
 * --------------------------------------------------------
 * If the generator itself runs out of VUs it silently drops iterations instead of
 * sending them, and the run then looks like a target that handled the load
 * perfectly. The threshold below fails the run when that happens, because a
 * dropped-iteration run is not evidence about the target at all. If it trips,
 * raise MAX_VUS or lower TARGET_RPS - and if raising MAX_VUS fixes it, the
 * generator was the bottleneck, not the application.
 *
 * Knobs:
 *   TARGET_URL            required, no default
 *   TARGET_RPS            default 500   (requests per second offered)
 *   TEST_DURATION         default 1m
 *   PREALLOCATED_VUS      default 100   (VUs created up front)
 *   MAX_VUS               default 400   (ceiling the generator may grow to)
 *   REQUEST_HEADERS       optional authentication headers, see lib/env.js
 */

import http from "k6/http";
import { check } from "k6";

import { USER_AGENT, TREND_STATS, buildRequestHeaders, envNumber, envString, requireTargetUrl } from "./lib/env.js";
import { makeHandleSummary } from "./lib/summary.js";

const testType = "rate";
const targetUrl = requireTargetUrl();

const targetRps = envNumber("TARGET_RPS", 500);
const testDuration = envString("TEST_DURATION", "1m");
const preAllocatedVus = envNumber("PREALLOCATED_VUS", 100);
// maxVUs must be at least preAllocatedVUs, or k6 refuses to start the scenario.
const maxVus = Math.max(preAllocatedVus, envNumber("MAX_VUS", 400));

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: TREND_STATS,
  userAgent: USER_AGENT,
  tags: { test_type: testType },

  scenarios: {
    rate: {
      executor: "constant-arrival-rate",
      rate: targetRps,
      timeUnit: "1s",
      duration: testDuration,
      preAllocatedVUs: preAllocatedVus,
      maxVUs: maxVus,
    },
  },

  thresholds: {
    // Generous, because the interesting question here is not "did it pass" but
    // "at what offered rate does latency break". A rate test that fails its
    // latency threshold has found the answer, not a broken build.
    http_req_failed: ["rate<0.05"],
    http_req_duration: ["p(95)<2000", "p(99)<5000"],
    checks: ["rate>0.95"],
    // The one threshold that protects the experiment. See the header comment.
    dropped_iterations: ["count<100"],
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
}

export const handleSummary = makeHandleSummary({
  test_type: testType,
  target_url: targetUrl,
});
