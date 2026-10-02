/*
 * JOURNEY TEST - a real multi-step user flow, which is what most load tests
 * actually need to measure.
 *
 * Question it answers : does the flow the user actually performs still meet its
 *                       SLO when many users perform it at once - and which STEP is
 *                       the one that breaks?
 * Profile             : log in once, then each VU repeats the steps.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * Every other scenario in this kit issues a single GET to one URL. That is a
 * perfectly good way to measure an endpoint, and a poor way to measure a product:
 * real traffic is a sequence - authenticate, open the dashboard, load the wallet
 * list, poll the request queue - and the interesting failures are interactions
 * (a token that is reused, a warm cache one step creates for the next) that a
 * single-endpoint test cannot see at all.
 *
 * WHICH STEP IS SLOW?
 * -------------------
 * This is the part that is easy to get wrong. A journey that issues four requests
 * without tagging them produces ONE blended http_req_duration, and "the journey got
 * slower" is then unanswerable. Each request here carries `tags: { name: ... }`, so
 * k6 keeps them as separate sub-metrics and both the console summary and the Grafana
 * dashboards can tell you that /wallets is the slow step and the other three are fine.
 * The thresholds below are per step for the same reason: an SLO belongs to an
 * endpoint, not to a journey.
 *
 *
 * RUN IT AGAINST A HOSTILE-NETWORK TARGET WITH CARE
 * -------------------------------------------------
 * A journey usually points at a shared development environment reached over the public
 * internet, so absolute latency includes WAN round trips and whatever else the team is
 * doing there - and hammering it affects other people. Treat the numbers as "is the
 * flow functional, and roughly how does it scale", then move to a dedicated
 * environment before drawing capacity conclusions.
 *
 * CONFIGURATION - all required from the environment, with no fallbacks
 * -------------------------------------------------------------------
 * There is deliberately no default login URL, no account anywhere in this file, and no
 * default API base beyond TARGET_URL. A built-in login URL lets a run appear to work
 * against an environment nobody chose; a password written into a scenario file is a
 * password in git. Locally pass these with -EnvVars; in Kubernetes inject them from a
 * Secret.
 *
 *   JOURNEY_USERNAME          required, no default
 *   JOURNEY_PASSWORD          required, no default
 *   LOGIN_URL                 required, no default
 *   API_BASE_URL              optional: falls back to TARGET_URL, which every runner
 *                             already sets, validates and records
 *   KYC_STEP_PATH             default /api/new-core/kyc/step
 *   WALLETS_PATH              default /api/new-core/wallets
 *   REQUESTS_ACTIVE_PATH      default /api/new-core/requests/active
 *   TARGET_VUS                default 5
 *   TEST_DURATION             default 1m
 *   STEP_PAUSE                default 0    (think time BETWEEN steps, seconds)
 *   REQUEST_PAUSE             default 0.5  (think time between journeys)
 *   REQUEST_HEADERS           optional extra headers, see lib/env.js
 *
 * HOW THE LOAD IS SHAPED - this is a CLOSED, VU-based model
 * ---------------------------------------------------------
 * One login in setup(), then every VU repeats the three steps for TEST_DURATION at a
 * constant VU count. There is no ramp, no hold and no ramp-down.
 *
 * Two consequences follow, and both matter when reading the numbers:
 *   * Offered load FALLS when the target slows down, because each VU waits for its own
 *     response before sending the next request. The test backs off exactly when you
 *     want to see the system buckle.
 *   * It cannot answer "does one pod beat three". That comparison needs a FIXED offered
 *     rate, which is what rate-test.js provides.
 * Add `stages` to the options below if you want a ramp; the per-step tags and
 * thresholds keep working unchanged.
 */

import http from "k6/http";
import { check, sleep } from "k6";
import encoding from "k6/encoding";

import { USER_AGENT, TREND_STATS, buildRequestHeaders, envNumber, envString } from "./lib/env.js";
import { makeHandleSummary } from "./lib/summary.js";

const testType = "journey";

/*
 * Report EVERY missing required variable in one pass.
 *
 * requireEnv throws on the first one it finds, so a half-configured run tells you about
 * LOGIN_URL, then JOURNEY_USERNAME, then JOURNEY_PASSWORD over three separate attempts.
 * Collecting them first turns three round trips into one.
 */
function assertPresent(names) {
  const missing = names.filter(function (name) {
    const raw = __ENV[name];
    return raw === undefined || String(raw).trim() === "";
  });

  if (missing.length > 0) {
    throw new Error(
      "The journey test is missing required configuration: " +
        missing.join(", ") +
        ".\nPass them as environment variables, never in this file. For example:\n" +
        "  -EnvVars LOGIN_URL=https://idp.example.com/accounts/login," +
        "JOURNEY_USERNAME=someone@example.com,JOURNEY_PASSWORD=***"
    );
  }
}

// No fallback login URL and no account anywhere in this file: a built-in login URL lets
// a run appear to work against an environment nobody chose, and a password written into
// a scenario file is a password in git.
assertPresent(["LOGIN_URL", "JOURNEY_USERNAME", "JOURNEY_PASSWORD"]);

const loginUrl = envString("LOGIN_URL", "");
const username = envString("JOURNEY_USERNAME", "");
const password = envString("JOURNEY_PASSWORD", "");

// The API base is API_BASE_URL, or TARGET_URL - which both runners already set, validate
// and record, so `-TargetUrl <api base>` is enough to run a journey. At least one must be
if (envString("API_BASE_URL", "") === "" && envString("TARGET_URL", "") === "") {
  throw new Error(
    "The journey test needs a base URL. Pass -TargetUrl <api base> to the runner, or set " +
      "API_BASE_URL. There is deliberately no default: a built-in URL would let a run " +
      "measure an environment nobody chose."
  );
}

const apiBaseUrl = (envString("API_BASE_URL", "") || envString("TARGET_URL", "")).replace(/\/+$/, "");

const kycStepPath = envString("KYC_STEP_PATH", "/api/new-core/kyc/step");
const walletsPath = envString("WALLETS_PATH", "/api/new-core/wallets");
const requestsActivePath = envString("REQUESTS_ACTIVE_PATH", "/api/new-core/requests/active");

const targetVus = envNumber("TARGET_VUS", 5);
const testDuration = envString("TEST_DURATION", "1m");
const stepPause = envNumber("STEP_PAUSE", 0);
const requestPause = envNumber("REQUEST_PAUSE", 0.5);

// Tag names are deliberately free of "/" so they are safe as Prometheus label values
// and as k6 threshold selectors.
const STEP_LOGIN = "login";
const STEP_KYC = "kyc-step";
const STEP_WALLETS = "wallets";
const STEP_REQUESTS = "requests-active";

export const options = {
  discardResponseBodies: true,
  summaryTrendStats: TREND_STATS,
  userAgent: USER_AGENT,
  tags: { test_type: testType },

  vus: targetVus,
  duration: testDuration,

  thresholds: {
    // abortOnFail: a journey where authentication or the first step is broken should
    // stop in seconds, not spend the whole duration generating 401s. A whole run of
    // failures is the most expensive possible way to learn that a password changed.
    http_req_failed: [{ threshold: "rate<0.01", abortOnFail: true, delayAbortEval: "20s" }],
    checks: ["rate>0.99"],

    // Per-step SLOs. This is the payoff of tagging each request: a single slow step
    // fails its own threshold instead of averaging away inside a journey-wide number.
    "http_req_duration{name:login}": ["p(95)<3000"],
    "http_req_duration{name:kyc-step}": ["p(95)<2000"],
    "http_req_duration{name:wallets}": ["p(95)<2000"],
    "http_req_duration{name:requests-active}": ["p(95)<2000"],
  },
};

/*
 * Log in and return the access token.
 *
 * Exported so a scenario that wants to authenticate per iteration (or to measure the
 * identity provider) can reuse it rather than duplicating the request shape.
 */
export function login() {
  const response = http.post(
    loginUrl,
    JSON.stringify({ Email: username, Password: password, RememberMe: true }),
    {
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      // Load-bearing. Options.discardResponseBodies is true for this test - the
      // generator's memory must not become the thing under test - and that would
      // discard THIS response too, leaving JSON.parse with an empty body. The result
      // is a run where the login POST returns 200 and looks healthy in the metrics
      // while every iteration fails with a confusing parse error.
      responseType: "text",
      tags: { name: STEP_LOGIN },
    }
  );

  if (response.status < 200 || response.status >= 300) {
    throw new Error(
      "Login failed: HTTP " +
        response.status +
        " from " +
        loginUrl +
        ".\n" +
        "Check JOURNEY_USERNAME/JOURNEY_PASSWORD. Response: " +
        String(response.body).slice(0, 300)
    );
  }

  let payload;
  try {
    payload = JSON.parse(response.body);
  }
  catch (error) {
    throw new Error(
      "Login returned HTTP " +
        response.status +
        " but the body is not JSON. Got: " +
        String(response.body).slice(0, 200)
    );
  }

  const token = payload && payload.data ? payload.data.accessToken : null;
  if (!token) {
    throw new Error(
      "Login response has no data.accessToken. Got keys: " +
        (payload ? Object.keys(payload).join(", ") : "(no object)") +
        (payload && payload.data ? " / data keys: " + Object.keys(payload.data).join(", ") : "")
    );
  }

  logTokenLifetime(token);
  return token;
}

/*
 * Decode the JWT payload and say when the token expires.
 *
 * Worth the few lines: this scenario logs in ONCE for the whole run, so the token has
 * to outlive the test. Logging the expiry turns "the journey started returning 401s
 * after six hours" from a mystery into an obvious consequence. A failure to decode is
 * ignored - the token is opaque to us and the run is still valid.
 */
function logTokenLifetime(token) {
  try {
    const segments = String(token).split(".");
    if (segments.length < 2) {
      return;
    }

    const payload = JSON.parse(encoding.b64decode(segments[1], "rawurl", "s"));
    if (!payload || typeof payload.exp !== "number") {
      return;
    }

    const expiresAt = new Date(payload.exp * 1000);
    const secondsRemaining = Math.round(payload.exp - Date.now() / 1000);

    console.log(
      "[journey] logged in as sub=" +
        (payload.sub || "?") +
        "; token expires " +
        expiresAt.toISOString() +
        " (" +
        Math.round(secondsRemaining / 60) +
        " minutes from now)"
    );

    // The run is set up to authenticate once, so a token that expires before the test
    // ends silently converts every later step into a 401.
    if (secondsRemaining < 300) {
      console.warn(
        "[journey] the access token expires in under 5 minutes and this test logs in only once. " +
          "Expect 401s near the end of a longer run; use a longer-lived token or log in per iteration."
      );
    }
  }
  catch (ignored) {
    // Opaque token, or a JWT we cannot decode: not worth failing a load test over.
  }
}

export function setup() {
  return { token: login() };
}

function requestStep(name, url, headers) {
  const response = http.get(url, {
    headers: headers,
    tags: { name: name },
  });

  // A check per step, so summary.json names the step that returned a bad status
  // rather than reporting one aggregate "some request failed".
  const assertions = {};
  assertions[name + " responded 2xx"] = (result) => result.status >= 200 && result.status < 400;
  check(response, assertions);

  return response;
}

export default function (data) {
  // buildRequestHeaders() keeps REQUEST_HEADERS working as an escape hatch for extra
  // headers (a tenant id, a gateway token). The Authorization header set here wins,
  // because the token in `data` is the logged-in one for this run.
  const headers = Object.assign({}, buildRequestHeaders(), {
    Authorization: "Bearer " + data.token,
  });

  requestStep(STEP_KYC, apiBaseUrl + kycStepPath, headers);
  if (stepPause > 0) {
    sleep(stepPause);
  }

  requestStep(STEP_WALLETS, apiBaseUrl + walletsPath, headers);
  if (stepPause > 0) {
    sleep(stepPause);
  }

  requestStep(STEP_REQUESTS, apiBaseUrl + requestsActivePath, headers);

  sleep(requestPause);
}

export const handleSummary = makeHandleSummary({
  test_type: testType,
  target_url: apiBaseUrl,
});
