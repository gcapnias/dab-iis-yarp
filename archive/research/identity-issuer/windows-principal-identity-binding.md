# Windows principal SID binding for the identity issuer

Date: 2026-10-02. Scope: verify whether the issuer can obtain the authenticated Windows user's SID from ASP.NET Core/IIS without an Active Directory lookup or delegated directory-search account, and assess the current implementation.

## Finding

The concern that Windows Authentication exposes only a username and domain/machine name is not correct for the issuer's supported Windows hosts. On Windows, IIS and ASP.NET Core Negotiate expose the authenticated request as a Windows principal backed by a Windows access token. That token contains the user's SID, and .NET reads it directly from the token. The application does not need to query Active Directory to obtain the SID and does not need delegated directory-search credentials.

The distinction is the identity source: use the SID from the authenticated *request principal*. Do not use `WindowsIdentity.GetCurrent()` to identify the caller; outside an impersonated operation it can refer to the issuer worker or process identity.

## Platform behavior in .NET 10

- The .NET 10 ASP.NET Core Negotiate handler checks whether the server runs on Windows and its negotiated identity is a `WindowsIdentity`. In that case it creates a `WindowsPrincipal` over that identity. On other platforms it creates a regular `ClaimsPrincipal` with a `ClaimsIdentity` instead. The handler has an optional LDAP claim-resolution path, which is a separate feature and is not enabled in this issuer's `.AddNegotiate()` configuration.
- The .NET 10 IIS server obtains the request's authenticated Windows token and wraps it in `WindowsIdentity`/`WindowsPrincipal`; when automatic authentication is enabled, this becomes the request `User`.
- In the .NET 10 runtime, `WindowsIdentity.User` calls `GetTokenInformation` with `TokenUser` and constructs the SID from that token field. The runtime's primary SID claim is likewise read from `TokenUser`. This is OS token inspection, not an LDAP/AD search.
- The Windows access-token contract says the token contains the SID for the account associated with it. This applies to local as well as domain users. A local account is issued by that computer's local security authority; its SID is available from the authenticated token without consulting AD.

The account's display/logon name can be represented as `DOMAIN\\user` or, for a local account, `MACHINE\\user`. Names identify accounts less reliably than SIDs: a rename leaves the SID unchanged, while a newly created account with a reused name receives a different SID. Local-account SIDs are machine-specific, so the same local username on two servers is not one shared identity. Domain accounts are the appropriate shared principal for a multi-host deployment.

## Assessment of ticket #11 implementation

`AuthenticatedWindowsIdentity.GetSid` in `src/IdentityIssuer/IdentityDirectory.cs` first reads `ClaimTypes.PrimarySid`/`ClaimTypes.Sid` from the authenticated request principal, then on Windows reads `User` from a `WindowsIdentity` in that same principal. It does not inspect `WindowsIdentity.GetCurrent()` and makes no AD/LDAP call. `IdentityProfileResolver` fails closed if no SID is available, and `AspNetIdentityDirectory` queries the issuer SQL Identity store by the SID. This is the appropriate stable binding for the supported Windows-hosted flow.

The recorded Kestrel/Negotiate live proof demonstrates successful default-credential authentication and SID-keyed Identity mapping, including for the current local Windows account. It does not say whether the claim path or `WindowsIdentity.User` fallback supplied the SID. It also does not prove IIS runtime behavior; IIS support is established here from .NET 10 source and Microsoft documentation, not a live IIS run. The implementer is performing a sanitized follow-up that records only the principal type and boolean indicators for SID-source presence, without emitting account names, SIDs, tokens, or claims.

## Recommendation

Keep SID-based provisioning and request-principal lookup; do not replace them with a `DOMAIN\\username` or `MACHINE\\username` lookup and do not add an AD query or search service account. Preserve fail-closed behavior when the authenticated request provides no SID. State that production issuer hosting for this SID binding must use Windows (IIS or Windows Kestrel/Negotiate). A non-Windows Negotiate deployment receives a generic claims identity, and would need an explicitly designed and trusted identity-to-SID mapping path before it could use this resolver. Do not treat optional LDAP group-claim resolution as an implicit SID-resolution contract.

For local development, an operator can provision the SID from the Windows account itself (for example, `whoami /user` while signed in as that account). Provisioning must use the exact SID that Windows Authentication presents. If the issuer moves to another machine and authenticates a local account there, that local account needs its own explicit mapping because its SID is different.

## Primary sources

- [.NET 10 ASP.NET Core Negotiate handler source](https://github.com/dotnet/aspnetcore/blob/v10.0.0/src/Security/Authentication/Negotiate/src/NegotiateHandler.cs#L292-L320) — Windows uses `WindowsPrincipal`/`WindowsIdentity`; other platforms use `ClaimsIdentity`; LDAP claim retrieval is a separate option.
- [.NET 10 IIS request context source](https://github.com/dotnet/aspnetcore/blob/v10.0.0/src/Servers/IIS/IIS/src/Core/IISHttpContext.cs#L264-L270) and [IIS Windows-principal construction](https://github.com/dotnet/aspnetcore/blob/v10.0.0/src/Servers/IIS/IIS/src/Core/IISHttpContext.cs#L806-L819) — authenticated request token is wrapped as a Windows identity and principal.
- [.NET 10 `WindowsIdentity.User` implementation](https://github.com/dotnet/runtime/blob/v10.0.0/src/libraries/System.Security.Principal.Windows/src/System/Security/Principal/WindowsIdentity.cs#L556-L573) — obtains `TokenUser` from the Windows token.
- [.NET 10 primary SID claim implementation](https://github.com/dotnet/runtime/blob/v10.0.0/src/libraries/System.Security.Principal.Windows/src/System/Security/Principal/WindowsIdentity.cs#L1043-L1075) — obtains the SID claim from `TokenUser`.
- [Windows access-token contents](https://learn.microsoft.com/en-us/windows/win32/secauthz/access-tokens) — the user SID is part of the account's token.
- [WindowsIdentity.User API (.NET 10)](https://learn.microsoft.com/en-us/dotnet/api/system.security.principal.windowsidentity.user?view=net-10.0) — documents that `User` returns the user's SID.
- [Configure Windows Authentication in ASP.NET Core (.NET 10)](https://learn.microsoft.com/en-us/aspnet/core/security/authentication/windowsauth?view=aspnetcore-10.0) — documents IIS, Kestrel, Windows Authentication, and Windows identity behavior.
- [Microsoft local accounts](https://learn.microsoft.com/en-us/windows/security/identity-protection/access-control/local-accounts) — local user accounts are defined by the computer's local security authority.
- [Security Identifiers](https://learn.microsoft.com/en-us/windows/win32/secauthz/security-identifiers) — Windows uses SIDs in tokens to identify users for subsequent security checks.
- [Windows principal role documentation (.NET 10)](https://learn.microsoft.com/en-us/aspnet/core/security/authorization/roles?view=aspnetcore-10.0) — describes the Windows identity in the request principal and SID claims.
