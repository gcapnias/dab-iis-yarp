# Node.js application hosting through IIS: decision research

Research date: 2026-10-13. Status: HttpPlatformHandler design confirmed by the user in Q14; operator guide finalized, deployment not tested.

## Existing repository evidence

The existing `archive/research/` material contains no Node.js-specific hosting research. Its relevant IIS evidence concerns ASP.NET Core applications and embedded DAB, not a Node.js runtime.

- [Windows Server/IIS evaluation](../windows-server-iis/EVALUATION.md): an evaluated Windows Server 2025/IIS 10 topology with separate ASP.NET Core applications and ANCM in-process hosting. This establishes the documented .NET deployment result; it does not establish Node.js hosting or Node process recovery.
- [Archived YARP gateway guide](../../dab-using-yarp-reverse-proxy/dab-yarp-gateway-guide.md): describes proxying to a separate backend and explicitly distinguishes request forwarding from process supervision in section 18. Its proxy boundary is useful background for Node.js; its DAB-specific configuration cannot be copied as a Node.js runbook.
- [Archived DAB behind YARP guide](../../dab-using-yarp-reverse-proxy/dab-behind-yarp.md): describes an IIS-hosted gateway and an internal DAB application. It is an alternative design document, not evidence that Node.js was deployed or tested.
- [Existing DAB integration decision](../../../docs/adr/0001-conditional-same-process-dab-integration.md): records the chosen DAB embedding boundary. The new Node.js guidance does not revise that decision.

## Research added for this discussion

- [IIS-managed process options](iis-managed-options.md): HttpPlatformHandler and iisnode.
- [Reverse proxy and independently supervised process options](reverse-proxy-options.md): ARR/URL Rewrite, YARP, and Windows service supervision.
- [Component maintenance and support evidence](component-maintenance.md): Microsoft-published availability and support statements for HPH, ARR, and URL Rewrite, with exact-target compatibility limits.

These reports gather upstream contracts and maintenance evidence. They are not local deployment proofs.

## Confirmed scope

The user confirmed that this guidance concerns a standalone application, independent of the DAB/identity prototypes. The application is [Wiki.js](https://github.com/Requarks/wiki). Research must therefore check the stable Wiki.js installation contract and listener configuration before treating any generic Node.js hosting option as compatible.

The installed Wiki.js version is **v2.5.311**, as supplied by the user. The requested guidance also covers upgrading this existing installation to the latest stable **2.x** release; a move to the 3.x beta is not requested. The latest destination release must be verified when preparing the upgrade procedure. Earlier v2.5.316 source reviews are reference evidence, not a statement of the installed version.

The current installation starts through **Windows Task Scheduler**, with a task launching a batch file at Windows startup. The user confirmed that the upgrade and IIS hosting change should be separate maintenance steps: upgrade and verify the application first using the current launch arrangement, then change hosting.

Subsequent answers establish the current folder as `C:\wiki`, with batch commands `cd \`, `cd wiki`, and `node server`; Wiki.js currently listens natively on port 80. SQL Server is at `seesqldev3.dotsee.local:1519`. IIS is not yet installed on that machine. The user selected HttpPlatformHandler process ownership and the final IIS physical path **`C:\inetpub\www-wikijs`**, beside `wwwroot`. SQL database name, authentication details, Node executable/version, and task name remain operator inventory values.

The public URL remains **`https://docs.dot-see.dev/`**, reached through an existing Cloudflare Tunnel. The final IIS HTTPS origin will be **`https://seedocs.dotsee.local`**, using an already available certificate if it covers that name. These are intentionally different hostnames. Wiki.js's public Site URL and Google callback stay on the public `.dev` address; certificate validation and IIS origin routing use `.local`. The connector location and tunnel management mode remain to identify. The user approved planned downtime for both maintenance steps.

The upgrade research verifies [v2.5.316](https://github.com/Requarks/wiki-v2/releases/tag/v2.5.316) as the current stable 2.x destination. Its Windows artifact must be selected from the stable repository's explicit release. The old Windows upgrade documentation's moving `Requarks/wiki/releases/latest` download now points at the 3.x beta release line, so it must not be used for this 2.x upgrade.

The user excluded iisnode from consideration. Its historical comparison remains in the background report, but it is not a candidate for the implementation guide. The original `tjanczuk/iisnode` lineage and the Azure-owned repository mean that calling it purely third-party would overstate the provenance finding; the exclusion does not depend on resolving a support classification.

The target is Windows Server 2025 Standard with IIS. Google sign-in is required. Wiki.js owns the Google authentication integration, application session, and wiki permissions; IIS can provide HTTPS and forwarding. The [official Google provider documentation](https://docs.requarks.io/auth/google) describes enabling the strategy in Wiki.js and registering its generated callback URI with a Google OAuth client. IIS Windows Authentication is not the requested sign-in method.

The remaining runtime-hosting candidates are ARR plus URL Rewrite with an independently supervised Wiki.js process, an IIS-hosted YARP gateway with an independently supervised Wiki.js process, and HttpPlatformHandler with an adapted Wiki.js port configuration.

The user clarified the iisnode concern as its long interval without functional updates, recalling the analogous dependency/support question from the DAB project. This does not establish a blanket Microsoft-only component policy. The linked maintenance research records release status and documented support for the remaining components; HttpPlatformHandler was selected after that review.

The user also confirmed the reason for the different DAB hosting mechanism: the current integrated DAB application is an ASP.NET Core application. Its retained deployment uses ANCM in-process. Older archived alternative guides describe ANCM out-of-process; neither is a recorded HttpPlatformHandler choice. Wiki.js remains a Node.js application and needs its own process-management decision.

Wiki.js-specific follow-up reports:

- [Application requirements](wikijs-requirements.md).
- [IIS-managed compatibility](wikijs-iis-managed-compatibility.md).
- [Installed v2.5.311 source baseline](wikijs-v2.5.311-baseline.md).
- [Stable 2.x upgrade research](wikijs-v2-upgrade-research.md).
- [SQL Server backup and recovery](sqlserver-upgrade-recovery.md).
- [HttpPlatformHandler implementation contract](httpplatformhandler-implementation-contract.md).
- [Cloudflare Tunnel HTTPS origin](cloudflare-tunnel-iis-https.md).

## Decision prerequisites

Standalone Wiki.js scope is confirmed. Its stable runtime, database, installation format, and proxy requirements are the application-specific prerequisites for selecting a hosting approach.

Upgrade prerequisites still to establish are the exact task/batch-file locations, SQL database name and backup/restore method, and existing runtime/file/configuration state. The install directory, launch commands, SQL engine/address, two-step maintenance sequence, new IIS directory, and planned downtime are confirmed. No server modification or upgrade has been performed.

For a runtime server, the main architectural choice is who owns startup, shutdown, crash recovery, and reboot recovery: an IIS process handler or a separate service supervisor. Routing, authentication, application path, streaming/WebSockets, and deployment procedures depend on that choice and on the application's actual behavior.

The implementation guide is finalized for the architecture and behavior confirmed in Q14. It distinguishes source-derived settings from deployment proof and exposes remaining operator inventory values rather than inventing them. The unidentified tunnel management mode and connector placement are covered by explicit alternatives in the guide.

The user accepted HttpPlatformHandler as the IIS process owner in Q10. This selects the intended guidance architecture, not a tested deployment. The separate-service proxy options remain alternatives only if the selected arrangement fails its acceptance checks and the user chooses a different architecture.

The [operator guide](../../../docs/runbooks/wikijs-upgrade-and-iis-httpplatformhandler.md) combines the upgrade, SQL recovery, IIS/HPH, and Cloudflare origin procedures. The [accepted decision record](../../../docs/adr/0004-wikijs-httpplatformhandler-hosting.md) records the selected trade-off and final shared-understanding confirmation.

## Remaining hosting options

| Option | Who runs Wiki.js? | Reason to choose it | Trade-off to resolve |
| --- | --- | --- | --- |
| IIS + HttpPlatformHandler | IIS handler starts and manages the Node listener. | Keeps process management in the IIS deployment model, without a separate Node service supervisor. | Adapt Wiki.js's configured port to the handler-assigned environment variable; verify startup, recycle, shutdown, WebSockets, and Google callback behavior. |
| IIS + ARR / URL Rewrite | A separate Windows service supervisor. | Uses Wiki.js's normal fixed-port startup without a custom gateway application. | Select and assess the service supervisor and operate its lifecycle separately from IIS. |
| IIS-hosted ASP.NET Core / YARP gateway | A separate Windows service supervisor; ANCM manages the .NET gateway. | Offers code-owned routing and gateway policy if that customization is required. | Adds a .NET application and its deployment/runtime to the independently managed Wiki.js service. |

These are options, not selected implementations. See the linked primary-source reports for contracts and evidence limits. Microsoft's supported-downloads listings provide support signals for the IIS extensions but do not specifically certify these add-ons with Wiki.js on Windows Server 2025.
