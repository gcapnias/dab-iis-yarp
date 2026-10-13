# Wiki.js on Windows behind IIS: application fit and deployment options

Research date: 2026-10-13\
Target: Windows Server 2025 Standard with IIS\
Status: source review only; no install, OAuth client, IIS configuration, or proxy topology tested.

## Which Wiki.js line to evaluate

Use the v2 maintenance line for a production candidate. The original [`requarks/wiki`](https://github.com/requarks/wiki) repository now describes its main line as Wiki.js 3.0 beta and says it is not for production; it points stable 2.x users to [`requarks/wiki-v2`](https://github.com/requarks/wiki-v2). The v2 repository identifies itself as the maintenance version and currently lists **v2.5.316** as its latest release. The release state is easy to misread because the original repo's “latest” release may be a 3.0 beta. Pin an explicit v2 release artifact/tag instead of following an ambiguous “latest” URL. [Original repo README](https://github.com/requarks/wiki) [v2 maintenance repo](https://github.com/requarks/wiki-v2) [v2 releases](https://github.com/requarks/wiki-v2/releases)

## Runtime and database requirements

The maintained v2 requirements page explicitly lists Windows as supported wherever Node.js is supported. It does not name Windows Server 2025 or promise an IIS-specific deployment, so the target is plausible but still needs a real install and smoke test on Server 2025. The current v2 requirements page lists **Node.js 22.0+ and 24.0+**, supported since Wiki.js 2.5.302; that baseline predates and applies to current v2.5.316. The exact v2.5.316 `package.json` says `engines.node >=20`; this broader package metadata is not the same as the narrower explicit supported-version list. For a supported deployment target, use Node 22 or 24 and keep the Wiki.js release explicit. [v2 requirements](https://github.com/requarks/wiki-docs-v2/blob/master/install/requirements.md) [v2.5.316 package.json](https://github.com/requarks/wiki-v2/blob/v2.5.316/package.json)

Wiki.js recommends PostgreSQL and supports PostgreSQL 9.5 or later in v2. Stable v2 also lists MySQL 8+, MariaDB 10.2.7+, SQL Server 2012+, and SQLite 3.9+; it warns SQLite is not recommended for production. It also states MySQL, MariaDB, SQL Server, and SQLite will not be supported by 3.x, so PostgreSQL is the lower-friction choice if a future major upgrade matters. Wiki.js expects the database to exist already and recommends an empty database and distinct credentials. [v2 requirements](https://github.com/requarks/wiki-docs-v2/blob/master/install/requirements.md)

## IIS role and listener configuration

Wiki.js supplies its own HTTP server and says it does not need a web server. Its official Windows instructions install the Windows archive, rename `config.sample.yml` to `config.yml`, set database/port values, then run `node server`; the docs mention operating it as a background service. This is a direct fit for an IIS front end proxying to a separately supervised Node process. [Windows installation](https://github.com/requarks/wiki-docs-v2/blob/master/install/windows.md) [v2 requirements](https://github.com/requarks/wiki-docs-v2/blob/master/install/requirements.md)

The Windows page names service options such as AlwaysUp, PM2 plus `pm2-windows-service`, `forever`, and `node-windows`, but this list is not a current support endorsement. If using a third-party wrapper such as WinSW, the upstream GitHub release page currently marks **v2.12.0 (2023-01-28)** as latest stable and **v3.0.0-alpha.11 (2023-01-29)** as a prerelease; the WinSW README says v3 development occurs on the default branch while releases contain stable 2.x and prerelease 3.x. This establishes release status, not an assurance of current maintenance or Microsoft support. Pin and assess the selected wrapper/release and its service-account, stop, restart, and logging behavior as its own dependency. [WinSW releases](https://github.com/winsw/winsw/releases) [WinSW README](https://github.com/winsw/winsw)

The v2 sample config defaults to `port: 3000` and `bindIP: 0.0.0.0`. `port` is the Node listener port, distinct from IIS's public 80/443 bindings. For a proxy topology, choose an explicit backend port and bind only to loopback where the selected hosting model permits it; the public listener belongs to IIS. The sample config also has a separate `ssl` block, default disabled, with an internal HTTPS port. For TLS termination at IIS, leave Wiki.js's own HTTPS disabled unless the IIS-to-Node hop has a specific encryption requirement. [v2 sample config](https://github.com/requarks/wiki-v2/blob/main/config.sample.yml) [v2 configuration reference](https://github.com/requarks/wiki-docs-v2/blob/master/install/config.md)

### Candidate fit

| Option | Wiki.js fit based on its published contract | What remains to prove |
| --- | --- | --- |
| IIS ARR + URL Rewrite → standalone Node service | Strong fit to the documented installation model: Wiki.js owns a fixed configured HTTP port and can run as `node server`; IIS forwards requests to that listener. | Configure the public host/site URL, trusted forwarded scheme/host, loopback reachability, and WebSocket upgrade path; test login, assets, editing, and sockets on the actual IIS/ARR build. |
| HTTP Platform Handler (HPH) launches Node | Potential fit, conditional on passing the HPH-assigned backend port into Wiki.js. Wiki.js documents `$(ENV_NAME)` interpolation in `config.yml`; if HPH provides `HTTP_PLATFORM_PORT`, a config value such as `port: $(HTTP_PLATFORM_PORT)` is a candidate integration. | This is an inference from two independent contracts, not a tested Wiki.js/HPH combination. Confirm HPH process startup, environment injection, process recycle behavior, configured listener bind address, and WebSockets. HPH compatibility details are covered in the separate HPH research. |
| IIS-hosted ASP.NET Core YARP gateway (ANCM) → independently supervised Node service | The Wiki.js side remains an ordinary fixed-port HTTP backend, so YARP can route to it without changing the Wiki.js application. YARP runs in the IIS worker process through ASP.NET Core Module (ANCM); Node remains a separate process with its own supervisor. | Validate the exact IIS/ANCM/YARP configuration, public TLS termination, forwarded-header transforms, WebSocket upgrades/timeouts, and Node service startup ordering. YARP itself does not supervise Node. |

`iisnode` is omitted per the user's explicit exclusion. These are fit assessments, not successful deployment evidence. The IIS product choice does not change Wiki.js's authentication or application URL requirements.

## Public URL, reverse proxy, and base-path constraints

Wiki.js **cannot be hosted under a URL subfolder** such as `https://example.com/wiki`; the v2 requirements and troubleshooting docs say to use a dedicated domain/subdomain. The IIS site should route Wiki.js at `/` for its hostname. [v2 requirements](https://github.com/requarks/wiki-docs-v2/blob/master/install/requirements.md) [v2 troubleshooting](https://github.com/requarks/wiki-docs-v2/blob/master/troubleshooting.md)

Do not put the public URL into a made-up `host` key in `config.yml`: the v2 sample config has `port`, `bindIP`, database, TLS and related settings, but no top-level public `host` property. Set the public **Site URL** in Wiki.js Administration → General. The current documentation references this setting as “Site URL field in Admin > General.” This must be the browser-facing scheme and hostname, e.g. `https://wiki.example.com`, with no backend port when IIS serves standard HTTPS on 443. [v2 sample config](https://github.com/requarks/wiki-v2/blob/main/config.sample.yml) [Wiki.js v2 release notes](https://docs.requarks.io/releases/previous)

The v2 config reference explicitly says reverse-proxy TLS termination should be handled by the reverse proxy, not Wiki.js. Proxy the public HTTPS site to Wiki.js's configured HTTP port and ensure the application observes the public host/scheme needed to build links and OAuth redirects. Wiki.js docs describe the public URL as an Admin setting; do not assume IIS automatically changes that setting or that merely preserving the `Host` header fixes an incorrect saved Site URL. [v2 configuration reference](https://github.com/requarks/wiki-docs-v2/blob/master/install/config.md)

## WebSockets

The v2.5.316 source installs GraphQL subscription handlers on both its HTTP and HTTPS servers, and configures the subscription path as `/graphql-subscriptions`. Therefore IIS must preserve WebSocket upgrades on that path. Treat WebSockets as a required acceptance path for the deployed app, not an optional proxy enhancement. Microsoft's IIS documentation notes WebSocket Protocol support is an IIS feature and specifically cautions that Node.js Socket.IO deployments may need the IIS WebSocket module disabled so it does not intercept the app's WebSocket handling. That Socket.IO caveat is not a blanket configuration for Wiki.js; test the actual Wiki.js endpoint and exact IIS/proxy modules. [Wiki.js v2.5.316 HTTP server source](https://github.com/requarks/wiki-v2/blob/v2.5.316/server/core/servers.js) [Microsoft IIS WebSocket support](https://learn.microsoft.com/en-us/iis/get-started/whats-new-in-iis-8/iis-80-websocket-protocol-support)

## Google sign-in: Wiki.js handles the application authentication

Yes. IIS can terminate TLS and proxy requests, while Wiki.js's own Google authentication strategy handles the OAuth login and its Wiki.js session. The official Wiki.js guide has operators enable **Administration → Authentication → Google**, enter the OAuth **Client ID** and **Client Secret**, choose whether to allow self-registration and the group for new users, activate the strategy, and apply the change. The Google strategy configuration and Wiki.js groups therefore control the application's sign-in and authorization behavior; IIS is not the Google identity provider and does not replace those controls. [Wiki.js Google authentication](https://docs.requarks.io/auth/google) [Wiki.js users, groups, and permissions](https://docs.requarks.io/groups)

Wiki.js instructs the administrator to copy the Google strategy's generated redirect URI from its **Configuration Reference** into the Google OAuth client's **Authorized redirect URIs**, and to register the Wiki.js domain as an authorized JavaScript origin. Use the generated value from the running v2 site instead of guessing it. The public callback must use the externally visible HTTPS origin and route, not `http://localhost:3000` or the internal HTTP backend. Google requires the `redirect_uri` in the authorization request to exactly match an authorized redirect URI (including scheme, host, path, and trailing slash), and its production policies require HTTPS origins and redirect URIs. Correct public Site URL/forwarded host and scheme are therefore material to Google sign-in behind IIS. [Wiki.js Google authentication](https://docs.requarks.io/auth/google) [Google OAuth web-server flow](https://developers.google.com/identity/protocols/oauth2/web-server) [Google OAuth policies](https://developers.google.com/identity/protocols/oauth2/policies)

**Stale step in Wiki.js's Google page:** it still tells operators to enable the Google+ API. Google shut down the legacy Google+ APIs on March 7, 2019. Do not follow that old API-enable instruction as a current prerequisite; configure the current OAuth web client and use the exact callback URI supplied by Wiki.js. The Wiki.js v2 package does include `passport-google-oauth20`, which is consistent with its Google OAuth strategy. [Wiki.js Google authentication (last edited 2019)](https://docs.requarks.io/auth/google) [Google+ API shutdown](https://developers.googleblog.com/google-apis-shutting-down-march-7-2019/) [v2 package.json](https://github.com/requarks/wiki-v2/blob/main/package.json)

## Windows Server 2025 decision boundary

First-party Wiki.js docs support Windows generically, but do not specifically certify Windows Server 2025 Standard or IIS. Windows Server 2025 with an explicit stable v2 release, supported Node 22/24, and an external IIS reverse proxy is a reasonable candidate to evaluate. Keep the later guidance honest about the evidence boundary: source docs establish the application contract; a Server 2025 deployment and Google round-trip still need to be run before describing the stack as validated.

## Sources

- [Wiki.js original repository (3.x beta line)](https://github.com/requarks/wiki)
- [Wiki.js v2 maintenance repository](https://github.com/requarks/wiki-v2)
- [Wiki.js v2 releases](https://github.com/requarks/wiki-v2/releases)
- [Wiki.js v2 requirements](https://github.com/requarks/wiki-docs-v2/blob/master/install/requirements.md)
- [Wiki.js v2 Windows installation](https://github.com/requarks/wiki-docs-v2/blob/master/install/windows.md)
- [Wiki.js v2 configuration reference](https://github.com/requarks/wiki-docs-v2/blob/master/install/config.md)
- [Wiki.js v2 sample config](https://github.com/requarks/wiki-v2/blob/main/config.sample.yml)
- [Wiki.js v2 package.json](https://github.com/requarks/wiki-v2/blob/main/package.json)
- [Wiki.js v2.5.316 package.json](https://github.com/requarks/wiki-v2/blob/v2.5.316/package.json)
- [Wiki.js v2.5.316 config interpolation source](https://github.com/requarks/wiki-v2/blob/v2.5.316/server/helpers/config.js)
- [Wiki.js v2.5.316 HTTP and GraphQL subscription source](https://github.com/requarks/wiki-v2/blob/v2.5.316/server/core/servers.js)
- [Wiki.js v2 troubleshooting](https://github.com/requarks/wiki-docs-v2/blob/master/troubleshooting.md)
- [Wiki.js Google authentication](https://docs.requarks.io/auth/google)
- [Wiki.js users, groups, and permissions](https://docs.requarks.io/groups)
- [Google OAuth 2.0 web-server flow](https://developers.google.com/identity/protocols/oauth2/web-server)
- [Google OAuth 2.0 policies](https://developers.google.com/identity/protocols/oauth2/policies)
- [Google+ API shutdown notice](https://developers.googleblog.com/google-apis-shutting-down-march-7-2019/)
- [Microsoft IIS WebSocket Protocol support](https://learn.microsoft.com/en-us/iis/get-started/whats-new-in-iis-8/iis-80-websocket-protocol-support)
