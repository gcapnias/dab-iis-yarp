# Integrated DAB Application

An application that provides end users access to the API described by its DAB configuration, using identities and access credentials supplied by a separate issuer.

## Language

**Configuration-driven DAB access**:
Access through the application to every REST and GraphQL endpoint enabled by DAB configuration, including configured operations and permissions. Configuration changes take effect after restarting the application, without recompiling it; MCP access is optional.
_Avoid_: Products-only integration, fixed-endpoint integration

**Configured resource permission**:
The access rule declared for a DAB resource, operation and role. An issuer role carried in a credential grants resource access only when the DAB application's validated caller and configured permission agree.
_Avoid_: Issuer login permission, automatic role access

**Requested resource role**:
The issuer role selected for an API request. Selection is valid only when the validated access credential contains that role; it does not create a role grant or override configured resource permissions.
_Avoid_: Client-granted role, role-header permission

**Local API proof**:
Evidence for configuration-driven REST and GraphQL behavior in the embedded application, using isolated data and explicitly identified permissions. It is separate from issuer interoperability and server environment evaluation.
_Avoid_: Complete security proof, production readiness

**Issuer interoperability proof**:
Evidence that the real Windows caller-to-persisted-issuer-account-to-browser-credential chain reaches the embedded application, where DAB validates the caller and enforces configured REST and GraphQL permissions. Controlled invalid-credential tests complement this live proof; neither part substitutes for server environment evaluation.
_Avoid_: Issuer-only proof, anonymous API proof

**Identity issuer**:
The separate application that binds an authenticated Windows caller to an issuer account and issues access credentials from its persisted profile and roles.
_Avoid_: DAB login service, DAB application

**Windows caller**:
The user authenticated for the current request by Windows Authentication, distinct from the account running the application.
_Avoid_: Worker identity, application-pool identity

**Worker identity**:
The operating-system account under which an issuer or embedded application's process runs, with access to that application's files and required services. It does not identify the Windows caller or grant that caller issuer roles or resource permissions.
_Avoid_: Caller identity, issuer account

**Deployment operator**:
The person authorized to prepare the test environment and provision application identities, credentials and access boundaries. Installation authority does not make the operator the application's runtime identity or its verification caller.
_Avoid_: Application user, administrator caller

**Issuer account**:
The locally persisted account explicitly mapped to a Windows caller, with an enabled state, profile, roles and permitted claims. A Windows identity alone does not grant issuer access.
_Avoid_: Automatically registered user, Windows group membership

**Profile**:
The issuer account's stable application identity and intended descriptive or authorization attributes. Profile attributes influence DAB access only through explicitly configured policies.
_Avoid_: Windows profile, directory record

**Issuer role**:
An operator-assigned role persisted for an issuer account and carried in its access credential. Windows groups do not automatically become issuer roles.
_Avoid_: AD group, operating-system permission

**Issuer store**:
The persisted issuer accounts, profiles, roles and credential-renewal state. It is separate from the resources exposed to callers through DAB.
_Avoid_: Northwind account store, API resource data

**DAB resource store**:
The data exposed through configured DAB resources and governed by configured resource permissions. Access to that data does not provision an issuer account or assign its roles.
_Avoid_: Identity database, login store

**Mutation fixture**:
Disposable resource data explicitly authorized for verification that creates, updates or deletes records. Successful fixture mutations do not authorize writes to the separately evaluated resource store.
_Avoid_: Northwind write proof, unrestricted test data

**Cookie session**:
The browser's issuer-managed access and refresh credentials, separate from the browser's cached Windows Authentication state. Ending that session removes browser credentials and revokes refresh access, but does not invalidate a copied access credential before its expiry.
_Avoid_: Windows logon session

**Refresh family**:
The lineage of rotating refresh credentials for one session or authorization. Reuse of a consumed credential revokes that lineage, including its active descendants.
_Avoid_: Independent reusable refresh token

**Embedded-host cookie bridge**:
The DAB application's boundary that adapts the issuer's browser credential for validation by the DAB engine. Transport adaptation does not authenticate the caller or grant resource permissions on its own.
_Avoid_: Issuer-hosted DAB, automatic DAB cookie support

**Browser API origin**:
The origin from which the browser makes requests to the embedded application's API; the issuer and API can share an origin while remaining separate applications. Cookie eligibility does not grant cross-origin access or permission to change resources.
_Avoid_: Shared-cookie authorization, cookie-derived origin permission

**Cookie mutation protection**:
The embedded application's requirement that a state-changing cookie request comes from its API origin and carries an antiforgery credential bound to the authenticated caller. A valid access credential alone does not satisfy that requirement.
_Avoid_: JWT-only CSRF protection, anonymous antiforgery validation

**Local issuer proof**:
Evidence for the Windows caller-to-persisted-account-to-token/cookie chain on the development machine, with fixture and real-service results identified separately.
_Avoid_: IIS proof, production readiness

**Server environment evaluation**:
Evidence that the delivered applications work in an identified Windows Server/IIS test environment, with its identities, permissions and acceptance scope stated explicitly.
_Avoid_: Local Kestrel proof, production rollout

**Deployment reproduction proof**:
Evidence that the delivered applications can be installed and verified in another empty test environment by following the documented procedure. A successful existing-server evaluation or reviewed installation guide does not alone establish this proof.
_Avoid_: Syntax-checked deployment, reviewed runbook as installation evidence
