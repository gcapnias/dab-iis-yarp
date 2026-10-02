# Integrated DAB Application

An application that provides end users access to the API described by its DAB configuration, using identities and access credentials supplied by a separate issuer.

## Language

**Configuration-driven DAB access**:
Access through the application to every REST and GraphQL endpoint enabled by DAB configuration, including configured operations and permissions. Configuration changes take effect after restarting the application, without recompiling it; MCP access is optional.
_Avoid_: Products-only integration, fixed-endpoint integration

**Configured resource permission**:
The access rule declared for a DAB resource, operation and role. An issuer role carried in a credential grants resource access only when the DAB application's validated caller and configured permission agree.
_Avoid_: Issuer login permission, automatic role access

**Local API proof**:
Evidence for configuration-driven REST and GraphQL behavior in the embedded application, using isolated data and explicitly identified permissions. It is separate from issuer interoperability and server environment evaluation.
_Avoid_: Complete security proof, production readiness

**Issuer interoperability proof**:
Evidence that issuer credentials reach the embedded application and the real DAB engine validates the caller and enforces configured resource permissions through REST and GraphQL. Controlled credential tests and the real Windows caller-to-issuer-account chain are distinct parts of this proof.
_Avoid_: Issuer-only proof, anonymous API proof

**Identity issuer**:
The separate application that binds an authenticated Windows caller to an issuer account and issues access credentials from its persisted profile and roles.
_Avoid_: DAB login service, DAB application

**Windows caller**:
The user authenticated for the current request by Windows Authentication, distinct from the account running the application.
_Avoid_: Worker identity, application-pool identity

**Issuer account**:
The locally persisted account explicitly mapped to a Windows caller, with an enabled state, profile, roles and permitted claims. A Windows identity alone does not grant issuer access.
_Avoid_: Automatically registered user, Windows group membership

**Profile**:
The issuer account's stable application identity and intended descriptive or authorization attributes. Profile attributes influence DAB access only through explicitly configured policies.
_Avoid_: Windows profile, directory record

**Issuer role**:
An operator-assigned role persisted for an issuer account and carried in its access credential. Windows groups do not automatically become issuer roles.
_Avoid_: AD group, operating-system permission

**Cookie session**:
The browser's issuer-managed access and refresh credentials, separate from the browser's cached Windows Authentication state.
_Avoid_: Windows logon session

**Refresh family**:
The lineage of rotating refresh credentials for one session or authorization. Reuse of a consumed credential revokes that lineage, including its active descendants.
_Avoid_: Independent reusable refresh token

**Embedded-host cookie bridge**:
The DAB application's boundary that consumes the issuer's browser credential and supplies a validated token to the DAB engine. Its compatibility and resource permissions are proved separately from issuer behavior.
_Avoid_: Issuer-hosted DAB, automatic DAB cookie support

**Local issuer proof**:
Evidence for the Windows caller-to-persisted-account-to-token/cookie chain on the development machine, with fixture and real-service results identified separately.
_Avoid_: IIS proof, production readiness

**Server environment evaluation**:
The later validation of delivered applications and runbooks on an identified Windows Server/IIS test environment.
_Avoid_: Local Kestrel proof, production rollout
