async page => {
  const options = __OPTIONS__;
  const result = {};
  let stage = "browser_startup";
  const fail = name => { throw new Error(`Browser check failed: ${name}`); };
  const requireCheck = (condition, name) => { result[name] = Boolean(condition); if (!condition) fail(name); };
  try {
  const issuer = new URL(options.issuer);
  const discoveryUrl = new URL(`${issuer.pathname.replace(/\/$/, "")}/.well-known/openid-configuration`, issuer.origin);
  const discoveryResponse = await page.goto(discoveryUrl.toString());
  requireCheck(discoveryResponse?.status() === 200, "discovery_status");
  const metadata = await page.evaluate(async url => await (await fetch(url, { credentials: "omit" })).json(), discoveryUrl.toString());
  requireCheck(new URL(metadata.issuer).href === new URL(options.issuer).href, "discovery_issuer_matches");
  const basePath = new URL(metadata.issuer).pathname.replace(/\/$/, "");
  const endpoint = name => `${basePath}/${name}`;
  const callbackUri = new URL(options.redirectUri);
  requireCheck(callbackUri.origin === issuer.origin && callbackUri.pathname === endpoint("oidc-browser-test/callback"), "same_origin_test_callback_configured");

  const identityResponse = await page.evaluate(async path => {
    const response = await fetch(path, { credentials: "same-origin" });
    return { status: response.status, identity: await response.json() };
  }, endpoint("diagnostics/windows-auth"));
  if (identityResponse.status !== 200) fail(`windows_auth_diagnostic_status_${identityResponse.status}`);
  const identity = identityResponse.identity;
  requireCheck(identity.identityType === "WindowsIdentity" && identity.hasSidClaim && identity.hasRequestWindowsIdentity && identity.hasRequestWindowsIdentityUser, "request_windows_sid_binding_available");

  const csrfResponse = await page.evaluate(async path => await (await fetch(path, { credentials: "same-origin" })).json(), endpoint("csrf"));
  requireCheck(typeof csrfResponse.requestToken === "string" && csrfResponse.requestToken.length > 20, "windows_authenticated_csrf");
  const csrfCookie = (await page.context().cookies(issuer.origin)).find(cookie => cookie.name === "issuer_csrf");
  requireCheck(Boolean(csrfCookie?.httpOnly && csrfCookie.secure && csrfCookie.sameSite?.toLowerCase() === "strict"), "antiforgery_cookie_flags");

  const missingCsrf = await page.evaluate(async path => {
    const response = await fetch(path, { method: "POST", credentials: "same-origin" });
    return { status: response.status };
  }, endpoint("session"));
  requireCheck(missingCsrf.status === 400, "missing_csrf_rejected");

  const createSession = await page.evaluate(async ({ path, token }) => {
    const response = await fetch(path, { method: "POST", credentials: "same-origin", headers: { "X-CSRF-TOKEN": token } });
    return { status: response.status };
  }, { path: endpoint("session"), token: csrfResponse.requestToken });
  requireCheck(createSession.status === 204, "windows_session_created");
  const documentCookies = await page.evaluate(() => document.cookie);
  requireCheck(!documentCookies.includes(options.accessCookieName) && !documentCookies.includes(options.refreshCookieName), "session_cookies_hidden_from_javascript");

  const cookieSnapshot = await page.context().cookies(issuer.origin);
  const access = cookieSnapshot.find(cookie => cookie.name === options.accessCookieName);
  const refresh = cookieSnapshot.find(cookie => cookie.name === options.refreshCookieName);
  requireCheck(Boolean(access?.httpOnly && access.secure && access.sameSite?.toLowerCase() === "lax" && access.path === "/" && access.expires > Date.now() / 1000), "access_cookie_attributes");
  requireCheck(Boolean(refresh?.httpOnly && refresh.secure && refresh.sameSite?.toLowerCase() === "strict" && refresh.path === (basePath || "/") && refresh.expires > Date.now() / 1000), "refresh_cookie_attributes");
  requireCheck(Boolean(access && refresh && (!options.cookieDomain || (access.domain === options.cookieDomain && refresh.domain === options.cookieDomain))), "host_or_configured_domain_scope");

  const oldRefreshValue = refresh.value;
  const rotate = await page.evaluate(async ({ path, token }) => {
    const response = await fetch(path, { method: "POST", credentials: "same-origin", headers: { "X-CSRF-TOKEN": token } });
    return { status: response.status };
  }, { path: endpoint("session/refresh"), token: csrfResponse.requestToken });
  requireCheck(rotate.status === 204, "session_refresh_rotated");
  const secondRotation = await page.evaluate(async ({ path, token }) => {
    const response = await fetch(path, { method: "POST", credentials: "same-origin", headers: { "X-CSRF-TOKEN": token } });
    return { status: response.status };
  }, { path: endpoint("session/refresh"), token: csrfResponse.requestToken });
  if (secondRotation.status !== 204) fail(`browser_stored_rotated_refresh_cookie_status_${secondRotation.status}`);
  await page.context().addCookies([{ ...refresh, value: oldRefreshValue }]);
  const replay = await page.evaluate(async ({ path, token }) => {
    const response = await fetch(path, { method: "POST", credentials: "same-origin", headers: { "X-CSRF-TOKEN": token } });
    return { status: response.status };
  }, { path: endpoint("session/refresh"), token: csrfResponse.requestToken });
  requireCheck(replay.status === 401, "replayed_refresh_rejected");

  const secondSession = await page.evaluate(async ({ path, token }) => {
    const response = await fetch(path, { method: "POST", credentials: "same-origin", headers: { "X-CSRF-TOKEN": token } });
    return { status: response.status };
  }, { path: endpoint("session"), token: csrfResponse.requestToken });
  requireCheck(secondSession.status === 204, "session_recreated_before_logout");
  const logout = await page.evaluate(async ({ path, token }) => {
    const response = await fetch(path, { method: "POST", credentials: "same-origin", headers: { "X-CSRF-TOKEN": token } });
    return { status: response.status };
  }, { path: endpoint("session/logout"), token: csrfResponse.requestToken });
  requireCheck(logout.status === 204, "session_logout");
  const afterLogout = await page.context().cookies(issuer.origin);
  requireCheck(!afterLogout.some(cookie => cookie.name === options.accessCookieName || cookie.name === options.refreshCookieName), "logout_removed_session_cookies");

  const bytesToBase64Url = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const nonceBytes = crypto.getRandomValues(new Uint8Array(24));
  const verifierBytes = crypto.getRandomValues(new Uint8Array(32));
  const nonce = bytesToBase64Url(nonceBytes);
  const state = bytesToBase64Url(crypto.getRandomValues(new Uint8Array(24)));
  const verifier = bytesToBase64Url(verifierBytes);
  const challenge = bytesToBase64Url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  const authorize = new URL(metadata.authorization_endpoint);
  authorize.search = new URLSearchParams({
    client_id: options.clientId,
    redirect_uri: options.redirectUri,
    response_type: "code",
    scope: "openid profile roles offline_access",
    state,
    nonce,
    code_challenge: challenge,
    code_challenge_method: "S256"
  }).toString();
  stage = "oidc_callback_navigation";
  const callbackResponse = await page.goto(authorize.toString());
  const callbackLocation = new URL(page.url());
  // Keep the code in this test's memory only, even if a later assertion fails.
  try { await page.evaluate(() => history.replaceState(null, "", location.pathname)); } catch { }
  requireCheck(callbackResponse?.status() === 200, "oidc_callback_loaded");
  requireCheck(callbackLocation.origin === callbackUri.origin && callbackLocation.pathname === callbackUri.pathname, "oidc_callback_origin_and_path");
  requireCheck(callbackLocation.searchParams.get("state") === state, "oidc_callback_state_matches");
  const code = callbackLocation.searchParams.get("code");
  requireCheck(Boolean(code), "windows_oidc_authorize_returned_code");
  requireCheck(await page.evaluate(tokenEndpoint => location.origin === new URL(tokenEndpoint).origin, metadata.token_endpoint), "oidc_token_fetch_same_origin");
  stage = "oidc_code_pkce_exchange";
  const oidcTokens = await page.evaluate(async ({ tokenEndpoint, clientId, accessAudience, redirectUri, code, verifier, nonce, issuer, jwksUri }) => {
    let operation = "token_post";
    try {
    const form = new URLSearchParams({ grant_type: "authorization_code", client_id: clientId, redirect_uri: redirectUri, code, code_verifier: verifier });
    const response = await fetch(tokenEndpoint, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: form });
    if (!response.ok) return { status: response.status };
    const tokens = await response.json();
    const decode = value => JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=")), c => c.charCodeAt(0))));
    operation = "jwks_fetch";
    const jwks = await (await fetch(jwksUri)).json();
    const validate = async token => {
      if (typeof token !== "string") return false;
      const [encodedHeader, encodedPayload, encodedSignature] = token.split(".");
      if (!encodedSignature) return false;
      const header = decode(encodedHeader);
      const payload = decode(encodedPayload);
      const key = jwks.keys.find(item => item.kid === header.kid && item.alg === "RS256");
      if (!key) return false;
      const cryptoKey = await crypto.subtle.importKey("jwk", key, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
      const signature = Uint8Array.from(atob(encodedSignature.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(encodedSignature.length / 4) * 4, "=")), c => c.charCodeAt(0));
      const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", cryptoKey, signature, new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`));
      return valid && header.alg === "RS256" && payload.iss === issuer && Number(payload.exp) > Date.now() / 1000;
    };
    const id = typeof tokens.id_token === "string" ? decode(tokens.id_token.split(".")[1]) : {};
    const access = typeof tokens.access_token === "string" ? decode(tokens.access_token.split(".")[1]) : {};
    operation = "id_token_signature";
    const idValid = await validate(tokens.id_token);
    operation = "access_token_signature";
    const accessValid = await validate(tokens.access_token);
    const audience = value => (Array.isArray(value) ? value : [value]).includes(clientId);
    const hasAccessAudience = value => (Array.isArray(value) ? value : [value]).includes(accessAudience);
    operation = "refresh_post";
    const rotatedResponse = await fetch(tokenEndpoint, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "refresh_token", client_id: clientId, refresh_token: tokens.refresh_token }) });
    const rotated = rotatedResponse.ok ? await rotatedResponse.json() : {};
    const replayResponse = await fetch(tokenEndpoint, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "refresh_token", client_id: clientId, refresh_token: tokens.refresh_token }) });
    const descendantResponse = await fetch(tokenEndpoint, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ grant_type: "refresh_token", client_id: clientId, refresh_token: rotated.refresh_token ?? "" }) });
    return {
      status: response.status,
      idTokenValid: idValid && audience(id.aud) && id.nonce === nonce && Boolean(id.sub),
      accessTokenValid: accessValid && hasAccessAudience(access.aud) && Boolean(access.sub),
      accessClaimContract: Boolean(access.profile_id) && (Boolean(access.role) || (Array.isArray(access.roles) && access.roles.length > 0)),
      refreshStatus: rotatedResponse.status,
      refreshRotated: Boolean(rotated.refresh_token && rotated.refresh_token !== tokens.refresh_token),
      replayStatus: replayResponse.status,
      descendantReplayStatus: descendantResponse.status
    };
    } catch (error) {
      return { runtimeFailure: `${operation}_${String(error?.name ?? "error").toLowerCase()}` };
    }
  }, {
    tokenEndpoint: metadata.token_endpoint,
    clientId: options.clientId,
    accessAudience: options.accessAudience,
    redirectUri: options.redirectUri,
    code,
    verifier,
    nonce,
    issuer: metadata.issuer,
    jwksUri: metadata.jwks_uri
  });
  result.oidc_token_status = oidcTokens.status;
  if (oidcTokens.runtimeFailure) fail(`oidc_${oidcTokens.runtimeFailure}`);
  requireCheck(oidcTokens.status === 200, "oidc_code_pkce_exchange");
  requireCheck(oidcTokens.idTokenValid, "oidc_id_token_signature_issuer_audience_nonce");
  requireCheck(oidcTokens.accessTokenValid && oidcTokens.accessClaimContract, "oidc_access_token_signature_claim_contract");
  requireCheck(oidcTokens.refreshStatus === 200 && oidcTokens.refreshRotated, "oidc_refresh_rotation");
  requireCheck(oidcTokens.replayStatus === 400 && oidcTokens.descendantReplayStatus === 400, "oidc_refresh_replay_family_revocation");

  stage = "complete";
  return `ISSUER_IIS_BROWSER_RESULT:${JSON.stringify(result)}`;
  } catch (error) {
    const check = String(error?.message ?? "").match(/Browser check failed: ([a-z0-9_]+)/);
    result.failure = check?.[1] ?? `${stage}_runtime_${String(error?.name ?? "error").toLowerCase()}`;
    try {
      const issuer = new URL(options.issuer);
      await page.goto(new URL(`${issuer.pathname.replace(/\/$/, "")}/.well-known/openid-configuration`, issuer.origin).toString(), { timeout: 5000 });
    } catch { }
    return `ISSUER_IIS_BROWSER_RESULT:${JSON.stringify(result)}`;
  }
}
