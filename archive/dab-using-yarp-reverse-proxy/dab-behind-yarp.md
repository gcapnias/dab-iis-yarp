# Exposing Data API builder through YARP in the main ASP.NET Core application

**Scope:** Microsoft Data API builder (DAB) 2.0.x runs as an **internal-only** IIS site in its own application pool. The public ASP.NET Core application (plain ASP.NET Core or Umbraco 13/17) forwards selected paths to it with **YARP** (`Yarp.ReverseProxy` NuGet package). From the outside, DAB looks like part of the main application.

**Validated against:** DAB `v2.0.12` source and the `dab_net8.0_win-x64-2.0.12.zip` release package, and YARP 2.x. Re-check the details marked *(verify per version)* when you upgrade.

---

## 1. Target architecture

```
          https://www.example.gr/data/...        https://www.example.gr/graphql
                          │                                   │
                  ┌───────▼───────────────────────────────────▼──────┐
                  │  Main app (IIS site "ExampleSite", ExamplePool)  │
                  │  ASP.NET Core / Umbraco + YARP                   │
                  │   • authn / authz at the edge (optional)          │
                  │   • header sanitising                             │
                  │   • route allowlist, rate limiting                │
                  └───────────────────────┬───────────────────────────┘
                                          │ http://127.0.0.1:5080  (loopback only)
                  ┌───────────────────────▼───────────────────────────┐
                  │  IIS site "dab-internal", DabPool (No Managed)   │
                  │  ANCM in-process → Azure.DataApiBuilder.Service  │
                  └───────────────────────┬───────────────────────────┘
                                          │ SQL (Integrated Security)
                                    ┌─────▼─────┐
                                    │ SQL Server│
                                    └───────────┘
```

Public endpoints:

| Purpose | Public URL | Forwarded to DAB |
|---|---|---|
| REST | `https://www.example.gr/data/{entity}` | `http://127.0.0.1:5080/data/{entity}` |
| GraphQL | `https://www.example.gr/graphql` | `http://127.0.0.1:5080/graphql` |
| Health | *not public* | `http://127.0.0.1:5080/` |

## 2. Key design decision: don't strip the path prefix

A common YARP pattern is `/data/{**catch-all}` + `PathRemovePrefix: /data`, forwarding to DAB's default `/api`. **Avoid that with DAB.**

DAB builds absolute URLs (REST pagination `nextLink`, `Location` on `201 Created`) from:

- scheme: `X-Forwarded-Proto`, or the request scheme
- host: `X-Forwarded-Host`, or the request host
- path base: `runtime.base-route` only. This is allowed **only** with the `StaticWebApps` auth provider, and the IIS/ASP.NET path base is ignored.
- path: the path DAB received

If YARP strips `/data`, DAB receives `/api/Product` and returns `https://www.example.gr/api/Product?$after=…`, which is a broken link. Instead, set DAB's own REST path to the public prefix:

- `runtime.rest.path = "/data"`, so the public and internal paths are identical and links are correct with YARP's default `X-Forwarded-*` headers.
- REST and GraphQL paths must each be a **single segment** (DAB rejects `/` inside them). So GraphQL can't live at `/data/graphql` and gets its own top-level path, `/graphql`. Rename it (e.g. `/data-graphql`) or disable GraphQL if you don't need it.

## 3. Part A: the internal DAB site

### 3.1 Binaries

Use the self-contained Windows release. It ships its own .NET 8 runtime and `aspnetcorev2_inprocess.dll`, so only the ASP.NET Core Module (from any current Hosting Bundle) is needed on the server.

```powershell
$ver = "2.0.12"
$zip = "dab_net8.0_win-x64-$ver.zip"
Invoke-WebRequest "https://github.com/Azure/data-api-builder/releases/download/v$ver/$zip" -OutFile $zip
Expand-Archive $zip -DestinationPath "D:\Sites\dab-internal"
```

> **.NET 8 support note.** DAB 2.0.x targets .NET 8, which reaches end of support on 10 November 2026. Stay on current DAB releases; DAB's `main` branch already targets .NET 10.

### 3.2 `dab-config.json`

```json
{
  "$schema": "https://github.com/Azure/data-api-builder/releases/download/v2.0.12/dab.draft.schema.json",
  "data-source": {
    "database-type": "mssql",
    "connection-string": "@env('DAB_SQL_CONN')",
    "options": { "set-session-context": false }
  },
  "runtime": {
    "rest":    { "enabled": true, "path": "/data", "request-body-strict": true },
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

| Setting | Reason |
|---|---|
| `rest.path: /data` | Keeps public and internal paths identical (section 2). |
| `host.mode: production` | Disables Swagger UI and the Nitro IDE. |
| `allow-introspection: false` | Hides the GraphQL schema from anonymous probing. |
| `mcp.enabled: false` | DAB 2.x exposes `/mcp` by default. It also isn't routed by YARP. |
| `cors.origins: []` | The browser only talks to the main app's origin. |
| `health.enabled: false` | The comprehensive `/health` endpoint calls DAB over `http://localhost:{port}`. The port is taken from `ASPNETCORE_URLS`/`ASPNETCORE_HTTP_PORTS`/`DEFAULT_PORT`, else 5000, so it doesn't work under IIS. The basic `/` liveness endpoint remains. |
| `authentication` | See section 6. Pattern B replaces this block with `AppService`. |

Compression can stay at the default. YARP passes `Accept-Encoding` through and streams compressed responses back unchanged.

Validate in your pipeline with the CLI from the same zip:

```powershell
.\Microsoft.DataApiBuilder.exe validate --config .\dab-config.json
```

### 3.3 `web.config`

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
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

    <applicationInitialization doAppInitAfterRestart="true">
      <add initializationPage="/" />
    </applicationInitialization>

    <!-- Defence in depth: only loopback callers (requires the IP and Domain Restrictions feature
         and unlocking the section: appcmd unlock config -section:system.webServer/security/ipSecurity) -->
    <security>
      <ipSecurity allowUnlisted="false">
        <add ipAddress="127.0.0.1" allowed="true" />
        <add ipAddress="::1" allowed="true" />
      </ipSecurity>
    </security>
  </system.webServer>
</configuration>
```

`--no-https-redirect` is essential here. The loopback hop is plain HTTP, and DAB's HTTPS redirect middleware would otherwise redirect YARP's requests.

### 3.4 Secrets and database identity

Prefer Integrated Security with the app pool identity. This means no secret at all:

| SQL location | Pool identity | SQL login |
|---|---|---|
| Same server | `ApplicationPoolIdentity` | `IIS AppPool\DabPool` |
| Remote, domain-joined | `ApplicationPoolIdentity` | `DOMAIN\WEBSERVER$` |
| Remote, per-app identity | gMSA / service account | that account |

Set `DAB_SQL_CONN` on the application pool so it never appears in a deployed file:

```powershell
Import-Module WebAdministration
Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
  -Filter "system.applicationHost/applicationPools/add[@name='DabPool']/environmentVariables" `
  -Name "." `
  -Value @{ name = 'DAB_SQL_CONN'; value = 'Server=sql01;Database=Shop;Integrated Security=True;Encrypt=True;Application Name=dab-shop' }
```

### 3.5 Create the pool and the internal site

```powershell
$appcmd = "$env:windir\System32\inetsrv\appcmd.exe"
$pool = "DabPool"
$path = "D:\Sites\dab-internal"

& $appcmd add apppool /name:$pool /managedRuntimeVersion:"" /managedPipelineMode:Integrated `
    /startMode:AlwaysRunning /processModel.idleTimeout:00:00:00
& $appcmd set apppool $pool /recycling.periodicRestart.time:00:00:00

& $appcmd add site /name:dab-internal /physicalPath:$path /bindings:"http/127.0.0.1:5080:"
& $appcmd set app "dab-internal/" /applicationPool:$pool /preloadEnabled:true

icacls $path /grant "IIS AppPool\$($pool):(OI)(CI)RX"

# Block the port from the network as well
New-NetFirewallRule -DisplayName "Block DAB internal 5080" -Direction Inbound `
  -LocalPort 5080 -Protocol TCP -Action Block
```

The IP-specific binding plus firewall rule plus `ipSecurity` together keep DAB unreachable from anywhere except the local main app. That matters for the trust model in section 5.

> **DAB on a different server?** Use HTTPS between the servers, restrict the port to the web server's IP at the firewall, and prefer authentication pattern A (section 6). Pattern B relies on DAB being reachable *only* through the gateway.

## 4. Part B: YARP in the main application

### 4.1 Package

```powershell
dotnet add package Yarp.ReverseProxy
```

### 4.2 `appsettings.json`

```json
{
  "ReverseProxy": {
    "Routes": {
      "dab-rest": {
        "ClusterId": "dab",
        "Match": { "Path": "/data/{**catch-all}" },
        "Transforms": [
          { "RequestHeaderRemove": "X-MS-CLIENT-PRINCIPAL" },
          { "RequestHeaderRemove": "Cookie" },
          { "X-Forwarded": "Set" }
        ]
      },
      "dab-graphql": {
        "ClusterId": "dab",
        "Match": { "Path": "/graphql", "Methods": [ "POST" ] },
        "Transforms": [
          { "RequestHeaderRemove": "X-MS-CLIENT-PRINCIPAL" },
          { "RequestHeaderRemove": "Cookie" },
          { "X-Forwarded": "Set" }
        ]
      }
    },
    "Clusters": {
      "dab": {
        "Destinations": {
          "local": { "Address": "http://127.0.0.1:5080/" }
        },
        "HttpRequest": {
          "ActivityTimeout": "00:01:00",
          "Version": "1.1",
          "VersionPolicy": "RequestVersionExact"
        }
      }
    }
  }
}
```

What each transform does:

| Transform | Why |
|---|---|
| `RequestHeaderRemove: X-MS-CLIENT-PRINCIPAL` | **Critical.** With the `AppService`/`StaticWebApps` providers, DAB trusts this header as the user identity. Remove it from every client request. Pattern B re-adds a gateway-built value. |
| `RequestHeaderRemove: Cookie` | Umbraco back-office and member cookies must never reach DAB or its logs. |
| `X-Forwarded: Set` | Overwrites (not appends) `X-Forwarded-Proto/Host/For/Prefix`, so clients can't spoof them. DAB uses Proto + Host to build correct `nextLink`/`Location` URLs. |
| `Methods: [POST]` on GraphQL | Blocks GET-based GraphQL (and the IDE) at the edge. Add `GET` if you need persisted/GET queries. |

`Authorization` and `X-MS-API-ROLE` are forwarded unchanged on purpose. DAB validates the bearer token itself, and it only honours `X-MS-API-ROLE` when the authenticated principal actually holds that role (anonymous requests are forced to `anonymous`). Stripping `X-MS-API-ROLE` is therefore not a security requirement. Strip it only if you don't want clients to choose among their roles.

### 4.3 `Program.cs`: plain ASP.NET Core

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"));

var app = builder.Build();

app.UseHttpsRedirection();
app.UseAuthentication();
app.UseAuthorization();

app.MapReverseProxy();

app.Run();
```

### 4.4 `Program.cs`: Umbraco 13/17

Register YARP on the service collection and map it inside Umbraco's endpoint configuration so it shares Umbraco's routing, authentication and authorization pipeline:

```csharp
WebApplicationBuilder builder = WebApplication.CreateBuilder(args);

builder.CreateUmbracoBuilder()
    .AddBackOffice()
    .AddWebsite()
    .AddComposers()
    .Build();

builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"));

WebApplication app = builder.Build();

await app.BootUmbracoAsync();

app.UseUmbraco()
    .WithMiddleware(u =>
    {
        u.UseBackOffice();
        u.UseWebsite();
    })
    .WithEndpoints(u =>
    {
        u.EndpointRouteBuilder.MapReverseProxy();
        u.UseBackOfficeEndpoints();
        u.UseWebsiteEndpoints();
    });

await app.RunAsync();
```

Adapt this to your existing `Program.cs` (Delivery API, custom composers, and so on). The YARP routes are explicit endpoints and take precedence over Umbraco's content catch-all. If Umbraco ever renders its 404 page for `/data/...`, add `~/data/` to `Umbraco:CMS:Global:ReservedPaths`. That setting replaces the default list, so keep the defaults in it.

## 5. Trust model in one table

| Header | Client → YARP | YARP → DAB |
|---|---|---|
| `Authorization` | forwarded | validated by DAB (pattern A) |
| `X-MS-API-ROLE` | forwarded | validated by DAB against the principal's roles |
| `X-MS-CLIENT-PRINCIPAL` | **always removed** | absent (A) or built by the gateway (B) |
| `X-Forwarded-*` | overwritten | trusted by DAB for link building only |
| `Cookie` | removed | absent |

This model is only sound if DAB can't be reached except through YARP (section 3.5).

## 6. Authentication patterns

### Pattern A: JWT pass-through (recommended default)

Clients get a token for the DAB API from Entra ID (or another OIDC provider) and send `Authorization: Bearer …`. YARP forwards it, and DAB validates `aud`, `iss` and the signature against the `EntraID` provider config (section 3.2). Use `"provider": "Custom"` for non-Entra identity providers; DAB expects role claims named `roles`.

Optionally, reject unauthenticated traffic at the edge so it never reaches DAB. This is useful when no entity allows `anonymous`:

```csharp
builder.Services.AddAuthentication()
    .AddJwtBearer("DabJwt", o =>
    {
        o.Authority = "https://login.microsoftonline.com/<tenant-id>/v2.0";
        o.Audience  = "api://<dab-app-id>";
    });

builder.Services.AddAuthorization(o =>
    o.AddPolicy("dab-callers", p => p
        .AddAuthenticationSchemes("DabJwt")
        .RequireAuthenticatedUser()));
```

```json
"dab-rest": { "ClusterId": "dab", "AuthorizationPolicy": "dab-callers", "...": "..." }
```

In Umbraco, adding a named JWT scheme with `AddAuthentication()` (no default override) leaves Umbraco's own schemes untouched.

### Pattern B: gateway-asserted identity (reuse the main app's login)

Use this when DAB should act on behalf of users who are already signed in to the main app, for example **Umbraco members**, whose member groups become roles. The gateway converts `HttpContext.User` into DAB's EasyAuth header format, and DAB runs with the `AppService` provider.

DAB config change:

```json
"authentication": { "provider": "AppService" }
```

DAB logs a warning at startup that App Service environment variables are missing. That's expected outside Azure App Service.

Gateway transform (add to `Program.cs`):

```csharp
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using Yarp.ReverseProxy.Transforms;

builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"))
    .AddTransforms(ctx =>
    {
        if (ctx.Route.ClusterId != "dab") return;

        ctx.AddRequestTransform(t =>
        {
            // Belt and braces: never forward a client-supplied principal
            t.ProxyRequest.Headers.Remove("X-MS-CLIENT-PRINCIPAL");

            ClaimsPrincipal user = t.HttpContext.User;
            if (user.Identity?.IsAuthenticated != true) return ValueTask.CompletedTask;

            var claims = user.Claims
                .Where(c => c.Type is ClaimTypes.NameIdentifier or ClaimTypes.Name
                                   or ClaimTypes.Email or ClaimTypes.Role)
                .Select(c => new
                {
                    typ = c.Type == ClaimTypes.Role ? "roles" : c.Type,
                    val = c.Value
                });

            var principal = new
            {
                auth_typ = "gateway",
                name_typ = ClaimTypes.Name,
                role_typ = "roles",
                claims
            };

            string encoded = Convert.ToBase64String(
                Encoding.UTF8.GetBytes(JsonSerializer.Serialize(principal)));

            t.ProxyRequest.Headers.Add("X-MS-CLIENT-PRINCIPAL", encoded);
            return ValueTask.CompletedTask;
        });
    });
```

Notes for pattern B:

- DAB parses the header as base64 JSON with `auth_typ`, `name_typ`, `role_typ` and `claims[{ typ, val }]`. `auth_typ` must be non-empty for the user to count as authenticated.
- DAB permission roles then equal the claim values you emit, e.g. Umbraco member group names. Clients still pick one with `X-MS-API-ROLE`, or you can set that header in the same transform when a user has exactly one relevant role.
- Confirm that `HttpContext.User` is populated for your member session on the proxied routes. Umbraco's member scheme is the site's default for front-end requests *(verify per version)*.
- If DAB policies use claims (`@claims.email`, etc.), include those claim types in the `Where` filter.
- **Only use pattern B while DAB is loopback-only.** Anyone who can reach DAB directly can forge this header.

## 7. Hardening at the edge

**Block DAB's OpenAPI document publicly.** DAB serves it at `{rest.path}/openapi`, i.e. `/data/openapi`. A literal endpoint outranks the YARP catch-all:

```csharp
// plain ASP.NET Core: app.MapGet(...); Umbraco: inside WithEndpoints
u.EndpointRouteBuilder.MapGet("/data/openapi", () => Results.NotFound());
```

**Rate limiting** (per route via `RateLimiterPolicy`):

```csharp
builder.Services.AddRateLimiter(o =>
    o.AddFixedWindowLimiter("dab", l =>
    {
        l.PermitLimit = 120;
        l.Window = TimeSpan.FromMinutes(1);
        l.QueueLimit = 0;
    }));
```

```json
"dab-rest": { "ClusterId": "dab", "RateLimiterPolicy": "dab", "...": "..." }
```

`UseRateLimiter()` must run after routing. In plain ASP.NET Core, call `app.UseRateLimiter()` after `UseRouting()`/before `MapReverseProxy()`. In Umbraco, register it as a pipeline filter:

```csharp
builder.Services.Configure<UmbracoPipelineOptions>(o =>
    o.AddFilter(new UmbracoPipelineFilter("RateLimiter")
    {
        PostRouting = app => app.UseRateLimiter()
    }));
```

**Other edge controls:**

- **Request size:** IIS `maxAllowedContentLength` on the main site applies to proxied bodies too.
- **Timeouts:** `ActivityTimeout` (60 s above) bounds slow queries. Align it with DAB's database command timeout.
- **Only expose what you route:** `/`, `/health`, `/mcp`, `/configuration` and any other DAB path stay unreachable because no YARP route matches them.

## 8. Health and warm-up

- DAB warm-up: `startMode=AlwaysRunning`, `preloadEnabled`, and `applicationInitialization` hitting `/` (section 3.3).
- Monitoring: probe `http://127.0.0.1:5080/` from the server (scheduled task, agent), or expose it through a dedicated, authorised main-app endpoint if your monitoring runs externally.
- Optional YARP active health check (useful if you later add a second DAB destination):

```json
"dab": {
  "HealthCheck": { "Active": { "Enabled": true, "Interval": "00:00:30", "Timeout": "00:00:05", "Path": "/" } },
  "Destinations": { "local": { "Address": "http://127.0.0.1:5080/" } }
}
```

- Config changes: recycle `DabPool` after editing `dab-config*.json`.

## 9. Deployment (Azure DevOps)

Two independent deployables:

1. **DAB internal site:** pinned release zip + `dab-config*.json` + `web.config` from source control → `validate` → IIS Web App Deploy with *Take App Offline*.
2. **Main app:** normal build/deploy. The YARP routes and transforms ship with it.

Because they're decoupled, you can upgrade DAB or change its entities without redeploying the main site, and the reverse.

## 10. Verification checklist

Run from a machine outside the server unless noted.

```powershell
$site = "https://www.example.gr"

# Anonymous read through the gateway
curl.exe -s -i "$site/data/Product?`$first=2"

# nextLink must start with https://www.example.gr/data/Product
curl.exe -s "$site/data/Product?`$first=2"

# Forged principal is stripped → anonymous → write rejected (403)
curl.exe -s -i -X POST "$site/data/Product" -H "Content-Type: application/json" `
  -H "X-MS-CLIENT-PRINCIPAL: eyJhdXRoX3R5cCI6ImZha2UiLCJyb2xlX3R5cCI6InJvbGVzIiwiY2xhaW1zIjpbeyJ0eXAiOiJyb2xlcyIsInZhbCI6ImNhdGFsb2cuZWRpdG9yIn1dfQ==" `
  -H "X-MS-API-ROLE: catalog.editor" -d "{}"

# Not exposed (expect 404 from the main app)
curl.exe -s -o NUL -w "%{http_code}`n" "$site/data/openapi"
curl.exe -s -o NUL -w "%{http_code}`n" "$site/mcp"
curl.exe -s -o NUL -w "%{http_code}`n" "$site/health"

# Authenticated write (pattern A)
curl.exe -s -i -X POST "$site/data/Product" -H "Content-Type: application/json" `
  -H "Authorization: Bearer $token" -H "X-MS-API-ROLE: catalog.editor" -d "{ ""Name"": ""Test"" }"
# → 201; Location must start with https://www.example.gr/data/Product

# DAB must be unreachable from the network (run from another machine)
curl.exe -s -m 5 "http://<server-ip>:5080/"   # expect timeout / connection refused

# On the server itself: liveness
curl.exe -s "http://127.0.0.1:5080/"
```

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| 502 from YARP | DAB site stopped or startup failure | Check the `DabPool` state and the Event Log; enable stdout logging temporarily |
| 504 / slow first call | Cold start or `ActivityTimeout` too low | Warm-up settings; raise the timeout |
| 307 redirect loops or redirect to `https://127.0.0.1` | DAB HTTPS redirect active | Add `--no-https-redirect` to `arguments` |
| `nextLink` points at `127.0.0.1:5080` | `X-Forwarded` transform missing | Add `{ "X-Forwarded": "Set" }` to the route |
| `nextLink` missing `/data` | Prefix stripped in YARP | Remove `PathRemovePrefix`; set `rest.path` to `/data` |
| Umbraco 404 page for `/data/...` | Route not mapped or Umbraco intercepting | Check `MapReverseProxy()` inside `WithEndpoints`; add `~/data/` to ReservedPaths |
| 401 with a valid token (A) | `aud`/`iss` mismatch | Compare decoded token claims to the `jwt` config |
| Users always anonymous (B) | `HttpContext.User` empty on proxy route, or header not added | Log `User.Identity.IsAuthenticated` in the transform; check `auth_typ` is non-empty |
| 403 for a user with the right group (B) | Role claim type mismatch | Emit `typ: "roles"` and `role_typ: "roles"`; send `X-MS-API-ROLE` |
