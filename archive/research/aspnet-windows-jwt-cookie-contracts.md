# ASP.NET Core Windows identity, JWT discovery, and browser cookies

Research date: 2026-10-01. This note records upstream contracts that shape the issuer prototype in [ticket #11](https://github.com/gcapnias/dab-iis-yarp/issues/11). It does not establish access to the project's identity data or prove the Windows-to-SQL-to-JWT chain on a configured host.

## Windows identity source

ASP.NET Core supports Windows Authentication with IIS, Kestrel, and HTTP.sys. For IIS hosting, the site must enable Windows Authentication; the IIS integration layer supplies the authenticated request principal through `HttpContext.User` when automatic authentication is enabled. The issuer therefore reads the caller from the request principal. It must not use `WindowsIdentity.GetCurrent()` as the caller mapping key: that method can describe the application process when request impersonation is not active. A Windows SID is the stable machine-readable identifier exposed by `WindowsIdentity.User` and is suitable for an explicit local Identity-user mapping. The prototype requires the authenticated principal's SID and an exact match to the persisted mapping before it issues a token.

Sources: [ASP.NET Core Windows Authentication](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/windowsauth?view=aspnetcore-10.0), [IIS in-process hosting and automatic authentication](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/in-process-hosting?view=aspnetcore-10.0), [WindowsIdentity.User](https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.windowsidentity.user?view=net-10.0), and [WindowsIdentity.GetCurrent](https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.windowsidentity.getcurrent?view=net-10.0).

## JWT and public-key discovery

The token contract uses a configured HTTPS issuer identifier and resource audience, a stable subject, `iat`, `nbf`, and `exp`, and RS256 signatures. The issuer publishes only the public RSA parameters in a JWKS document and includes a key identifier (`kid`) in both the JWT header and JWK so a consumer can select the verification key. Consumers must validate the signature, exact issuer, intended audience, and expiration; a `roles` claim carries role names. The issuer does not publish its private signing parameters.

The standards define the claim meanings and metadata/key structures: [RFC 7519, JSON Web Token](https://www.rfc-editor.org/rfc/rfc7519.html), [RFC 8414, Authorization Server Metadata](https://www.rfc-editor.org/rfc/rfc8414.html), [RFC 7517, JSON Web Key](https://www.rfc-editor.org/rfc/rfc7517.html), and [RFC 9068, JWT Profile for OAuth 2.0 Access Tokens](https://www.rfc-editor.org/rfc/rfc9068.html). DAB's [Custom authentication provider guidance](https://learn.microsoft.com/azure/data-api-builder/concept/security/authenticate-custom) requires a compatible issuer/key-discovery contract and role claims named `roles`. Issuer-side conformance does not prove that the embedded DAB host discovers or validates this prototype's tokens; that remains ticket #10.

The selected profile claims are deliberately small: `profile_id` is a persisted Identity profile key and `name` is a persisted display name. `sub` is the ASP.NET Identity user identifier. These profile claims do not grant access by themselves; DAB permissions can use them only through explicitly configured policies.

## Browser cookie and CSRF behavior

The issuer returns the signed token only in an `HttpOnly`, `Secure`, `SameSite=Lax` cookie with a host-only scope by default and an expiry equal to the token lifetime. A deployment may configure a parent-domain cookie only when the issuer and embedded host share a deliberately chosen DNS trust boundary. `SameSite=None` is appropriate only when a cross-site cookie is required and must be paired with `Secure`. Browsers do not expose an HttpOnly token to JavaScript.

The issuer uses an antiforgery cookie and request token for state-changing session and logout requests. SameSite is useful defense in depth but does not replace CSRF verification. The later embedded application must independently validate the browser request before it translates this cookie into an Authorization header for DAB. Ticket #11 does not implement or validate that bridge.

Sources: [ASP.NET Core SameSite guidance](https://learn.microsoft.com/en-us/aspnet/core/security/samesite?view=aspnetcore-10.0), [ASP.NET Core antiforgery](https://learn.microsoft.com/en-us/aspnet/core/security/anti-request-forgery?view=aspnetcore-10.0), and [ASP.NET Core cookie authentication](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/cookie?view=aspnetcore-10.0). The prototype uses custom JWT cookies rather than ASP.NET Core Identity authentication cookies, so it applies these cookie attributes directly.

ASP.NET Core 10 treats known API endpoints specially for cookie authentication, returning 401 or 403 instead of redirects to login pages. The issuer endpoints are API-shaped and follow those status semantics. Source: [.NET 10 cookie authentication API behavior](https://learn.microsoft.com/en-us/aspnet/core/breaking-changes/10/cookie-authentication-api-endpoints?view=aspnetcore-10.0).

## Evidence boundary

These primary sources describe framework and protocol behavior. They do not prove that the current workstation has IIS Windows Authentication enabled, that a test Windows identity can reach the issuer, or that the Northwind database accepts schema changes. Northwind use documented elsewhere in this repository is read-only. The issuer migration is generated for a dedicated schema, but applying it requires an authorized development database and explicit DDL approval.
