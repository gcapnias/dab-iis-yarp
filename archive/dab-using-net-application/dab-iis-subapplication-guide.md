# Microsoft Data API Builder as an IIS Sub-Application (`/dab`)

## Purpose

This guide describes how to deploy Microsoft Data API Builder (DAB) on a Windows Server running IIS so that DAB is exposed as an IIS sub-application:

```text
https://api.example.com/dab/
```

with REST endpoints such as:

```text
https://api.example.com/dab/api/Book
```

and GraphQL at:

```text
https://api.example.com/dab/graphql
```

The parent IIS site can host another application independently.

> [!IMPORTANT]
> Microsoft currently documents DAB deployment to Azure App Service, containers, and other hosting environments, but does not publish a dedicated "DAB hosted by IIS" recipe.
>
> The approach in this document combines two supported building blocks:
>
> 1. Microsoft's documented DAB runtime payload (`Microsoft.DataApiBuilder.dll`), which can be started directly with `dotnet`.
> 2. Microsoft's documented ASP.NET Core Module (ANCM) support for IIS applications and sub-applications.
>
> For this reason, this document recommends **ANCM out-of-process hosting**. IIS owns the application lifecycle and proxies requests to a DAB/Kestrel process. It does not assume that DAB is designed to run in-process inside `w3wp.exe`.

---

## 1. Architecture

```text
                         HTTPS
                           │
                           ▼
                    ┌──────────────┐
                    │     IIS      │
                    │ api.example  │
                    └──────┬───────┘
                           │
             ┌─────────────┴──────────────┐
             │                            │
             ▼                            ▼
     Main IIS Application          /dab IIS Application
     MainAppPool                   DabAppPool
             │                            │
             │                            ▼
             │                     ASP.NET Core Module
             │                     (OutOfProcess)
             │                            │
             │                            ▼
             │                    DAB / Kestrel process
             │                    Microsoft.DataApiBuilder.dll
             │                            │
             └────────────────────────────┼────────────
                                          ▼
                                      Database
```

The `/dab` application receives a URL such as:

```text
https://api.example.com/dab/api/Book
```

IIS treats `/dab` as the application path. The DAB application itself continues to use its normal REST path `/api`.

This is preferable to trying to configure DAB's REST path as `/dab/api`. DAB's endpoint path settings are endpoint paths, while the IIS application path should remain an IIS concern.

---

## 2. Recommended hosting model

Use:

```text
IIS Application
    -> ASP.NET Core Module V2
        -> Out-of-process
            -> dotnet Microsoft.DataApiBuilder.dll start
                -> Kestrel
```

### Why out-of-process?

DAB is distributed as a runnable .NET application/tool and Microsoft's current non-container App Service guidance starts the restored runtime directly:

```text
dotnet ./dab/Microsoft.DataApiBuilder.dll start --config ./dab-config.json
```

ANCM's out-of-process model is designed to launch an ASP.NET Core process and proxy IIS requests to it.

This avoids relying on undocumented assumptions about loading the DAB runtime directly into the IIS worker process.

---

## 3. Prerequisites

On the IIS server install:

- IIS.
- IIS Management Console.
- The appropriate .NET Hosting Bundle.
- ASP.NET Core Module V2 (installed by the Hosting Bundle).
- Network/database connectivity from the server to the database.
- A dedicated IIS application pool for DAB.

On the build/deployment workstation install:

- .NET SDK.
- DAB as a pinned local .NET tool.

Check the installed runtime:

```powershell
dotnet --info
```

---

## 4. Create a reproducible DAB build

Create a deployment working directory:

```powershell
mkdir C:\Build\MyDab
cd C:\Build\MyDab
```

Create a local tool manifest:

```powershell
dotnet new tool-manifest
```

Install and pin the DAB version you have validated:

```powershell
dotnet tool install microsoft.dataapibuilder --version "<DAB-VERSION>"
```

Restore it:

```powershell
dotnet tool restore
```

Verify:

```powershell
dotnet tool run dab --version
```

Pinning the tool version is important for production because an upgrade to DAB should be an explicit deployment decision.

---

## 5. Create the DAB configuration

A simplified `dab-config.json` might look like:

```json
{
  "$schema": "https://github.com/Azure/data-api-builder/releases/latest/download/dab.draft.schema.json",
  "data-source": {
    "database-type": "mssql",
    "connection-string": "@env('DATABASE_CONNECTION_STRING')"
  },
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
  },
  "entities": {
    "Book": {
      "source": "dbo.Books",
      "permissions": [
        {
          "role": "anonymous",
          "actions": [ "read" ]
        }
      ]
    }
  }
}
```

### Do not put `/dab` in `runtime.rest.path`

Keep:

```json
"path": "/api"
```

not:

```json
"path": "/dab/api"
```

The external `/dab` prefix belongs to IIS.

### Keep secrets out of `dab-config.json`

Use:

```json
"connection-string": "@env('DATABASE_CONNECTION_STRING')"
```

instead of committing credentials to the file.

---

## 6. Test DAB before IIS deployment

Set a test connection string:

```powershell
$env:DATABASE_CONNECTION_STRING = "Server=...;Database=...;..."
```

Start DAB:

```powershell
dotnet tool run dab start --config .\dab-config.json
```

Test:

```text
http://localhost:5000/api/Book
```

or whatever address DAB reports at startup.

Do not continue with IIS configuration until DAB works directly.

---

## 7. Assemble the DAB runtime payload

Microsoft's App Service guidance deploys the restored DAB runtime files rather than installing/restoring the tool when the production application starts.

The following PowerShell follows that pattern.

```powershell
$DabVersion = "<DAB-VERSION>"

$GlobalPackages = (
    dotnet nuget locals global-packages --list
) -replace '^global-packages:\s*', ''

$DabPayload = Join-Path `
    $GlobalPackages `
    "microsoft.dataapibuilder\$DabVersion\tools\net8.0\any"

$DeployRoot = "C:\Deploy\Dab"

Remove-Item $DeployRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $DeployRoot -Force | Out-Null
New-Item -ItemType Directory -Path "$DeployRoot\runtime" -Force | Out-Null

Copy-Item ".\dab-config.json" -Destination $DeployRoot
Copy-Item "$DabPayload\*" -Destination "$DeployRoot\runtime" -Recurse

if (-not (Test-Path "$DeployRoot\runtime\Microsoft.DataApiBuilder.dll")) {
    throw "Microsoft.DataApiBuilder.dll was not found."
}
```

The resulting deployment folder should resemble:

```text
C:\Deploy\Dab\
│
├── dab-config.json
├── web.config
├── logs\
└── runtime\
    ├── Microsoft.DataApiBuilder.dll
    ├── Microsoft.DataApiBuilder.deps.json
    ├── Microsoft.DataApiBuilder.runtimeconfig.json
    └── ...
```

---

## 8. Create `web.config`

Create:

```text
C:\Deploy\Dab\web.config
```

with:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>

  <location path="." inheritInChildApplications="false">
    <system.webServer>

      <handlers>
        <add name="aspNetCore"
             path="*"
             verb="*"
             modules="AspNetCoreModuleV2"
             resourceType="Unspecified" />
      </handlers>

      <aspNetCore
          processPath="dotnet"
          arguments=".\runtime\Microsoft.DataApiBuilder.dll start --config .\dab-config.json --no-https-redirect"
          stdoutLogEnabled="false"
          stdoutLogFile=".\logs\stdout"
          hostingModel="outofprocess">

        <environmentVariables>
          <environmentVariable
              name="ASPNETCORE_ENVIRONMENT"
              value="Production" />
        </environmentVariables>

      </aspNetCore>

    </system.webServer>
  </location>

</configuration>
```

### Why `--no-https-redirect`?

IIS should normally terminate HTTPS.

The internal ANCM-to-Kestrel connection is an implementation detail. Disabling DAB's own HTTPS redirect avoids unnecessary or incorrect redirect behavior when TLS is already enforced at IIS.

HTTPS should instead be enforced at the IIS site level.

---

## 9. Create the IIS application pool

In **IIS Manager**:

1. Open **Application Pools**.
2. Select **Add Application Pool**.
3. Name it:

   ```text
   DabAppPool
   ```

4. Set:

   ```text
   .NET CLR Version: No Managed Code
   Managed pipeline mode: Integrated
   ```

5. Open **Advanced Settings**.

Recommended starting values:

```text
Identity                       ApplicationPoolIdentity
Start Mode                     AlwaysRunning
Idle Time-out (minutes)        0
Enable 32-Bit Applications     False
```

For production availability, also review the site's preload/application initialization configuration according to your organization's IIS standards.

### Separate application pool

Keep DAB in a different application pool from the parent application.

Benefits include:

- lifecycle isolation;
- independent recycle;
- independent identity;
- independent resource limits;
- simpler troubleshooting;
- failure isolation.

---

## 10. Grant filesystem permissions

The DAB application pool requires at least read/execute access to the deployment directory.

Example:

```powershell
icacls "C:\Deploy\Dab" `
  /grant "IIS AppPool\DabAppPool:(OI)(CI)RX"
```

If file logging is enabled, grant modify access only to the log directory:

```powershell
New-Item -ItemType Directory `
    -Path "C:\Deploy\Dab\logs" `
    -Force | Out-Null

icacls "C:\Deploy\Dab\logs" `
  /grant "IIS AppPool\DabAppPool:(OI)(CI)M"
```

Avoid granting unnecessary write permission to the entire application directory.

---

## 11. Configure the connection string as an environment variable

One option is to add it to the `<environmentVariables>` element in `web.config`:

```xml
<environmentVariable
    name="DATABASE_CONNECTION_STRING"
    value="..." />
```

However, storing a password in `web.config` is usually undesirable.

Prefer one of the following where possible:

- Windows-integrated database authentication;
- certificate-based authentication;
- managed identity where applicable;
- a protected deployment-time secret mechanism;
- a machine/account-level environment variable controlled by operations.

DAB resolves:

```text
@env('DATABASE_CONNECTION_STRING')
```

at runtime.

---

## 12. Create the IIS sub-application

Assume the existing site is:

```text
Default Web Site
```

or:

```text
api.example.com
```

In IIS Manager:

1. Right-click the site.
2. Select **Add Application**.
3. Set:

   ```text
   Alias: dab
   ```

4. Set the physical path:

   ```text
   C:\Deploy\Dab
   ```

5. Select:

   ```text
   DabAppPool
   ```

6. Save.

The URL becomes:

```text
https://api.example.com/dab
```

---

## 13. Expected endpoint mapping

With the following DAB configuration:

```json
"rest": {
  "path": "/api"
},
"graphql": {
  "path": "/graphql"
}
```

the public URLs are:

| Function | Public URL |
|---|---|
| DAB root application | `/dab` |
| REST entity | `/dab/api/Book` |
| GraphQL | `/dab/graphql` |
| Health endpoint, when configured/available | `/dab/health` |

The IIS application path is external to DAB's endpoint configuration.

---

## 14. Test the deployment

Recycle/start the pool:

```powershell
Restart-WebAppPool -Name "DabAppPool"
```

Test the REST endpoint:

```powershell
Invoke-RestMethod `
    -Uri "https://api.example.com/dab/api/Book"
```

Also test the root:

```powershell
Invoke-WebRequest `
    -Uri "https://api.example.com/dab/"
```

Check:

- IIS access logs;
- Windows Event Viewer;
- ANCM stdout logs temporarily if startup fails;
- DAB application logs.

---

## 15. Temporary ANCM startup logging

If DAB fails to start, temporarily change:

```xml
stdoutLogEnabled="true"
```

and ensure:

```text
C:\Deploy\Dab\logs
```

is writable by `IIS AppPool\DabAppPool`.

After troubleshooting, turn stdout logging back off.

Unbounded stdout logging is not intended as a production logging strategy.

---

## 16. Authentication considerations

DAB authorization and IIS authentication are separate concerns.

### Option A — DAB JWT authentication

A common design is:

```text
Client
   │ Bearer token
   ▼
IIS
   │
   ▼
DAB
   │ validates token / applies DAB roles
   ▼
Database
```

In this model IIS should allow the `Authorization` header to reach DAB.

### Option B — Windows authentication

Do not assume that enabling Windows Authentication in IIS automatically gives DAB a usable DAB identity/role model.

If Windows/AD identity must be translated into DAB authorization, design and test that integration explicitly.

### DAB entity permissions still matter

Network protection alone is not a replacement for correctly configured DAB entity permissions.

Avoid production configurations such as:

```json
"permissions": [
  {
    "role": "anonymous",
    "actions": [ "*" ]
  }
]
```

unless anonymous full access is genuinely intended.

---

## 17. CORS

If browser clients use the same origin:

```text
https://api.example.com
```

and DAB is:

```text
https://api.example.com/dab
```

the request is normally same-origin and a separate CORS policy may not be required.

If the frontend uses a different origin, configure DAB's CORS settings explicitly.

Do not use a wildcard origin together with credentialed cross-origin requests.

---

## 18. Pagination and externally visible URLs

Reverse proxies and sub-applications can expose path-base issues in generated URLs.

DAB supports pagination configuration including relative next links in current releases.

If clients encounter incorrect host/path values in pagination links, prefer relative pagination links where appropriate and verify the behavior of your deployed DAB version.

Test pagination as part of deployment acceptance, not just simple entity reads.

---

## 19. Production application-pool considerations

Review at least:

- pool identity;
- idle timeout;
- scheduled recycle policy;
- rapid-fail protection;
- CPU limits;
- private-memory limits;
- application initialization;
- preload;
- database connection limits;
- server patch/reboot behavior.

Do not arbitrarily impose tight memory or CPU limits before measuring DAB under realistic traffic.

---

## 20. Deployment and upgrades

Treat DAB binaries and configuration as one versioned deployment unit:

```text
DAB version
+
dab-config.json version
+
database schema expectations
```

Recommended deployment flow:

```text
Build
  ↓
Pin DAB version
  ↓
Restore runtime
  ↓
Validate dab-config.json
  ↓
Integration test
  ↓
Stop/recycle DabAppPool
  ↓
Deploy files
  ↓
Start pool
  ↓
Health/smoke tests
```

Do not allow the production server to automatically retrieve "latest DAB" during application startup.

---

## 21. Blue/green alternative

For stricter production environments, consider two deployment directories:

```text
C:\Apps\Dab\v2.0.x-A
C:\Apps\Dab\v2.0.x-B
```

Deploy and validate the inactive copy, then change the IIS application's physical path.

This provides a simpler rollback strategy than modifying files in place.

---

## 22. Known limitations and caveats

### 22.1 This is not an official DAB IIS deployment recipe

Microsoft documents the components used here, but does not currently provide an IIS-specific DAB deployment walkthrough.

Validate the complete arrangement in a staging environment before production adoption.

### 22.2 Do not assume in-process DAB hosting

This guide deliberately uses:

```xml
hostingModel="outofprocess"
```

DAB remains its own .NET/Kestrel process.

### 22.3 `/dab` is the IIS application path

Keep DAB REST and GraphQL paths conventional:

```text
/api
/graphql
```

and let IIS contribute `/dab`.

### 22.4 Parent and child application configuration

The parent ASP.NET Core application's published `web.config` should normally use:

```xml
<location path="." inheritInChildApplications="false">
```

so the parent application's ASP.NET Core handler configuration is not inherited incorrectly by the `/dab` child application.

---

## 23. Recommended final topology

```text
https://api.example.com/
        │
        ├── Main application
        │      App Pool: MainAppPool
        │
        └── /dab
               App Pool: DabAppPool
                    │
                    ▼
              ANCM OutOfProcess
                    │
                    ▼
              DAB / Kestrel
                    │
                    ▼
                 Database
```

This provides a conventional IIS operational model while keeping DAB isolated as its own process.

---

# References

Microsoft documentation:

- Data API Builder — Deploy to Azure App Service  
  https://learn.microsoft.com/en-us/azure/data-api-builder/deployment/azure-app-service

- Data API Builder — `dab start` command  
  https://learn.microsoft.com/en-us/azure/data-api-builder/command-line/dab-start

- Data API Builder — Runtime configuration  
  https://learn.microsoft.com/en-us/azure/data-api-builder/configuration/runtime

- Data API Builder — REST endpoints  
  https://learn.microsoft.com/en-us/azure/data-api-builder/concept/rest/overview

- ASP.NET Core Module for IIS  
  https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/aspnet-core-module

- Host ASP.NET Core on Windows with IIS  
  https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/

- IIS / ASP.NET Core advanced configuration and sub-applications  
  https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/advanced

---

## Verification note

This document was prepared against Microsoft documentation available on **2026-09-29**. DAB is evolving quickly; validate the selected DAB version's release notes and configuration schema before production deployment.
