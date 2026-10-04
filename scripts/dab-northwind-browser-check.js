async page => {
  const options = __OPTIONS__;
  const result = {};
  let stage = 'issuer_session';
  const check = (condition, name) => {
    result[name] = Boolean(condition);
    if (!condition) throw new Error(name);
  };
  try {
    const issuer = new URL(options.issuer);
    const api = new URL(options.api);
    const issuerBase = issuer.pathname.replace(/\/$/, '');
    const apiBase = api.pathname.replace(/\/$/, '');
    check(issuer.hostname === api.hostname, 'shared_hostname_cookie_scope');
    await page.goto(new URL(issuerBase + '/.well-known/openid-configuration', issuer).href);
    const session = await page.evaluate(async base => {
      const identity = await (await fetch(base + '/diagnostics/windows-auth')).json();
      const csrf = await (await fetch(base + '/csrf')).json();
      const response = await fetch(base + '/session', { method: 'POST', headers: { 'X-CSRF-TOKEN': csrf.requestToken } });
      return { status: response.status, windows: identity.identityType === 'WindowsIdentity' && identity.hasSidClaim };
    }, issuerBase);
    check(session.windows && session.status === 204, 'real_windows_database_session');
    const access = (await page.context().cookies(issuer.origin)).find(cookie => cookie.name === 'dab_access_token');
    check(access?.httpOnly && access.secure && access.path === '/' && access.domain === issuer.hostname, 'issuer_host_only_secure_cookie');
    const claims = JSON.parse(Buffer.from(access.value.split('.')[1], 'base64url').toString());
    const role = Array.isArray(claims.roles) ? claims.roles[0] : claims.roles;
    check(Boolean(role && claims.profile_id && claims.sub), 'persisted_profile_and_roles_present');
    await page.goto(new URL(apiBase + '/host', api).href);
    stage = 'northwind_reads';
    const checks = await page.evaluate(async ({ base, role }) => {
      const headers = { 'X-MS-API-ROLE': role };
      const rest = await fetch(base + '/api/Products?$first=2', { headers });
      const products = await rest.json();
      const graph = await fetch(base + '/graphql?query=' + encodeURIComponent('{ products(first: 2) { items { ProductID ProductName } } }'), { headers });
      const graphBody = await graph.json();
      const nextUrl = products.nextLink ? new URL(products.nextLink, location.origin) : null;
      const next = nextUrl ? await fetch(nextUrl.href, { headers }) : null;
      const nextBody = next ? await next.json() : null;
      const denied = await fetch(base + '/api/Products', { headers: { 'X-MS-API-ROLE': 'ungranted-iis-proof-role' } });
      return {
        northwind_rest_chai_chang: rest.status === 200 && products.value?.[0]?.ProductID === 1 && products.value?.[0]?.ProductName === 'Chai' && products.value?.[1]?.ProductName === 'Chang',
        northwind_graphql_chai_chang: graph.status === 200 && !graphBody.errors && graphBody.data?.products?.items?.[0]?.ProductID === 1 && graphBody.data?.products?.items?.[1]?.ProductName === 'Chang',
        pagination_keeps_iis_application_path: nextUrl?.pathname === base + '/api/Products' && next?.status === 200 && nextBody.value?.[0]?.ProductID === 3,
        ungranted_role_denied: [401,403].includes(denied.status),
        same_process_rest_and_graphql: rest.headers.get('X-Spike-Process-Id') === graph.headers.get('X-Spike-Process-Id') && Boolean(rest.headers.get('X-Spike-Process-Id'))
      };
    }, { base: apiBase, role });
    for (const [name, passed] of Object.entries(checks)) check(passed, name);
    stage = 'logout';
    await page.goto(new URL(issuerBase + '/.well-known/openid-configuration', issuer).href);
    const logout = await page.evaluate(async base => {
      const csrf = await (await fetch(base + '/csrf')).json();
      return (await fetch(base + '/session/logout', { method: 'POST', headers: { 'X-CSRF-TOKEN': csrf.requestToken } })).status;
    }, issuerBase);
    check(logout === 204, 'issuer_logout');
    check(!(await page.context().cookies(api.origin)).some(cookie => cookie.name === 'dab_access_token'), 'browser_logout_removes_api_credential');
    await page.goto(new URL(apiBase + '/host', api).href);
    const denied = await page.evaluate(async base => {
      const rest = await fetch(base + '/api/Products');
      const graph = await fetch(base + '/graphql?query=' + encodeURIComponent('{ products(first: 1) { items { ProductID } } }'));
      const body = await graph.json();
      return [401,403].includes(rest.status) && ([400,401,403].includes(graph.status) || (Boolean(body.errors?.length) && !body.data?.products));
    }, apiBase);
    check(denied, 'rest_graphql_denied_after_logout');
  } catch (error) {
    const message = String(error?.message ?? '');
    result.failure = Object.hasOwn(result, message) ? message : `${stage}_${String(error?.name ?? 'error').toLowerCase()}`;
  }
  return `DAB_ISSUER_BROWSER_RESULT:${JSON.stringify(result)}`;
}
