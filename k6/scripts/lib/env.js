/*
 * Environment helpers shared by every scenario.
 *
 * Two rules this file enforces:
 *
 * 1. There is no default TARGET_URL. A wrong default silently load-tests the
 *    wrong thing (which is exactly how the old `http://api-service/` default
 *    behaved once the API was moved to port 8080). A missing target is a
 *    configuration error and must fail loudly, at init time.
 *
 * 2. An empty string means "not set". `Number(__ENV.X || fallback)` looks like
 *    it does that, but it silently accepts garbage ("abc" -> NaN) and cannot
 *    express an intentional 0 for some knobs. Parse explicitly instead.
 *
 * Request headers - static ones plus authentication - are built here too, so that
 * every scenario picks up auth support without touching the scenario file. The
 * token machinery lives in lib/auth.js.
 */

import { authHeaders } from "./auth.js";

export function requireEnv(name, example) {
  const raw = __ENV[name];
  if (raw === undefined || String(raw).trim() === "") {
    const hint = example ? ` Example: ${name}=${example}` : "";
    throw new Error(
      `${name} is required but was not set.${hint}\n` +
        "This kit deliberately defines no default so a misconfigured run fails " +
        "loudly instead of quietly measuring the wrong endpoint."
    );
  }
  return String(raw).trim();
}

export function requireTargetUrl() {
  return requireEnv("TARGET_URL", "http://api-service:8080/api/health");
}

export function envString(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || String(raw).trim() === "") {
    return fallback;
  }
  return String(raw).trim();
}

export function envNumber(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || String(raw).trim() === "") {
    return fallback;
  }
  const parsed = Number(String(raw).trim());
  if (!isFinite(parsed) || parsed < 0) {
    throw new Error(`${name} must be a non-negative number, but got "${raw}".`);
  }
  return parsed;
}

export function envBoolean(name, fallback) {
  const value = envString(name, "");
  if (value === "") {
    return fallback;
  }
  return ["1", "true", "yes", "on"].indexOf(value.toLowerCase()) !== -1;
}

/*
 * Request headers for the target, merged from two sources:
 *
 *   1. A bearer token from lib/auth.js, when AUTH_TOKEN_URL is configured. That
 *      module fetches the token and RENEWS it shortly before expiry, which is what
 *      makes an authenticated soak test possible at all.
 *   2. Headers from REQUEST_HEADERS, which WIN on a name collision. That is the
 *      deliberate escape hatch: an explicitly supplied header always beats one the
 *      kit inferred, and it is what a non-OAuth target needs - a gateway that
 *      injects trusted headers, say, or a token somebody pasted in by hand.
 *
 * Why any of this exists: a protected target answers 401 to every request, which k6
 * faithfully records as a *fast, successful-looking* run at a 100% failure rate. The
 * scenarios originally sent nothing but `Accept: application/json`, so the kit could
 * not load test an authenticated service at all, in the cluster or anywhere else.
 *
 * REQUEST_HEADERS format: `Name: value` entries separated by `;;`, e.g.
 *
 *   REQUEST_HEADERS=X-Auth-User: loadtest;;X-Auth-Secret: s3cret;;X-Auth-Roles: Admin
 *
 * `;;` rather than a comma, because header values legitimately contain commas
 * (Accept, Date, cookie lists). The value is everything after the FIRST colon, so
 * `Authorization: Bearer a:b` survives intact.
 *
 * Safe and cheap to call once PER ITERATION, which is how the scenarios use it: the
 * static headers are parsed once at module load, and the token comes from a cache
 * until it needs renewing. Calling it per iteration rather than once per VU is
 * precisely what lets a long run pick up a renewed token.
 */
function parseStaticHeaders(raw) {
  const headers = { Accept: "application/json" };

  if (raw === "") {
    return headers;
  }

  const malformed = [];

  raw.split(";;").forEach(function (entry) {
    const trimmed = entry.trim();
    if (trimmed === "") {
      return;
    }

    const separator = trimmed.indexOf(":");
    if (separator <= 0) {
      malformed.push(trimmed);
      return;
    }

    const name = trimmed.slice(0, separator).trim();
    const value = trimmed.slice(separator + 1).trim();

    if (name === "") {
      malformed.push(trimmed);
      return;
    }

    headers[name] = value;
  });

  if (malformed.length > 0) {
    throw new Error(
      "REQUEST_HEADERS entries must look like 'Name: value', separated by ';;'. " +
        "Could not parse: " +
        malformed.join(", ")
    );
  }

  return headers;
}

const STATIC_HEADERS = parseStaticHeaders(envString("REQUEST_HEADERS", ""));

export function buildRequestHeaders() {
  // Object.assign returns a fresh object, so a caller that mutates the result cannot
  // corrupt STATIC_HEADERS for every later iteration of the run.
  return Object.assign({}, authHeaders(), STATIC_HEADERS);
}

/*
 * Sent as the User-Agent on every request so the request shows up as this kit
 * in the API's own logs and APM, rather than as an anonymous client.
 */
export const USER_AGENT = "perf-test-kit/1.0 (k6)";

/*
 * Trend statistics requested on every run. p(90)/p(95)/p(99) are the numbers
 * the regression gate in scripts/compare-summary.ps1 reads back out of the
 * summary, so keep them in sync with that script.
 */
export const TREND_STATS = ["avg", "min", "med", "max", "p(90)", "p(95)", "p(99)"];
