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
    // Cookies share a hostname across IIS application paths and local listener ports.
    check(issuer.hostname === api.hostname, 'shared_hostname_cookie_scope');
    const issuerBase = issuer.pathname.replace(/\/$/, '');
    const apiBase = api.pathname.replace(/\/$/, '');
    await page.goto(new URL(issuerBase + '/.well-known/openid-configuration', issuer).href);
    const session = await page.evaluate(async base => {
      const diagnostic = await fetch(base + '/diagnostics/windows-auth');
      const identity = await diagnostic.json();
      const csrf = await (await fetch(base + '/csrf')).json();
      const response = await fetch(base + '/session', { method: 'POST', headers: { 'X-CSRF-TOKEN': csrf.requestToken } });
      return { status: response.status, windows: identity.identityType === 'WindowsIdentity' && identity.hasSidClaim };
    }, issuerBase);
    check(session.windows && session.status === 204, 'real_windows_database_session');
    const access = (await page.context().cookies(issuer.origin)).find(cookie => cookie.name === 'dab_access_token');
    check(access?.httpOnly && access.secure && access.path === '/' && access.domain === issuer.hostname, 'issuer_host_only_secure_cookie');
    // Values stay in process memory. Never serialize claims or the token into results.
    const claims = JSON.parse(Buffer.from(access.value.split('.')[1], 'base64url').toString());
    const role = Array.isArray(claims.roles) ? claims.roles[0] : claims.roles;
    check(Boolean(role && claims.profile_id && claims.sub), 'persisted_profile_and_roles_present');
    stage = 'api_navigation';
    await page.goto(new URL(apiBase + '/host', api).href);
    stage = 'api_cookie_visibility';
    check(!(await page.evaluate(() => document.cookie)).includes('dab_access_token'), 'access_cookie_hidden_at_api_origin');
    stage = 'api_requests';
    const exercise = await page.evaluate(async ({ role, rowId, base }) => {
      const checks = {};
      let phase = 'csrf';
      try {
      const headers = { 'X-MS-API-ROLE': role };
      const csrfResponse = await fetch(base + '/bridge/csrf', { headers });
      const csrf = await csrfResponse.json();
      const writeHeaders = { ...headers, 'X-CSRF-TOKEN': csrf.requestToken, 'Content-Type': 'application/json' };
      phase = 'rest_read';
      const rest = await fetch(base + '/api/Widget', { headers });
      const restBody = await rest.json();
      checks.rest_read = rest.status === 200 && restBody.value?.some(row => row.name === 'fixture-one');
      phase = 'graphql_read';
      const graph = await fetch(base + '/graphql?query=' + encodeURIComponent('{ widgets { items { id name } } }'), { headers });
      const graphBody = await graph.json();
      checks.graphql_read = graph.status === 200 && !graphBody.errors && graphBody.data?.widgets?.items?.some(row => row.name === 'fixture-one');
      phase = 'missing_csrf';
      const missingRest = await fetch(base + '/api/Widget', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ id: 88, name: 'must-not-create', quantity: 1 }) });
      const missingGraph = await fetch(base + '/graphql', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: 'mutation { createWidget(item: { id: 89, name: "must-not-create", quantity: 1 }) { id } }' }) });
      checks.rest_missing_csrf = missingRest.status === 400;
      checks.graphql_missing_csrf = missingGraph.status === 400;
      phase = 'rest_mutation';
      const created = await fetch(base + '/api/Widget', { method: 'POST', headers: writeHeaders, body: JSON.stringify({ id: rowId, name: 'real-chain-rest', quantity: 1 }) });
      checks.rest_cookie_mutation = created.status === 201;
      phase = 'graphql_mutation';
      const createdGraph = await fetch(base + '/graphql', { method: 'POST', headers: writeHeaders, body: JSON.stringify({ query: `mutation { createWidget(item: { id: ${rowId + 1}, name: "real-chain-graphql", quantity: 1 }) { id name } }` }) });
      const createdGraphBody = await createdGraph.json();
      checks.graphql_cookie_mutation = createdGraph.status === 200 && !createdGraphBody.errors && createdGraphBody.data?.createWidget?.id === rowId + 1;
      phase = 'permission_denial';
      const denied = await fetch(base + '/api/RetiredWidget', { method: 'POST', headers: writeHeaders, body: JSON.stringify({ name: 'must-not-create' }) });
      checks.configured_rest_write_denial = [401,403].includes(denied.status);
      const deniedGraph = await fetch(base + '/graphql', { method: 'POST', headers: writeHeaders, body: JSON.stringify({ query: 'mutation { createRetiredWidget(item: { name: "must-not-create" }) { id } }' }) });
      const deniedGraphBody = await deniedGraph.json();
      checks.configured_graphql_write_denial = [400,401,403].includes(deniedGraph.status) || (Boolean(deniedGraphBody.errors?.length) && !deniedGraphBody.data?.createRetiredWidget);
      phase = 'ungranted_role';
      const forged = { 'X-MS-API-ROLE': 'ungranted-live-proof-role' };
      const forgedRest = await fetch(base + '/api/Widget', { headers: forged });
      const forgedGraph = await fetch(base + '/graphql?query=' + encodeURIComponent('{ widgets { items { id } } }'), { headers: forged });
      const forgedBody = [400,401,403].includes(forgedGraph.status) ? {} : await forgedGraph.json();
      checks.rest_ungranted_role = [401,403].includes(forgedRest.status);
      checks.graphql_ungranted_role = [400,401,403].includes(forgedGraph.status) || (Boolean(forgedBody.errors?.length) && !forgedBody.data?.widgets);
      phase = 'cleanup';
      const removed = await fetch(base + '/api/Widget/id/' + rowId, { method: 'DELETE', headers: writeHeaders });
      const removedGraph = await fetch(base + '/graphql', { method: 'POST', headers: writeHeaders, body: JSON.stringify({ query: `mutation { deleteWidget(id: ${rowId + 1}) { id } }` }) });
      const removedBody = await removedGraph.json();
      checks.disposable_rows_deleted = [200,204].includes(removed.status) && !removedBody.errors && removedBody.data?.deleteWidget?.id === rowId + 1;
      } catch { checks[`runtime_${phase}`] = false; }
      return checks;
    }, { base: apiBase, role, rowId: 1000 + Math.floor(Math.random() * 1000000) * 2 });
    for (const [name, passed] of Object.entries(exercise)) check(passed, name);
    await page.goto(new URL(issuerBase + '/.well-known/openid-configuration', issuer).href);
    const logout = await page.evaluate(async base => {
      const csrf = await (await fetch(base + '/csrf')).json();
      return (await fetch(base + '/session/logout', { method: 'POST', headers: { 'X-CSRF-TOKEN': csrf.requestToken } })).status;
    }, issuerBase);
    check(logout === 204, 'issuer_logout');
    check(!(await page.context().cookies(api.origin)).some(cookie => cookie.name === 'dab_access_token'), 'browser_logout_removes_api_credential');
    await page.goto(new URL(apiBase + '/host', api).href);
    const anonymous = await page.evaluate(async base => {
      const rest = await fetch(base + '/api/Widget');
      const graph = await fetch(base + '/graphql?query=' + encodeURIComponent('{ widgets { items { id } } }'));
      const body = await graph.json();
      return { rest: [401,403].includes(rest.status), graph: [400,401,403].includes(graph.status) || (Boolean(body.errors?.length) && !body.data?.widgets) };
    }, apiBase);
    check(anonymous.rest && anonymous.graph, 'rest_graphql_denied_after_logout');
  } catch (error) {
    const message = String(error?.message ?? '');
    result.failure = Object.hasOwn(result, message) ? message : `${stage}_${String(error?.name ?? 'error').toLowerCase()}`;
  }
  return `DAB_ISSUER_BROWSER_RESULT:${JSON.stringify(result)}`;
}
