/*
 * Authentication for the target, shared by every scenario.
 *
 * WHY THIS EXISTS
 * ---------------
 * Real APIs require authentication, and a load test that cannot authenticate
 * measures nothing: every request is a 401, which k6 reports as a fast run with a
 * 100% failure rate. The kit previously sent only `Accept: application/json`.
 *
 * There are two ways to authenticate a run, and this file supports both.
 *
 * 1. A STATIC TOKEN you already hold, passed as a header:
 *
 *    REQUEST_HEADERS=Authorization: Bearer eyJhbGciOi...
 *
 *    Fine for a one-off two-minute run. Useless for a soak: the token expires
 *    mid-run and every request after that is a 401, which looks like the service
 *    falling over rather than the test losing its credentials.
 *
 * 2. A TOKEN THE SCENARIO FETCHES AND REFRESHES ITSELF (OAuth2 client
 *    credentials, or resource-owner password for a dedicated test user). The kit
 *    obtains a token, caches it, and renews it shortly before expiry, so a run of
 *    any length keeps working. This is the mode to use for anything long.
 *
 * CONFIGURATION - environment variables, never committed to the repository:
 *
 *   AUTH_TOKEN_URL       OAuth2/OIDC token endpoint. Setting this switches auth on.
 *   AUTH_CLIENT_ID       client id
 *   AUTH_CLIENT_SECRET   client secret
 *   AUTH_SCOPE           optional, space separated
 *   AUTH_GRANT_TYPE      client_credentials (default) | password
 *   AUTH_USERNAME        password grant only
 *   AUTH_PASSWORD        password grant only
 *   AUTH_AUDIENCE        optional, sent as `audience` (Auth0 and others)
 *   AUTH_TOKEN_HEADER    default `Authorization`
 *   AUTH_TOKEN_PREFIX    default `Bearer ` (include the trailing space; set empty
 *                        for APIs that take a bare token in a custom header)
 *   AUTH_EXPIRY_SKEW     seconds of safety margin before real expiry, default 30
 *
 * Leave AUTH_TOKEN_URL unset and this module does nothing, so the kit keeps
 * working against unauthenticated targets with no configuration at all.
 *
 * PROOF IT WORKED
 * ---------------
 * Never trust a run where authentication is silently absent. The scenario log
 * prints one line when a token is fetched and one warning if AUTH_TOKEN_URL is set
 * but the endpoint rejects the credentials. If you configure auth and see neither
 * line, the environment variable did not reach the container - which is the usual
 * cause, because the k6 Job's env comes from the runner, not from your shell.
 *
 * A NOTE ON VIRTUAL USERS
 * -----------------------
 * k6 gives every VU its own JavaScript runtime, so this cache is per-VU: 50 VUs
 * means 50 token requests, all at roughly the same moment when the run starts. That
 * is normally harmless, but if your identity provider rate-limits the token
 * endpoint you will see it here first. Mitigations, in order of preference: reduce
 * the number of VUs that ramp up simultaneously, raise AUTH_EXPIRY_SKEW so tokens
 * are reused longer, or move the fetch into `setup()` (which runs once) and pass the
 * token to the VUs - see the note at the bottom of this file.
 */

import http from "k6/http";
import encoding from "k6/encoding";

/*
 * A token, as cached for one VU. `expiresAt` is when the kit should stop using it,
 * which is deliberately earlier than the real expiry by AUTH_EXPIRY_SKEW.
 */
let cachedToken = null;

function envValue(name, fallback) {
  const raw = __ENV[name];
  if (raw === undefined || String(raw).trim() === "") {
    return fallback;
  }
  return String(raw).trim();
}

function envNumber(name, fallback) {
  const raw = envValue(name, "");
  if (raw === "") {
    return fallback;
  }
  const parsed = Number(raw);
  return isFinite(parsed) ? parsed : fallback;
}

/*
 * Which mechanism to use.
 *
 *   oauth2      (default) a standard OAuth2/OIDC token endpoint: a form-encoded POST,
 *               client_credentials or password grant.
 *   json-login  a bespoke login endpoint that takes a JSON body and answers with a token
 *               somewhere in the response. Plenty of first-party identity APIs work this
 *               way and are not OAuth2 at all, so the form-encoded flow cannot talk to
 *               them: the content type is wrong, the grant types do not exist, and the
 *               token arrives in a body field rather than as `access_token`.
 *   off         authentication disabled, whatever else is configured. This is how a
 *               caller that authenticates by other means stops this module repeating
 *               the login - the journey scenario logs in once in setup() and passes
 *               AUTH_MODE=off for exactly that reason.
 */
function authMode() {
  return envValue("AUTH_MODE", "oauth2").toLowerCase();
}

/* The JSON-login endpoint. LOGIN_URL first, so one .env serves the journey and these. */
function jsonLoginUrl() {
  return envValue("LOGIN_URL", "") || envValue("AUTH_LOGIN_URL", "");
}

/* True when this module has work to do. */
export function isAuthConfigured() {
  const mode = authMode();

  if (mode === "off" || mode === "none" || mode === "disabled") {
    return false;
  }
  if (mode === "json-login") {
    return jsonLoginUrl() !== "";
  }
  return envValue("AUTH_TOKEN_URL", "") !== "";
}

function readAuthConfiguration() {
  const mode = authMode();

  const configuration = {
    mode: mode,
    tokenUrl: envValue("AUTH_TOKEN_URL", ""),
    clientId: envValue("AUTH_CLIENT_ID", ""),
    clientSecret: envValue("AUTH_CLIENT_SECRET", ""),
    scope: envValue("AUTH_SCOPE", ""),
    grantType: envValue("AUTH_GRANT_TYPE", "client_credentials"),
    username: envValue("AUTH_USERNAME", ""),
    password: envValue("AUTH_PASSWORD", ""),
    audience: envValue("AUTH_AUDIENCE", ""),
    tokenHeader: envValue("AUTH_TOKEN_HEADER", "Authorization"),
    tokenPrefix: envValue("AUTH_TOKEN_PREFIX", "Bearer "),
    expirySkewSeconds: envNumber("AUTH_EXPIRY_SKEW", 30),

    // json-login only.
    loginUrl: jsonLoginUrl(),
    // A JSON template in which {{username}} and {{password}} are substituted, so an
    // endpoint that wants different field names - or extra fields like RememberMe - can
    // be driven without a code change. Left empty, the default body in
    // requestJsonLoginToken() is used.
    loginBody: envValue("AUTH_LOGIN_BODY", ""),
    // Where the token sits in the response, dot-separated. The default matches the
    // shape {"data":{"accessToken":"..."}}.
    tokenPath: envValue("AUTH_TOKEN_PATH", "data.accessToken"),
    // Used only when the token is opaque and carries no expiry of its own. A JWT does,
    // and its own exp is always preferred.
    fallbackLifetimeSeconds: envNumber("AUTH_EXPIRES_IN", 300),
  };

  // The journey names these JOURNEY_*, and falling back to them means one .env file
  // serves the journey AND every other test type, with the account stored once.
  if (configuration.username === "") {
    configuration.username = envValue("JOURNEY_USERNAME", "");
  }
  if (configuration.password === "") {
    configuration.password = envValue("JOURNEY_PASSWORD", "");
  }

  // Fail before the run rather than 40 seconds into it, and name what is missing. A
  // half-configured login produces a 400 from the identity provider whose message
  // usually does not mention the absent parameter.
  const problems = [];

  if (mode === "json-login") {
    if (configuration.loginUrl === "") {
      problems.push("LOGIN_URL (or AUTH_LOGIN_URL)");
    }
    if (configuration.username === "") {
      problems.push("AUTH_USERNAME (or JOURNEY_USERNAME)");
    }
    if (configuration.password === "") {
      problems.push("AUTH_PASSWORD (or JOURNEY_PASSWORD)");
    }
  }
  else if (mode === "oauth2") {
    if (configuration.tokenUrl === "") {
      problems.push("AUTH_TOKEN_URL");
    }
    if (configuration.grantType === "password") {
      if (configuration.username === "") {
        problems.push("AUTH_USERNAME (required by AUTH_GRANT_TYPE=password)");
      }
      if (configuration.password === "") {
        problems.push("AUTH_PASSWORD (required by AUTH_GRANT_TYPE=password)");
      }
    }
    else if (configuration.grantType !== "client_credentials") {
      problems.push(
        'AUTH_GRANT_TYPE must be "client_credentials" or "password", but got "' +
          configuration.grantType +
          '"'
      );
    }
  }
  else {
    problems.push('AUTH_MODE must be "oauth2", "json-login" or "off", but got "' + mode + '"');
  }

  if (problems.length > 0) {
    throw new Error(
      "Authentication is misconfigured. Missing or invalid: " +
        problems.join(", ") +
        ".\nSet them as environment variables on the run. For a standard OAuth2 endpoint:\n" +
        "  -EnvVars AUTH_TOKEN_URL=https://idp.example.com/connect/token," +
        "AUTH_CLIENT_ID=my-client,AUTH_CLIENT_SECRET=***\n" +
        "For a bespoke JSON login endpoint:\n" +
        "  -EnvVars AUTH_MODE=json-login,LOGIN_URL=https://idp.example.com/accounts/login," +
        "JOURNEY_USERNAME=someone@example.com,JOURNEY_PASSWORD=***"
    );
  }

  // The secret legitimately may be empty when the IdP authenticates the client by mTLS
  // or network position, but that is rare enough to be worth a nudge.
  if (mode === "oauth2" && configuration.grantType === "client_credentials" &&
      configuration.clientSecret === "") {
    console.warn(
      "[auth] AUTH_CLIENT_SECRET is empty. That is correct only for a public client " +
        "or one authenticated by mTLS; otherwise the token endpoint will reject the request."
    );
  }

  return configuration;
}

function formEncode(pairs) {
  return pairs
    .filter(function (pair) {
      return pair[1] !== "" && pair[1] !== undefined && pair[1] !== null;
    })
    .map(function (pair) {
      return encodeURIComponent(pair[0]) + "=" + encodeURIComponent(pair[1]);
    })
    .join("&");
}

function requestToken(configuration) {
  if (configuration.mode === "json-login") {
    return requestJsonLoginToken(configuration);
  }
  return requestOAuth2Token(configuration);
}

/* Read a dot-separated path out of a parsed response body. */
function readJsonPath(value, path) {
  let current = value;

  const parts = String(path).split(".");
  for (let index = 0; index < parts.length; index += 1) {
    if (current === null || current === undefined || typeof current !== "object") {
      return null;
    }
    current = current[parts[index]];
  }

  return typeof current === "string" && current !== "" ? current : null;
}

/*
 * How long this token is good for.
 *
 * A JWT states its own expiry and that is always preferred: inventing a lifetime and
 * renewing against the guess either wastes logins or - worse - keeps using an expired
 * token because the guess was too generous. If there is no readable exp, the configured
 * fallback applies.
 */
function tokenLifetimeSeconds(accessToken, configuration) {
  try {
    const segments = String(accessToken).split(".");
    if (segments.length === 3) {
      const payload = JSON.parse(encoding.b64decode(segments[1], "rawurl", "s"));
      if (payload && typeof payload.exp === "number") {
        const secondsRemaining = Math.round(payload.exp - Date.now() / 1000);
        if (secondsRemaining > 0) {
          return secondsRemaining;
        }
      }
    }
  }
  catch (ignored) {
    // Opaque token, or a JWT this runtime cannot decode: use the configured lifetime.
  }

  return configuration.fallbackLifetimeSeconds;
}

/* JSON-escape a value for substitution into a body template, without its quotes. */
function jsonStringBody(value) {
  const encoded = JSON.stringify(String(value));
  return encoded.slice(1, encoded.length - 1);
}

/*
 * Log in against a bespoke JSON endpoint.
 *
 * This is the reason the mode exists: a first-party identity API usually takes
 * application/json, has no grant types, and answers with the token nested somewhere like
 * {"data":{"accessToken":"..."}}. Sending it a form-encoded body - which is what the
 * OAuth2 path does - gets a 415 or a 400 that names nothing useful.
 */
function requestJsonLoginToken(configuration) {
  const body = configuration.loginBody === ""
    ? JSON.stringify({
        Email: configuration.username,
        Password: configuration.password,
        RememberMe: true,
      })
    : configuration.loginBody
        .replace(/\{\{username\}\}/g, jsonStringBody(configuration.username))
        .replace(/\{\{password\}\}/g, jsonStringBody(configuration.password));

  const response = http.post(configuration.loginUrl, body, {
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    // Same reason as the OAuth2 path: discardResponseBodies would empty this response
    // and leave the token unreadable, while the POST itself still looked healthy.
    responseType: "text",
    tags: { name: "auth/login" },
  });

  if (response.status < 200 || response.status >= 300) {
    let detail = "";
    try {
      detail = String(response.body).slice(0, 300);
    }
    catch (ignored) {
      detail = "(body unavailable)";
    }

    throw new Error(
      "Login failed: HTTP " +
        response.status +
        " from " +
        configuration.loginUrl +
        ".\nResponse: " +
        detail +
        "\nCheck AUTH_USERNAME/AUTH_PASSWORD (or JOURNEY_USERNAME/JOURNEY_PASSWORD), and the login URL."
    );
  }

  let payload;
  try {
    payload = JSON.parse(response.body);
  }
  catch (error) {
    const raw = response.body === undefined || response.body === null ? "" : String(response.body);
    throw new Error(
      "Login returned HTTP " +
        response.status +
        " but the body could not be parsed as JSON" +
        (raw === ""
          ? ". The body is EMPTY - the response was discarded (check discardResponseBodies and responseType)."
          : ". Got: " + raw.slice(0, 200))
    );
  }

  const accessToken = readJsonPath(payload, configuration.tokenPath);
  if (!accessToken) {
    throw new Error(
      "Login response has no token at '" +
        configuration.tokenPath +
        "'. Top-level keys: " +
        (payload ? Object.keys(payload).join(", ") : "(no object)") +
        ". Set AUTH_TOKEN_PATH if the token lives elsewhere in the response."
    );
  }

  return finishToken(configuration, accessToken, "", tokenLifetimeSeconds(accessToken, configuration));
}

function requestOAuth2Token(configuration) {
  const pairs = [["grant_type", configuration.grantType]];

  if (configuration.grantType === "password") {
    pairs.push(["username", configuration.username]);
    pairs.push(["password", configuration.password]);
  }
  else {
    pairs.push(["client_id", configuration.clientId]);
    pairs.push(["client_secret", configuration.clientSecret]);
  }

  if (configuration.scope !== "") {
    pairs.push(["scope", configuration.scope]);
  }
  if (configuration.audience !== "") {
    pairs.push(["audience", configuration.audience]);
  }

  const response = http.post(configuration.tokenUrl, formEncode(pairs), {
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    // responseType is set explicitly, and that is load-bearing.
    //
    // Every scenario sets `discardResponseBodies: true` so the generator's memory is
    // not what is under test. That option discards THIS response too, so
    // response.json() has nothing to parse and throws - which fails the whole
    // iteration with a misleading "body is not JSON" error, while the token POST
    // itself succeeded and looks perfectly healthy in the metrics. Setting
    // responseType overrides discardResponseBodies for this one request.
    responseType: "text",
    tags: { name: "auth/token" },
  });

  if (response.status < 200 || response.status >= 300) {
    // Include the response body: identity providers put the actual reason there
    // ("invalid_client", "invalid_scope"), and it is the difference between a
    // five-second fix and an afternoon.
    let detail = "";
    try {
      detail = String(response.body).slice(0, 300);
    }
    catch (ignored) {
      detail = "(body unavailable)";
    }

    throw new Error(
      "Token request failed: HTTP " +
        response.status +
        " from " +
        configuration.tokenUrl +
        ".\nResponse: " +
        detail +
        "\nCheck AUTH_CLIENT_ID/AUTH_CLIENT_SECRET/AUTH_SCOPE, and that the IdP allows this grant type."
    );
  }

  let payload;
  try {
    payload = JSON.parse(response.body);
  }
  catch (error) {
    const body = response.body === undefined || response.body === null ? "" : String(response.body);
    throw new Error(
      "Token endpoint returned HTTP " +
        response.status +
        " but the body could not be parsed as JSON" +
        (body === ""
          ? ". The body is EMPTY - if this is not a 204 response, the response was discarded " +
            "(check discardResponseBodies and that this request sets responseType)."
          : ". Got: " + body.slice(0, 200))
    );
  }

  if (!payload || typeof payload.access_token !== "string" || payload.access_token === "") {
    throw new Error(
      "Token response has no access_token field. Got keys: " +
        (payload ? Object.keys(payload).join(", ") : "(no object)")
    );
  }

  // expires_in is seconds and optional in the specification. Defaulting to an hour and
  // then refreshing against that assumption is worse than refreshing often, so when it
  // is absent the kit renews every 5 minutes instead.
  let lifetimeSeconds = Number(payload.expires_in);
  if (!isFinite(lifetimeSeconds) || lifetimeSeconds <= 0) {
    lifetimeSeconds = 300;
  }

  return finishToken(configuration, payload.access_token, payload.token_type || "", lifetimeSeconds);
}

/*
 * Assemble the cached token and log it. Shared by both mechanisms so the renewal
 * arithmetic cannot drift between them.
 */
function finishToken(configuration, accessToken, tokenType, lifetimeSeconds) {
  // Never let the safety margin exceed the lifetime, or the token is considered expired
  // the moment it is issued and every iteration fetches a new one.
  const skew = Math.min(configuration.expirySkewSeconds, Math.floor(lifetimeSeconds / 2));

  const token = {
    value: accessToken,
    expiresAt: Date.now() + (lifetimeSeconds - skew) * 1000,
    tokenType: tokenType,
    lifetimeSeconds: lifetimeSeconds,
  };

  // Deliberately does NOT log the token itself - run logs get archived and shared.
  console.log(
    "[auth] obtained a token (" +
      lifetimeSeconds +
      "s lifetime, will renew in " +
      (lifetimeSeconds - skew) +
      "s, type " +
      (token.tokenType || "unspecified") +
      ")"
  );

  return token;
}

function currentToken() {
  const now = Date.now();

  if (cachedToken !== null && now < cachedToken.expiresAt) {
    return cachedToken;
  }

  cachedToken = requestToken(readAuthConfiguration());
  return cachedToken;
}

/*
 * Called by lib/env.js, and available to any scenario that needs to build its own
 * request. Returns {} when no token endpoint is configured, so callers can merge it
 * unconditionally.
 */
export function authHeaders() {
  if (!isAuthConfigured()) {
    return {};
  }

  const configuration = readAuthConfiguration();
  const token = currentToken();
  const headers = {};

  headers[configuration.tokenHeader] = configuration.tokenPrefix + token.value;
  return headers;
}

/*
 * Drop the cached token, so the next call fetches a new one.
 *
 * Useful in a scenario that receives a 401 mid-run - a token revoked out of band, or
 * an IdP restart - and wants to retry rather than fail every remaining iteration
 * with credentials it believes are still valid.
 */
export function invalidateAuthToken() {
  cachedToken = null;
}

/* Seconds until the cached token is renewed, or null when nothing is cached. */
export function authTokenSecondsRemaining() {
  if (cachedToken === null) {
    return null;
  }
  return Math.max(0, Math.round((cachedToken.expiresAt - Date.now()) / 1000));
}

/*
 * FETCHING THE TOKEN ONCE INSTEAD OF PER VU
 * ----------------------------------------
 * k6 runs each VU in its own runtime, so the cache above is per-VU and N VUs make N
 * token requests. When that matters, fetch in setup() and hand the token to the VUs:
 *
 *   import { fetchTokenForSetup, authHeadersFromToken } from "./lib/auth.js";
 *
 *   export function setup() {
 *     return { token: fetchTokenForSetup() };
 *   }
 *
 *   export default function (data) {
 *     const response = http.get(targetUrl, {
 *       headers: { ...authHeadersFromToken(data.token) },
 *     });
 *   }
 *
 * The returned value crosses a JSON boundary, so only the string travels; setup()
 * runs once for the whole test, which is the point.
 */
export function fetchTokenForSetup() {
  return currentToken().value;
}

export function authHeadersFromToken(tokenValue) {
  if (!isAuthConfigured() || !tokenValue) {
    return {};
  }

  const configuration = readAuthConfiguration();
  const headers = {};
  headers[configuration.tokenHeader] = configuration.tokenPrefix + tokenValue;
  return headers;
}
