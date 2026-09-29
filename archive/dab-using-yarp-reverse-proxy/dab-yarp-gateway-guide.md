# Exposing Microsoft Data API Builder Through an ASP.NET Core / YARP Gateway

## Purpose

This guide describes a production architecture in which:

- the main ASP.NET Core application is hosted in IIS;
- the main application includes `Yarp.ReverseProxy`;
- DAB runs as a separate local service/process;
- clients never connect directly to DAB;
- requests under:

```text
/data/{**catch-all}
```

are routed to DAB;
- YARP rewrites the public route into DAB's internal endpoint path;
- forwarding and security-related headers are controlled explicitly.

Example:

```text
Public request:
https://api.example.com/data/Book/42

                         │
                         ▼

YARP route:
/data/{**catch-all}

                         │
                         ▼

Internal DAB request:
http://127.0.0.1:5000/api/Book/42
```

---

## 1. Architecture

```text
                           Internet / LAN
                                │
                                │ HTTPS
                                ▼
                         ┌─────────────┐
                         │     IIS     │
                         └──────┬──────┘
                                │
                                ▼
                    ┌──────────────────────┐
                    │ Main ASP.NET Core App│
                    │                      │
                    │ Controllers          │
                    │ Authentication       │
                    │ Authorization        │
                    │ Logging              │
                    │ Rate Limiting        │
                    │ YARP                 │
                    └──────────┬───────────┘
                               │
              /data/*          │ HTTP localhost
                               ▼
                    ┌──────────────────────┐
                    │         DAB          │
                    │   127.0.0.1:5000     │
                    │                      │
                    │ /api/*               │
                    │ /graphql             │
                    └──────────┬───────────┘
                               │
                               ▼
                            Database
```

The important security boundary is:

```text
External clients -> YARP only
YARP -> private DAB listener
```

DAB should not be published directly on an Internet-facing address.

---

## 2. Why this architecture is attractive

It separates responsibilities.

### IIS

Provides:

- TLS termination;
- site bindings;
- Windows operational management;
- application pool lifecycle for the gateway;
- request filtering;
- certificate management.

### Main ASP.NET Core application

Provides:

- authentication;
- authorization;
- rate limiting;
- application-specific middleware;
- request correlation;
- observability;
- API composition;
- YARP routing.

### DAB

Provides:

- database REST API;
- GraphQL;
- DAB entity permissions;
- filtering/sorting/pagination;
- database access.

### YARP

Provides:

- route matching;
- path rewriting;
- header transforms;
- forwarding;
- destination health/load-balancing options if multiple DAB instances are added later.

---

## 3. Recommended public/internal URL design

Public REST API:

```text
/data/{entity}
/data/{entity}/{id}
```

Internal DAB REST API:

```text
/api/{entity}
/api/{entity}/{id}
```

Therefore:

```text
/data/Book
```

must become:

```text
/api/Book
```

A YARP `PathPattern` transform is an elegant way to perform this mapping.

---

## 4. Create or update the ASP.NET Core project

Example:

```powershell
dotnet new webapi -n ApiGateway
cd ApiGateway
```

Add YARP:

```powershell
dotnet add package Yarp.ReverseProxy
```

For production, pin the package version in source control rather than relying on an unbounded version range.

---

## 5. Configure `Program.cs`

Minimal configuration:

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers();

builder.Services
    .AddReverseProxy()
    .LoadFromConfig(
        builder.Configuration.GetSection("ReverseProxy"));

var app = builder.Build();

app.UseHttpsRedirection();

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

app.MapReverseProxy();

app.Run();
```

If the project doesn't use authentication yet, remove the authentication calls until authentication is configured.

A more realistic production application might also include:

```csharp
app.UseExceptionHandler();
app.UseForwardedHeaders();
app.UseRateLimiter();
```

depending on the architecture.

---

## 6. Basic YARP configuration

Add this to `appsettings.json`:

```json
{
  "ReverseProxy": {
    "Routes": {
      "dab-rest": {
        "ClusterId": "dab",
        "Match": {
          "Path": "/data/{**catch-all}"
        },
        "Transforms": [
          {
            "PathPattern": "/api/{**catch-all}"
          }
        ]
      }
    },

    "Clusters": {
      "dab": {
        "Destinations": {
          "dab-local": {
            "Address": "http://127.0.0.1:5000/"
          }
        }
      }
    }
  }
}
```

This yields:

```text
/data/Book
    ↓
/api/Book
```

and:

```text
/data/Book/42
    ↓
/api/Book/42
```

Query strings are preserved:

```text
/data/Book?$filter=price gt 10
    ↓
/api/Book?$filter=price gt 10
```

---

## 7. Why `PathPattern` instead of only `PathRemovePrefix`

This configuration:

```json
{
  "PathRemovePrefix": "/data"
}
```

would produce:

```text
/data/Book
    ↓
/Book
```

but DAB's default REST path is:

```text
/api/Book
```

You could combine transforms, but the direct mapping is clearer:

```json
{
  "PathPattern": "/api/{**catch-all}"
}
```

The catch-all route value from:

```text
/data/{**catch-all}
```

is reused to construct the DAB request path.

---

## 8. Header behavior: what YARP already does

By default YARP:

- copies incoming request headers except the original `Host`;
- sets the destination `Host` according to the destination address;
- adds forwarding information such as:
  - `X-Forwarded-For`;
  - `X-Forwarded-Proto`;
  - `X-Forwarded-Host`;
  - `X-Forwarded-Prefix` where applicable.

Therefore, do not add duplicate transforms simply because a reverse proxy normally needs forwarded headers.

Instead, add transforms where you have a specific reason.

---

## 9. Recommended explicit header transforms

A production route can explicitly add a gateway marker and remove identity headers that clients must not be allowed to forge.

Example:

```json
{
  "ReverseProxy": {
    "Routes": {
      "dab-rest": {
        "ClusterId": "dab",

        "Match": {
          "Path": "/data/{**catch-all}"
        },

        "Transforms": [
          {
            "PathPattern": "/api/{**catch-all}"
          },
          {
            "RequestHeader": "X-Gateway",
            "Set": "MainApi"
          },
          {
            "RequestHeader": "X-Forwarded-Prefix",
            "Set": "/data"
          },
          {
            "RequestHeader": "X-MS-CLIENT-PRINCIPAL",
            "Set": ""
          },
          {
            "RequestHeader": "X-MS-CLIENT-PRINCIPAL-ID",
            "Set": ""
          }
        ]
      }
    },

    "Clusters": {
      "dab": {
        "Destinations": {
          "dab-local": {
            "Address": "http://127.0.0.1:5000/"
          }
        }
      }
    }
  }
}
```

> [!CAUTION]
> Only remove identity headers that are not part of your chosen, trusted authentication architecture.
>
> If DAB is intentionally configured to trust authentication headers from a platform/provider, use a carefully designed trusted-proxy pattern instead of blindly deleting or forwarding them.

---

## 10. `Host` header behavior

YARP suppresses the incoming `Host` header by default and uses the host from the destination URI.

For:

```json
"Address": "http://127.0.0.1:5000/"
```

DAB normally receives a host corresponding to the internal destination.

This is generally the safest default.

Do not preserve the original `Host` unless DAB specifically needs it and you have tested the implications.

YARP supports `RequestHeaderOriginalHost` when original-host forwarding is intentionally required.

---

## 11. Authorization header

YARP normally copies the incoming `Authorization` header.

That makes this architecture well suited to DAB JWT authentication:

```text
Client
   │
   │ Authorization: Bearer <token>
   ▼
Gateway
   │
   │ same bearer token
   ▼
DAB
   │
   ▼
DAB validates token and applies entity permissions
```

This is often preferable to inventing proprietary identity headers.

The gateway can authenticate the same token as well, if central gateway authorization is desired.

---

## 12. Authentication patterns

There are three common patterns.

### Pattern A — DAB validates the JWT

```text
Client
  │ JWT
  ▼
Gateway
  │ forwards JWT
  ▼
DAB
  │ validates JWT
  ▼
Database
```

Advantages:

- DAB receives a standard security token;
- DAB authorization works naturally;
- fewer trusted custom headers.

This is generally a strong default.

---

### Pattern B — gateway and DAB both validate the JWT

```text
Client
   │
   ▼
Gateway Authentication
   │
   ├── Gateway authorization/rate policy
   │
   ▼
DAB authentication
   │
   ▼
DAB entity authorization
```

This provides defense in depth.

It also allows the gateway to reject obviously unauthorized traffic before it reaches DAB.

---

### Pattern C — gateway authenticates and translates identity

```text
Client
   │
   ▼
Gateway authentication
   │
   │ trusted identity headers
   ▼
DAB
```

Use this only when the selected DAB authentication provider explicitly supports the trusted header mechanism you are implementing.

Never allow Internet clients to supply trusted internal identity headers unchanged.

---

## 13. Add authorization to the YARP endpoint

YARP routes can participate in ASP.NET Core authorization.

For example, configure a policy:

```csharp
builder.Services
    .AddAuthorization(options =>
    {
        options.AddPolicy(
            "DabAccess",
            policy => policy.RequireAuthenticatedUser());
    });
```

Then apply authorization to proxy endpoints in code:

```csharp
app.MapReverseProxy()
   .RequireAuthorization("DabAccess");
```

This applies the policy to all mapped YARP routes.

If different proxy routes require different policies, use route metadata/configuration appropriate to the application's design rather than applying one global policy blindly.

DAB should still enforce its own entity permissions.

---

## 14. Add rate limiting

Because all DAB traffic passes through the gateway, ASP.NET Core rate limiting can protect DAB.

Example conceptually:

```csharp
builder.Services.AddRateLimiter(options =>
{
    // Configure policies appropriate to the application.
});
```

Pipeline:

```csharp
app.UseRateLimiter();
```

Then apply a rate policy to the proxy endpoint.

Rate limits should be derived from:

- expected client volume;
- database capacity;
- DAB query cost;
- SLA requirements.

Do not use an arbitrary low global limit without load testing.

---

## 15. DAB configuration

DAB itself can retain its normal REST path:

```json
{
  "runtime": {
    "rest": {
      "enabled": true,
      "path": "/api"
    },
    "graphql": {
      "enabled": true,
      "path": "/graphql"
    },
    "host": {
      "mode": "production"
    }
  }
}
```

DAB does not need to know that the public route is `/data`.

YARP performs the translation.

---

## 16. Run DAB only on loopback

For a single-server design, bind DAB to loopback only.

Example environment variable:

```powershell
$env:ASPNETCORE_URLS = "http://127.0.0.1:5000"
```

Then start DAB:

```powershell
dotnet .\Microsoft.DataApiBuilder.dll `
    start `
    --config .\dab-config.json `
    --no-https-redirect
```

The external TLS boundary is IIS/YARP:

```text
Client --HTTPS--> IIS / Gateway --HTTP localhost--> DAB
```

Loopback HTTP avoids unnecessary certificate management between two processes on the same machine.

---

## 17. Do not expose port 5000 externally

Windows Firewall should not permit remote access to the DAB listener.

If DAB is bound only to:

```text
127.0.0.1
```

remote hosts cannot connect directly.

This is preferable to:

```text
0.0.0.0:5000
```

for the same-machine architecture.

---

## 18. Managing the DAB process

YARP does **not** start or supervise DAB.

A process manager is still required.

Possible Windows approaches include:

- a Windows Service;
- a service wrapper approved by your organization;
- a dedicated IIS/ANCM application;
- another enterprise process supervisor.

This is an important architectural distinction:

```text
YARP = reverse proxy
YARP ≠ process manager
```

If you use the companion IIS sub-application approach described in the other guide, IIS/ANCM can supervise DAB. If YARP talks directly to localhost, ensure the DAB process has a reliable lifecycle manager.

---

## 19. Alternative: YARP proxy to the `/dab` IIS application

If DAB is already deployed as:

```text
https://localhost/dab/api/...
```

YARP can proxy to that IIS application instead of to a raw DAB port.

However, on the same server this adds another IIS HTTP hop:

```text
Client
  ↓
IIS
  ↓
Gateway
  ↓
YARP
  ↓
IIS
  ↓
/dab
  ↓
ANCM
  ↓
DAB
```

That is operationally possible but unnecessarily indirect in many installations.

If the gateway and DAB live on the same machine, prefer one of these:

```text
YARP -> DAB localhost port
```

or:

```text
IIS exposes /dab directly
```

depending on the desired isolation model.

---

## 20. GraphQL routing

If you also want:

```text
/data/graphql
```

to map to:

```text
/graphql
```

create a dedicated route before/general alongside the REST route.

Example:

```json
{
  "ReverseProxy": {
    "Routes": {

      "dab-graphql": {
        "ClusterId": "dab",
        "Order": -10,
        "Match": {
          "Path": "/data/graphql"
        },
        "Transforms": [
          {
            "PathSet": "/graphql"
          },
          {
            "RequestHeader": "X-Forwarded-Prefix",
            "Set": "/data"
          }
        ]
      },

      "dab-rest": {
        "ClusterId": "dab",
        "Match": {
          "Path": "/data/{**catch-all}"
        },
        "Transforms": [
          {
            "PathPattern": "/api/{**catch-all}"
          },
          {
            "RequestHeader": "X-Forwarded-Prefix",
            "Set": "/data"
          }
        ]
      }
    },

    "Clusters": {
      "dab": {
        "Destinations": {
          "dab-local": {
            "Address": "http://127.0.0.1:5000/"
          }
        }
      }
    }
  }
}
```

Now:

```text
/data/graphql
    ↓
/graphql
```

while:

```text
/data/Book
    ↓
/api/Book
```

---

## 21. Health endpoint

Do not necessarily expose DAB's full health endpoint publicly.

A better design is often:

```text
Internet
   │
   ▼
Gateway /health
```

with the gateway performing an internal DAB health/readiness check.

This lets you expose a minimal health status without disclosing unnecessary backend information.

Health checks can also be used by YARP clusters when multiple DAB instances are introduced.

---

## 22. Request correlation

A gateway is a good place to establish a correlation ID.

For example:

```text
X-Correlation-ID
```

The gateway can:

1. accept an existing trusted format;
2. generate one if missing;
3. forward it to DAB;
4. add it to logging scopes.

Example transform with a static header is easy, but correlation IDs are dynamic and are better handled in middleware or a programmatic YARP transform.

---

## 23. Programmatic transform example

Configuration-based transforms are ideal for static rewrites.

For request-dependent behavior, use YARP's transform API.

Example skeleton:

```csharp
builder.Services
    .AddReverseProxy()
    .LoadFromConfig(
        builder.Configuration.GetSection("ReverseProxy"))
    .AddTransforms(context =>
    {
        if (context.Route.RouteId == "dab-rest")
        {
            context.AddRequestTransform(transformContext =>
            {
                var httpContext = transformContext.HttpContext;

                var correlationId =
                    httpContext.TraceIdentifier;

                transformContext.ProxyRequest.Headers.Remove(
                    "X-Correlation-ID");

                transformContext.ProxyRequest.Headers.TryAddWithoutValidation(
                    "X-Correlation-ID",
                    correlationId);

                return ValueTask.CompletedTask;
            });
        }
    });
```

Use programmatic transforms when values must be calculated per request.

---

## 24. Do not blindly trust `X-Forwarded-*`

If IIS is in front of ASP.NET Core, configure the application's forwarded-header handling according to the known proxy topology.

The gateway should not treat arbitrary client-supplied forwarding headers as trusted identity or security facts.

Differentiate between:

```text
transport metadata
```

and:

```text
authenticated identity
```

`X-Forwarded-For` is not proof of identity.

---

## 25. Error handling

Decide whether DAB errors should pass through unchanged.

For API clients, preserving DAB's HTTP status code and response body is often useful.

Avoid gateway middleware that converts every backend response into:

```text
200 OK
```

or generic HTML error pages.

Also ensure IIS custom-error configuration does not replace useful JSON error responses intended for API clients.

---

## 26. Timeout configuration

DAB queries can legitimately take longer than a trivial web request.

Configure timeouts intentionally at each layer:

```text
Client
  ↓
IIS
  ↓
ASP.NET Core / YARP
  ↓
DAB
  ↓
Database
```

The database command timeout, reverse-proxy activity timeout, and IIS request behavior should be consistent with the intended workload.

Do not simply set all timeouts to unlimited.

---

## 27. Request and response size limits

Review limits at:

- IIS request filtering;
- ASP.NET Core;
- YARP;
- DAB;
- database/query result layer.

DAB itself has runtime response-size controls.

A request that works by connecting directly to DAB can still fail through IIS if IIS has a lower request-size restriction.

---

## 28. Logging

Log at the gateway:

- request method;
- normalized route;
- status code;
- duration;
- correlation ID;
- authenticated subject identifier when appropriate;
- YARP destination/route identifier.

Avoid logging:

- bearer tokens;
- database connection strings;
- credentials;
- sensitive request payloads by default.

DAB should retain its own backend/database-oriented logging.

---

## 29. Complete example `appsettings.json`

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning",
      "Yarp.ReverseProxy": "Information"
    }
  },

  "AllowedHosts": "*",

  "ReverseProxy": {
    "Routes": {

      "dab-graphql": {
        "ClusterId": "dab",
        "Order": -10,

        "Match": {
          "Path": "/data/graphql"
        },

        "Transforms": [
          {
            "PathSet": "/graphql"
          },
          {
            "RequestHeader": "X-Forwarded-Prefix",
            "Set": "/data"
          },
          {
            "RequestHeader": "X-Gateway",
            "Set": "MainApi"
          }
        ]
      },

      "dab-rest": {
        "ClusterId": "dab",

        "Match": {
          "Path": "/data/{**catch-all}"
        },

        "Transforms": [
          {
            "PathPattern": "/api/{**catch-all}"
          },
          {
            "RequestHeader": "X-Forwarded-Prefix",
            "Set": "/data"
          },
          {
            "RequestHeader": "X-Gateway",
            "Set": "MainApi"
          }
        ]
      }
    },

    "Clusters": {
      "dab": {
        "Destinations": {
          "dab-local": {
            "Address": "http://127.0.0.1:5000/"
          }
        }
      }
    }
  }
}
```

---

## 30. Complete minimal `Program.cs`

```csharp
var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers();

builder.Services
    .AddReverseProxy()
    .LoadFromConfig(
        builder.Configuration.GetSection("ReverseProxy"));

var app = builder.Build();

app.UseHttpsRedirection();

app.MapControllers();

app.MapReverseProxy();

app.Run();
```

Production systems can then add:

- authentication;
- authorization;
- rate limiting;
- OpenTelemetry;
- health checks;
- correlation middleware;
- structured logging.

---

## 31. IIS deployment of the gateway

Publish:

```powershell
dotnet publish `
    -c Release `
    -o C:\Deploy\ApiGateway
```

Install the .NET Hosting Bundle on the IIS server.

Create a dedicated application pool:

```text
ApiGatewayPool
```

Recommended baseline:

```text
.NET CLR Version      No Managed Code
Identity              ApplicationPoolIdentity
```

Publish the ASP.NET Core application as the IIS site's root application.

ASP.NET Core publishing creates the appropriate ANCM `web.config`.

---

## 32. End-to-end request example

Client:

```http
GET /data/Book/42 HTTP/1.1
Host: api.example.com
Authorization: Bearer ey...
```

YARP route match:

```text
/data/{**catch-all}

catch-all = Book/42
```

Path transform:

```text
/api/{**catch-all}
```

Backend request conceptually becomes:

```http
GET /api/Book/42 HTTP/1.1
Host: 127.0.0.1:5000
Authorization: Bearer ey...
X-Forwarded-For: <client-ip>
X-Forwarded-Proto: https
X-Forwarded-Host: api.example.com
X-Forwarded-Prefix: /data
X-Gateway: MainApi
```

DAB processes:

```text
/api/Book/42
```

and returns the result through YARP.

---

## 33. Security checklist

Before production:

- [ ] DAB listens only on loopback/private network.
- [ ] Firewall prevents clients bypassing the gateway.
- [ ] HTTPS is enforced at IIS.
- [ ] Authentication is enabled where required.
- [ ] DAB entity permissions follow least privilege.
- [ ] Client-controlled identity headers are not trusted.
- [ ] `Authorization` forwarding has been tested.
- [ ] Gateway rate limits are configured if needed.
- [ ] Secrets are outside source-controlled JSON.
- [ ] DAB runs in production host mode.
- [ ] GraphQL introspection policy has been reviewed.
- [ ] Request/response limits are reviewed.
- [ ] Timeout values are reviewed.
- [ ] Health endpoints do not leak sensitive detail.
- [ ] Logs do not contain bearer tokens or credentials.

---

## 34. Availability and scaling

Initially:

```text
YARP
  │
  ▼
DAB #1
127.0.0.1:5000
```

Later YARP can support multiple destinations:

```text
               ┌── DAB #1
YARP ──────────┼── DAB #2
               └── DAB #3
```

Example cluster:

```json
"Clusters": {
  "dab": {
    "Destinations": {
      "dab01": {
        "Address": "http://10.0.0.21:5000/"
      },
      "dab02": {
        "Address": "http://10.0.0.22:5000/"
      }
    }
  }
}
```

At that point also configure health checks and an appropriate load-balancing policy.

---

## 35. Recommended production topology

For your scenario, the cleanest separation is generally:

```text
                          IIS
                           │
                           ▼
                ASP.NET Core Main App
                           │
                    Yarp.ReverseProxy
                           │
                      /data/*
                           │
                           ▼
                 127.0.0.1:5000
                           │
                           ▼
                           DAB
                           │
                           ▼
                        Database
```

Externally:

```text
https://api.example.com/data/Book
```

Internally:

```text
http://127.0.0.1:5000/api/Book
```

This hides DAB as an implementation detail and allows the main ASP.NET Core application to become the single API façade.

---

# References

Microsoft documentation:

- YARP — Getting started  
  https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/getting-started

- YARP — Request and response transforms  
  https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/transforms

- YARP — Request transforms  
  https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/transforms-request

- Data API Builder — Runtime configuration  
  https://learn.microsoft.com/en-us/azure/data-api-builder/configuration/runtime

- Data API Builder — REST API overview  
  https://learn.microsoft.com/en-us/azure/data-api-builder/concept/rest/overview

- Data API Builder — `dab start`  
  https://learn.microsoft.com/en-us/azure/data-api-builder/command-line/dab-start

- Data API Builder — Deploy to Azure App Service  
  https://learn.microsoft.com/en-us/azure/data-api-builder/deployment/azure-app-service

- ASP.NET Core Module for IIS  
  https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/aspnet-core-module

- Host ASP.NET Core on Windows with IIS  
  https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/

---

## Verification note

This document was prepared against Microsoft documentation available on **2026-09-29**. Pin and validate both the DAB and `Yarp.ReverseProxy` versions used by your production deployment.
