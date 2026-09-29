# Production Guide: Hosting Microsoft Data API Builder (DAB) as an IIS Sub-Application (`/dab`)

This guide explains how to deploy Microsoft Data API Builder (DAB) as an IIS sub-application hosted under the path `/dab` beneath a primary IIS website.

---

## 1. Architecture Overview

```
[ Incoming Request: https://example.com/dab/rest/Book ]
                         │
                         ▼
           ┌───────────────────────────┐
           │     IIS Main Website      │
           │   (e.g., ASP.NET / ASP)   │
           └─────────────┬─────────────┘
                         │
        ┌────────────────┴────────────────┐
        │  Virtual Application Path: /dab │
        ▼                                 ▼
┌──────────────────────────────────────────────────────────┐
│              Dedicated Application Pool                  │
│       (.NET CLR Version: "No Managed Code")              │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ ASP.NET Core Module V2 (ANCM - OutOfProcess)       │  │
│  │ Executing: dotnet Microsoft.DataApiBuilder.dll     │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

---

## 2. Prerequisites & Parent `web.config` Setup

### A. Install IIS Prerequisites
* **IIS 8.5+**
* **ASP.NET Core Module v2 (ANCM)**: Included in the [.NET Core Hosting Bundle](https://dotnet.microsoft.com/download/dotnet).

### B. Prevent `web.config` Inheritance
By default, IIS sub-applications inherit handlers and modules from the parent website. To prevent configuration conflicts (such as duplicate handler errors):

Wrap the parent website's `<system.webServer>` configuration inside a `<location>` tag with `inheritInChildApplications="false"` in the parent website's `web.config`:

```xml
<!-- Parent Site web.config -->
<configuration>
  <location path="." inheritInChildApplications="false">
    <system.webServer>
      <handlers>
        <!-- Parent Handlers -->
      </handlers>
    </system.webServer>
  </location>
  
  <!-- Shared settings allowed to inherit go outside the location tag -->
  <system.webServer>
    <!-- E.g., shared static content rules -->
  </system.webServer>
</configuration>
```

---

## 3. IIS Directory & App Pool Setup

### Step 1: Create a Dedicated Application Pool
1. Open **IIS Manager**.
2. Right-click **Application Pools** > **Add Application Pool...**
3. Configure the pool:
   * **Name**: `DabAppPool`
   * **.NET CLR Version**: `No Managed Code`
   * **Managed pipeline mode**: `Integrated`
4. Click **OK**.

### Step 2: Create the Physical Folder & Deploy DAB
1. Create a physical directory on disk, e.g., `C:\inetpub\wwwroot\my-main-site\dab`.
2. Extract the published DAB binaries or installed `.NET tool` binaries into this directory.
3. Ensure the directory contains your configuration file: `dab-config.json`.

### Step 3: Convert the Folder to an IIS Application
1. In IIS Manager, expand your **Main Website**.
2. Right-click the `dab` folder > **Convert to Application**.
3. Click **Select...** and choose `DabAppPool`.
4. Verify the alias is set to `dab`.

---

## 4. Sub-Application Configuration

### A. Sub-Application `web.config`
Create a `web.config` file inside `C:\inetpub\wwwroot\my-main-site\dab\web.config`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <!-- Clear inherited handlers to isolate DAB -->
      <clear />
      <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
    </handlers>
    
    <aspNetCore processPath="dotnet" 
                arguments=".\Microsoft.DataApiBuilder.dll" 
                stdoutLogEnabled="true" 
                stdoutLogFile=".\logs\stdout" 
                hostingModel="OutOfProcess">
      <environmentVariables>
        <environmentVariable name="ASPNETCORE_ENVIRONMENT" value="Production" />
        <!-- DAB base path setting or custom connection string overrides -->
        <environmentVariable name="DATABASE_CONNECTION_STRING" value="Server=tcp:sqlserver.database.windows.net;Database=prod;User Id=app_user;Password=Secret;" />
      </environmentVariables>
    </aspNetCore>
    
    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
```

### B. Adjusting `dab-config.json` Base Paths
When running under an IIS sub-application (`/dab`), requests reaching the application will retain the path prefix unless stripped. Ensure your DAB path configuration aligns with your URI schema:

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
      "cors": {
        "origins": [ "https://example.com" ],
        "allow-credentials": true
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
        }
      ]
    }
  }
}
```

*Resulting Endpoints:*
* REST: `https://example.com/dab/rest/Book`
* GraphQL: `https://example.com/dab/graphql`

---

## 5. Verification & Troubleshooting

1. **Verify File Permissions**: Ensure the IIS AppPool Identity (`IIS AppPool\DabAppPool`) has **Read & Execute** permissions on `C:\inetpub\wwwroot\my-main-site\dab`.
2. **Logs**: Check `C:\inetpub\wwwroot\my-main-site\dab\logs\stdout_*.log` for engine startup logs if an HTTP 500.19 or 502.5 error occurs.
3. **Test Endpoint**:
   ```bash
   curl -i https://example.com/dab/rest/Book
   ```