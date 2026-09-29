# Hosting Data API builder as an IIS sub-application (`/dab`)

**Scope:** Microsoft Data API builder (DAB) 2.0.x on Windows Server / IIS 10, mounted as a sub-application under an existing ASP.NET Core site (for example an Umbraco 13/17 site). DAB runs in its own application pool with the ASP.NET Core Module (ANCM) in-process hosting model.

**Validated against:** DAB `v2.0.12` source and the `dab_net8.0_win-x64-2.0.12.zip` release package. Re-check the details marked *(verify per version)* when you upgrade.

---

## 1. Target architecture

```text
                         https://www.example.gr
                                   │
                          ┌────────▼────────┐
                          │   IIS site      │
                          │  "ExampleSite"  │
                          └───┬─────────┬───┘
                    /  (root) │         │ /dab  (sub-application)
                              │         │
                  ┌───────────▼──┐   ┌──▼──────────────────────┐
                  │ App pool:    │   │ App pool: DabPool       │
                  │ ExamplePool  │   │ No Managed Code         │
                  │ Umbraco      │   │ ANCM in-process         │
                  │ (in-process) │   │ Azure.DataApiBuilder    │
                  └──────────────┘   │ .Service.exe            │
                                     └──────────┬──────────────┘
                                                │ SQL (Integrated Security)
                                          ┌─────▼─────┐
                                          │ SQL Server│
                                          └───────────┘
```

Public endpoints:

| Purpose | URL |
| --- | --- |
| REST | `https://www.example.gr/dab/api/{entity}` |
| GraphQL | `https://www.example.gr/dab/graphql` |
| Basic health (liveness) | `https://www.example.gr/dab/` |

## 2. When to choose this model and what it costs

**Good fit when** you want the simplest setup with no extra code: DAB appears under the main site's host name, gets its own app pool (isolated crashes and recycles, separate identity), and shares the parent's TLS binding.

**Limitations to accept up front:**

1. **Absolute URLs lose the `/dab` prefix.** DAB builds REST pagination `nextLink` values and `Location` headers (on `201 Created`) from scheme + host + the optional `runtime.base-route` + the request path. It does **not** use the IIS path base. The `base-route` setting is only allowed with the `StaticWebApps` authentication provider. So a `nextLink` comes out as `https://www.example.gr/api/Product?$after=...` instead of `/dab/api/...`. Section 9 fixes this with URL Rewrite outbound rules.
2. **No shared identity with the parent site.** DAB runs in a different process, so it can't see Umbraco member or back-office cookies. Callers must authenticate to DAB directly, typically with an Entra ID or other OIDC JWT.
3. **No edge controls.** There is no gateway to rate-limit, allowlist routes or strip headers. Everything is controlled through DAB config and IIS.

If limitations 2 or 3 matter, use the YARP model in the companion guide instead.

## 3. Prerequisites

- IIS 10 with the **ASP.NET Core Module V2**. It's installed by any current .NET Hosting Bundle, including the .NET 10 bundle you already use for Umbraco 17.
- **URL Rewrite 2.1**, needed for section 9.
- **Application Initialization** (IIS role feature), for warm-up.
- A SQL login for the app pool identity (section 7).
- You don't need a separate .NET 8 runtime. The DAB `win-x64` release zip is **self-contained**: its runtimeconfig lists the .NET and ASP.NET Core 8 frameworks as *included*, and it ships `aspnetcorev2_inprocess.dll`.

> **.NET 8 support note.** DAB 2.0.x targets .NET 8, which reaches end of support on 10 November 2026. The self-contained package carries its own runtime patches, so stay on current DAB releases. DAB's `main` branch already targets .NET 10.

## 4. Get the DAB binaries

Use the official release zip rather than the dotnet tool. It's deterministic and easy to pin in a pipeline.

```powershell
$ver = "2.0.12"
$zip = "dab_net8.0_win-x64-$ver.zip"
Invoke-WebRequest "https://github.com/Azure/data-api-builder/releases/download/v$ver/$zip" -OutFile $zip
Expand-Archive $zip -DestinationPath "D:\Sites\ExampleSite\dab"
```

The zip contains both the CLI (`Microsoft.DataApiBuilder.exe`) and the engine (`Azure.DataApiBuilder.Service.exe` / `.dll`). IIS hosts the **engine** directly; the CLI isn't used at runtime.

In Azure DevOps, store the zip as a pipeline artifact or in Azure Artifacts (universal package) so deployments don't depend on GitHub availability.

## 5. Folder layout

The DAB folder must **not** sit inside the parent app's published output, or a parent deployment could wipe it. Use a sibling folder and point the sub-application at it.

```text
D:\Sites\ExampleSite\
├── www\                     ← parent site physical path (Umbraco)
└── dab\                     ← sub-application physical path
    ├── Azure.DataApiBuilder.Service.exe
    ├── Azure.DataApiBuilder.Service.dll
    ├── ... (runtime + dependencies from the zip)
    ├── dab-config.json      ← base config
    ├── dab-config.Production.json   (optional overrides)
    ├── web.config
    └── logs\                ← only if stdout logging is enabled
```

## 6. DAB configuration

DAB resolves its config file relative to the **current directory**. With ANCM in-process hosting, the current directory is set to the application folder by default, so `dab-config.json` next to the exe works. If you ever see "config file not found", pass an absolute path with `--ConfigFileName` (section 8).

When `DAB_ENVIRONMENT` is set (for example `Production`), DAB merges `dab-config.Production.json` over `dab-config.json`. If it isn't set, the default environment is Production.

`dab-config.json`:

```json
{
  "$schema": "https://github.com/Azure/data-api-builder/releases/download/v2.0.12/dab.draft.schema.json",
  "data-source": {
    "database-type": "mssql",
    "connection-string": "@env('DAB_SQL_CONN')",
    "options": { "set-session-context": false }
  },
  "runtime": {
    "rest":    { "enabled": true, "path": "/api", "request-body-strict": true },
    "graphql": { "enabled": true, "path": "/graphql", "allow-introspection": false },
    "mcp":     { "enabled": false },
    "host": {
      "mode": "production",
      "cors": { "origins": [], "allow-credentials": false },
      "authentication": {
        "provider": "EntraID",
        "jwt": {
          "audience": "api://<dab-app-id>",
          "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0"
        }
      }
    },
    "compression": { "level": "none" },
    "health": { "enabled": false }
  },
  "entities": {
    "Product": {
      "source": { "object": "dbo.Products", "type": "table" },
      "permissions": [
        { "role": "anonymous", "actions": [ "read" ] },
        { "role": "catalog.editor", "actions": [ "*" ] }
      ]
    }
  }
}
```

Why each production setting:

| Setting | Reason |
| --- | --- |
| `host.mode: production` | Disables Swagger UI and the Nitro GraphQL IDE. |
| `graphql.allow-introspection: false` | Hides the schema from anonymous probing. Keep it on in non-production. |
| `mcp.enabled: false` | DAB 2.x exposes an MCP endpoint at `/mcp` by default. Turn it off unless you use it. |
| `cors.origins: []` | Same-origin calls through the parent host name don't need CORS. |
| `compression.level: none` | Lets URL Rewrite outbound rules see plain JSON (section 9). IIS dynamic compression compresses afterwards. |
| `health.enabled: false` | The *comprehensive* `/health` endpoint calls DAB over `http://localhost:{port}`. The port is taken from `ASPNETCORE_URLS`/`ASPNETCORE_HTTP_PORTS`/`DEFAULT_PORT` and falls back to 5000, so it doesn't work under IIS hosting. The basic liveness endpoint at `/` is unaffected. |
| `@env('DAB_SQL_CONN')` | No secrets in the config file. |

Validate before every deployment (in the pipeline, using the CLI from the same zip):

```powershell
$env:DAB_SQL_CONN = "<connection string for the validation agent>"
.\Microsoft.DataApiBuilder.exe validate --config .\dab-config.json
```

## 7. Secrets and database identity

**Preferred: no secret at all.** Give the app pool a Windows identity and use Integrated Security:

| SQL location | Pool identity | SQL login to create |
| --- | --- | --- |
| Same server | `ApplicationPoolIdentity` | `IIS AppPool\DabPool` |
| Remote, domain-joined | `ApplicationPoolIdentity` | `DOMAIN\WEBSERVER$` (machine account) |
| Remote, want per-app identity | gMSA or domain service account | that account |

```text
Server=sql01;Database=Shop;Integrated Security=True;Encrypt=True;TrustServerCertificate=False;Application Name=dab-shop
```

Grant only what DAB needs, typically `db_datareader` plus `db_datawriter` or explicit table/view/procedure permissions.

**Where to put the variable.** Setting it on the **application pool** keeps it out of the deployed `web.config`:

```powershell
Import-Module WebAdministration
Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
  -Filter "system.applicationHost/applicationPools/add[@name='DabPool']/environmentVariables" `
  -Name "." `
  -Value @{ name = 'DAB_SQL_CONN'; value = 'Server=sql01;Database=Shop;Integrated Security=True;Encrypt=True;Application Name=dab-shop' }
```

Don't deploy a `.env` file to the server.

## 8. `web.config` for the sub-application

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <!-- Defensive: avoids 500.19 "duplicate aspNetCore" if the parent's handler is inherited -->
      <remove name="aspNetCore" />
      <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
    </handlers>

    <aspNetCore processPath=".\Azure.DataApiBuilder.Service.exe"
                arguments="--no-https-redirect"
                hostingModel="inprocess"
                stdoutLogEnabled="false"
                stdoutLogFile=".\logs\stdout">
      <environmentVariables>
        <environmentVariable name="DAB_ENVIRONMENT" value="Production" />
      </environmentVariables>
    </aspNetCore>

    <!-- Warm-up: the basic health endpoint forces DAB to load DB metadata -->
    <applicationInitialization doAppInitAfterRestart="true">
      <add initializationPage="/" />
    </applicationInitialization>

    <!-- See section 9 -->
    <urlCompression doDynamicCompression="true" dynamicCompressionBeforeCache="false" />
    <rewrite>
      <!-- outbound rules from section 9 go here -->
    </rewrite>
  </system.webServer>
</configuration>
```

Notes:

- `--no-https-redirect` turns off DAB's own HTTP→HTTPS redirect middleware. Let the parent site (URL Rewrite or HSTS) enforce HTTPS so there's a single source of truth.
- To pin the config path explicitly, use `arguments="--no-https-redirect --ConfigFileName D:\Sites\ExampleSite\dab\dab-config.json"`. Be aware this may bypass the environment-file merge (*verify per version*).
- For troubleshooting only, set `stdoutLogEnabled="true"`, create the `logs` folder, and give `IIS AppPool\DabPool` modify rights on it. Turn it off again afterwards.

## 9. Fix absolute URLs (`nextLink`, `Location`)

As explained in section 2, DAB emits absolute URLs without `/dab`. Add these outbound rules inside `<rewrite>` in the sub-application's `web.config`. The examples assume `rest.path` is `/api`; adjust if you change it.

```xml
<outboundRules>
  <rule name="DAB Location header" preCondition="IsCreatedOrRedirect">
    <match serverVariable="RESPONSE_Location" pattern="^(https?://[^/]+)/api/(.*)$" />
    <action type="Rewrite" value="{R:1}/dab/api/{R:2}" />
  </rule>

  <rule name="DAB nextLink" preCondition="IsJson">
    <match filterByTags="None"
           pattern="(&quot;nextLink&quot;\s*:\s*&quot;https?://[^/&quot;]+)/api/" />
    <action type="Rewrite" value="{R:1}/dab/api/" />
  </rule>

  <preConditions>
    <preCondition name="IsJson">
      <add input="{RESPONSE_CONTENT_TYPE}" pattern="^application/json" />
    </preCondition>
    <preCondition name="IsCreatedOrRedirect">
      <add input="{RESPONSE_STATUS}" pattern="^(201|3\d\d)$" />
    </preCondition>
  </preConditions>
</outboundRules>
```

Why the compression settings matter: URL Rewrite can't rewrite a body that's already compressed. DAB's own compression is off (`compression.level: none`), and `dynamicCompressionBeforeCache="false"` keeps IIS from compressing before the outbound rule runs. Confirm with a request that sends `Accept-Encoding: gzip` (section 12).

**Alternative without rewriting:** treat `nextLink` as opaque on the client, extract only the `$after` token, and build the next URL yourself. This is fine for your own front-ends, but not for third-party consumers.

## 10. Create the app pool and sub-application

```powershell
$appcmd = "$env:windir\System32\inetsrv\appcmd.exe"
$site   = "ExampleSite"
$pool   = "DabPool"
$path   = "D:\Sites\ExampleSite\dab"

# Dedicated pool: required, because in-process hosting allows one app per pool (else 500.35)
& $appcmd add apppool /name:$pool /managedRuntimeVersion:"" /managedPipelineMode:Integrated `
    /startMode:AlwaysRunning /processModel.idleTimeout:00:00:00
& $appcmd set apppool $pool /recycling.periodicRestart.time:00:00:00
# Optionally schedule a recycle out of hours instead:
# & $appcmd set apppool $pool /+recycling.periodicRestart.schedule.[value='04:00:00']

# Sub-application
& $appcmd add app /site.name:$site /path:/dab /physicalPath:$path /applicationPool:$pool
& $appcmd set app "$site/dab" /preloadEnabled:true

# File permissions for the pool identity (read + execute)
icacls $path /grant "IIS AppPool\$($pool):(OI)(CI)RX"
```

Keep `maxProcesses` at 1 (no web garden). DAB's cache and GraphQL schema are per process.

## 11. Parent `web.config` inheritance: check this before go-live

IIS child applications inherit the parent's `system.webServer` configuration unless the parent wraps it in `<location path="." inheritInChildApplications="false">`. The default ASP.NET Core publish output does this for the `aspNetCore` handler, but hand-edited Umbraco `web.config` files often add sections **outside** that wrapper.

Review what's inherited:

| Parent section | Risk for `/dab` | Action |
| --- | --- | --- |
| `handlers` → `aspNetCore` | 500.19 duplicate entry | Handled by `<remove name="aspNetCore" />` in the child |
| `rewrite/rules` (lowercase, trailing slash, redirects) | Can alter REST paths, entity names and query strings | Add `<rules><clear /></rules>`, then re-add only what DAB needs (e.g. HTTPS) |
| `httpProtocol/customHeaders` (CSP, X-Frame-Options) | Usually harmless for JSON | Keep |
| `security/requestFiltering` (`maxAllowedContentLength`) | Limits large POST/PATCH bodies | Keep or override |
| `staticContent`, `httpErrors` custom pages | HTML error pages instead of DAB JSON errors | `<httpErrors existingResponse="PassThrough" />` in the child |

Umbraco itself needs no changes. IIS dispatches `/dab/*` to the sub-application before the parent app sees the request.

## 12. Authentication

In this model DAB validates tokens itself. The `EntraID` provider needs `jwt.audience` and `jwt.issuer`, which must **exactly** match the token's `aud` and `iss` claims.

1. Create an Entra app registration for the DAB API, set its Application ID URI (`api://<dab-app-id>`), and define app roles (e.g. `catalog.editor`).
2. Assign roles to users, groups or client applications.
3. Callers send `Authorization: Bearer <token>`. If the token has several roles, they choose one with `X-MS-API-ROLE: catalog.editor`. DAB accepts the header only if the principal actually holds that role, and forces anonymous requests to the `anonymous` role.
4. Authenticated requests without `X-MS-API-ROLE` run as the system role `authenticated`, so grant permissions to that role if needed.

For non-Entra identity providers, use `"provider": "Custom"` with the same `jwt` block. DAB expects role claims named exactly `roles`.

**Never use `AppService`, `StaticWebApps` or `Simulator` in this model.** They trust request headers (`X-MS-CLIENT-PRINCIPAL`) that any client can forge when DAB is directly reachable.

## 13. Health, warm-up and monitoring

- **Liveness:** `GET https://www.example.gr/dab/` returns a small JSON health report. Point your uptime monitor at it.
- **Warm-up:** `startMode=AlwaysRunning` + `preloadEnabled` + `applicationInitialization` make the first real request fast. DAB reads database metadata on startup.
- **Config changes:** DAB doesn't pick up `dab-config*.json` edits made in place in production. Recycle `DabPool`, or touch `web.config`.
- **Logs:** use the Windows Event Log (ANCM start failures) plus stdout logging when diagnosing. For steady-state telemetry, DAB supports Application Insights / OpenTelemetry in `runtime.telemetry` *(verify per version)*.

## 14. Deployment and upgrades (Azure DevOps)

1. Download the pinned DAB zip from your artifact feed.
2. Overlay `dab-config.json`, `dab-config.Production.json` and `web.config` from source control.
3. Run `Microsoft.DataApiBuilder.exe validate` against a staging database.
4. Deploy with the *IIS Web App Deploy* task and **Take App Offline** enabled. ANCM honours `app_offline.htm`, which releases file locks on the exe.
5. Smoke-test (section 15).

Upgrade = change the pinned version, re-validate, redeploy. Read the DAB release notes for config schema changes; the `$schema` URL is pinned to the version on purpose.

## 15. Verification checklist

```powershell
$base = "https://www.example.gr/dab"

# Liveness
curl.exe -s "$base/"

# Anonymous read
curl.exe -s -i "$base/api/Product?`$first=2"

# nextLink must contain /dab/api/ (also with compression requested)
curl.exe -s --compressed -H "Accept-Encoding: gzip" "$base/api/Product?`$first=2"

# Swagger / Nitro must NOT be served in production
curl.exe -s -o NUL -w "%{http_code}`n" "$base/swagger"
curl.exe -s -o NUL -w "%{http_code}`n" "$base/mcp"

# Forged EasyAuth header must have no effect (expect anonymous behaviour)
curl.exe -s -i -H "X-MS-CLIENT-PRINCIPAL: eyJhdXRoX3R5cCI6ImZha2UiLCJyb2xlX3R5cCI6InJvbGVzIiwiY2xhaW1zIjpbeyJ0eXAiOiJyb2xlcyIsInZhbCI6ImNhdGFsb2cuZWRpdG9yIn1dfQ==" -H "X-MS-API-ROLE: catalog.editor" `
  -X POST "$base/api/Product" -H "Content-Type: application/json" -d "{}"

# Authenticated write
curl.exe -s -i -H "Authorization: Bearer $token" -H "X-MS-API-ROLE: catalog.editor" `
  -X POST "$base/api/Product" -H "Content-Type: application/json" -d "{ ""Name"": ""Test"" }"
# → 201, and the Location header must contain /dab/api/
```

## 16. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| HTTP 500.19, duplicate `aspNetCore` | Parent handler inherited | `<remove name="aspNetCore" />` in the child `web.config` |
| HTTP 500.35 | Two in-process apps share a pool | Separate `DabPool` |
| HTTP 500.30 / 500.37 | DAB failed or timed out at startup | Enable stdout log. Usual causes: missing `DAB_SQL_CONN`, DB unreachable, invalid config |
| "Config file not found" in stdout | Current directory not the app folder | Add `--ConfigFileName <absolute path>` |
| 401 with a valid-looking token | `aud`/`iss` mismatch (v1 vs v2 issuer) | Compare decoded token claims with `jwt.audience` / `jwt.issuer` |
| 403 on an authorised user | Missing `X-MS-API-ROLE`, or role not in permissions | Send the header; check the entity's `permissions` |
| `nextLink` / `Location` without `/dab` | Outbound rules not applied | Check URL Rewrite is installed, the compression settings, and the rule patterns vs `rest.path` |
| HTML error page instead of JSON | Parent `httpErrors` inherited | `<httpErrors existingResponse="PassThrough" />` |
| Config change ignored | No hot reload in production | Recycle `DabPool` |
