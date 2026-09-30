---
status: accepted
---

# Conditional same-process DAB integration

Proceed with specifying an ASP.NET Core application that hosts the real DAB Core engine in the same process through application-owned bootstrap and HTTP adapters. The user accepts ownership of this integration layer, supplemental dependency pins, and upgrade validation to preserve the required single-application access boundary despite the absence of an established upstream-supported embedding contract.

The application must expose all REST and GraphQL endpoints, operations, and permissions enabled by DAB configuration. Configuration changes may require an application restart but must not require recompilation. MCP is optional. The final target framework and package policy remain a separate decision.

This is a conditional go for specification, not production readiness. The Core 2.0.12 spike demonstrated a fixed anonymous Products read adapter on .NET 8 and .NET 10; it did not demonstrate configuration-driven endpoint changes after restart or GraphQL hosting. These requirements need a further proof before the architecture is considered fully validated. Security, lifecycle, deployment under IIS, and the final acceptance matrix remain subsequent planning and validation gates.

JWT bearer authentication and DAB permission enforcement are required for REST and GraphQL. Tokens are issued by another application and validated using DAB's Custom provider; the DAB application does not issue tokens. The embedded host must validate tokens and apply the configured DAB roles and permissions; the anonymous spike is not evidence of that integration. The security proof must include valid permitted requests, invalid or expired tokens, authenticated callers lacking permission, unauthorized role selection, and issuer/audience validation. The concrete issuer URL, audience, signing-key lifecycle, and profile claims remain to be specified; compatibility of the agreed discovery and roles contract must be demonstrated. DAB documents JWT support through Microsoft Entra ID and its Custom provider: [security overview](https://learn.microsoft.com/azure/data-api-builder/concept/security/overview) and [custom JWT authentication](https://learn.microsoft.com/azure/data-api-builder/concept/security/authenticate-custom).

Revisit the decision if required REST or GraphQL behavior cannot be exposed from configuration without rebuilding, the agreed issuer JWTs cannot be validated and authorized correctly by DAB, or the integration cannot be maintained across the selected package upgrades. A separate DAB process or application would change the agreed boundary and requires a new user decision.

The external identity issuer will be developed in parallel as an ASP.NET Core .NET 10 C# application. It authenticates users through Windows Authentication, retrieves profiles and roles from an existing database, and issues JWTs for the DAB application. Token issuance must bind claims to the authenticated Windows identity and database results. The issuer will expose standard OpenID Connect discovery and public signing keys compatible with DAB's Custom provider, and place named roles in the `roles` claim. Profile claims influence authorization only through explicitly configured policies. A focused interoperability spike will establish a JWT/discovery contract compatible with DAB, using synthetic profile and role inputs; implementing Windows Authentication and database identity lookup is outside that spike. Production issuer implementation remains outside this planning map.

Develop both runnable proof prototypes under `src/` on `develop`: the JWT issuer and the DAB-integrated application. Their purpose is to validate the architecture and provide reproducible evidence for the implementation specification, rather than deliver production applications.

Decision ticket: [Decide whether Core-only same-process DAB is viable](https://github.com/gcapnias/dab-iis-yarp/issues/7). Evidence: [Core hosting research](../../archive/research/dab-core-hosting/README.md).
