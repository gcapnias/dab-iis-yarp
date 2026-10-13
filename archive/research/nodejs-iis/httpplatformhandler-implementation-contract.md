# HttpPlatformHandler implementation contract for Wiki.js

Research snapshot: 2026-10-13. This is a source-backed candidate for moving the existing Wiki.js v2.5.311 installation from the foreground `node server` process at `C:\wiki` to IIS. The requested future IIS physical path is `C:\inetpub\www-wikijs`. The origin IIS binding will use hostname `seedocs.dotsee.local`; the public Wiki.js URL remains `https://docs.dot-see.dev`. Confirm the existing certificate's SAN covers `seedocs.dotsee.local` before using it; no replacement certificate is assumed here. The Cloudflare Tunnel currently reaches the Node listener on port 80. No IIS installation, application change, service stop, or deployment was performed. This note defines a candidate IIS/HPH boundary and flags the steps that need an outage and end-to-end acceptance testing.

## Proposed process contract

IIS owns the HTTPS origin binding for `seedocs.dotsee.local`; the public URL is `https://docs.dot-see.dev`. HttpPlatformHandler (HPH) starts and supervises one Node process and proxies to the port HPH assigns. The Node process listens only on `127.0.0.1` at `HTTP_PLATFORM_PORT`. Do not configure the Wiki process to bind port 80/443 or a fixed backend port. Preserve the existing SQL Server connection and its TLS settings in the Wiki config; IIS/HPH does not replace or terminate that database connection. Also verify how the current scheduled launch authenticates to SQL Server: a new IIS app-pool identity is a different Windows security context, so do not assume Windows Integrated Authentication will continue to use the scheduled user's identity. Keep database TLS verification enabled.

Wiki.js v2.5.311 reads its configured numeric port and bind address and passes both to `listen()`. Its `PORT` fallback only applies when the configured port is less than 1 or `HEROKU` is set, so the ordinary sample `port: 3000` does not automatically accept HPH's port. The v2 config helper replaces `$(ENV_VAR)` before YAML parsing, making this the direct configuration candidate in the deployed `config.yml`:

```yaml
port: $(HTTP_PLATFORM_PORT)
bindIP: 127.0.0.1
```

HPH's documented examples pass `%HTTP_PLATFORM_PORT%` into the child process environment/arguments. Wiki.js's pre-YAML substitution means the injected digit string is parsed as the numeric YAML port. This exact combination is derived from the two projects' documented/source contracts; it has not been executed on the target server.

## Candidate application `web.config`

The sample assumes the x64 Node executable is at `C:\Program Files\nodejs\node.exe`; verify the actual installed path before using it. It assumes a small `iis-start.js` bootstrap at the physical root:

```js
// iis-start.js - candidate, not yet created or runtime-tested
process.chdir(__dirname)
require('./server')
```

Wiki.js v2 startup derives `WIKI.ROOTPATH` from `process.cwd()`, while HPH's configuration reference does not document a working-directory setting. Changing directory in this same-process bootstrap makes that dependency explicit; invoking the package's normal `node server` command with an absolute script path alone does not establish the working directory. Validate the exact v2.5.311 entrypoint path and config discovery before deployment.

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <clear />
      <add name="httpplatformhandler"
           path="*"
           verb="*"
           modules="httpPlatformHandler"
           resourceType="Unspecified" />
    </handlers>
    <httpPlatform processPath="C:\Program Files\nodejs\node.exe"
                  arguments="&quot;C:\inetpub\www-wikijs\iis-start.js&quot;"
                  startupTimeLimit="120"
                  startupRetryCount="3"
                  requestTimeout="00:05:00"
                  processesPerApplication="1"
                  stdoutLogEnabled="true"
                  stdoutLogFile="C:\ProgramData\WikiJs\logs\httpplatform-stdout">
      <recycleOnFileChange>
        <file path=".\config.yml" />
        <file path=".\iis-start.js" />
      </recycleOnFileChange>
    </httpPlatform>
    <security>
      <requestFiltering>
        <hiddenSegments>
          <add segment="config.yml" />
          <add segment="config.sample.yml" />
          <add segment="node_modules" />
          <add segment=".git" />
        </hiddenSegments>
      </requestFiltering>
    </security>
  </system.webServer>
</configuration>
```

The wildcard HPH mapping follows Microsoft's own example. `<clear />` is intentional for this Node-owned site: it removes inherited IIS mappings such as static-file handling so requests, including paths that match source/config filenames, reach the app handler. The explicit hidden-segment filters are additional IIS-side protection for sensitive/configuration paths. Keep the IIS default hidden segment for `web.config`; do not clear the request-filtering collection. The HPH `recycleOnFileChange` entries use documented site-relative syntax and request a worker recycle when the Wiki configuration or bootstrap changes; they do not watch the entire deployment tree. Deploy only the required Wiki.js runtime files, and ACL `config.yml` so the app-pool identity can read it while other local users cannot. The app pool needs write permission only to the Wiki.js data directory and the separately provisioned HPH log directory; keep application source/config read-only to that identity where practicable. Create the log directory before startup and grant the app-pool identity write access. The 120-second startup budget and five-minute request wait are starting values for testing, not Microsoft-prescribed Wiki.js values; tune them from measured cold-start and request behavior. HPH's default process count is already one, but it is stated explicitly to prevent accidental multiple Wiki instances using the same database.

`processesPerApplication="1"` avoids HPH spawning multiple Wiki processes. Preserve that setting unless Wiki.js state, scheduled/background work, uploads, and database side effects have been reviewed for multi-process operation. Do not run the old `C:\wiki` process and new IIS-managed Wiki.js concurrently against the same database during testing or cutover.

That HPH limit alone does not guarantee a single Wiki process during an IIS app-pool recycle: IIS can overlap old and replacement worker processes. For a single-instance Wiki using this database, separately configure the dedicated pool with `processModel.maxProcesses="1"` and `recycling.disallowOverlappingRotation="true"` in `applicationHost.config`. The second setting deliberately gives up overlap during recycling and can create a brief outage while the old worker shuts down and the new one starts. Test the recycle path and shutdown duration; Wiki.js v2.5.311 registers a `SIGTERM` shutdown handler, but Microsoft's HPH docs do not promise how it coordinates that application handler during worker rotation.

## Prerequisites and cutover boundary

The Windows Server does not currently have IIS installed. Install the Web Server (IIS) role with management tools, then HttpPlatformHandler v1.2 from its direct x64 MSI. The candidate config uses IIS Request Filtering for the sensitive-path blocks; verify that role service is present (it is included in a default IIS install). The WebSocket Protocol role service is needed only if the desired Wiki GraphQL subscription path is to be tested/enabled. Application Initialization is optional for automatic warm start after pool start/recycle. Microsoft documents HPH as a separate IIS module installer, with x86/x64 installer links; the HPH page lists IIS 7.5, 8, 8.5, and 10 and describes Node.exe as a supported example process. That listing does not explicitly certify Windows Server 2025, so target compatibility must be checked during an approved installation/test window. Do not use the historical Web Platform Installer route.


For IIS warm startup, Microsoft documents `startMode="AlwaysRunning"` on the application pool and `preloadEnabled="true"` on the IIS application; Application Initialization provides the simulated request. These are IIS `applicationHost.config`/site application settings, not HPH process attributes. A candidate app-pool fragment is:

```xml
<add name="WikiJsPool" startMode="AlwaysRunning">
  <processModel maxProcesses="1" idleTimeout="00:00:00" />
  <recycling disallowOverlappingRotation="true" />
</add>
```

Set `preloadEnabled="true"` on the site application's `<application>` element in `applicationHost.config`. The `idleTimeout="00:00:00"` setting disables app-pool idle timeout, but it does not promise that an out-of-process child stays alive under every condition. Treat AlwaysRunning/preload as warm-start behavior to test, not a replacement for monitoring/recovery. Keep IIS's periodic recycle policy explicit and observe how HPH/Node behaves during a recycle; disallowing overlap avoids two Wiki instances sharing the database but means a restart gap while the app pool stops and starts. The sources do not establish a Wiki-specific graceful shutdown contract.

## WebSockets, security and acceptance checks

Wiki.js v2.5.311 exposes GraphQL subscriptions at `/graphql-subscriptions`. IIS documents the separate WebSocket Protocol feature and its `<webSocket enabled="true" />` setting. HPH's configuration reference describes HTTP listener management and request proxying but does not specify WebSocket upgrade behavior. Therefore WebSocket support through this HPH arrangement is unresolved by the sources and must be tested through the real public `docs.dot-see.dev` TLS/tunnel path, including reconnect after an IIS app-pool recycle. Do not infer HPH WebSocket compatibility from IIS WebSocket role installation alone.

Wiki.js v2.5.311 stores its public `host` setting as application configuration, and its authentication setup builds provider callback URLs as `${WIKI.config.host}/login/${strategyKey}/callback`. Keep that Site URL set to the public `https://docs.dot-see.dev` even though the IIS origin binding is `seedocs.dotsee.local`; acceptance-test the generated Google callback and public canonical links. The pinned default `securityTrustProxy` is false. Enabling that Wiki setting calls Express `app.enable('trust proxy')`, which trusts proxy headers broadly; do not enable it without ensuring the app is reachable only through the trusted proxy and that the tunnel overwrites forwarded headers. The public callback is built from the configured site URL rather than inferred from the origin `Host` header.

Before relying on the candidate, validate: IIS HTTPS SNI origin binding and that the existing certificate SAN covers `seedocs.dotsee.local`; cold start and HPH's injected port; loopback-only binding; health/read/write behavior; public canonical links and generated Google callback on `docs.dot-see.dev`; GraphQL WebSocket upgrade and reconnect; SQL Server connectivity with the existing authentication method and TLS verification intact; upload/data-path write access; denial of direct requests for `config.yml`, source, `node_modules`, and `.git`; HPH stdout creation/rotation and ACL; process restart/recycle; and rollback to the preserved `C:\wiki` topology. The connector/TLS certificate and Cloudflare settings are separate from this Node/HPH process contract.

## Primary sources

- [Microsoft IIS: HttpPlatformHandler Configuration Reference](https://learn.microsoft.com/en-us/iis/extensions/httpplatformhandler/httpplatformhandler-configuration-reference) — supported process pattern, `processPath`, arguments, environment expansion, startup/retry/request limits, logging paths, process count, and the documented wildcard handler example. It does not document a working-directory attribute or WebSocket forwarding contract.
- [Microsoft IIS: HttpPlatformHandler v1.2 download](https://www.iis.net/downloads/microsoft/httpplatformhandler) — direct x86/x64 installer links, listed IIS versions, and Node.exe example.
- [Microsoft Learn: Install the Web Server role](https://learn.microsoft.com/en-us/windows-server/networking/core-network-guide/cncg/server-certs/install-the-web-server-web1) and [Install-WindowsFeature for Windows Server 2025](https://learn.microsoft.com/en-us/powershell/module/servermanager/install-windowsfeature?view=windowsserver2025-ps) — server role and management-tools installation facts; this report does not run these commands.
- [Microsoft Learn: Windows Server roles and role services](https://learn.microsoft.com/en-us/windows-server/administration/server-core/server-core-roles-and-services?tabs=roles) — lists the IIS `Web-AppInit`, `Web-WebSockets`, and management feature names.
- [Microsoft IIS: WebSocket Protocol configuration](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/websocket) — separate IIS WebSocket role service and configuration.
- [Microsoft IIS: Application Initialization](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/applicationinitialization/) and [IIS application defaults](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/sites/site/applicationdefaults) — AlwaysRunning/preload behavior.
- [Microsoft IIS: Application pool process model](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/applicationpools/add/processmodel) — app-pool idle timeout and process identity settings.
- [Microsoft IIS: Application pool recycling](https://learn.microsoft.com/en-us/iis/configuration/system.applicationhost/applicationpools/add/recycling) — overlapping worker rotation setting; use with `maxProcesses="1"` to avoid concurrent Wiki instances during recycle, accepting a recycle gap.
- [Microsoft IIS: Handlers](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/handlers/) — application-level handler collection, wildcard mappings, and `<clear />` behavior.
- [Microsoft IIS: Request Filtering](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/security/requestfiltering/) and [Hidden Segments](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/security/requestfiltering/hiddensegments/) — IIS request-filter and hidden-path behavior.
- [Wiki.js stable v2.5.311 package manifest](https://github.com/Requarks/wiki-v2/blob/v2.5.311/package.json), [sample config](https://github.com/Requarks/wiki-v2/blob/v2.5.311/config.sample.yml), [config loader](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/core/config.js), [environment helper](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/helpers/config.js), [server bootstrap](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/index.js), [HTTP/HTTPS listener](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/core/servers.js), [authentication setup](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/core/auth.js), [Google strategy](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/modules/authentication/google/authentication.js), [site configuration resolver](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/graph/resolvers/site.js), and [default site config](https://github.com/Requarks/wiki-v2/blob/v2.5.311/server/app/data.yml) — pinned startup, config interpolation, binding, shutdown handler, public host/callback construction, trust-proxy toggle, and subscription source; summarized in [the v2.5.311 baseline note](wikijs-v2.5.311-baseline.md).
