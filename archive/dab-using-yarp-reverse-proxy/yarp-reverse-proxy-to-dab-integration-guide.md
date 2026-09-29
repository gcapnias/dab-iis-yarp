# Production Guide: Routing to DAB using YARP Reverse Proxy

This guide covers setting up an ASP.NET Core host application using `Yarp.ReverseProxy` to route traffic matching `/data/{**catch-all}` to a backend Data API Builder (DAB) instance, with path transformations and custom header forwarding.

---

## 1. Architectural Pattern

```
[ Client Request ]
  │
  │ GET https://myapp.example.com/data/rest/Book
  │ Header: Authorization: Bearer <JWT>
  ▼
┌─────────────────────────────────────────────────────────────┐
│                 Main ASP.NET Core Application               │
│                                                             │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ YARP Middleware Pipeline                            │   │
│   │                                                     │   │
│   │ 1. Transform Path: /data/rest/Book -> /rest/Book    │   │
│   │ 2. Transform Header: Add X-MS-API-ROLE: authenticated│   │
│   │ 3. Forward Client Headers (X-Forwarded-For, etc.)   │   │
│   └──────────────────────────┬──────────────────────────┘   │
└──────────────────────────────┼──────────────────────────────┘
                               │ Local HTTP / Private VNet
                               ▼
            ┌────────────────────────────────────┐
            │ Data API Builder (DAB) Instance    │
            │ Listening on http://127.0.0.1:5000 │
            └────────────────────────────────────┘
```

---

## 2. Project Setup

### Add the Required Package
In your main ASP.NET Core application, install the YARP NuGet package:

```bash
dotnet add package Yarp.ReverseProxy
```

---

## 3. YARP Configuration in `appsettings.json`

Configure the YARP routes, clusters, and transformations in `appsettings.json`:

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Yarp": "Warning"
    }
  },
  "ReverseProxy": {
    "Routes": {
      "dab-rest-and-graphql": {
        "ClusterId": "dab-backend-cluster",
        "Match": {
          "Path": "/data/{**catch-all}"
        },
        "Transforms": [
          {
            "PathRemovePrefix": "/data"
          },
          {
            "RequestHeader": "X-Forwarded-Prefix",
            "Set": "/data"
          },
          {
            "X-Forwarded": "Set",
            "For": "Append",
            "Host": "Set",
            "Proto": "Set"
          }
        ]
      }
    },
    "Clusters": {
      "dab-backend-cluster": {
        "Destinations": {
          "dab-primary": {
            "Address": "http://127.0.0.1:5000/"
          }
        },
        "HttpClient": {
          "DangerousAcceptAnyServerCertificate": false
        }
      }
    }
  }
}
```

---

## 4. Programmatic Customization & Role Transforms (`Program.cs`)

To dynamically inspect authentication tokens or inject custom headers required by DAB (such as `X-MS-API-ROLE`), configure YARP programmatically using request transforms.

### Complete `Program.cs` Implementation

```csharp
using System.Security.Claims;
using Yarp.ReverseProxy.Transforms;

var builder = WebApplication.CreateBuilder(args);

// Register YARP services and load configuration from appsettings.json
builder.Services.AddReverseProxy()
    .LoadFromConfig(builder.Configuration.GetSection("ReverseProxy"))
    .AddTransforms(transformBuilderContext =>
    {
        // Custom transform rule to automatically assign DAB Roles based on Auth Claims
        transformBuilderContext.AddRequestTransform(async transformContext =>
        {
            var user = transformContext.HttpContext.User;

            if (user.Identity?.IsAuthenticated == true)
            {
                // Extract role from JWT or default to 'authenticated'
                var userRole = user.FindFirst(ClaimTypes.Role)?.Value ?? "authenticated";
                
                // Inject DAB-specific role header
                transformContext.ProxyRequest.Headers.Remove("X-MS-API-ROLE");
                transformContext.ProxyRequest.Headers.Add("X-MS-API-ROLE", userRole);
            }
            else
            {
                // Fallback to anonymous role for unauthenticated users
                transformContext.ProxyRequest.Headers.Remove("X-MS-API-ROLE");
                transformContext.ProxyRequest.Headers.Add("X-MS-API-ROLE", "anonymous");
            }

            await Task.CompletedTask;
        });
    });

// Add Authentication / Authorization services if required by main app
builder.Services.AddAuthentication().AddJwtBearer();
builder.Services.AddAuthorization();

var app = builder.Build();

app.UseRouting();

app.UseAuthentication();
app.UseAuthorization();

// Map YARP proxy endpoints
app.MapReverseProxy();

app.Run();
```

---

## 5. DAB Configuration (`dab-config.json`)

Configure DAB to support `StaticWebApps` or custom authentication mode so that it honors the proxy-injected `X-MS-API-ROLE` header.

```json
{
  "$schema": "https://github.com/Azure/data-api-builder/releases/download/v1.0.0/dab.draft-01.schema.json",
  "runtime": {
    "rest": {
      "enabled": true,
      "path": "/rest"
    },
    "graphql": {
      "enabled": true,
      "path": "/graphql"
    },
    "host": {
      "mode": "Production",
      "authentication": {
        "provider": "StaticWebApps"
      }
    }
  },
  "entities": {
    "Book": {
      "source": "dbo.Books",
      "permissions": [
        {
          "role": "anonymous",
          "actions": [ "read" ]
        },
        {
          "role": "authenticated",
          "actions": [ "*" ]
        },
        {
          "role": "admin",
          "actions": [ "*" ]
        }
      ]
    }
  }
}
```

---

## 6. End-to-End Route Mapping Verification

| Incoming Gateway URL | YARP Action | Transformed Target URL (DAB) |
| :--- | :--- | :--- |
| `GET /data/rest/Book` | Remove `/data` prefix | `GET http://127.0.0.1:5000/rest/Book` |
| `POST /data/graphql` | Remove `/data` prefix | `POST http://127.0.0.1:5000/graphql` |
| `GET /data/rest/Book/id/1` | Remove `/data` prefix | `GET http://127.0.0.1:5000/rest/Book/id/1` |

---

## 7. Operational Best Practices

1. **Security Isolation**: Ensure the backend DAB instance (port `5000`) is configured to only accept loopback connections (`127.0.0.1` or `localhost`), blocking external ingress directly to DAB.
2. **Streaming & WebSockets**: If using GraphQL Subscriptions over WebSockets, ensure YARP WebSocket proxying is enabled (enabled by default in YARP).
3. **Correlation ID Tracking**: Add a `X-Correlation-ID` header transform in YARP to simplify distributed logging between the gateway app and DAB backend.