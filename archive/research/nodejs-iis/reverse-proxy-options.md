# Reverse proxy options for Node.js behind IIS

Research date: 2026-10-13\
Status: options and source-backed constraints; no architecture selected and no Node.js/IIS topology tested.

## Scope and existing evidence

This note compares putting IIS in front of a Node.js HTTP application while a separate Windows service owns the Node process. It covers the existing IIS reverse-proxy route (ARR plus URL Rewrite) and a custom YARP gateway hosted as an ASP.NET Core application under IIS.

The repository's DAB/YARP design material is useful for the gateway shape, but its statements about backend process supervision and its .NET execution proofs do not prove Node.js hosting or behavior. The existing Windows Server IIS evaluation is ANCM/.NET evidence. The options below are proposals grounded in the cited product contracts, not measured Node.js deployments.

## Options at a glance

| Option | Request path | Main benefit | Main cost / decision point |
| --- | --- | --- | --- |
| IIS + ARR + URL Rewrite, Node as a Windows service | Client → IIS/ARR → loopback Node listener | Smallest IIS-specific proxy stack; routing is configured in IIS and no custom gateway app is needed. Microsoft's walkthrough documents URL Rewrite plus ARR reverse-proxy rules and requires enabling the ARR proxy feature. [ARR reverse-proxy walkthrough](https://learn.microsoft.com/en-us/iis/extensions/url-rewrite-module/reverse-proxy-with-url-rewrite-v2-and-application-request-routing) | Requires installing/configuring ARR and URL Rewrite; rules and header behavior live in IIS configuration. Validate the exact installed IIS/ARR versions against WebSockets and application path/redirect needs. |
| IIS → YARP gateway hosted by ASP.NET Core Module, Node as a Windows service | Client → IIS/ANCM → ASP.NET Core/YARP → loopback Node listener | Routing, transforms, active/passive destination health checks, and custom policy can be expressed in the gateway application. YARP is a .NET library configured in an ASP.NET Core app, not a standalone IIS module or built-in executable. [YARP getting started](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/getting-started?view=aspnetcore-10.0) [YARP health checks](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/dests-health-checks?view=aspnetcore-10.0) | Adds a .NET application, deployment/runtime requirements, a second configuration surface, and a gateway process whose lifetime is tied to IIS/ANCM. YARP does not thereby own or supervise the Node service. |

Both options can terminate public TLS at an IIS HTTPS binding and proxy to a loopback HTTP endpoint. IIS documents HTTPS site bindings and certificate selection; the proxy-to-Node hop is a separate connection whose encryption is an optional design choice. [IIS SSL bindings](https://learn.microsoft.com/en-us/iis/manage/configuring-security/how-to-set-up-ssl-on-iis) [YARP HTTPS/TLS](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/https-tls?view=aspnetcore-10.0)

## Process ownership and lifecycle

For either proxy option, treat Node.js as an independently supervised service: configure its service account, working directory, absolute executable path, environment, logs, automatic/delayed startup, failure restart policy, and graceful-stop timeout. WinSW is one candidate: its official v3 docs describe it as a wrapper that runs an executable as a Windows service, supports automatic start, restart-on-failure actions, configurable stop timeout, and log configuration. The actual Node launch command and service behavior still need to be validated under the chosen service account. [WinSW README](https://github.com/winsw/winsw) [WinSW configuration](https://github.com/winsw/winsw/blob/v3/docs/xml-config-file.md) [WinSW troubleshooting](https://github.com/winsw/winsw/blob/v3/docs/troubleshooting.md)

PM2 remains useful for Node process features, but its own startup-hook documentation lists Linux/BSD/macOS init systems and points Windows users to external packages such as `pm2-windows-service` or `pm2-windows-startup`. The `pm2-windows-service` project identifies itself as deprecated. Therefore, do not present PM2's built-in `startup` support as a Windows service solution; if PM2 is desired, select and assess a maintained Windows service integration separately. [PM2 startup hook](https://pm2.io/docs/runtime/guide/startup-hook/) [deprecated pm2-windows-service](https://github.com/jon-hall/pm2-windows-service)

Expected lifecycle boundaries, to verify in an implementation:

- On OS boot, the Windows Service Control Manager starts the Node service according to its configured start policy. IIS/WAS starts separately; configure health/readiness and useful 502/503 handling for the interval when the backend is not ready.
- If Node exits, the service wrapper can restart it according to its failure policy. ARR or YARP routes requests; neither proxy option is the Node process supervisor.
- If IIS recycles/stops an app pool, an IIS-hosted YARP gateway is restarted by the ASP.NET Core Module/IIS hosting path and may interrupt in-flight requests or sockets. The independent Node service is not thereby restarted. ASP.NET Core Module out-of-process hosting starts its app on demand and restarts it after shutdown/crash; its exact lifecycle does not transfer to Node. [IIS hosting models and ANCM](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/?view=aspnetcore-10.0)
- ARR configuration remains in IIS while IIS recycles. Node remains a separate service. Confirm outage/recovery behavior with the selected IIS modules and service settings instead of inferring zero downtime.

## Shared request and security boundaries

**TLS.** Bind the public hostname and certificate to the IIS site. Terminating TLS at IIS means the backend sees the proxy's connection scheme unless the proxy communicates the public scheme. YARP's docs likewise describe TLS termination at the proxy and optional TLS to destinations. Bind Node to loopback or another restricted interface and allow only the proxy to reach it; do not expose an unauthenticated backend listener to the network.

**Forwarded headers.** Agree exactly which proxy sets `X-Forwarded-For`, `X-Forwarded-Proto`, and, if needed, `X-Forwarded-Host`; strip or overwrite caller-supplied values at the trusted edge. Configure the Node framework to trust only that proxy/hop. Express explicitly warns that `trust proxy: true` is unsafe if the last proxy does not overwrite forwarded headers, and says the correct trust setting depends on the topology. [Express: behind proxies](https://expressjs.com/en/guide/behind-proxies/)

**WebSockets.** YARP documents WebSocket proxying enabled by default. For IIS, enable the WebSocket Protocol feature where required and test the precise application/proxy route, including long-lived connections across app-pool or service restarts. Microsoft specifically notes that when Node Socket.IO handles WebSockets, the IIS WebSocket module may need to be disabled in the site's configuration so IIS does not intercept the communication. This is an application-specific setting, not a blanket instruction for all Node apps. [YARP WebSockets](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/websockets?view=aspnetcore-10.0) [IIS WebSocket and Node Socket.IO note](https://learn.microsoft.com/en-us/iis/get-started/whats-new-in-iis-8/iis-80-websocket-protocol-support)

**Windows Authentication.** IIS can authenticate Windows users, particularly in intranet/domain scenarios, but this does not by itself establish that the downstream Node process receives a usable Windows principal or delegated user credentials. NTLM is connection-oriented and IIS's Windows Authentication documentation says HTTP proxy connections are not supported by NTLM. Treat IIS/YARP as the authentication boundary unless a deliberate delegation design is proven. If Node needs the user identity, the proxy must create a trusted identity assertion/header, overwrite any client-supplied copy, and ensure only the proxy can reach Node; Node must accept it only on that protected hop. For a YARP gateway, implement explicit principal-to-header mapping. For ARR, configure explicit server-variable/header rewriting. Test the intended Kerberos/NTLM behavior with the real domain, browser, and IIS configuration. [IIS Windows Authentication](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/security/authentication/windowsauthentication) [IIS URL Rewrite header/server-variable setting](https://learn.microsoft.com/en-us/iis/extensions/url-rewrite-module/setting-http-request-headers-and-iis-server-variables)

## Decision questions for the later guidance document

1. Should the gateway remain configuration-only in IIS (ARR + URL Rewrite), or should proxy routing/policy be code-owned in an ASP.NET Core/YARP application?
2. Is the organization prepared to operate a small .NET gateway and its runtime/ANCM lifecycle in addition to Node, or is that extra application acceptable because YARP customization is valuable?
3. Which Windows service wrapper and account will own Node, and what restart, graceful-stop, logging, and startup-readiness behavior is required?
4. Does the Node app need forwarded client IP/public scheme/host, WebSockets, or a Windows-authenticated user identity? These requirements may change the implementation and acceptance tests.
5. Should the IIS-to-Node hop stay on loopback HTTP, or is backend TLS required by a broader deployment boundary?

## Sources

- [Microsoft: Reverse Proxy with URL Rewrite and ARR](https://learn.microsoft.com/en-us/iis/extensions/url-rewrite-module/reverse-proxy-with-url-rewrite-v2-and-application-request-routing)
- [Microsoft: Get started with YARP](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/getting-started?view=aspnetcore-10.0)
- [Microsoft: YARP destination health checks](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/dests-health-checks?view=aspnetcore-10.0)
- [Microsoft: Host ASP.NET Core on Windows with IIS](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/?view=aspnetcore-10.0)
- [Microsoft: YARP HTTPS and TLS](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/https-tls?view=aspnetcore-10.0)
- [Microsoft: Set up SSL on IIS](https://learn.microsoft.com/en-us/iis/manage/configuring-security/how-to-set-up-ssl-on-iis)
- [Microsoft: YARP WebSockets](https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/yarp/websockets?view=aspnetcore-10.0)
- [Microsoft: IIS WebSocket Protocol Support](https://learn.microsoft.com/en-us/iis/get-started/whats-new-in-iis-8/iis-80-websocket-protocol-support)
- [Microsoft: Windows Authentication configuration](https://learn.microsoft.com/en-us/iis/configuration/system.webserver/security/authentication/windowsauthentication)
- [Microsoft: Set HTTP request headers and IIS server variables](https://learn.microsoft.com/en-us/iis/extensions/url-rewrite-module/setting-http-request-headers-and-iis-server-variables)
- [Express: Behind proxies](https://expressjs.com/en/guide/behind-proxies/)
- [WinSW](https://github.com/winsw/winsw)
- [WinSW v3 service configuration](https://github.com/winsw/winsw/blob/v3/docs/xml-config-file.md)
- [WinSW troubleshooting](https://github.com/winsw/winsw/blob/v3/docs/troubleshooting.md)
- [PM2 startup hook](https://pm2.io/docs/runtime/guide/startup-hook/)
- [Deprecated pm2-windows-service](https://github.com/jon-hall/pm2-windows-service)
